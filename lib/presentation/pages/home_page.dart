import 'dart:math' show Random;

import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/logic/library_integrity.dart';
import 'package:auvy/providers/library_provider.dart';
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
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/presentation/widgets/listen_together_sheet.dart';
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
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/presentation/widgets/signing_reminder_card.dart';
import 'package:auvy/presentation/pages/whats_new_page.dart';
import 'package:auvy/providers/whats_new_provider.dart';

/// The home screen: a vertical list of horizontally scrolling rails.
///
/// Rails come from home_provider as [HomeSection]s whose TITLE carries the
/// meaning ("For You: Drake"). [_kSectionPrefixes] is the one table used both
/// for the kicker above the header and for working out which artist a tap
/// should open; keep both paths reading it.
///
/// The feed pages in as it scrolls, so build runs often: prefer const
/// children and keep work out of `build`.

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
      // Gated by Settings → Updates → "Check on launch". The banner is separately
      // gated by "Announce new versions", and `UpdateState.shouldAnnounce` makes
      // sure each release is announced only once.
      if (!await UpdateState.checkOnLaunch()) return;
      if (!mounted) return;
      final themeColor = ref.read(themeProvider);
      UpdaterService.checkForUpdates(context, themeColor, reminderMode: true);
    });
    _scrollController.addListener(_onScroll);
    _scrollController.addListener(_maybePullRefresh);

    // One-time prompt to exempt Auvy from battery optimization, which stops some
    // devices (e.g. Samsung/One UI) cutting the network with the screen off and
    // stalling the next track.
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

    // Die roll: a single turn with a slight settle, kept subtle so it isn't the
    // loudest motion on the page.
    _dieCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
    _dieScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08), weight: 35),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0), weight: 65),
    ]).animate(CurvedAnimation(parent: _dieCtrl, curve: Curves.easeInOut));
    _dieRotation = Tween<double>(begin: 0, end: 2 * 3.14159).animate(
        CurvedAnimation(parent: _dieCtrl, curve: Curves.easeOutCubic));
  }

  // Notification permission is requested ONCE in main._initBackgroundServices —
  // a second concurrent request from here raced it and threw PlatformException
  // ("A request for permissions is already running").

  void _rollDie() {
    HapticService.light();
    _dieCtrl.forward(from: 0.0).then((_) {
      if (!mounted) return;
      final home = ref.read(homeProvider);

      // Pick uniformly with Random() below; a clock-based index would cycle
      // through the same few entries on repeated taps.
      final pool = <Song>[
        ...home.quickPicks,
        // When quickPicks is empty (cold start, feed still building), fall back to
        // recent tracks and feed songs; a toast explains if there is still nothing.
        if (home.quickPicks.isEmpty) ...[
          ...home.keepListening,
          for (final section in home.feedSections) ...section.songs,
        ],
      ];
      if (pool.isEmpty) {
        AnimatedToast.show(context,
            text: 'Nothing to pick from yet',
            icon: Icons.casino_rounded,
            color: ref.read(themeProvider));
        return;
      }
      ref
          .read(playerProvider.notifier)
          .playSong(pool[Random().nextInt(pool.length)], source: "Dice");
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
      // Uses the same prefix table as the header (see [_kSectionPrefixes]).
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
        // Logs the query and the result, so a failure can be told apart: unknown
        // title format, empty search, or a genuine identity mismatch.
        print('WARN: artist shelf "${section.title}" -> query "$query" matched '
            'none of ${results.length} result(s): '
            '${results.take(4).map((s) => s.title).join(" | ")}');
        AnimatedToast.show(context, text: "Artist not found", icon: Icons.error_outline, color: Colors.red);
      }
      return;
    }

    // Everything else ("Take it easy", "All hits", mood mixes…) is a mix, not an
    // artist: open the section itself as a track list with Play/Shuffle.
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

                    // Mood / filter chips
                    SliverToBoxAdapter(child: _buildMoodChips(currentMood, themeColor)),

                    // iOS: the SideStore signature is about to run out (or the
                    // one-time offer of reminders). Nothing otherwise.
                    const SliverToBoxAdapter(child: SigningReminderCard()),

                    // Subtle loading bar
                    if (isLoading && !coldAndEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                          child: LinearProgressIndicator(color: themeColor, backgroundColor: Colors.white10, minHeight: 2),
                        ),
                      ),

                    // Cold start: skeleton shell instead of a lone spinner
                    if (coldAndEmpty) ...[
                      SliverToBoxAdapter(child: _buildMosaicSkeleton()),
                      SliverToBoxAdapter(child: _buildRailSkeleton()),
                      SliverToBoxAdapter(child: _buildRailSkeleton()),
                    ] else ...[
                      // Jump back in: 2-column mosaic
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

                      // Weekly Discovery: the built-in playlist rebuilt every Monday
                      // (see KeepFreshNotifier). Nothing until there is a list.
                      SliverToBoxAdapter(
                        child: Consumer(
                          builder: (_, ref, __) {
                            final weekly = ref.watch(libraryProvider
                                .select((s) => s.playlistSongs[kWeeklyDiscoveryTitle]));
                            if (weekly == null || weekly.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return _buildCardRail(
                              kWeeklyDiscoveryTitle,
                              'New for you every Monday',
                              weekly,
                              onHeaderTap: () {
                                final row = ref
                                    .read(libraryProvider)
                                    .allItems
                                    .where((i) => i.title == kWeeklyDiscoveryTitle)
                                    .firstOrNull;
                                if (row == null) return;
                                AppNavigation.push(
                                    context, PlaylistPage(libraryPlaylist: row),
                                    name: AppNavigation.playlistTag(row.title));
                              },
                            );
                          },
                        ),
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

                      // On this day: songs first played on today's date in an earlier year.
                      // Computed locally from existing history (no request), and renders nothing
                      // when there is no match.
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
    // Explicit status-bar inset: a SafeArea inside a scroll view sliver sees the
    // top padding already consumed, so the inset is measured outside the scroll
    // view and passed in.
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

            // What's New: releases and episodes from what the listener follows. The
            // dot says something arrived since the page was last opened.
            Consumer(builder: (_, ref, __) {
              final themeColor = ref.watch(themeProvider);
              final unseen = ref.watch(whatsNewProvider.select((s) => s.unseen));
              return IconButton(
                tooltip: unseen > 0 ? "What's New ($unseen new)" : "What's New",
                onPressed: () {
                  HapticService.selection();
                  AppNavigation.push(context, const WhatsNewPage(), name: 'whats-new');
                },
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      unseen > 0
                          ? Icons.notifications_rounded
                          : Icons.notifications_none_rounded,
                      color: Colors.white.withOpacity(0.72),
                      size: 24,
                    ),
                    if (unseen > 0)
                      Positioned(
                        right: 1,
                        top: 1,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: themeColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }),

            // Listen Together. The player page (its other entry point) needs a current
            // track, so this header button is the only way to start a session before
            // anything has played.
            Consumer(builder: (_, ref, __) {
              final themeColor = ref.watch(themeProvider);
              // Live sessions get the theme colour so an active room is
              // obvious from the feed without opening anything.
              final active = ref.watch(
                  listenTogetherProvider.select((s) => s.active));
              return IconButton(
                tooltip: active
                    ? 'Listen Together — session active'
                    : 'Listen Together',
                onPressed: () {
                  HapticService.selection();
                  showListenTogetherSheet(context);
                },
                icon: Icon(
                  active
                      ? Icons.people_alt_rounded
                      : Icons.people_outline_rounded,
                  color: active ? themeColor : Colors.white.withOpacity(0.72),
                  size: 24,
                ),
              );
            }),
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
          return AuvyPill(
            label: label,
            icon: icon,
            selected: currentMood == label,
            accent: themeColor,
            onTap: () => ref.read(homeProvider.notifier).setMood(label),
          );
        },
      ),
    );
  }

  // Jump back in: compact mosaic.
  //
  // The pool mixes recent tracks with all-time most played. When two or more
  // pool tracks share a real album, the grid shows that album as one tile
  // (tap → album page). The first tile is always the current/most recent track.
  //
  // Returns up to 18 entries in page order (chunked into pages of 6 by
  // _buildMosaicGrid, deduplicated across all pages):
  //   0–5   recency-sorted mix.
  //   6–11  all-time most played, by play count (same album collapse).
  //   12–17 variety: remaining most-played interleaved with older recents,
  //         albums and playlists that didn't make earlier pages.
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
    // Never spoken word: an episode's albumId is its feed and a chapter's is the
    // audiobook marker, and grouping them made an album tile that opened nothing
    // (chapters of different books even merged into one).
    bool hasRealAlbumId(Song s) =>
        !s.isSpokenWord &&
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

    // Page 1: the recency mix.
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

    // Hide recent playlist tiles whose library playlist was deleted or renamed.
    //
    // Filtered at render time rather than removed from the store, so undoing a
    // delete brings the tile back too. Only library playlists are checked; an
    // entry with an `externalId` opens independently of the library.
    //
    // An empty library means "not loaded yet", not "everything was deleted":
    // Home can build before the library has loaded, so with nothing to check
    // against every tile is shown.
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
    // Four equal cells, each a glyph over a label, so every label fits at a
    // quarter of the row width. The die is marked only by an accent-coloured
    // glyph, so it doesn't outshine the three destinations.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: _QuickAction(
              icon: Icons.podcasts_rounded,
              label: 'Podcasts',
              onTap: () => AppNavigation.push(context, const PodcastPage(),
                  name: AppNavigation.podcastTag),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _QuickAction(
              icon: Icons.radio_rounded,
              // Shortened from "Live Radio" so the label fits; the page title and glyph
              // already say it.
              label: 'Radio',
              onTap: () => AppNavigation.push(context, const RadioPage(),
                  name: AppNavigation.radioTag),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _QuickAction(
              icon: Icons.menu_book_rounded,
              label: 'Audiobooks',
              onTap: () => AppNavigation.push(context, const AudiobooksPage(),
                  name: AppNavigation.audiobooksTag),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedBuilder(
              animation: _dieCtrl,
              builder: (_, child) => Transform.scale(
                scale: _dieScale.value,
                child: Transform.rotate(angle: _dieRotation.value, child: child),
              ),
              child: _QuickAction(
                icon: Icons.casino_rounded,
                label: 'Surprise',
                accent: true,
                onTap: _rollDie,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Discovery feed: sections from the provider (fetchNextSection, moods,
  // curated mixes).
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
  /// Both the header and the artist tap handler ([_handleTitleTap]) read this
  /// table, so a new shelf format can't be handled by one and missed by the
  /// other (which makes every artist tap fail with "Artist not found").
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

  // "For You: Drake" → ("Drake", "FOR YOU"): the name becomes the header and the
  // prefix a small kicker above it. Unknown patterns get a generic kicker.
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

/// Whether [entry] is the collection playback is coming FROM.
///
/// Shared by the tile (to light itself) and the grid (to know whether any
/// collection already claims the playback, so a member song's tile can stand
/// down). One predicate keeps the two from disagreeing.
bool _collectionIsPlaying(PlayerState ps, _MosaicEntry entry) {
  if (!ps.isPlaying || ps.currentSong == null) return false;

  // Origin, not membership: a collection tile is lit because playback started
  // from it, not because the current track happens to belong to it. Once
  // playback rolls into autoplay ("Recommended") or an automatic jump
  // ("Discovery"), the collection is no longer the origin (see
  // player_playback.dart).
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

/// A mosaic tile's cover, with a user-chosen override applied.
///
/// Playlist covers are keyed `playlist:<title>`, the same key playlist_page
/// writes when a cover is picked. select() narrows the watch to this one
/// key, so only this tile repaints when it changes.
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

/// One cell of the Jump Back In mosaic, and which kind it is:
///   • song     — a single playable track.
///   • album    — a real album (2+ pooled tracks sharing a real album id).
///   • playlist — a recently played playlist (external or library) that
///                reopens the original.
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

      // Only one tile may claim the playback. When a collection tile is lit for
      // this playback, the song tile stands down, since the collection is what
      // you'd tap to get back to it. (Albums already fold their songs into one
      // tile; playlists can't, because a recent playlist has no track list.)
      //
      // Only then: a track reached by autoplay has no claiming collection, so its
      // own tile keeps the equalizer.
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
            // Collection tiles resolve their cover through [_entryImage], which watches
            // the cover override for this tile only, so a newly chosen cover appears
            // without a reload and without any request.
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
            // The equalizer means "this is the audio", so only a song tile shows it. A
            // lit collection tile shows an accent-coloured title instead, meaning
            // "playing from here".
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
                      duration: song.duration,
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
              duration: song.duration,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 2),
            // Flexible so oversized system font scales compress instead of
            // painting overflow stripes.
            Flexible(
              child: ExplicitArtistLine(
                isExplicit: song.isExplicit == true,
                text: song.displayArtist,
                style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 11.5),
                badgeSize: 11,
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
                    duration: song.duration,
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
                      duration: song.duration,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  ExplicitArtistLine(
                    isExplicit: song.isExplicit == true,
                    text: song.displayArtist,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 12),
                    badgeSize: 11,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }
}
/// One cell of the home quick-actions row (Podcasts, Radio, Audiobooks,
/// Surprise): a tinted glyph over a small label, kept quiet so it doesn't
/// outshine the feed below.
///
/// [accent] marks the one action among the destinations (the die) by
/// colouring its glyph only.
class _QuickAction extends ConsumerWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    return Semantics(
      label: label,
      button: true,
      child: GestureDetector(
        onTap: () {
          HapticService.light();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            // ONE treatment, not two. Fill AND border on a low-emphasis control
            // draws twice the attention it has earned.
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 19,
                  color: accent ? themeColor : Colors.white.withValues(alpha: 0.88)),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 10,
                  height: 1.0,
                  letterSpacing: 0.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
