import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:auvy/services/search_service.dart';

import 'package:auvy/presentation/pages/podcast_page.dart';
import 'package:auvy/presentation/pages/radio_page.dart';
import 'package:auvy/presentation/pages/audiobooks_page.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/services/updater_service.dart';
import 'package:auvy/services/update_state.dart';
import 'package:auvy/services/battery_optimization_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/home_provider.dart';
import 'package:auvy/providers/on_this_day_provider.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/presentation/widgets/playing_equalizer.dart';
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/section_page.dart';
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/providers/recent_playlists_provider.dart';
import 'package:auvy/providers/library_provider.dart' show libraryProvider;
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/scroll_control_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:auvy/providers/density_provider.dart';

/// The home screen: a vertical list of horizontally-scrolling rails.
///
/// Rails come from home_provider as [HomeSection]s, which carry a generated
/// TITLE ("For You: Drake") rather than structured fields. This file both renders
/// that title and interprets it — [_kSectionPrefixes] is the single table used
/// for the kicker above the header AND for working out which artist a tap should
/// open. Those two were separate once, and the incomplete copy made every artist
/// tap fail; keep them reading the same table.
///
/// Rails are built lazily and the feed pages in as it scrolls, so a build here
/// runs often — prefer const children and avoid work in `build`.

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _dieCtrl;
  late final Animation<double> _dieScale;
  late final Animation<double> _dieRotation;
  final Map<String, PageController> _pageCtrl = {};
  final Map<String, ValueNotifier<int>> _pageCurrent = {};
  // Pull-to-refresh: trigger the reload on a modest overscroll (~90px) instead
  // of Flutter's stock ~25%-of-viewport threshold, so it's easy to reach.
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();
  bool _pullArmed = false;

  @override
  void initState() {
    super.initState();
    // Update checks NEVER auto-popup. If the user left "Update reminders" on
    // (Settings), we silently check and show a dismissible banner — not a
    // blocking dialog. Otherwise nothing happens until they check manually.
    Future.delayed(const Duration(seconds: 3), () async {
      if (!mounted) return;
      // Gated by Settings → Updates → "Check on launch". This used to read
      // `update_reminders_enabled`, a pref with NO user interface anywhere — it
      // was permanently true in practice. The banner itself is separately gated
      // by "Announce new versions", and `UpdateState.shouldAnnounce` makes sure a
      // given release is only ever announced once.
      if (!await UpdateState.checkOnLaunch()) return;
      if (!mounted) return;
      final themeColor = ref.read(themeProvider);
      UpdaterService.checkForUpdates(context, themeColor, reminderMode: true);
    });
    _scrollController.addListener(_onScroll);
    _scrollController.addListener(_maybePullRefresh);

    // One-time prompt to exempt Auvy from battery optimization — the fix for
    // Samsung/One UI cutting the network with the screen off (next-track stalls).
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) BatteryOptimizationService.maybePromptOnce();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(homeScrollControlProvider.notifier).state = _scrollToTop;
      // Second tap on the active Home tab → refresh the feed (see
      // MainLayout._onItemTapped). Same work as pull-to-refresh.
      ref.read(tabReloadControlProvider.notifier).update((m) => {
            ...m,
            0: () async {
              _scrollToTop();
              await ref.read(homeProvider.notifier).refreshHome();
            },
          });
    });

    _dieCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _dieScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.35, end: 0.90), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 0.90, end: 1.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _dieCtrl, curve: Curves.easeInOut));
    _dieRotation = Tween<double>(begin: 0, end: 3 * 3.14159).animate(
        CurvedAnimation(parent: _dieCtrl, curve: Curves.easeOut));
  }

  // Notification permission is requested ONCE in main._initBackgroundServices —
  // a second concurrent request from here raced it and threw PlatformException
  // ("A request for permissions is already running").

  void _rollDie() {
    HapticService.heavy();
    _dieCtrl.forward(from: 0.0).then((_) {
      final picks = ref.read(homeProvider).quickPicks;
      if (picks.isNotEmpty) {
        final song = picks[DateTime.now().millisecondsSinceEpoch % picks.length];
        ref.read(playerProvider.notifier).playSong(song, source: "Dice");
      }
    });
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    }
  }

  // Pull-to-refresh that fires ON RELEASE, not mid-drag: a pull past ~90px only
  // ARMS the gesture; the reload fires once the overscroll springs back to the
  // top (which only happens when the user lets go). So holding a long pull —
  // or pulling then easing back up before releasing — never triggers until
  // release, and the required pull is far shorter than Flutter's ~25%-of-screen
  // stock threshold.
  void _maybePullRefresh() {
    if (!_scrollController.hasClients) return;
    final p = _scrollController.position.pixels;
    if (p <= -90) {
      _pullArmed = true; // pulled far enough — wait for release
    } else if (_pullArmed && p >= -2) {
      _pullArmed = false; // sprang back to the top ⇒ released
      _refreshKey.currentState?.show(); // no-op if already refreshing
    }
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Up late';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  // "Good evening · Friday" — the personal touch under the big title.
  String _greetingSubtitle() {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[DateTime.now().weekday - 1];
  }

  void _onScroll() {
    final homeState = ref.read(homeProvider);
    
    if (_scrollController.position.pixels >= 
        _scrollController.position.maxScrollExtent - 1000) {
      if (!homeState.isFetchingMore && !homeState.hasReachedEnd) {
        ref.read(homeProvider.notifier).fetchNextSection();
      }
    }
  }

  PageController _ctrl(String key) =>
      _pageCtrl.putIfAbsent(key, () => PageController());

  ValueNotifier<int> _page(String key) =>
      _pageCurrent.putIfAbsent(key, () => ValueNotifier(0));

  Widget _buildGridSection(String key, String title, String subtitle, List<Song> songs) {
    if (songs.isEmpty) return const SizedBox.shrink();
    
    // Show only the REAL (already-deduped) tracks — never pad by repeating them.
    // Padding a short list up to a fixed 28 is exactly why a single played track
    // was duplicated 28× across every section for new users. The page count now
    // follows the actual number of tracks (4 per page), so a section with 1 track
    // renders 1 tile on 1 page instead of 28 copies.
    final limited = songs.take(28).toList();
    final pageCount = (limited.length / 4).ceil().clamp(1, 7);
    final themeColor = ref.read(themeProvider);
    final notifier = ref.read(playerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subtitle.toUpperCase(),
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.66),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1)),
                    const SizedBox(height: 3),
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 250,
          child: PageView.builder(
            controller: _ctrl(key),
            itemCount: pageCount,
            onPageChanged: (p) => _page(key).value = p,
            itemBuilder: (context, pageIdx) {
              final start = pageIdx * 4;
              final end = (start + 4).clamp(0, limited.length);
              final pageSongs = limited.sublist(start, end);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: pageSongs
                      .map((s) => _TrackListTile(
                            song: s,
                            onTap: () => notifier.playSong(s, source: "Home"),
                          ))
                      .toList(),
                ),
              );
            },
          ),
        ),
        if (pageCount > 1)
          ValueListenableBuilder<int>(
            valueListenable: _page(key),
            builder: (_, cur, __) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  pageCount,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: cur == i ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: cur == i ? themeColor : Colors.white24,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  // NOTE: the account dialog (sessions / connect / logout) lives ONLY in the
  // Library page now — its header avatar is the single entry point. The
  // duplicate copy that used to live here (plus its session-card/connect
  // helpers and the header avatar) was removed.

  @override
  void dispose() {
    _scrollController.dispose();
    _dieCtrl.dispose();
    for (final c in _pageCtrl.values) c.dispose();
    for (final n in _pageCurrent.values) n.dispose();
    super.dispose();
  }

  // Redirection Logic
  Future<void> _handleTitleTap(HomeSection section) async {
    HapticService.light();

    // Artist-anchored shelves ("More from X" / "Best of X") open that artist.
    if (section.type == 'artist') {
      // The SAME table the header uses. See [_kSectionPrefixes] for the bug
      // that came of these two paths disagreeing.
      final query = _bareSectionTitle(section.title);
      final service = ref.read(searchServiceProvider);
      final results = await service.search(query, 'artist');
      // Not results.first. Search ranks by popularity, not by identity, so
      // the top hit for a name can be a different artist entirely — a tribute
      // act, a "- Topic" channel for someone else, or simply a bigger artist
      // with a similar name.
      final match = SearchService.pickArtistMatch(results, query, (s) => s.title);
      if (match != null && mounted) {
        AppNavigation.push(context, ArtistPage(artist: match), name: AppNavigation.artistTag(match));
      } else if (mounted) {
        // Names the QUERY and what came back. "Artist not found" alone cannot
        // distinguish the three real causes — a title this strip does not know,
        // a search that returned nothing, and a genuine identity mismatch —
        // which is why the prefix bug survived as long as it did.
        print('WARN: artist shelf "${section.title}" -> query "$query" matched '
            'none of ${results.length} result(s): '
            '${results.take(4).map((s) => s.title).join(" | ")}');
        AnimatedToast.show(context, text: "Artist not found", icon: Icons.error_outline, color: Colors.red);
      }
      return;
    }

    // Everything else ("Take it easy", "All hits", mood mixes…) is a MIX, not
    // an artist — open the section itself: full track list with Play/Shuffle.
    // (The old code searched these titles as artist names and landed on a
    // wrong artist page.)
    if (section.songs.isEmpty) return;
    AppNavigation.push(
        context, SectionPage(title: section.title, songs: section.songs));
  }

  @override
  Widget build(BuildContext context) {
    final isLoading      = ref.watch(homeProvider.select((s) => s.isLoading));
    final currentMood    = ref.watch(homeProvider.select((s) => s.currentMood));
    final quickPicks     = ref.watch(homeProvider.select((s) => s.quickPicks));
    final feedSections   = ref.watch(homeProvider.select((s) => s.feedSections));
    final isFetchingMore = ref.watch(homeProvider.select((s) => s.isFetchingMore));
    final themeColor     = ref.watch(themeProvider);
    // Deduped recents (by id AND title+artist) so the same track resolved under
    // different video ids doesn't appear twice in "Jump Back In". (The provider
    // itself listens to history, so no direct playerProvider.history watch here
    // — that watch rebuilt the entire page on every single play.)
    final keepListening = ref.watch(homeProvider.select((s) => s.keepListening));

    final bool moodActive = currentMood != 'All';
    final bool coldAndEmpty = isLoading &&
        keepListening.isEmpty && quickPicks.isEmpty && feedSections.isEmpty;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => ref.read(activeOverlayIdProvider.notifier).state = null,
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),

              RefreshIndicator(
                key: _refreshKey,
                displacement: 40,
                color: themeColor,
                backgroundColor: const Color(0xFF2A2A2A),
                strokeWidth: 3.0,
                onRefresh: () async {
                  HapticService.medium();
                  await ref.read(homeProvider.notifier).refreshHome();
                },
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  slivers: [
                    // HEADER: personalized greeting
                    SliverToBoxAdapter(child: _buildHeader(context, MediaQuery.paddingOf(context).top)),

                    // MOOD / FILTER CHIPS (Spotify-style)
                    SliverToBoxAdapter(child: _buildMoodChips(currentMood, themeColor)),

                    // Subtle loading bar
                    if (isLoading && !coldAndEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                          child: LinearProgressIndicator(color: themeColor, backgroundColor: Colors.white10, minHeight: 2),
                        ),
                      ),

                    // ── COLD START: skeleton shell, no spinner-only screen ─
                    if (coldAndEmpty) ...[
                      SliverToBoxAdapter(child: _buildMosaicSkeleton()),
                      SliverToBoxAdapter(child: _buildRailSkeleton()),
                      SliverToBoxAdapter(child: _buildRailSkeleton()),
                    ] else ...[
                      // JUMP BACK IN: signature 2-col mosaic
                      SliverToBoxAdapter(child: _buildMosaicGrid(keepListening)),

                      // QUICK ACTIONS (Die, Podcast, Radio)
                      SliverToBoxAdapter(child: _buildQuickActions(context)),

                      // When a mood chip is active its results come FIRST —
                      // that's what the user just asked for.
                      if (moodActive)
                        ..._buildFeedSlivers(feedSections, isFetchingMore, themeColor),

                      // QUICK PICKS: made-for-you pager
                      SliverToBoxAdapter(
                        child: _buildGridSection('quickpicks', 'Quick Picks', 'Made for you', quickPicks),
                      ),

                      // RAILS: most played / rediscover
                      SliverToBoxAdapter(
                        child: Consumer(
                          builder: (_, ref, __) {
                            final speedDial = ref.watch(homeProvider.select((s) => s.speedDial));
                            return _buildCardRail('Speed Dial', 'Your most played', speedDial);
                          },
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Consumer(
                          builder: (_, ref, __) {
                            final forgotten = ref.watch(homeProvider.select((s) => s.forgottenFavorites));
                            return _buildCardRail('Forgotten Favorites', 'Rediscover your past', forgotten);
                          },
                        ),
                      ),

                      // On this day
                      // Songs whose FIRST play was today's date in an earlier
                      // year — the day each one entered your library. Computed
                      // locally from data the app already keeps, so it costs no
                      // request. Renders NOTHING when there is no match (which
                      // includes everyone with under a year of history) rather
                      // than an empty row with a heading over it.
                      SliverToBoxAdapter(
                        child: Consumer(
                          builder: (_, ref, __) {
                            final shelf = ref.watch(onThisDayProvider);
                            if (shelf.isEmpty) return const SizedBox.shrink();
                            return _buildCardRail(
                                'On This Day', shelf.subtitle, shelf.songs);
                          },
                        ),
                      ),

                      // DISCOVERY FEED (infinite)
                      if (!moodActive)
                        ..._buildFeedSlivers(feedSections, isFetchingMore, themeColor),
                    ],

                    const SliverToBoxAdapter(child: SizedBox(height: 160)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Header
  Widget _buildHeader(BuildContext context, double topInset) {
    // Explicit status-bar inset: a SafeArea INSIDE a CustomScrollView sliver
    // reads a stripped MediaQuery (scrollables consume the top padding), so
    // the header used to render under the clock. The inset is measured
    // OUTSIDE the scroll view and passed in.
    return Padding(
        padding: EdgeInsets.fromLTRB(20, topInset + 12, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_greeting()} · ${_greetingSubtitle()}',
                      style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  // First name when signed in — "Home" for guests.
                  Consumer(builder: (_, ref, __) {
                    final name = ref.watch(accountProvider.select((a) {
                      final n = (a.displayName ?? '').trim();
                      return n.isEmpty ? '' : n.split(' ').first;
                    }));
                    return Text(
                      name.isEmpty ? 'Home' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                    );
                  }),
                ],
              ),
            ),
            // Stats and History MOVED to the library side panel (under "You").
            //
            // Both are places you visit occasionally to look back at your own
            // listening — they belong with the other account-level destinations,
            // not as permanent chrome on the feed you open twenty times a day.
            // Removing them also gives the greeting the full width, which is what
            // the header is actually for.
            //
            // Account avatar was removed earlier for the same reason: one
            // canonical entry point, in the Library header.
          ],
        ),
    );
  }

  // Mood chips
  static const List<(String, IconData?)> _moods = [
    ('All', null),
    ('Energize', Icons.bolt_rounded),
    ('Relax', Icons.spa_rounded),
    ('Focus', Icons.center_focus_strong_rounded),
    ('Workout', Icons.fitness_center_rounded),
    ('Party', Icons.celebration_rounded),
    ('Sad', Icons.water_drop_rounded),
    ('Random', Icons.shuffle_rounded),
  ];

  Widget _buildMoodChips(String currentMood, Color themeColor) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        physics: const BouncingScrollPhysics(),
        itemCount: _moods.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (label, icon) = _moods[i];
          final selected = currentMood == label;
          return GestureDetector(
            onTap: () {
              HapticService.selection();
              ref.read(homeProvider.notifier).setMood(label);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? themeColor : Colors.white.withOpacity(0.07),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: selected ? Colors.black : Colors.white60),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // JUMP BACK IN: Spotify-signature compact mosaic
  // Not just recents anymore: the pool mixes RECENT tracks with all-time MOST
  // PLAYED, and when two or more pool tracks come from the same real album the
  // grid shows THAT ALBUM as one tile (tap → album page) instead of the
  // individual tracks — the Spotify jump-back-in behavior. The head tile is
  // always the current/most-recent TRACK.
  //
  // Returns up to 18 entries in swipe-page priority order (chunked into 2×3
  // pages of 6 by _buildMosaicGrid, deduped by identity across ALL pages):
  //   0–5   recency-sorted mix — identical to the old single grid.
  //   6–11  all-time most played, play-count order (same album collapse).
  //   12–17 variety mix: remaining most-played interleaved with the older
  //         recents / albums / playlists that didn't make earlier pages.
  List<_MosaicEntry> _buildMosaicEntries(
      List<Song> recents, List<RecentPlaylist> recentPlaylists) {
    final intel = ref.read(intelligenceProvider);

    bool realTrack(Song s) =>
        !s.id.startsWith('http') && s.albumTitle != 'Podcast' && s.albumTitle != 'RADIO';
    String sigOf(Song s) => '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';

    // A track PLAYED FROM a collection (album/playlist) that is itself shown in
    // the mosaic is represented by that collection tile ONLY — suppress the
    // individual song so the same play never appears twice (song + collection).
    String normColl(String t) => t.toLowerCase().trim();
    final recentPlaylistKeys = {for (final p in recentPlaylists) p.key};
    final playOrigin = ref.read(recentPlaylistsProvider.notifier).origin;
    // Titles of ALBUMS the user played FROM (recorded in recents). The album tile
    // represents them, so their member tracks are suppressed from the song pool.
    // Matched by TITLE, not id, because the video→audio conform rewrites a
    // track's albumId (and deluxe / name-resolved ids don't always match the
    // recorded album id) — id matching alone let the track slip through next to
    // its album, and let a 2nd album tile with a mismatched id duplicate it.
    final shownAlbumTitles = <String>{
      for (final p in recentPlaylists)
        if (p.isAlbum && p.title.trim().isNotEmpty) normColl(p.title),
    };
    bool inShownAlbum(Song s) =>
        s.albumTitle.trim().isNotEmpty &&
        shownAlbumTitles.contains(normColl(s.albumTitle));
    bool isSubsumed(Song s) {
      if (inShownAlbum(s)) return true;
      final k = playOrigin[s.id] ?? playOrigin[sigOf(s)];
      return k != null && recentPlaylistKeys.contains(k);
    }

    final pool = <Song>[];
    final seenIds = <String>{};
    final seenSigs = <String>{};
    void addCandidate(Song s) {
      if (!realTrack(s) || s.image.isEmpty) return;
      if (isSubsumed(s)) return;
      final sig = sigOf(s);
      if (seenIds.contains(s.id) || seenSigs.contains(sig)) return;
      seenIds.add(s.id);
      seenSigs.add(sig);
      pool.add(s);
    }

    for (final s in recents) {
      addCandidate(s);
      if (pool.length >= 8) break;
    }
    final topPlayed = intel.playCounts.entries
        .where((e) => e.value >= 2 && intel.trackMetadata.containsKey(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in topPlayed) {
      addCandidate(intel.trackMetadata[e.key]!);
      if (pool.length >= 14) break;
    }
    // Does this track belong to a GENUINE album — a real album id, not a single,
    // a placeholder, or a self-referential id? (Mirrors buildAlbumForSong.)
    // Title-only bundles are NOT real re-openable playlists, so they are NOT
    // grouped here — they stay individual songs. Real playlists come from the
    // recently-played store below (they alone carry a re-openable id).
    bool hasRealAlbumId(Song s) =>
        s.albumId.isNotEmpty && s.albumId != 'null' && s.albumId != s.id;

    // When each item was last engaged with, so songs, albums and playlists can
    // be interleaved by true recency (the most recent thing leads the grid).
    int tsOf(Song s) => intel.lastPlayTimestamps[s.id] ?? 0;

    _MosaicEntry albumEntryFor(Song s) => _MosaicEntry.album(
          Album(
            id: s.albumId,
            title: s.albumTitle.trim(),
            image: s.image,
            releaseDate: s.releaseDate.isNotEmpty ? s.releaseDate : 'Unknown',
            recordType: 'album',
          ),
          s.artist,
          s,
        );

    // Only collapse into an ALBUM tile when 2+ of the given tracks share a
    // REAL album; order is preserved (the album sits where its first track was).
    List<_MosaicEntry> collapse(List<Song> songs) {
      final albumCounts = <String, int>{};
      for (final s in songs) {
        if (hasRealAlbumId(s)) {
          albumCounts[s.albumId] = (albumCounts[s.albumId] ?? 0) + 1;
        }
      }
      final out = <_MosaicEntry>[];
      final emittedAlbums = <String>{};
      for (final s in songs) {
        if (hasRealAlbumId(s) && (albumCounts[s.albumId] ?? 0) >= 2) {
          if (emittedAlbums.contains(s.albumId)) continue; // folded into its tile
          emittedAlbums.add(s.albumId);
          out.add(albumEntryFor(s));
        } else {
          out.add(_MosaicEntry.song(s));
        }
      }
      return out;
    }

    final candidates = <({_MosaicEntry entry, int ts})>[];
    for (final e in collapse(pool)) {
      if (e.isAlbum) {
        int albumTs = 0;
        for (final t in pool) {
          if (t.albumId == e.album!.id) {
            final v = tsOf(t);
            if (v > albumTs) albumTs = v;
          }
        }
        candidates.add((entry: e, ts: albumTs));
      } else {
        candidates.add((entry: e, ts: tsOf(e.song!)));
      }
    }

    // Real recently-played playlists AND albums — these reopen the EXACT
    // original (external browse id or library playlist), not a fabricated copy.
    for (final p in recentPlaylists) {
      if (p.image.isEmpty) continue;
      if (p.isAlbum && p.externalId != null) {
        // Opened albums become genuine album tiles (dedupes against albums
        // synthesized from played tracks via the same album id).
        candidates.add((
          entry: _MosaicEntry.album(
            Album(
              id: p.externalId!,
              title: p.title,
              image: p.image,
              releaseDate: 'Unknown',
              recordType: 'album',
            ),
            p.subtitle,
          ),
          ts: p.playedAt,
        ));
      } else {
        candidates.add((entry: _MosaicEntry.playlist(p), ts: p.playedAt));
      }
    }

    if (candidates.isEmpty) return const [];
    // Most-recent first — the top 6 fill page 1's 2×3 grid unchanged.
    candidates.sort((a, b) => b.ts.compareTo(a.ts));

    // Cross-PAGE identity dedupe: each song id / album id / playlist key shows
    // on exactly one page. An emitted ALBUM folds its member songs, and a song
    // shown solo blocks its album tile later — never the same artwork twice.
    final entries = <_MosaicEntry>[];
    final usedSongIds = <String>{};
    final usedSigs = <String>{};
    final usedAlbumIds = <String>{}; // emitted as album tiles
    final soloAlbumIds = <String>{}; // already represented by a solo song tile
    final usedPlaylistKeys = <String>{};
    // Collection identity by TITLE too — catches the same album/playlist showing
    // twice under DIFFERENT ids (recents id vs the tracks' albumId; a playlist
    // opened both externally and from the library). This is what kills the
    // "duplicate album/playlist" tiles.
    final usedCollectionTitles = <String>{};
    bool canEmit(_MosaicEntry e) {
      if (e.isAlbum) {
        return !usedAlbumIds.contains(e.album!.id) &&
            !soloAlbumIds.contains(e.album!.id) &&
            !usedCollectionTitles.contains(normColl(e.album!.title));
      }
      if (e.isPlaylist) {
        return !usedPlaylistKeys.contains(e.playlist!.key) &&
            !usedCollectionTitles.contains(normColl(e.playlist!.title));
      }
      final s = e.song!;
      return !usedSongIds.contains(s.id) &&
          !usedSigs.contains(sigOf(s)) &&
          !(hasRealAlbumId(s) && usedAlbumIds.contains(s.albumId)) &&
          // A song whose album is shown as an album tile (by title) is hidden.
          !(s.albumTitle.trim().isNotEmpty &&
              usedCollectionTitles.contains(normColl(s.albumTitle)));
    }

    void emit(_MosaicEntry e) {
      entries.add(e);
      if (e.isAlbum) {
        usedAlbumIds.add(e.album!.id);
        if (e.album!.title.trim().isNotEmpty) {
          usedCollectionTitles.add(normColl(e.album!.title));
        }
      } else if (e.isPlaylist) {
        usedPlaylistKeys.add(e.playlist!.key);
        if (e.playlist!.title.trim().isNotEmpty) {
          usedCollectionTitles.add(normColl(e.playlist!.title));
        }
      } else {
        usedSongIds.add(e.song!.id);
        usedSigs.add(sigOf(e.song!));
        if (hasRealAlbumId(e.song!)) soloAlbumIds.add(e.song!.albumId);
      }
    }

    // Page 1 — the recency mix, exactly the old single-grid top 6.
    for (final c in candidates) {
      if (entries.length >= 6) break;
      if (canEmit(c.entry)) emit(c.entry);
    }

    // Page 2 — all-time most played in play-count order, rebuilt from the FULL
    // ranking (not the recency-capped pool) so heavy favorites that lost the
    // recency race still surface. Whatever doesn't fit becomes page-3 fodder.
    final mpSongs = <Song>[];
    final mpIds = <String>{};
    final mpSigs = <String>{};
    for (final e in topPlayed) {
      final s = intel.trackMetadata[e.key]!;
      if (!realTrack(s) || s.image.isEmpty) continue;
      if (isSubsumed(s)) continue; // represented by its collection tile
      if (mpIds.contains(s.id) || mpSigs.contains(sigOf(s))) continue;
      if (!canEmit(_MosaicEntry.song(s))) continue; // already shown on page 1
      mpIds.add(s.id);
      mpSigs.add(sigOf(s));
      mpSongs.add(s);
      if (mpSongs.length >= 14) break;
    }
    final mpLeftovers = <_MosaicEntry>[];
    for (final e in collapse(mpSongs)) {
      if (entries.length < 12 && canEmit(e)) {
        emit(e);
      } else {
        mpLeftovers.add(e);
      }
    }

    // Page 3 — remaining most-played interleaved with the older recents /
    // albums / playlists page 1 had no room for (still recency-ordered).
    final recencyLeftovers = candidates.skip(6).map((c) => c.entry).toList();
    final mixed = <_MosaicEntry>[];
    for (var i = 0; i < mpLeftovers.length || i < recencyLeftovers.length; i++) {
      if (i < mpLeftovers.length) mixed.add(mpLeftovers[i]);
      if (i < recencyLeftovers.length) mixed.add(recencyLeftovers[i]);
    }
    for (final e in mixed) {
      if (entries.length >= 18) break;
      if (canEmit(e)) emit(e);
    }

    return entries;
  }

  Widget _buildMosaicGrid(List<Song> recents) {
    // Watch so the grid refreshes when a playlist is opened/recorded.
    final recentPlaylists = ref.watch(recentPlaylistsProvider);

    // A deleted playlist must NOT keep its tile
    //
    // Recents record a library playlist by TITLE and persist the whole entry,
    // artwork included, so deleting or renaming the playlist left this list still
    // pointing at it: the tile stayed on Home with the old cover, and tapping it
    // re-resolved by title and found nothing.
    //
    // FILTERED AT RENDER TIME, NOT PRUNED FROM THE STORE. Deleting a library
    // item is UNDOABLE, and dropping the recent entry on delete would mean Undo
    // restored the playlist but not its tile. Checking existence here is
    // self-correcting in both directions and costs a set lookup per entry.
    //
    // Only LIBRARY entries are checked. One with an `externalId` is a fetched
    // YouTube/Spotify playlist or album that opens whether or not it was ever
    // saved locally, so its absence from the library says nothing about whether it
    // still works — filtering those would erase valid history.
    // AN EMPTY LIBRARY MEANS "NOT LOADED YET", NOT "EVERYTHING WAS DELETED".
    //
    // The first version of this filtered unconditionally, and it hid every
    // user-made playlist tile: Home builds before LibraryNotifier has finished
    // reading its blob, so `allItems` is briefly empty and every library recent
    // failed the existence test. The user saw their own playlist's cover vanish
    // from the mosaic — a worse bug than the stale tile this is meant to fix.
    //
    // Same reasoning as the library's own save guards: absence of data is not
    // evidence of deletion. With nothing to check against, show the tile.
    final libraryTitles = ref
        .watch(libraryProvider.select((s) => s.allItems.map((i) => i.title).toSet()));
    final live = libraryTitles.isEmpty
        ? recentPlaylists
        : recentPlaylists.where((p) {
            final t = p.libraryTitle;
            if (t == null || t.trim().isEmpty) return true;
            return libraryTitles.contains(t);
          }).toList();

    final entries = _buildMosaicEntries(recents, live);
    if (entries.isEmpty) return const SizedBox.shrink();

    // Asked over the entries that were actually EMITTED, not over the library:
    // a song tile should only stand down for a collection tile the user can
    // see. Narrowed to a bool by select(), so this rebuilds when the answer
    // flips rather than on every position tick.
    final claimed = ref.watch(playerProvider.select((ps) => entries.any(
        (e) => (e.isAlbum || e.isPlaylist) && _collectionIsPlaying(ps, e))));

    // ≤6 entries (fresh installs): the original static grid — no pager, no dots.
    if (entries.length <= 6) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: _buildMosaicPage(entries, claimed),
      );
    }

    final pageCount = (entries.length / 6).ceil();
    final themeColor = ref.read(themeProvider);
    // Tallest page: 3 rows × 56 + 2 × 10 spacing. Fixed so swiping between a
    // full and a partial page never shifts the layout; short pages top-align.
    const pageHeight = 3 * 56.0 + 2 * 10.0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: SizedBox(
            height: pageHeight,
            child: PageView.builder(
              controller: _ctrl('mosaic'),
              itemCount: pageCount,
              onPageChanged: (p) => _page('mosaic').value = p,
              itemBuilder: (context, pageIdx) {
                final start = pageIdx * 6;
                final end = (start + 6).clamp(0, entries.length);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildMosaicPage(entries.sublist(start, end), claimed),
                );
              },
            ),
          ),
        ),
        if (pageCount > 1)
          ValueListenableBuilder<int>(
            valueListenable: _page('mosaic'),
            builder: (_, cur, __) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  pageCount,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: cur == i ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: cur == i ? themeColor : Colors.white24,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // One 2×3 grid page of the mosaic — shared by the static (≤6) layout and
  // every pager page so the tiles and tap wiring stay identical.
  Widget _buildMosaicPage(
      List<_MosaicEntry> entries, bool collectionClaimsPlayback) {
    final notifier = ref.read(playerProvider.notifier);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 56,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return _MosaicTile(
          entry: entry,
          collectionClaimsPlayback: collectionClaimsPlayback,
          onTap: () {
            if (entry.isAlbum) {
              HapticService.light();
              AppNavigation.push(
                context,
                AlbumPage(
                  album: entry.album!,
                  artistName: entry.artistName,
                  fallbackTrack: entry.seed,
                ),
                name: AppNavigation.albumTag(entry.album!),
              );
            } else if (entry.isPlaylist) {
              HapticService.light();
              // Reopen the EXACT original playlist it was played from — an
              // external browse id, or a library playlist re-resolved by title.
              final p = entry.playlist!;
              AppNavigation.push(
                context,
                p.externalId != null
                    ? PlaylistPage(
                        externalId: p.externalId,
                        externalTitle: p.title,
                        externalImage: p.image,
                        externalSubtitle: p.subtitle,
                      )
                    : PlaylistPage(
                        libraryPlaylist: LibraryItem(
                          title: p.libraryTitle ?? p.title,
                          subtitle: p.subtitle,
                          image: p.image,
                          dateAdded: DateTime.now(),
                        ),
                      ),
                name: AppNavigation.playlistTag(
                    p.externalId ?? p.libraryTitle ?? p.title),
              );
            } else {
              notifier.playSong(entry.song!, source: 'Home');
            }
          },
        );
      },
    );
  }

  // Quick actions
  Widget _buildQuickActions(BuildContext context) {
    // Browse + shuffle
    //
    // Podcasts, Radio and Audiobooks were ActionChips in a horizontally scrolling
    // row — easy to miss. They are now proper tiles sharing the width, with the
    // shuffle die as a square control beside them rather than leading the row:
    // it is a novelty, not the main destination.
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: _BrowseTile(
              icon: Icons.podcasts_rounded,
              label: 'Podcasts',
              onTap: () => AppNavigation.push(context, const PodcastPage(),
                  name: AppNavigation.podcastTag),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _BrowseTile(
              icon: Icons.radio_rounded,
              label: 'Live Radio',
              onTap: () => AppNavigation.push(context, const RadioPage(),
                  name: AppNavigation.radioTag),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _BrowseTile(
              icon: Icons.menu_book_rounded,
              label: 'Audiobooks',
              onTap: () => AppNavigation.push(context, const AudiobooksPage(),
                  name: AppNavigation.audiobooksTag),
            ),
          ),
          const SizedBox(width: 10),
          // Animated die — "surprise me". Same size as the tiles so the row
          // reads as one control strip.
          AnimatedBuilder(
            animation: _dieCtrl,
            builder: (_, child) => Transform.scale(
              scale: _dieScale.value,
              child: Transform.rotate(angle: _dieRotation.value, child: child),
            ),
            child: GestureDetector(
              onTap: _rollDie,
              child: Consumer(
                builder: (_, ref, __) {
                  final tc = ref.watch(themeProvider);
                  return Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: tc.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: tc.withOpacity(0.35)),
                    ),
                    child: Icon(Icons.casino_rounded, color: tc, size: 24),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Discovery feed
  // The provider machinery (fetchNextSection, moods, YTM curated mixes) was
  // fetching these all along — the previous UI just never rendered them.
  List<Widget> _buildFeedSlivers(List<HomeSection> sections, bool isFetchingMore, Color themeColor) {
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final sec = sections[i];
            final (title, kicker) = _splitSectionTitle(sec.title, sec.type);
            return _buildCardRail(
              title,
              kicker,
              sec.songs,
              onHeaderTap: (sec.type == 'artist' || sec.type == 'mix')
                  ? () => _handleTitleTap(sec)
                  : null,
            );
          },
          childCount: sections.length,
        ),
      ),
      // Shimmer rail while the next section loads in.
      if (isFetchingMore) SliverToBoxAdapter(child: _buildRailSkeleton()),
    ];
  }

  /// Shelf-title prefix → the kicker shown above the bare title.
  ///
  /// One table, because there used to be two
  ///
  /// [_handleTitleTap] had its own idea of the prefixes, stripping only
  /// "More from " and "Best of " — while home_provider titles an artist shelf
  /// "For You: $name". So the artist tap searched for the literal string
  /// "For You: Lil Nas X", `pickArtistMatch` correctly refused every candidate,
  /// and the toast said "Artist not found" for EVERY artist shelf on the page.
  ///
  /// The display path already knew all six prefixes. Both paths now read this
  /// table, so adding a shelf format cannot leave the tap handler behind.
  static const Map<String, String> _kSectionPrefixes = {
    'For You: ': 'For you',
    'Best of ': 'Best of',
    'Mix for ': 'Your mix',
    'Random: ': 'Explore',
    'More from ': 'More from',
    'Daily Mix: ': 'Daily mix',
  };

  /// [raw] without whichever shelf prefix it carries.
  static String _bareSectionTitle(String raw) {
    for (final key in _kSectionPrefixes.keys) {
      if (raw.startsWith(key)) return raw.substring(key.length);
    }
    return raw;
  }

  // "For You: Drake" → ("Drake", "FOR YOU") so headers read premium instead of
  // prefix-heavy. Unknown patterns pass through with a generic kicker.
  (String, String) _splitSectionTitle(String raw, [String type = 'generic']) {
    // "Right Now" carries the day-part itself as its title ("Friday night"), so
    // the kicker names the feature rather than the usual "Curated for you".
    if (type == 'rightnow') return (raw, 'Right now');
    if (type == 'chart') return (raw, 'Charts');
    if (type == 'release') return (raw, 'New releases');
    for (final e in _kSectionPrefixes.entries) {
      if (raw.startsWith(e.key)) return (raw.substring(e.key.length), e.value);
    }
    return (raw, 'Curated for you');
  }

  // Horizontal card rail
  Widget _buildCardRail(String title, String subtitle, List<Song> songs, {VoidCallback? onHeaderTap}) {
    if (songs.isEmpty) return const SizedBox.shrink();
    final notifier = ref.read(playerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
          child: GestureDetector(
            onTap: onHeaderTap,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(subtitle.toUpperCase(),
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.66),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1)),
                      const SizedBox(height: 3),
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.3)),
                    ],
                  ),
                ),
                if (onHeaderTap != null)
                  Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.35), size: 24),
              ],
            ),
          ),
        ),
        SizedBox(
          // 132 art + 8 + 2 gaps + two text lines; extra slack for device font
          // metrics (Samsung renders the pair 1px taller than stock).
          height: 186,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            physics: const BouncingScrollPhysics(),
            itemCount: songs.length,
            itemBuilder: (context, i) => _HomeSongTile(
              song: songs[i],
              onTap: () => notifier.playSong(songs[i], source: 'Home'),
            ),
          ),
        ),
      ],
    );
  }

  // SKELETONS (cold start / feed loading)
  Widget _buildMosaicSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        children: List.generate(3, (row) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: const [
              Expanded(child: SkeletonLoader(width: double.infinity, height: 56, borderRadius: 10)),
              SizedBox(width: 10),
              Expanded(child: SkeletonLoader(width: double.infinity, height: 56, borderRadius: 10)),
            ],
          ),
        )),
      ),
    );
  }

  Widget _buildRailSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 28, 20, 12),
          child: SkeletonLoader(width: 160, height: 20, borderRadius: 6),
        ),
        SizedBox(
          height: 186,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 4,
            itemBuilder: (_, __) => const Padding(
              padding: EdgeInsets.only(right: 14),
              child: SkeletonLoader(width: 132, height: 132, borderRadius: 14),
            ),
          ),
        ),
      ],
    );
  }
  
}

enum _MosaicKind { song, album, playlist }

/// One cell of the Jump Back In mosaic. It is one of three things, and it says
/// which so the tile is never mislabelled:
///   • SONG     — a single playable track.
///   • ALBUM    — a genuine album (2+ pooled tracks sharing a real album id).
///   • PLAYLIST — a real recently-played playlist (external or library) that
///                reopens the EXACT original — not a fabricated copy.
/// A mosaic tile's cover, with a user-chosen override applied.
///
/// Playlist covers are keyed `playlist:<title>` — the same key
/// playlist_page writes when the check is tapped, so the two agree by
/// construction rather than by coincidence. Watched through select() on that
/// single key: the map is local and only changes when a cover is picked, so
/// this costs one tile's repaint and no network.
/// Whether [entry] is the collection playback is coming FROM.
///
/// ONE PREDICATE, TWO CALLERS, AND THAT IS THE POINT. The tile asks it to
/// light itself; the grid asks it to find out whether ANY collection has
/// already claimed this playback, so a member song's tile can stand down.
/// Two copies of this rule would eventually disagree, and the failure would be
/// silent in both directions — either two tiles lit, or none.
bool _collectionIsPlaying(PlayerState ps, _MosaicEntry entry) {
  if (!ps.isPlaying || ps.currentSong == null) return false;

  // Origin, NOT membership
  //
  // A collection tile is lit to say "this is where the music is coming from",
  // and that is a claim about WHERE PLAYBACK STARTED, not about what the track
  // happens to belong to. The two come apart constantly:
  //
  //   • A playlist ends and autoplay carries on with recommendations. The
  //     context is still the playlist, but the track playing was never in it —
  //     the tile kept claiming credit for tracks it had nothing to do with.
  //   • A track that IS in a playlist gets played from its album instead. The
  //     album is the origin; the playlist should stay dark even though the
  //     track sits inside it.
  //
  // `playbackSource` is the app's own record of that, set where playback
  // advances (see player_playback.dart): once it rolls into autoplay the source
  // becomes "Recommended", and an automatic jump makes it "Discovery". Either
  // means the collection is no longer the origin.
  if (ps.playbackSource == 'Recommended' || ps.playbackSource == 'Discovery') {
    return false;
  }

  if (entry.isAlbum) {
    // The album must be the CONTEXT, not merely the track's album tag. That tag
    // matches whenever any track from the album plays, including one reached
    // from a playlist or a recommendation — the same false claim in a different
    // disguise.
    final t = entry.album!.title.trim().toLowerCase();
    return ps.contextType == 'album' &&
        (ps.contextTitle?.trim().toLowerCase() == t ||
            // Older sessions recorded no contextTitle for albums; fall back to
            // the track's album tag rather than losing the highlight entirely
            // for anyone mid-session on an upgrade.
            (ps.contextTitle == null &&
                ps.currentSong!.albumTitle.trim().toLowerCase() == t));
  }
  if (entry.isPlaylist) {
    final p = entry.playlist!;
    return ps.contextType == 'playlist' &&
        ps.contextTitle != null &&
        (ps.contextTitle == p.title ||
            (p.libraryTitle != null && ps.contextTitle == p.libraryTitle));
  }
  return false;
}

String _entryImage(WidgetRef ref, _MosaicEntry entry) {
  final title = entry.kind == _MosaicKind.playlist
      ? entry.playlist?.libraryTitle ?? entry.playlist?.title
      : null;
  if (title == null || title.trim().isEmpty) return entry.image;
  final override = ref.watch(
      artworkOverrideProvider.select((m) => m['playlist:${title.trim()}']));
  if (override == null || override.isEmpty) return entry.image;
  return override;
}

class _MosaicEntry {
  final _MosaicKind kind;
  final Song? song;               // song tile
  final Album? album;             // album tile
  final String artistName;        // album navigation
  final Song? seed;               // fallbackTrack for the album page
  final RecentPlaylist? playlist; // playlist tile → reopens the original

  const _MosaicEntry.song(Song this.song)
      : kind = _MosaicKind.song,
        album = null,
        artistName = '',
        seed = null,
        playlist = null;

  const _MosaicEntry.album(Album this.album, this.artistName, [this.seed])
      : kind = _MosaicKind.album,
        song = null,
        playlist = null;

  const _MosaicEntry.playlist(RecentPlaylist this.playlist)
      : kind = _MosaicKind.playlist,
        song = null,
        album = null,
        artistName = '',
        seed = null;

  bool get isAlbum => kind == _MosaicKind.album;
  bool get isPlaylist => kind == _MosaicKind.playlist;
  bool get isSong => kind == _MosaicKind.song;

  /// The image the entry was RECORDED with.
  ///
  /// A snapshot, not a live value — for a playlist this is the cover copied
  /// in when the play was recorded. Anything rendering a tile should go through
  /// [_entryImage], which lets a user-chosen cover override it; this getter is
  /// the fallback that runs when there is no override.
  String get image {
    switch (kind) {
      case _MosaicKind.album:
        return album!.image;
      case _MosaicKind.playlist:
        return playlist!.image;
      case _MosaicKind.song:
        return song!.image;
    }
  }

  String get title {
    switch (kind) {
      case _MosaicKind.album:
        return album!.title;
      case _MosaicKind.playlist:
        return playlist!.title;
      case _MosaicKind.song:
        return song!.title;
    }
  }
}

// Compact "Jump Back In" mosaic tile — image + bold title on a translucent
// card. Cheap: one image, no blur, select-based playing state. Album entries
// carry an "ALBUM" caption and highlight while any of their tracks plays.
class _MosaicTile extends ConsumerWidget {
  final _MosaicEntry entry;
  final VoidCallback onTap;

  /// True when some album or playlist tile in this mosaic is the origin of
  /// what is playing, so a member song's tile must not claim it as well.
  final bool collectionClaimsPlayback;

  const _MosaicTile({
    required this.entry,
    required this.onTap,
    required this.collectionClaimsPlayback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Song entries: show the audio track's square cover + clean title once
    // resolved; playback still targets the original row so queue logic is
    // unchanged. Album/playlist entries are left unchanged (display == null).
    final Song? display =
        entry.isSong ? conformedForDisplay(ref, entry.song!) : null;
    final bool isThisPlaying = ref.watch(playerProvider.select((ps) {
      if (!ps.isPlaying || ps.currentSong == null) return false;
      if (entry.isAlbum || entry.isPlaylist) {
        return _collectionIsPlaying(ps, entry);
      }

      // Exactly one tile may claim the playback
      //
      // THE BUG THIS FIXES: two tiles showing as playing at once. Both were
      // right by their own rule — the playlist tile says "this is where the
      // music is coming from", the song tile says "this is the audio" — and
      // both are true at the same time whenever you play a playlist and the
      // current track also has a tile of its own.
      //
      // It never showed up for ALBUMS because canEmit folds a song into its
      // album tile, so the pair cannot both be on screen. There is no
      // equivalent fold for playlists and there cannot be: a RecentPlaylist
      // carries a title, an image and a subtitle — never a track list, so the
      // mosaic has no way to know which songs belong to it.
      //
      // So the collection wins, because it is the tile you would tap to get
      // back to what you are hearing. [collectionClaimsPlayback] is computed
      // once for the whole mosaic from the SAME predicate the branch above
      // uses, so a tile only stands down for a tile that is genuinely lit.
      //
      // AND ONLY THEN. A track reached by autoplay is still the track that
      // is playing, and its own tile has to keep the equalizer — there the
      // origin is "Recommended", no collection claims anything, and the flag is
      // false. Gating the song branch unconditionally (the first shape of this
      // fix) darkened the playing track for the whole of an autoplay run.
      if (collectionClaimsPlayback) return false;

      // Identity, not the raw id — the same recording carries different ids in
      // different places (see isSameTrack).
      //
      // requireArtist: a mosaic entry can be a radio station or a playlist stored
      // AS a song, so a collection named after a track would otherwise light up
      // whenever that track played — two tiles both claiming to be what is on.
      final row = display ?? entry.song!;
      return isSameTrack(
        playingId: ps.currentSong!.id,
        playingTitle: ps.currentSong!.title,
        playingArtist: ps.currentSong!.displayArtist,
        rowId: entry.song!.id,
        rowAltId: row.id,
        rowTitle: row.title,
        rowArtist: row.displayArtist,
        requireArtist: true,
      );
    }));
    final themeColor = isThisPlaying ? ref.watch(themeProvider) : null;

    // The hold is CHARGED rather than silent. See HoldToOpen. It wraps the
    // gesture detector rather than replacing it, so onTap keeps behaving as it
    // did; HoldToOpen uses a raw Listener and claims no gesture.
    return HoldToOpen(
      borderRadius:
          BorderRadius.circular(ListeningPolicy.roundArtwork(10)),
      color: ref.watch(themeProvider),
      // Only single-song tiles get the track menu; album/playlist tiles
      // open/resume the collection instead, so they arm nothing.
      onHold: entry.isSong
          ? () => ContentMenus.showSongMenu(context, entry.song!, ref)
          : null,
      child: GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // A collection tile must see a new cover without a reload
            //
            // THE BUG THIS FIXES. A SONG tile goes through conformedForDisplay,
            // which watches artworkOverrideProvider, so setting a cover repaints
            // it immediately. An ALBUM or PLAYLIST tile fell back to
            // `entry.image`, and for a playlist that is RecentPlaylist.image, a
            // snapshot copied in when the play was recorded. Nothing watched the
            // override map, so a newly chosen cover did not appear until that
            // recents row happened to be rewritten, which reads as "I have to
            // reload the home page".
            //
            // AND IT IS NOT A DATA COST. artworkOverrideProvider is a local
            // map that changes only when someone picks or clears a cover, and the
            // select() narrows the watch to THIS tile's key, so one tile
            // repaints, no request is made, and nothing else in the mosaic is
            // touched.
            AuvyImage(
                path: display?.image ?? _entryImage(ref, entry),
                width: 56,
                height: 56,
                fit: BoxFit.cover),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    display?.title ?? entry.title,
                    maxLines: entry.isSong ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isThisPlaying ? themeColor : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                  // Type caption so a collection is never mislabelled: a real
                  // album says ALBUM; a title-only bundle says PLAYLIST.
                  if (entry.isAlbum || entry.isPlaylist) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          entry.isAlbum ? Icons.album_rounded : Icons.queue_music_rounded,
                          size: 9,
                          color: Colors.white.withOpacity(0.4),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          entry.isAlbum ? 'ALBUM' : 'PLAYLIST',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.66),
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // ── THE EQUALIZER MEANS "THIS IS THE AUDIO", AND ONLY A TRACK
            // CAN BE THAT
            //
            // Two tiles could light at once, and both were "correct" under their
            // own rule: a SONG tile lights when it IS the playing track, while an
            // ALBUM or PLAYLIST tile lights when playback is coming FROM it.
            // Reported as "two tiles playing", which is exactly how it reads —
            // observed with "Lean On" playing and the "Old timey" PLAYLIST tile
            // showing bars, because the song was being played from that playlist.
            //
            // Both facts are worth showing; they are just not the same fact. The
            // bars are the one that has to be unique, so only a track gets them.
            // A collection keeps the accent-coloured title, which reads as
            // "you are in here" rather than "this is sounding".
            if (isThisPlaying && entry.isSong)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: PlayingEqualizer(size: 10),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    ));
  }
}

// Discovery-rail card: 132px artwork, title + artist. Select-based playing
// state so a card only rebuilds when ITS song starts/stops.
class _HomeSongTile extends ConsumerWidget {
  final Song song;
  final VoidCallback onTap;
  const _HomeSongTile({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Show the audio track's square cover + clean title once resolved; playback
    // still targets the original row (onTap) so queue logic is unchanged.
    final display = conformedForDisplay(ref, song);

    return Container(
      width: 132,
      margin: const EdgeInsets.only(right: 14),
      child: HoldToOpen(
        borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(10)),
        color: ref.watch(themeProvider),
        onHold: () => ContentMenus.showSongMenu(context, song, ref),
        child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)),
              child: Stack(
                children: [
                  AuvyImage(path: display.image, width: 132, height: 132, fit: BoxFit.cover),
                  NowPlayingArtOverlay(
                      rowId: song.id,
                      altId: display.id,
                      title: display.title,
                      artist: song.displayArtist,
                      size: 132,
                      borderRadius: 0,
                      barSize: 16),
                ],
              ),
            ),
            const SizedBox(height: 8),
            NowPlayingTitle(
              title: display.title,
              rowId: song.id,
              altId: display.id,
              artist: song.displayArtist,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 2),
            // Flexible so oversized system font scales compress instead of
            // painting overflow stripes.
            Flexible(
              child: Text(
                song.displayArtist,
                style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 11.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      )),
    );
  }
}

class _TrackListTile extends ConsumerWidget {
  final Song song;
  final VoidCallback onTap;
  const _TrackListTile({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Show the audio track's square cover + clean title once resolved; playback
    // still targets the original row (onTap) so queue logic is unchanged.
    final display = conformedForDisplay(ref, song);

    // Press-and-hold opens the song options menu (replaces the ⋮ button), and
    // the hold is now visible while it charges. See HoldToOpen.
    return HoldToOpen(
      borderRadius: BorderRadius.circular(10),
      color: ref.watch(themeProvider),
      onHold: () => ContentMenus.showSongMenu(context, song, ref),
      child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(8)),
              child: Stack(children: [
                AuvyImage(
                    path: display.image,
                    width: densityNow.artwork(48),
                    height: densityNow.artwork(48),
                    fit: BoxFit.cover),
                NowPlayingArtOverlay(
                    rowId: song.id,
                    altId: display.id,
                    title: display.title,
                    artist: song.displayArtist,
                    borderRadius: 0,
                    barSize: 12),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NowPlayingTitle(
                      title: display.title,
                      rowId: song.id,
                      altId: display.id,
                      artist: song.displayArtist,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Text(song.displayArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.72), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }
}
/// A destination tile in the home browse row (Podcasts / Live Radio).
///
/// Deliberately quiet: a tinted glyph, a label, a hairline border. These are
/// signposts sitting directly above the feed — they must not out-shout the
/// content they introduce.
class _BrowseTile extends ConsumerWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BrowseTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    return GestureDetector(
      onTap: () {
        HapticService.light();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.07)),
        ),
        // ICON ONLY. The labels went when Audiobooks made three tiles: at that
        // width "Audiobooks" and "Live Radio" both ellipsised, so the row read as
        // truncated text rather than as controls. The icons are unambiguous and
        // each one is a standard glyph for its destination.
        //
        // [label] is KEPT and is now the accessibility name — dropping it would
        // leave a screen reader announcing three unlabelled buttons, which is a
        // worse outcome than the one being fixed.
        child: Semantics(
          label: label,
          button: true,
          child: Center(
            child: Icon(icon, color: themeColor, size: 23),
          ),
        ),
      ),
    );
  }
}
