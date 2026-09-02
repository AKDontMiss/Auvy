import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/services/podcast_service.dart';

import 'package:auvy/presentation/widgets/grouped_browse_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/podcast_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/density_provider.dart';

/// How far into an episode the listener got, and how long the episode actually
/// is. [durationMs] is 0 when it has never been played far enough for the engine
/// to report a length — callers fall back to the feed's advertised duration.
class EpisodeProgress {
  final int positionMs;
  final int durationMs;

  /// When this bookmark was last written (ms since epoch), 0 when unknown — a
  /// bookmark saved before timestamps were recorded. Used to pick the genuinely
  /// LAST-LISTENED episode for "Continue listening".
  final int updatedAtMs;

  const EpisodeProgress(this.positionMs, this.durationMs,
      [this.updatedAtMs = 0]);

  static const none = EpisodeProgress(0, 0);

  /// Milliseconds still to play, or null when the length isn't known well enough
  /// to say. Never returns a negative or absurd value: a stale bookmark past the
  /// end of a re-cut episode would otherwise render as a huge negative remainder.
  int? remainingMs(int feedDurationMs) {
    final total = durationMs > 0 ? durationMs : feedDurationMs;
    if (total <= 0 || positionMs <= 0 || positionMs >= total) return null;
    return total - positionMs;
  }
}

/// Saved per-episode bookmarks, the same ledger the player writes
/// (player_playback `auvy_podcast_positions`), keyed by `episode.id.hashCode`
///, and a podcast Song's id IS its streamUrl (see PodcastEpisode.toSong).
///
/// Two on-disk shapes are accepted. `{'p': ms, 'd': ms}` is current; a bare int
/// is a bookmark saved before episode lengths were recorded, and is read as a
/// position with an unknown duration so upgrading doesn't wipe existing progress.
///
/// autoDispose so every open re-reads the latest listening progress.
final podcastPositionsProvider =
    FutureProvider.autoDispose<Map<String, EpisodeProgress>>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('auvy_podcast_positions');
  if (raw == null) return const {};
  try {
    return Map<String, dynamic>.from(jsonDecode(raw) as Map).map((k, v) {
      if (v is int) return MapEntry(k, EpisodeProgress(v, 0));
      if (v is Map) {
        final p = v['p'];
        final d = v['d'];
        final t = v['t'];
        return MapEntry(
            k,
            EpisodeProgress(
                p is int ? p : 0, d is int ? d : 0, t is int ? t : 0));
      }
      return MapEntry(k, EpisodeProgress.none);
    });
  } catch (_) {
    return const {};
  }
});

/// Podcasts — discovery grid + episode browser.
///
/// Redesign notes: solid panels only (the old episode sheet ran a sigma-40
/// BackdropFilter on every scroll frame), skeleton loaders instead of a bare
/// spinner, topic chips over the personalized "For You" feed, and real
/// error/empty states with a retry.
// Pure string helpers, top-level because the episode sheet (also top-level so
// the player page can reuse it) renders with them.
String _cleanPodcastTitle(String rawTitle) {
  try {
    String decoded = rawTitle;
    // Only decode if it's safe, preventing the scrolling crash!
    if (decoded.contains('%')) {
      try { decoded = Uri.decodeFull(decoded.replaceAll('+', ' ')); } catch(_) {}
    } else {
      decoded = decoded.replaceAll('+', ' ');
    }

    return decoded
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  } catch (_) {
    return rawTitle;
  }
}

/// "Mon, 07 Jul 2026 10:00:00 +0000" → "07 Jul 2026".
String _cleanPodcastDate(String rawDate) {
  return rawDate
      .replaceAll(RegExp(r'\s*([+-]\d{4}|[A-Z]{3,4})\s*$'), '')
      .replaceAll(RegExp(r'^\s*[A-Za-z]{3},\s*'), '')
      .replaceAll(RegExp(r'\s*\d{1,2}:\d{2}(:\d{2})?\s*$'), '')
      .trim();
}

/// itunes:duration ("3600", "mm:ss" or "hh:mm:ss") → total milliseconds
/// (0 when unparseable). Used to size the resume-progress bar.
int _episodeDurationMs(String raw) {
  final r = raw.trim();
  if (r.isEmpty) return 0;
  int seconds = 0;
  if (r.contains(':')) {
    final parts = r.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    if (parts.length == 3) {
      seconds = parts[0] * 3600 + parts[1] * 60 + parts[2];
    } else if (parts.length == 2) {
      seconds = parts[0] * 60 + parts[1];
    }
  } else {
    seconds = int.tryParse(r) ?? 0;
  }
  return seconds * 1000;
}

/// Show-notes HTML → a plain-text snippet for the episode row.
String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// itunes:duration comes as raw seconds ("3600"), "mm:ss" or "hh:mm:ss".
String _formatEpisodeDuration(String raw) {
  final r = raw.trim();
  if (r.isEmpty) return '';
  int seconds = 0;
  if (r.contains(':')) {
    final parts = r.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    if (parts.length == 3) {
      seconds = parts[0] * 3600 + parts[1] * 60 + parts[2];
    } else if (parts.length == 2) {
      seconds = parts[0] * 60 + parts[1];
    }
  } else {
    seconds = int.tryParse(r) ?? 0;
  }
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '$h hr $m min';
  if (m > 0) return '$m min';
  return '${seconds}s';
}

class PodcastPage extends ConsumerStatefulWidget {
  const PodcastPage({Key? key}) : super(key: key);

  @override
  ConsumerState<PodcastPage> createState() => _PodcastPageState();
}

class _PodcastPageState extends ConsumerState<PodcastPage> {
  final TextEditingController _searchController = TextEditingController();

  /// Podcast searches are kept apart from music searches — see
  /// SearchService._historyPrefix for why the scopes cannot share a prefix.
  static const String _historyScope = 'podcast';

  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Recent searches are shown only while the field has focus, so this State
    // has to rebuild when focus changes — reading hasFocus does not subscribe.
    _searchFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onFocusChanged);
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _setQuery(String query) {
    ref.read(podcastSearchQueryProvider.notifier).state = query;
    setState(() {});
  }

  /// Run a query and remember it.
  void _submitQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _setQuery(q);
    recordScopedSearch(ref, _historyScope, q);
    _searchFocusNode.unfocus();
  }

  /// Recent podcast searches, shown only while the search field is focused.
  ///
  /// FOCUS-GATED, LIKE THE MUSIC PAGE. The directory below is the point of
  /// this page; a history list pinned above it would push the genre sections down
  /// on every visit for something the user only wants while typing.
  Widget _buildRecentPodcastSearches(Color themeColor) {
    if (!_searchFocusNode.hasFocus) return const SizedBox.shrink();
    final recent =
        ref.watch(scopedSearchHistoryProvider(_historyScope)).asData?.value ??
            const <String>[];
    if (recent.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text('Recent searches',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1)),
        ),
        for (final q in recent.take(6))
          InkWell(
            onTap: () {
              _searchController.text = q;
              _submitQuery(q);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
              child: Row(
                children: [
                  Icon(Icons.history_rounded,
                      size: 18, color: Colors.white.withOpacity(0.35)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(q,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500)),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => removeScopedSearch(ref, _historyScope, q),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close_rounded,
                          size: 15, color: Colors.white.withOpacity(0.4)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
          child: Divider(color: Colors.white.withOpacity(0.07), height: 1),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final showsAsync = ref.watch(podcastShowsProvider);
    final themeColor = ref.watch(themeProvider);
    final activeQuery = ref.watch(podcastSearchQueryProvider);

    return BrowseHubScaffold(
      title: 'Podcasts',
      // Mirrors the radio hub: say how much the directory holds so a page of
      // collapsed rows does not read as empty.
      subtitle: '${_browseGenres.length} genres · tap one to open it',
      accent: themeColor,
      onRefresh: () async {
        ref.invalidate(podcastShowsProvider);
        try { await ref.read(podcastShowsProvider.future); } catch (_) {}
      },
      onCollapseAll: () => setState(_openGenres.clear),
      canCollapse: _openGenres.isNotEmpty,
      searchField: AuvySearchField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        hint: 'Search podcasts',
        height: 48,
        radius: 24,
        fontSize: 14.5,
        textInputAction: TextInputAction.search,
        trailing: _searchController.text.isEmpty
            ? null
            : IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white38, size: 18),
                onPressed: () {
                  HapticService.selection();
                  _searchController.clear();
                  _setQuery('');
                },
              ),
        onSubmitted: _submitQuery,
      ),
      // Recent searches sit ABOVE the directory and collapse to nothing when the
      // field is not focused, so the page looks exactly as before until the user
      // actually taps into the search box.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildRecentPodcastSearches(themeColor),
          Expanded(child: _buildBody(themeColor, activeQuery, showsAsync)),
        ],
      ),
    );
  }

  /// Two states:
  ///   1. a typed query → flat search results
  ///   2. otherwise     → the sectioned directory
  ///
  /// The genre CHIPS were removed: the sections already are the genre
  /// breakdown, so the chips were a second, flatter route to the same content
  /// and the two could disagree about what you were looking at. (Radio keeps
  /// its chips — there the sections are countries and the chips are genres, so
  /// they are different axes.)
  Widget _buildBody(
      Color themeColor, String activeQuery, AsyncValue<List<PodcastShow>> showsAsync) {
    if (activeQuery.isNotEmpty) {
      return showsAsync.when(
        // Without this every keystroke swapped the results for a full-page grey
        // skeleton — the "whole page flashes" report.
        skipLoadingOnReload: true,
        loading: () => const _PodcastSkeletonGrid(),
        error: (err, stack) => const BrowseHubStatus(
          icon: Icons.cloud_off_rounded,
          title: "Couldn't load podcasts",
          subtitle: 'Check your connection and try again.',
        ),
        data: (shows) {
          if (shows.isEmpty) {
            return const BrowseHubStatus(
              icon: Icons.podcasts_rounded,
              title: 'No podcasts found',
              subtitle: 'Try a different search.',
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(top: 6, bottom: 180),
            itemCount: shows.length,
            itemBuilder: (context, i) =>
                _PodcastRow(show: shows[i], themeColor: themeColor),
          );
        },
      );
    }

    return _buildGenreBrowser(themeColor);
  }



  // Genre browser
  //
  // The radio hub groups by country; podcasts have no country, so the same
  // layout groups by GENRE. Countries come free with the station list, but there
  // is no "all podcasts" endpoint to group — each genre is its own search.
  //
  // So sections load LAZILY: opening one fetches it, and the result is kept for
  // the life of the page. Fetching all of them up front would be ~20 searches to
  // fill a screen that shows two.
  /// Apple's own podcast categories — the service maps each to a chart id.
  /// Using their taxonomy means a section is the REAL top of that category,
  /// not whatever a keyword search returned.
  static List<String> get _browseGenres =>
      PodcastService.genreIds.keys.toList()..sort();

  final Set<String> _openGenres = {};
  final Map<String, List<PodcastShow>> _genreShows = {};
  final Set<String> _loadingGenres = {};

  Future<void> _loadGenre(String genre) async {
    if (_genreShows.containsKey(genre) || _loadingGenres.contains(genre)) return;
    setState(() => _loadingGenres.add(genre));
    try {
      // getTopByGenre falls back to a search internally if the chart is
      // unavailable, so this still returns something on a bad day.
      final shows =
          await ref.read(podcastServiceProvider).getTopByGenre(genre);
      if (!mounted) return;
      setState(() {
        _genreShows[genre] = shows;
        _loadingGenres.remove(genre);
      });
    } catch (_) {
      if (!mounted) return;
      // Cache the empty result too, or reopening retries forever on a dead
      // network and the section spins each time.
      setState(() {
        _genreShows[genre] = const [];
        _loadingGenres.remove(genre);
      });
    }
  }


  Widget _buildGenreBrowser(Color themeColor) {
    // NO AUTO-EXPAND. This used to open the first genre on arrival so the
    // page had content immediately. In practice it pre-empted the choice: you
    // land on Arts expanded, have to collapse it to see the directory, and the
    // section you actually wanted is pushed off-screen behind 60 rows you did
    // not ask for. A closed directory is the honest starting point.
    final groups = <BrowseGroup>[
      for (final genre in _browseGenres)
        BrowseGroup(
          key: genre,
          title: genre,
          // Unknown until it has been opened once — a fabricated number would
          // be worse than none.
          count: _genreShows[genre]?.length ?? 0,
          loading: _loadingGenres.contains(genre),
          buildItems: () => [
            for (final show in (_genreShows[genre] ?? const <PodcastShow>[]))
              _PodcastRow(show: show, themeColor: themeColor),
          ],
        ),
    ];

    return GroupedBrowseView(
      groups: groups,
      expanded: _openGenres,
      accent: themeColor,
      onToggle: (k) {
        setState(() {
          if (!_openGenres.remove(k)) _openGenres.add(k);
        });
        if (_openGenres.contains(k)) _loadGenre(k);
      },
    );
  }



}

// Episode browser sheet
// Top-level so the player page can reopen the picker for the playing show
// (podcast title tap) without duplicating the sheet.
/// Exact clock time for a millisecond span — "8:04", or "1:12:30" past an hour.
///
/// Episode times are deliberately NOT rounded to minutes anywhere in this page.
/// The old row said "45 min left" for anything from 44:01 to 45:00, which reads
/// as wrong when the player is showing you the real number a second later.
String _exactSpan(int ms) {
  final total = (ms / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Opens a show as a PAGE rather than a bottom sheet.
///
/// It was a DraggableScrollableSheet, which was the wrong container for this
/// content: episode show-notes are long, a sheet fights the scroll gesture with
/// its own drag-to-dismiss, and it could never carry a proper header. As a real
/// route it also gets the app's standard transition and back behaviour, and it
/// matches how albums and playlists already open.
///
/// [fromRootRoute] is for callers that live on the ROOT navigator — the
/// full-screen player, which must route onto the active tab instead so the page
/// lands in the right back stack (see AppNavigation.pushOnActiveTab).
void openPodcastShow(BuildContext context, PodcastShow show, Color themeColor,
    {bool fromRootRoute = false}) {
  final page = PodcastShowPage(show: show, themeColor: themeColor);
  final name = 'podcast-show:${show.collectionName}';
  if (fromRootRoute) {
    AppNavigation.pushOnActiveTab(page, name: name);
  } else {
    AppNavigation.push(context, page, name: name);
  }
}

/// A podcast show: artwork hero, follow/play actions, and the episode list where
/// each episode can be read before it is played.
class PodcastShowPage extends ConsumerStatefulWidget {
  final PodcastShow show;
  final Color themeColor;
  const PodcastShowPage(
      {super.key, required this.show, required this.themeColor});

  @override
  ConsumerState<PodcastShowPage> createState() => _PodcastShowPageState();
}

class _PodcastShowPageState extends ConsumerState<PodcastShowPage> {
  String _query = '';
  // Which episodes have their show-notes open. Keyed by streamUrl (stable and
  // unique per episode) rather than list index, which shifts as you search.
  final Set<String> _openNotes = {};

  void _play(PodcastEpisode ep) {
    HapticService.medium();
    ref.read(playerProvider.notifier).playSong(
          ep.toSong(),
          newQueue: [],
          index: 0,
          isManual: true,
          source: "Podcast",
          contextType: "podcast",
          contextTitle: widget.show.collectionName,
        );
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final themeColor = widget.themeColor;
    final episodesAsync = ref.watch(podcastEpisodesProvider(show));
    final progress = ref.watch(podcastPositionsProvider).asData?.value ??
        const <String, EpisodeProgress>{};

    EpisodeProgress progressOf(PodcastEpisode ep) =>
        progress[ep.streamUrl.hashCode.toString()] ?? EpisodeProgress.none;

    // The shared backdrop, like every other page — a flat #0B0B0E Scaffold made
    // this the one page in the app with its own background.
    return DynamicBackground(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            // A SCRIM behind the pinned bar, not a solid colour.
            //
            // The bar keeps the show name visible while you scroll, but with a
            // fully transparent background the episode cards slid straight under
            // the title and the two became unreadable on top of each other. A
            // solid fill would fix that and lose the shared DynamicBackground
            // this page now sits on, so this fades from near-black at the top to
            // transparent at the bar's bottom edge: the title always has
            // something behind it, and the backdrop still shows through.
            flexibleSpace: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.92),
                    Colors.black.withOpacity(0.80),
                    Colors.black.withOpacity(0.0),
                  ],
                  stops: const [0.0, 0.62, 1.0],
                ),
              ),
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: () => Navigator.maybePop(context),
            ),
            title: Text(
              show.collectionName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700),
            ),
          ),
          SliverToBoxAdapter(
            child: _ShowHero(
              show: show,
              themeColor: themeColor,
              episodesAsync: episodesAsync,
              onPlayLatest: (ep) => _play(ep),
            ),
          ),

          // SEARCH SITS ABOVE "Continue listening" on purpose. Below it, with a
          // hero, a follow button and a resume card competing above, it was
          // routinely missed, and a show with 300 episodes is unusable without
          // it. Brighter fill and border for the same reason.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: AuvySearchField(
                hint: 'Search episodes',
                height: 50,
                radius: 25,
                fontSize: 15,
                iconSize: 22,
                fillColor: const Color(0x1FFFFFFF),
                borderColor: const Color(0x33FFFFFF),
                hintColor: Colors.white.withOpacity(0.55),
                onChanged: (val) => setState(() => _query = val),
              ),
            ),
          ),
          // Pick up where the listener left off, without hunting the list for the
          // one episode with a half-filled bar.
          SliverToBoxAdapter(
            child: episodesAsync.maybeWhen(
              data: (eps) {
                // The episode you were LAST LISTENING TO, not the newest one you
                // happen to have started. Taking the first in-progress episode in
                // feed order meant starting a brand-new episode for a minute
                // buried the one you were 40 minutes into.
                PodcastEpisode? resume;
                int bestAt = -1;
                for (final ep in eps) {
                  final p = progressOf(ep);
                  if (p.positionMs <= 0) continue;
                  // Bookmarks written before timestamps existed report 0; they
                  // still beat "nothing", and lose to any timestamped one.
                  if (p.updatedAtMs > bestAt) {
                    bestAt = p.updatedAtMs;
                    resume = ep;
                  }
                }
                if (resume == null) return const SizedBox.shrink();
                return _ContinueCard(
                  episode: resume,
                  progress: progressOf(resume),
                  themeColor: themeColor,
                  onResume: () => _play(resume!),
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
          ),


          episodesAsync.when(
            loading: () => const _EpisodeSkeletonList(),
            // _StatusSliver has always had a retry button and NOTHING ever
            // passed one — the analyzer had been reporting actionLabel/onAction
            // as never-supplied. A failed feed fetch is the one place it
            // obviously belongs: the usual cause is a momentary network blip,
            // and without this the only way to retry is to leave the page and
            // come back.
            error: (e, _) => _StatusSliver(
              icon: Icons.error_outline_rounded,
              title: "Couldn't load episodes",
              subtitle: "The feed may be temporarily unavailable.",
              actionLabel: "Retry",
              onAction: () => ref.invalidate(podcastEpisodesProvider(show)),
            ),
            data: (episodes) {
              if (episodes.isEmpty) {
                return const _StatusSliver(
                  icon: Icons.podcasts_rounded,
                  title: "No episodes found",
                );
              }
              final q = _query.trim().toLowerCase();
              // Search the show-notes too, not just titles: an episode is far
              // more often remembered by who was on it than by its title.
              final filtered = q.isEmpty
                  ? episodes
                  : episodes
                      .where((ep) =>
                          ep.title.toLowerCase().contains(q) ||
                          _stripHtml(ep.description).toLowerCase().contains(q))
                      .toList();
              if (filtered.isEmpty) {
                return const _StatusSliver(
                  icon: Icons.search_off_rounded,
                  title: "No matching episodes",
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final ep = filtered[index];
                    return _EpisodeCard(
                      date: _cleanPodcastDate(ep.pubDate).toUpperCase(),
                      title: _cleanPodcastTitle(ep.title),
                      rowId: ep.streamUrl,
                      showName: show.collectionName,
                      duration: _formatEpisodeDuration(ep.duration),
                      description: _stripHtml(ep.description),
                      progress: progressOf(ep),
                      feedDurationMs: _episodeDurationMs(ep.duration),
                      isNewest: index == 0 && q.isEmpty,
                      notesOpen: _openNotes.contains(ep.streamUrl),
                      themeColor: themeColor,
                      onToggleNotes: () => setState(() {
                        if (!_openNotes.remove(ep.streamUrl)) {
                          _openNotes.add(ep.streamUrl);
                        }
                      }),
                      onPlay: () => _play(ep),
                    );
                  },
                  childCount: filtered.length,
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
      ),
    );
  }
}

// Page widgets

class _PodcastSkeletonGrid extends StatelessWidget {
  const _PodcastSkeletonGrid();

  @override
  Widget build(BuildContext context) {
    // A BOX, NOT A SLIVER — same bug as _RadioSkeletonGrid. This returned a
    // SliverPadding, correct when the page was a CustomScrollView; after the
    // conversion to a Column it threw "A RenderFlex expected a child of type
    // RenderBox" on every load. It also now mirrors the ROW list it stands in
    // for rather than the grid the page no longer uses.
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 120),
      itemCount: 8,
      itemBuilder: (context, i) => const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            SkeletonLoader(width: 52, height: 52, borderRadius: 10),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLoader(width: 180, height: 12, borderRadius: 6),
                  SizedBox(height: 7),
                  SkeletonLoader(width: 100, height: 10, borderRadius: 5),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared empty/error sliver with an optional action button.
class _StatusSliver extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StatusSliver({
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white24, size: 44),
              const SizedBox(height: 14),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w700)),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(subtitle!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13, height: 1.4)),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                OutlinedButton(
                  onPressed: () {
                    HapticService.selection();
                    onAction!();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.25)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  ),
                  child: Text(actionLabel!,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Episode sheet widgets

/// Show identity and the two things you want first: play the newest episode, or
/// follow. Replaces the old sheet header — no drag handle, because this is a page.
class _ShowHero extends StatelessWidget {
  final PodcastShow show;
  final Color themeColor;
  final AsyncValue<List<PodcastEpisode>> episodesAsync;
  final void Function(PodcastEpisode) onPlayLatest;

  const _ShowHero({
    required this.show,
    required this.themeColor,
    required this.episodesAsync,
    required this.onPlayLatest,
  });

  @override
  Widget build(BuildContext context) {
    final PodcastEpisode? latest = episodesAsync.maybeWhen(
      data: (eps) => eps.isNotEmpty ? eps.first : null,
      orElse: () => null,
    );
    final String countLabel = episodesAsync.maybeWhen(
      data: (eps) => eps.length == 1 ? "1 episode" : "${eps.length} episodes",
      orElse: () => "Loading episodes…",
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: AuvyImage(
                    path: show.artworkUrl,
                    width: 116,
                    height: 116,
                    borderRadius: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      show.collectionName,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          height: 1.22),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      show.artistName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: themeColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(Icons.podcasts_rounded,
                            size: 12, color: Colors.white.withOpacity(0.30)),
                        const SizedBox(width: 5),
                        Text(countLabel,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              // Disabled until the feed has loaded — a play button that silently
              // does nothing reads as a broken page.
              Expanded(
                child: GestureDetector(
                  onTap: latest == null ? null : () => onPlayLatest(latest),
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: latest == null
                          ? Colors.white.withOpacity(0.08)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded,
                            size: 20,
                            color: latest == null
                                ? Colors.white.withOpacity(0.35)
                                : Colors.black),
                        const SizedBox(width: 5),
                        Text(
                          'Play latest',
                          style: TextStyle(
                            color: latest == null
                                ? Colors.white.withOpacity(0.66)
                                : Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _FollowButton(show: show, themeColor: themeColor)),
            ],
          ),
        ],
      ),
    );
  }
}

class _FollowButton extends ConsumerWidget {
  final PodcastShow show;
  final Color themeColor;
  const _FollowButton({required this.show, required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFollowing = ref.watch(
        libraryProvider.select((s) => s.likedAlbums.any((a) => a.title == show.collectionName)));

    return GestureDetector(
      onTap: () async {
        HapticService.medium();
        final dummyAlbum = Album(
            id: show.feedUrl,
            title: show.collectionName,
            image: show.artworkUrl,
            releaseDate: '',
            recordType: 'podcast');
        final notifier = ref.read(libraryProvider.notifier);
        if (isFollowing) {
          notifier.toggleAlbumLike(dummyAlbum, show.artistName);
          AnimatedToast.show(context,
              text: "Unfollowed", icon: Icons.bookmark_border_rounded, color: themeColor);
        } else {
          notifier.toggleAlbumLike(dummyAlbum, show.artistName);
          AnimatedToast.show(context,
              text: "Following ${show.collectionName}",
              icon: Icons.bookmark_rounded,
              color: themeColor);
          try {
            final episodes = await ref.read(podcastEpisodesProvider(show).future);
            notifier.updateAlbumTracks(
                show.collectionName, episodes.map((e) => e.toSong()).toList());
          } catch (e) {
            print("Error fetching episodes for library sync: $e");
          }
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 44,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isFollowing ? Colors.transparent : themeColor,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isFollowing ? Colors.white.withOpacity(0.25) : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFollowing ? Icons.check_rounded : Icons.add_rounded,
              size: 17,
              color: isFollowing ? Colors.white : Colors.black,
            ),
            const SizedBox(width: 7),
            Text(
              isFollowing ? "Following" : "Follow",
              style: TextStyle(
                color: isFollowing ? Colors.white : Colors.black,
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The episode already in progress, lifted out of the list so resuming doesn't
/// require scrolling for the one row with a half-filled bar.
class _ContinueCard extends StatelessWidget {
  final PodcastEpisode episode;
  final EpisodeProgress progress;
  final Color themeColor;
  final VoidCallback onResume;

  const _ContinueCard({
    required this.episode,
    required this.progress,
    required this.themeColor,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final int feedMs = _episodeDurationMs(episode.duration);
    final int total = progress.durationMs > 0 ? progress.durationMs : feedMs;
    final int? left = progress.remainingMs(feedMs);
    final double frac =
        total > 0 ? (progress.positionMs / total).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: const Color(0xFF17171C),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: themeColor.withOpacity(0.32), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.headphones_rounded, size: 13, color: themeColor),
                const SizedBox(width: 6),
                Text(
                  'CONTINUE LISTENING',
                  style: TextStyle(
                      color: themeColor,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _cleanPodcastTitle(episode.title),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.3),
            ),
            const SizedBox(height: 13),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 5,
                child: LinearProgressIndicator(
                  value: frac,
                  backgroundColor: Colors.white.withOpacity(0.10),
                  valueColor: AlwaysStoppedAnimation(themeColor),
                ),
              ),
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(
                  child: Text(
                    left != null
                        ? '${_exactSpan(progress.positionMs)} played  ·  ${_exactSpan(left)} left'
                        : '${_exactSpan(progress.positionMs)} played',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: onResume,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                    decoration: BoxDecoration(
                        color: themeColor,
                        borderRadius: BorderRadius.circular(20)),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded,
                            color: Colors.black, size: 18),
                        SizedBox(width: 3),
                        Text('Resume',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One episode: what it is, how far in you are, and its notes on demand.
class _EpisodeCard extends StatelessWidget {
  final String date;
  final String title;
  /// The episode's player id — `streamUrl`, which is what `toSong()` uses — so
  /// the one being listened to is marked like a track row anywhere else.
  final String rowId;
  /// The show name, so a title-only match can never confuse an episode with a
  /// song of the same name.
  final String showName;
  final String duration;
  final String description;
  final EpisodeProgress progress;

  /// Length advertised by the feed's `<itunes:duration>`. Used only when the
  /// engine has never reported a real one. See [EpisodeProgress].
  final int feedDurationMs;
  final bool isNewest;
  final bool notesOpen;
  final Color themeColor;
  final VoidCallback onToggleNotes;
  final VoidCallback onPlay;

  const _EpisodeCard({
    required this.date,
    required this.title,
    required this.rowId,
    required this.showName,
    required this.duration,
    required this.description,
    required this.progress,
    required this.feedDurationMs,
    required this.isNewest,
    required this.notesOpen,
    required this.themeColor,
    required this.onToggleNotes,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final bool inProgress = progress.positionMs > 0;
    final int total =
        progress.durationMs > 0 ? progress.durationMs : feedDurationMs;
    final int? left = progress.remainingMs(feedDurationMs);
    final double frac = (inProgress && total > 0)
        ? (progress.positionMs / total).clamp(0.0, 1.0)
        : 0.0;

    // EXACT times, never rounded to whole minutes, and never the position
    // masquerading as the remainder when the length is unknown.
    final String status = !inProgress
        ? (duration.isNotEmpty ? duration : 'Play episode')
        : left != null
            ? '${_exactSpan(progress.positionMs)} played  ·  ${_exactSpan(left)} left'
            : '${_exactSpan(progress.positionMs)} played';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      // Tapping the card reads, it does NOT play.
      //
      // The card used to start playback anywhere you touched it. That solved the
      // small-target problem and created a worse one: an hour-long episode
      // starts on a stray tap while you are scrolling or reaching for the
      // overview, replacing whatever you were already listening to. Playing is
      // now exclusively the play button, which is large and pinned to the right
      // where a thumb lands; the card's own tap opens the overview, so the big
      // hit area still does something useful and nothing irreversible.
      child: GestureDetector(
        onTap: description.isNotEmpty ? onToggleNotes : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF141418),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: inProgress
                  ? themeColor.withOpacity(0.20)
                  : Colors.white.withOpacity(0.06)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // No "LATEST" badge: episodes are already ordered newest-first,
                // so the top row IS the latest and the tag only repeated what
                // position already said.
                Expanded(
                  child: Text(
                    date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: themeColor.withOpacity(0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                if (duration.isNotEmpty && inProgress)
                  Text(
                    duration,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            NowPlayingTitle(
              title: title,
              rowId: rowId,
              artist: showName,
              maxLines: notesOpen ? 4 : 2,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15.5,
                  height: 1.3),
            ),
            if (inProgress) ...[
              const SizedBox(height: 11),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: frac,
                    backgroundColor: Colors.white.withOpacity(0.10),
                    valueColor:
                        AlwaysStoppedAnimation(themeColor.withOpacity(0.85)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            // Overview LEFT, play RIGHT. Reading and playing are opposite kinds
            // of action and they now sit at opposite ends, so neither is ever
            // hit by mistake while reaching for the other.
            Row(
              children: [
                // Notes stay COLLAPSED by default on purpose. Podcast feeds
                // overwhelmingly repeat the same sponsor/subscribe boilerplate in
                // every episode's <description>, so showing them inline made every
                // row read identically and doubled the list height. Behind a toggle,
                // the overview is there when you want to know what an episode is
                // before committing an hour to it, and out of the way when scanning.
                if (description.isNotEmpty)
                  GestureDetector(
                    onTap: onToggleNotes,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                      child: Row(
                        children: [
                          Text(
                            notesOpen ? 'Hide' : 'Overview',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 12,
                                fontWeight: FontWeight.w700),
                          ),
                          Icon(
                            notesOpen
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: Colors.white.withOpacity(0.45),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: inProgress
                            ? themeColor
                            : Colors.white.withOpacity(0.72),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 10),
                // The ONLY thing that starts an episode. 46px with an opaque hit
                // test — comfortably past the 44px minimum touch target, and the
                // easiest thing on the card to hit rather than the hardest.
                GestureDetector(
                  onTap: onPlay,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 26),
                  ),
                ),
              ],
            ),
            if (notesOpen && description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: Colors.white.withOpacity(0.07), height: 1),
              const SizedBox(height: 12),
              Text(
                description,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.78),
                  fontSize: 13,
                  height: 1.55,
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

class _EpisodeSkeletonList extends StatelessWidget {
  const _EpisodeSkeletonList();

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLoader(width: 90, height: 10, borderRadius: 5),
              SizedBox(height: 10),
              SkeletonLoader(width: double.infinity, height: 15, borderRadius: 6),
              SizedBox(height: 6),
              SkeletonLoader(width: 200, height: 15, borderRadius: 6),
              SizedBox(height: 14),
              SkeletonLoader(width: 34, height: 34, borderRadius: 17),
              SizedBox(height: 16),
            ],
          ),
        ),
        childCount: 5,
      ),
    );
  }
}

// Podcast ROW
// A section is a list, not a grid: inside an expandable genre, rows read
// top-to-bottom and keep each show's title readable at full width.
class _PodcastRow extends StatelessWidget {
  final PodcastShow show;
  final Color themeColor;
  const _PodcastRow({required this.show, required this.themeColor});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticService.light();
        FocusScope.of(context).unfocus();
        openPodcastShow(context, show, themeColor);
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // Hand-built row: the ListTile theme funnel cannot reach it, so it
// reads the density setting directly.
        padding: EdgeInsets.fromLTRB(
            20, 4 + densityNow.rowVerticalPadding, 14,
            4 + densityNow.rowVerticalPadding),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AuvyImage(
                path: show.artworkUrl,
                width: densityNow.artwork(52),
                height: densityNow.artwork(52),
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    show.collectionName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    show.artistName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withOpacity(0.25), size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

