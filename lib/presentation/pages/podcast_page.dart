import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/services/podcast_service.dart';

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
import 'package:auvy/presentation/widgets/interactive_pressable.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/presentation/widgets/hub_kit.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/whats_new_logic.dart';
import 'package:auvy/providers/whats_new_provider.dart';

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

/// Saved per-episode bookmarks, the same ledger the player writes (player_playback
/// `auvy_podcast_positions`), keyed by `episode.id.hashCode` (a podcast Song's id is
/// its streamUrl; see PodcastEpisode.toSong).
///
/// Two formats: `{'p': ms, 'd': ms}` is current; a bare int is an older bookmark
/// without a duration, read as a position with unknown length.
///
/// autoDispose so every open re-reads the latest progress.
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

/// Cleans a podcast title for display.
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

/// Podcasts: the listener's own listening first (episodes in progress, followed
/// shows, their new episodes), then the charts and categories to find more, and
/// search. A show opens on its own page.
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
    _migratePins();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// Pins were a second, separate list of favourite shows next to following.
  /// They are follows now: pins left from an older version become followed
  /// shows, once.
  Future<void> _migratePins() async {
    final pins = await ref.read(pinnedPodcastsProvider.notifier).loaded();
    if (pins.isEmpty || !mounted) return;
    final lib = ref.read(libraryProvider.notifier);
    var added = 0;
    for (final show in pins) {
      final followed = ref.read(libraryProvider).likedAlbums.any((a) =>
          a.recordType == 'podcast' && (a.id == show.feedUrl || a.title == show.collectionName));
      if (followed || show.feedUrl.isEmpty) continue;
      lib.toggleAlbumLike(
          Album(id: show.feedUrl, title: show.collectionName, image: show.artworkUrl,
              releaseDate: '', recordType: 'podcast'),
          show.artistName);
      added++;
    }
    await ref.read(pinnedPodcastsProvider.notifier).clear();
    print('podcasts: ${pins.length} pinned show(s) moved to followed ($added newly followed)');
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

  /// Recent podcast searches, shown only while the search field is focused, as on the
  /// music search page.
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
                  Semantics(
                    label: 'Remove from recent searches',
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => removeScopedSearch(ref, _historyScope, q),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.close_rounded,
                            size: 15, color: Colors.white.withOpacity(0.4)),
                      ),
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
    final themeColor = ref.watch(themeProvider);
    final activeQuery = ref.watch(podcastSearchQueryProvider);

    return BrowseHubScaffold(
      title: 'Podcasts',
      subtitle: 'Your shows, new episodes and the charts',
      accent: themeColor,
      onRefresh: () async {
        if (activeQuery.isNotEmpty) {
          ref.invalidate(podcastShowsProvider);
          try { await ref.read(podcastShowsProvider.future); } catch (_) {}
        } else {
          ref.invalidate(topPodcastsProvider);
          ref.invalidate(podcastPositionsProvider);
          try { await ref.read(topPodcastsProvider.future); } catch (_) {}
        }
      },
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
                tooltip: 'Clear search',
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildRecentPodcastSearches(themeColor),
          Expanded(
            child: activeQuery.isNotEmpty
                ? _SearchResults(themeColor: themeColor)
                : _PodcastHome(themeColor: themeColor),
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  final Color themeColor;
  const _SearchResults({required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showsAsync = ref.watch(podcastShowsProvider);
    return showsAsync.when(
      // Without this every keystroke swapped the results for a full-page grey
      // skeleton.
      skipLoadingOnReload: true,
      loading: () => const HubRowsSkeleton(),
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
          itemBuilder: (context, i) => _PodcastRow(show: shows[i], themeColor: themeColor),
        );
      },
    );
  }
}

/// The hub without a search: what the listener follows and is in the middle
/// of, then ways to find more.
class _PodcastHome extends ConsumerWidget {
  final Color themeColor;
  const _PodcastHome({required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followed = ref.watch(libraryProvider.select((l) => [
          for (final a in l.likedAlbums)
            if (a.recordType == 'podcast')
              PodcastShow(
                  collectionName: a.title,
                  artistName: a.artist,
                  artworkUrl: a.image,
                  feedUrl: a.id),
        ]));
    final whatsNew = ref.watch(whatsNewProvider);
    final newEpisodes = [
      for (final i in whatsNew.items)
        if (i.kind == WhatsNewKind.episode) i
    ]..sort((a, b) => b.dateMs.compareTo(a.dateMs));
    final unseenFeeds = {
      for (final i in newEpisodes)
        if (!whatsNew.seen.contains(i.key)) i.target
    };

    return CustomScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        SliverToBoxAdapter(child: _ContinueRail(themeColor: themeColor)),
        if (followed.isNotEmpty)
          SliverToBoxAdapter(
            child: HubRail(
              title: 'Your shows',
              accent: themeColor,
              items: [
                for (final show in followed)
                  HubRailItem(
                    art: hubArt(show.artworkUrl),
                    title: show.collectionName,
                    dot: unseenFeeds.contains(show.feedUrl),
                    onTap: () => openPodcastShow(context, show, themeColor),
                  ),
              ],
            ),
          ),
        if (newEpisodes.isNotEmpty) ...[
          const SliverToBoxAdapter(child: HubTitle('New from your shows')),
          SliverList.builder(
            itemCount: newEpisodes.length.clamp(0, 8),
            itemBuilder: (_, i) {
              final item = newEpisodes[i];
              final show = followed.where((s) => s.feedUrl == item.target).firstOrNull ??
                  PodcastShow(
                      collectionName: item.source,
                      artistName: '',
                      artworkUrl: item.image,
                      feedUrl: item.target);
              return _NewEpisodeRow(
                title: item.title,
                show: show,
                image: item.image.isNotEmpty ? item.image : show.artworkUrl,
                dateMs: item.dateMs,
                unseen: !whatsNew.seen.contains(item.key),
                themeColor: themeColor,
              );
            },
          ),
        ],
        SliverToBoxAdapter(child: _TopChartRail(themeColor: themeColor)),
        const SliverToBoxAdapter(child: HubTitle('Browse categories')),
        HubCategoryGrid(
          tiles: [
            for (final genre in PodcastService.topLevelGenres)
              HubTile(
                genre,
                () => AppNavigation.push(context, PodcastCategoryPage(genre: genre),
                    name: 'podcast-category:$genre'),
                preview: () => ref
                    .read(podcastServiceProvider)
                    .getChartArt(genre, country: podcastChartCountry()),
                previewKey: 'podcast:$genre',
              ),
            HubTile(
              'All categories',
              () => AppNavigation.push(context, const PodcastCategoriesPage(),
                  name: 'podcast-categories'),
              more: true,
            ),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
    );
  }
}

/// Episodes the listener is part-way through, most recent first: from the
/// player's history and the resume bookmarks it keeps (no network).
class _ContinueRail extends ConsumerWidget {
  final Color themeColor;
  const _ContinueRail({required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions = ref.watch(podcastPositionsProvider).asData?.value ??
        const <String, EpisodeProgress>{};
    final history = ref.watch(playerProvider.select((s) => s.history));
    final seen = <String>{};
    final items = <(Song, EpisodeProgress)>[];
    for (final song in history) {
      if (song.albumTitle != 'Podcast' || !seen.add(song.id)) continue;
      final p = positions[song.id.hashCode.toString()];
      if (p == null || p.positionMs <= 0) continue;
      final left = p.remainingMs(_episodeDurationMs(song.duration));
      if (left != null && left < 60000) continue;
      items.add((song, p));
    }
    items.sort((a, b) => b.$2.updatedAtMs.compareTo(a.$2.updatedAtMs));
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HubTitle('Continue listening'),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length.clamp(0, 10),
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final (song, p) = items[i];
              final feedMs = _episodeDurationMs(song.duration);
              final total = p.durationMs > 0 ? p.durationMs : feedMs;
              final frac = total > 0 ? (p.positionMs / total).clamp(0.0, 1.0) : 0.0;
              final left = p.remainingMs(feedMs);
              return InteractivePressable(
                scaleDown: 0.96,
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  HapticService.medium();
                  ref.read(playerProvider.notifier).playSong(song,
                      newQueue: [], index: 0, source: 'Podcast',
                      contextType: 'podcast', contextTitle: song.artist);
                },
                child: Container(
                  width: 270,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: themeColor.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    children: [
                      AuvyImage(path: song.image, width: 72, height: 72, borderRadius: 10, decodeWidth: 160),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_cleanPodcastTitle(song.title),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: frac,
                                minHeight: 3,
                                backgroundColor: Colors.white.withValues(alpha: 0.1),
                                valueColor: AlwaysStoppedAnimation(themeColor),
                              ),
                            ),
                            if (left != null) ...[
                              const SizedBox(height: 4),
                              Text('${_exactSpan(left)} left',
                                  style: TextStyle(color: themeColor, fontSize: 11, fontWeight: FontWeight.w600)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NewEpisodeRow extends StatelessWidget {
  final String title;
  final PodcastShow show;
  final String image;
  final int dateMs;
  final bool unseen;
  final Color themeColor;
  const _NewEpisodeRow({
    required this.title,
    required this.show,
    required this.image,
    required this.dateMs,
    required this.unseen,
    required this.themeColor,
  });

  @override
  Widget build(BuildContext context) {
    final days = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(dateMs)).inDays;
    final when = days <= 0 ? 'Today' : days == 1 ? 'Yesterday' : '$days days ago';
    return InkWell(
      onTap: () {
        HapticService.light();
        openPodcastShow(context, show, themeColor);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 10,
              child: unseen
                  ? Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(color: themeColor, shape: BoxShape.circle))
                  : null,
            ),
            const SizedBox(width: 4),
            AuvyImage(path: image, width: 52, height: 52, borderRadius: 8, decodeWidth: 120),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_cleanPodcastTitle(title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${show.collectionName} · $when',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Apple's overall chart. Tiles come from the chart itself; the show's feed is
/// looked up when one is opened.
class _TopChartRail extends ConsumerWidget {
  final Color themeColor;
  const _TopChartRail({required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chart = ref.watch(topPodcastsProvider);
    final shows = chart.asData?.value ?? const <ChartShow>[];
    if (chart.isLoading && shows.isEmpty) return const HubRailSkeleton(title: 'Top podcasts');
    return HubRail(
      title: 'Top podcasts',
      accent: themeColor,
      items: [
        for (final (i, s) in shows.indexed)
          HubRailItem(
            art: hubArt(s.image),
            title: s.name,
            subtitle: s.artist,
            rank: i + 1,
            onTap: () async {
              final show = await ref.read(podcastServiceProvider).lookupShow(s.id);
              if (!context.mounted) return;
              if (show == null) {
                AnimatedToast.message("Couldn't open ${s.name}");
                return;
              }
              openPodcastShow(context, show, themeColor);
            },
          ),
      ],
    );
  }
}

/// The top shows of one category (Apple's chart for it).
class PodcastCategoryPage extends ConsumerWidget {
  final String genre;
  const PodcastCategoryPage({super.key, required this.genre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    final shows = ref.watch(podcastCategoryProvider(genre));
    return DynamicBackground(
      child: HubListPage(
        title: genre,
        // Apple's chart for the category, in its order: what is popular now.
        subtitle: 'Top shows right now · Apple Podcasts chart',
        body: shows.when(
          loading: () => const HubRowsSkeleton(),
          error: (_, __) => const BrowseHubStatus(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load this category",
            subtitle: 'Check your connection and try again.',
          ),
          data: (list) => list.isEmpty
              ? const BrowseHubStatus(icon: Icons.podcasts_rounded, title: 'Nothing here yet')
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 180),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _PodcastRow(show: list[i], themeColor: themeColor, rank: i + 1),
                ),
        ),
      ),
    );
  }
}

/// All 110 of Apple's podcast categories, A to Z.
class PodcastCategoriesPage extends ConsumerWidget {
  const PodcastCategoriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = PodcastService.genreIds.keys.toList()..sort();
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('All categories', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
        body: ListView.builder(
          padding: const EdgeInsets.only(bottom: 180),
          itemCount: genres.length,
          itemBuilder: (_, i) => ListTile(
            title: Text(genres[i], style: const TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            onTap: () => AppNavigation.push(context, PodcastCategoryPage(genre: genres[i]),
                name: 'podcast-category:${genres[i]}'),
          ),
        ),
      ),
    );
  }
}

// Episode browser sheet
// Top-level so the player page can reopen the picker for the playing show
// (podcast title tap) without duplicating the sheet.
/// Exact time for a millisecond span ("8:04", or "1:12:30" past an hour). Episode
/// times aren't rounded to minutes anywhere on this page, so they match the
/// player.
String _exactSpan(int ms) {
  final total = (ms / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Opens a show as a page rather than a bottom sheet: show notes are long, a sheet's
/// drag-to-dismiss fights scrolling, and a route gets the standard transition, back
/// behaviour and header, like albums and playlists.
///
/// [fromRootRoute] is for callers on the root navigator (the full-screen player),
/// which must push onto the active tab so the page lands in the right back stack
/// (see AppNavigation.pushOnActiveTab).
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

  /// Show notes as plain text, made once per episode: searching re-filters on
  /// every keystroke, and stripping hundreds of notes each time made typing lag.
  final Map<String, String> _plainNotes = {};
  String _notesOf(PodcastEpisode ep) =>
      _plainNotes.putIfAbsent(ep.streamUrl, () => _stripHtml(ep.description));

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
            // A scrim behind the pinned bar, not a solid colour: it fades from near-black at
            // the top to transparent at the bottom, so the title stays readable over the
            // scrolling episodes while the shared DynamicBackground still shows.
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
              tooltip: 'Back',
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

          // Search sits above "Continue listening" so it's easy to find; a show with hundreds
          // of episodes is unusable without it.
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
                // The episode you were last listening to (by last-played time), not the first
                // in-progress one in feed order.
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
                          _notesOf(ep).toLowerCase().contains(q))
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
                      description: _notesOf(ep),
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

/// Show identity plus the two things you want first: play the newest episode, or
/// follow.
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
                child: InteractivePressable(
                  scaleDown: 0.95,
                  borderRadius: BorderRadius.circular(22),
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
              const SizedBox(width: 8),
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

    return InteractivePressable(
      scaleDown: 0.95,
      borderRadius: BorderRadius.circular(22),
      onTap: () async {
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
            // Only the newest few, like the background refresh: the library keeps a
            // snapshot for Android Auto and offline, not the whole feed.
            final episodes = await ref.read(podcastEpisodesProvider(show).future);
            notifier.updateAlbumTracks(show.collectionName, [
              for (final e in episodes.take(LibraryNotifier.podcastSnapshot)) e.toSong()
            ]);
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

  /// Length from the feed's `<itunes:duration>`, used only when the player has never
  /// reported a real one. See [EpisodeProgress].
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
      // Tapping the card opens the overview; it doesn't play. Playback is only the large
      // play button on the right, so a stray tap while scrolling can't replace what's
      // playing with an hour-long episode.
      child: InteractivePressable(
        scaleDown: description.isNotEmpty ? 0.985 : 1.0,
        borderRadius: BorderRadius.circular(18),
        onTap: description.isNotEmpty ? onToggleNotes : null,
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
                  Padding(
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
                InteractivePressable(
                  scaleDown: 0.88,
                  borderRadius: BorderRadius.circular(23),
                  onTap: onPlay,
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
                  height: 1.45,
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

// Pinned shows horizontal strip
// Podcast ROW
// A section is a list, not a grid: inside an expandable genre, rows read
// top-to-bottom and keep each show's title readable at full width.
class _PodcastRow extends ConsumerWidget {
  final PodcastShow show;
  final Color themeColor;

  /// Chart position, shown before the cover on a category page.
  final int? rank;
  const _PodcastRow({required this.show, required this.themeColor, this.rank});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final following = ref.watch(libraryProvider.select((l) => l.likedAlbums.any(
        (a) => a.recordType == 'podcast' && (a.id == show.feedUrl || a.title == show.collectionName))));

    return InteractivePressable(
      scaleDown: 0.98,
      highlightColor: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        FocusScope.of(context).unfocus();
        openPodcastShow(context, show, themeColor);
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            rank == null ? 20 : 12, 4 + densityNow.rowVerticalPadding, 12,
            4 + densityNow.rowVerticalPadding),
        child: Row(
          children: [
            if (rank != null)
              SizedBox(
                width: 28,
                child: Text('$rank',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
            if (rank != null) const SizedBox(width: 6),
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
                      color: Colors.white.withValues(alpha: 0.66),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            if (following)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.check_circle_rounded, color: themeColor, size: 18),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.25), size: 22),
            ),
          ],
        ),
      ),
    );
  }
}
