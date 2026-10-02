import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/page_cache_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

/// Removes rows whose title or artist is the placeholder word "general".

List<Song> scrubSongs(List<Song> rawList) {
  final generalRegex = RegExp(r'\bgeneral\b', caseSensitive: false);
  return rawList.where((item) {
    return !generalRegex.hasMatch(item.title) && !generalRegex.hasMatch(item.artist);
  }).toList();
}

/// A compilation title rather than a track ("Elvis Presley's Greatest Hits",
/// "Radio Top Hits", "Now That's What I Call Music"). Only applied to the
/// generic-search fallback pool, where searching a generic phrase returns records
/// named after it; elsewhere a record called "Best Of" may be exactly what the
/// user wants.
final RegExp _compilationTitle = RegExp(
  r"\bgreatest hits\b|\btop hits\b|\bbest of\b|\ball time\b|\bnow that'?s what\b"
  r"|\bmegamix\b|\bnon.?stop\b|\bhits collection\b|\bthe hits\b|\bmix tape\b"
  r"|\btop \d+\b|\bplaylist\b|\bcompilation\b|\banthology\b|\bessentials\b",
  caseSensitive: false,
);

bool _looksLikeCompilation(String title) => _compilationTitle.hasMatch(title);
  
// State model for the home screen containing recommendations and feed sections.
class HomeState {
  final List<Song> quickPicks;
  final List<Song> keepListening;
  final List<HomeSection> feedSections;
  final bool isLoading;
  final bool isFetchingMore;
  final String currentMood; 
  final Set<String> seenIds;
  final Set<String> usedTopics; 
  final bool hasReachedEnd; 
  final List<Song> speedDial;
  final List<Song> forgottenFavorites;

  HomeState({
    this.quickPicks = const [],
    this.keepListening = const [],
    this.feedSections = const [],
    this.speedDial = const [], 
    this.forgottenFavorites = const [],
    this.isLoading = true,
    this.isFetchingMore = false,
    this.hasReachedEnd = false, 
    this.currentMood = "All",
    Set<String>? seenIds,
    this.usedTopics = const {},
  }) : seenIds = seenIds ?? {};

  // Creates a copy of the state with updated values.
  HomeState copyWith({
    List<Song>? quickPicks,
    List<Song>? keepListening,
    List<Song>? speedDial, 
    List<Song>? forgottenFavorites,
    List<HomeSection>? feedSections,
    bool? hasReachedEnd,
    bool? isLoading,
    bool? isFetchingMore,
    String? currentMood,
    Set<String>? seenIds,
    Set<String>? usedTopics,
  }) {
    return HomeState(
      quickPicks: quickPicks ?? this.quickPicks,
      keepListening: keepListening ?? this.keepListening,
      speedDial: speedDial ?? this.speedDial,
      forgottenFavorites: forgottenFavorites ?? this.forgottenFavorites,
      feedSections: feedSections ?? this.feedSections,
      isLoading: isLoading ?? this.isLoading,
      hasReachedEnd: hasReachedEnd ?? this.hasReachedEnd,
      isFetchingMore: isFetchingMore ?? this.isFetchingMore,
      currentMood: currentMood ?? this.currentMood,
      seenIds: seenIds ?? this.seenIds,      
      usedTopics: usedTopics ?? this.usedTopics,
    );
  }
}

// Builds the home feed.
//
// The feed is assembled, not just fetched: YouTube Music supplies some shelves,
// and the rest are composed from the listener's taste (see intelligence_provider)
// and cached to disk, so the rails don't rebuild in a different order on every
// open.
//
// Section titles generated here are parsed back in home_page: an artist shelf
// is "For You: `<name>`", a genre shelf "Best of `<name>`". home_page's
// `_kSectionPrefixes` must know every prefix this file emits
// (test/ui_honesty_test.dart checks this). User-visible tracks are deduplicated
// against `seenIds` so a track doesn't appear in several rails.
class HomeNotifier extends StateNotifier<HomeState> {
  final Ref ref;
  final PageCacheService _cacheService = PageCacheService();
  static const int _maxSeenIds = 200;

  /// Personalized feed length: the home feed ends where the personalization
  /// runs out. Light/new listeners get a short feed that stops cleanly instead
  /// of paging through generic filler; heavy listeners can scroll deeper.
  /// (Connectivity still applies its own ceiling on top of this.)
  int _personalizedSectionCap() {
    final intel = ref.read(intelligenceProvider);
    final tasteSignals =
        intel.artistAffinities.length + intel.genreAffinities.length;
    final historyDepth = ref.read(playerProvider).history.length;
    // 6 sections baseline, +1 per ~4 known artists/genres, +1 per ~25 plays.
    final cap = 6 + (tasteSignals ~/ 4) + (historyDepth ~/ 25);
    return cap.clamp(6, 24);
  }

  Set<String> _pruneSeenIds(Set<String> ids) {
    if (ids.length <= _maxSeenIds) return ids;
    return ids.toList().sublist(ids.length - _maxSeenIds).toSet();
  }

  // Dedup history for "Jump back in" — by id AND by title+artist so the same
  // track resolved under different video ids doesn't show up twice.
  List<Song> _uniqueSongs(List<Song> songs, {int limit = 28}) {
    final seenIds = <String>{};
    final seenSig = <String>{};
    final out = <Song>[];
    for (final s in songs) {
      final sig = '${s.title.toLowerCase().trim()}|${s.artist.toLowerCase().trim()}';
      if (seenIds.contains(s.id) || seenSig.contains(sig)) continue;
      seenIds.add(s.id);
      seenSig.add(sig);
      out.add(s);
      if (out.length >= limit) break;
    }
    return out;
  }
  
  // Seed topics - will be dynamically expanded based on user taste
  final List<String> _seedArtistTopics = ["The Weeknd", "Tory Lanez", "Taylor Swift", "Ariana Grande", "Post Malone", "Ed Sheeran", "Travis Scott", "Bad Bunny", "Doja Cat", "Drake", "Billie Eilish", "SZA"];
  final List<String> _seedGenreTopics = ["Pop", "R&B", "Hip-hop", "Electronic", "Rock", "Indie", "Lo-Fi", "Trap", "Dance", "Soul"];

  // Both topic lists are memoised: they're read at many call sites, some inside
  // per-topic loops, and the genre build (walking 50 history entries and sorting)
  // is expensive.
  //
  // Keyed on the maps they read (not the whole state object, which changes on
  // every write). The functions are pure in those maps plus fixed seed lists, and
  // the maps are always replaced rather than edited (a test enforces this), so an
  // identical map means an identical answer. The length is checked too, as a
  // cheap backstop against an in-place edit. The returned lists are shared, so
  // callers must not mutate them; copy first.
  Map<String, double>? _artistTopicsFromAffinities;
  int _artistTopicsFromLength = -1;
  List<String>? _artistTopicsMemo;
  Set<String>? _artistTopicsSet;
  Map<String, double>? _genreTopicsFromAffinities;
  int _genreTopicsFromLength = -1;
  Object? _genreTopicsFromBoosts;
  Object? _genreTopicsFromHistory;
  DateTime? _genreTopicsAt;
  List<String>? _genreTopicsMemo;

  /// A time bound, because one input isn't in any map: getGenreBoostMultiplier
  /// returns 1.0 once a boost expires, which depends on the clock. 30 seconds still
  /// collapses a burst of calls.
  static const Duration _genreTopicsMaxAge = Duration(seconds: 30);

  /// Membership without rebuilding the list — the shape four call sites wanted.
  bool _isArtistTopic(String q) {
    _getArtistTopics();
    return _artistTopicsSet!.contains(q);
  }

  // Dynamic topic generation based on user intelligence
  List<String> _getArtistTopics() {
    final intel = ref.read(intelligenceProvider);
    if (_artistTopicsMemo != null &&
        identical(_artistTopicsFromAffinities, intel.artistAffinities) &&
        _artistTopicsFromLength == intel.artistAffinities.length) {
      return _artistTopicsMemo!;
    }
    // Ranked by today's taste (see IntelligenceNotifier.topArtistsNow), not
    // lifetime totals, so topics don't keep circling artists played heavily years
    // ago. topArtistsNow already drops placeholder names and non-positive scores.
    final userArtists =
        ref.read(intelligenceProvider.notifier).topArtistsNow(limit: 20);
    
    // Drop placeholder artists ("General"/"Unknown"/"Artist"/...) so they're
    // never searched or shown as home topics.
    final combined = <String>{...userArtists, ..._seedArtistTopics}
        .where((a) => !isJunkMusicTerm(a))
        .toList();

    // Sort by affinity: `userArtists` is already in current-taste order, so its
    // position is the ranking. Static seed topics have no affinity and go last.
    final rank = {for (var i = 0; i < userArtists.length; i++) userArtists[i]: i};
    combined.sort((a, b) => (rank[a] ?? userArtists.length)
        .compareTo(rank[b] ?? userArtists.length));
    
    print("Dynamic Artist Topics: ${combined.take(10).join(', ')}");
    _artistTopicsFromAffinities = intel.artistAffinities;
    _artistTopicsFromLength = intel.artistAffinities.length;
    _artistTopicsMemo = combined;
    _artistTopicsSet = combined.toSet();
    return combined;
  }

  List<String> _getGenreTopics() {
    final intel = ref.read(intelligenceProvider);
    // The notifier as well as the state: genre inference is one rule and lives
    // there (see [genresFor]).
    final intelNotifier = ref.read(intelligenceProvider.notifier);
    final history = ref.read(playerProvider).history;
    if (_genreTopicsMemo != null &&
        identical(_genreTopicsFromAffinities, intel.genreAffinities) &&
        _genreTopicsFromLength == intel.genreAffinities.length &&
        identical(_genreTopicsFromBoosts, intel.genreBoosts) &&
        identical(_genreTopicsFromHistory, history) &&
        DateTime.now().difference(_genreTopicsAt!) < _genreTopicsMaxAge) {
      return _genreTopicsMemo!;
    }
    
    // Extract genres from recently played songs
    final recentGenres = <String>{};
    for (final song in history.take(50)) {
      // Extract genre-like keywords from song metadata
      if (song.albumTitle.isNotEmpty) {
        final keywords = intelNotifier.genresFor(song);
        recentGenres.addAll(keywords);
      }
    }
    
    // Combine with seed genres and user's genre affinities
    final topGenres = intel.genreAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    final userGenres = topGenres
      .where((e) => e.value > 1.0)
      .take(15)
      .map((e) => e.key)
      .toList();
    
    final raw = <String>{
      ...userGenres,
      ...recentGenres,
      ..._seedGenreTopics,
    }.toList();

    // Collapse case-duplicates ("pop"/"Pop") and drop placeholder/junk genres,
    // which were showing up as duplicate/garbage topic rows on the home feed.
    const junk = {'general', 'unknown', 'music', 'single', 'podcast', ''};
    final seenLower = <String>{};
    final combined = <String>[];
    for (final g in raw) {
      final t = g.trim();
      final lower = t.toLowerCase();
      if (junk.contains(lower) || isJunkMusicTerm(t)) continue;
      if (seenLower.add(lower)) combined.add(t);
    }

    // Sort by affinity + boost, scoring each genre once instead of on every
    // comparison.
    final notifier = ref.read(intelligenceProvider.notifier);
    // A boost must not deepen a negative: genre affinity is signed (a hard skip
    // subtracts), so multiplying a disliked genre by a boost would push it further
    // down.
    final score = <String, double>{
      for (final g in combined)
        g: () {
          final affinity = intel.genreAffinities[g] ?? 0.0;
          if (affinity <= 0) return affinity;
          return affinity * notifier.getGenreBoostMultiplier(g);
        }(),
    };
    combined.sort((a, b) => score[b]!.compareTo(score[a]!));
    
    print("Dynamic Genre Topics: ${combined.take(10).join(', ')}");
    _genreTopicsFromAffinities = intel.genreAffinities;
    _genreTopicsFromLength = intel.genreAffinities.length;
    _genreTopicsFromBoosts = intel.genreBoosts;
    _genreTopicsFromHistory = history;
    _genreTopicsAt = DateTime.now();
    _genreTopicsMemo = combined;
    return combined;
  }


  HomeNotifier(this.ref) : super(HomeState()) {
    _initHome();

    // fireImmediately is required: ref.listen only fires on a change, so without it
    // the "Jump back in" mosaic stayed empty until something new was played,
    // depending on whether history was restored before or after this listener
    // registered. Clearing history now also clears the mosaic.
    ref.listen(playerProvider.select((p) => p.history), (prev, next) {
      final tiles = _uniqueSongs(next);
      // Only publish when the TILES actually differ. History changes far more
      // often than the mosaic's content does — a replay, a reorder, or the same
      // track recorded again all produce an identical tile list, and assigning
      // it anyway rebuilt the whole mosaic for no visible change.
      if (_sameSongs(state.keepListening, tiles)) return;
      state = state.copyWith(keepListening: tiles);
    }, fireImmediately: true);

    // Audio-only mode flip: the cached/in-memory home was assembled under the
    // other mode (it may contain music videos, or be missing them), so rebuild
    // it. Without this the toggle looks like it "doesn't work" until the next
    // manual refresh.
    ref.listen(playerProvider.select((p) => p.processVideosEnabled), (prev, next) {
      if (prev != null && prev != next) refreshHome();
    });
  }
  SearchService get _searchService => ref.read(searchServiceProvider);

  /// Whether two tile lists are the same songs in the same order.
  ///
  /// By id, because the mosaic only renders identity — a Song object rebuilt from
  /// a fresh parse is a different instance describing the same tile.
  static bool _sameSongs(List<Song> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> refreshHome() async {
    // Offline: a forced refresh would wipe the cache and then fail on the
    // network, leaving an empty home. Keep serving the cache instead.
    if (ref.read(connectivityProvider).isOffline) {
      AnimatedToast.message("You're offline — showing saved content");
      await _initHome();
      return;
    }
    await _cacheService.clearHomeCache();
    await _initHome(forceRefresh: true);
  }

  /// Search terms for a mood chip, personalised first: mood/genre descriptors only
  /// (never artist names), with the first entries combining the mood with the
  /// listener's own top genres, so "Relax" means their kind of chill. Falls back to
  /// the generic descriptors when there's no taste data yet.
  List<String> _moodTopics(String mood) {
    const profiles = <String, List<String>>{
      // Nine each, not five. A mood page builds one shelf per descriptor, so
      // five capped the whole page at a handful of rows while All showed a full
      // feed — tapping a mood felt like the app had LESS to offer, not more.
      'Energize': ['upbeat', 'high energy', 'dance', 'feel good', 'anthems',
          'pop bangers', 'summer hits', 'road trip', 'motivation'],
      'Relax': ['chill', 'lo-fi', 'acoustic', 'mellow', 'calm',
          'sunday morning', 'coffeehouse', 'soft indie', 'late night'],
      'Focus': ['instrumental', 'ambient', 'study', 'concentration', 'piano',
          'deep focus', 'minimal', 'soundtrack', 'reading'],
      'Workout': ['workout', 'gym', 'hype', 'running', 'pump up',
          'cardio', 'training', 'beast mode', 'sprint'],
      'Party': ['party', 'club', 'dance hits', 'house', 'bangers',
          'throwback party', 'latin party', 'afrobeats', 'pregame'],
      'Sad': ['sad', 'heartbreak', 'emotional', 'ballads', 'melancholy',
          'crying', 'breakup', 'slow burn', 'rainy day'],
    };
    final descriptors = profiles[mood];
    if (descriptors == null) {
      return [..._getArtistTopics(), ..._getGenreTopics()];
    }

    // The listener's strongest genres, best first.
    final intel = ref.read(intelligenceProvider);
    final myGenres = intel.genreAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final out = <String>[];
    // "<my genre> <mood descriptor>" — on-theme AND in the listener's world.
    for (final g in myGenres.take(2)) {
      if (g.key.trim().isEmpty) continue;
      out.add('${g.key} ${descriptors.first}');
    }
    // Generic mood descriptors as the reliable tail (also the whole list for a
    // brand-new listener).
    out.addAll(descriptors.map((d) => '$d music'));
    return out;
  }

  /// "Right now": what you listen to in this slice of the week, ranked by day-part
  /// lift rather than raw play counts (see `IntelligenceNotifier.dayPartSignature`).
  /// Built offline from tracks already in `trackMetadata`, so it costs no network.
  /// Empty until there's enough history, and never restored from the home cache,
  /// since it depends on the current day part.
  List<HomeSection> _rightNowSections() {
    try {
      final intelNotifier = ref.read(intelligenceProvider.notifier);
      final mix = intelNotifier.rightNowMix();
      if (mix.length < 5) return const [];
      return [
        HomeSection(
          title: intelNotifier.dayPartLabel(),
          songs: mix,
          type: 'rightnow',
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Shared while a load is in flight, so overlapping callers join it rather than
  /// starting a second one.
  Future<void>? _inFlightHome;

  /// When the last load finished, so a refresh arriving moments later can be
  /// recognised as redundant.
  DateTime? _lastHomeLoadAt;

  /// How close together two loads have to be to count as the same one.
  ///
  /// Generous on purpose: the collision this exists for is two callers reacting
  /// to the same launch, seconds apart at most. A user pulling to refresh is
  /// FORCED (see forceRefresh) and always goes through.
  static const Duration _homeCoalesce = Duration(seconds: 8);

  /// Coalesced: `_initHome` is called from the constructor, refreshHome's offline
  /// branch and setMood("All"), and overlapping calls would each parse the cache or
  /// issue their own large browse requests. A forced refresh always runs.
  Future<void> _initHome({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      // Nothing goes over the network before there's a user. This notifier is built
      // during boot, so on a fresh install it would build a home feed on the login
      // page, for someone not yet approved, and cache Quick Picks built from an empty
      // taste profile. Sign-in calls refreshHome(forceRefresh: true), which skips this
      // guard. The signal is the sticky signed-in flag rather than readable cookies,
      // so a storage hiccup can't lock a signed-in user out of their feed.
      if (!await SessionCookieManager().hasPersistentSession()) {
        print('home: no session yet — skipping the pre-login feed fetch '
            '(sign-in calls refreshHome)');
        return;
      }
      final pending = _inFlightHome;
      if (pending != null) return pending;
      final last = _lastHomeLoadAt;
      if (last != null && DateTime.now().difference(last) < _homeCoalesce) {
        return;
      }
    }
    final run = _initHomeBody(forceRefresh: forceRefresh);
    _inFlightHome = run;
    try {
      await run;
    } finally {
      if (_inFlightHome == run) _inFlightHome = null;
      _lastHomeLoadAt = DateTime.now();
    }
  }

  Future<void> _initHomeBody({bool forceRefresh = false}) async {
    //  CACHE: Try loading from cache first
    if (!forceRefresh) {
      // Offline, take the cache WHATEVER its age. The freshness rules exist to
      // keep the feed moving day to day; with no network there is nothing to
      // move to, and discarding the cache left the page blank but for the
      // recents mosaic (local state, not cache, which is why that one row kept
      // showing while everything under it vanished).
      final bool offline = ref.read(connectivityProvider).isOffline;
      final cachedData =
          await _cacheService.getCachedHomeData(allowStale: offline);
      if (cachedData != null) {
        try {
          // Parse cached data
          final quickPicks = (cachedData['quickPicks'] as List?)
              ?.map((json) => Song.fromMap(json))
              .toList() ?? [];
          final sections = (cachedData['sections'] as List?)
              ?.map((json) => HomeSection.fromJson(json))
              .toList() ?? [];
          
          // The cache layer already logs the hit (PageCacheService), so this doesn't log
          // it again.
          
          // We must generate the intelligence lists before returning
          final intel = ref.read(intelligenceProvider);
          final history = ref.read(playerProvider).history;
          
          // 1. Speed Dial — genuinely most-played (>= 2 plays). No relax to
          // "any track" and no recent-history fallback, so it stays empty until
          // songs are actually replayed instead of echoing one recent track.
          final pcEntries = intel.playCounts.entries
              .where((e) => e.value >= 2 && intel.trackMetadata.containsKey(e.key) && !e.key.startsWith('onb_'))
              .toList()..sort((a, b) => b.value.compareTo(a.value));
          final speedDial = pcEntries.map((e) => intel.trackMetadata[e.key]!).where((s) => s.image.isNotEmpty).toList();

          // 2. Forgotten Favorites — high-affinity AND not played in >14 days.
          // No relax/history fallback, so a lone recent play yields an empty row
          // rather than duplicating that track into this section too.
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          const fourteenDays = 14 * 24 * 60 * 60 * 1000;
          final ffEntries = intel.trackAffinities.entries.where((e) {
            final last = intel.lastPlayTimestamps[e.key] ?? 0;
            return e.value > 1.0 && (nowMs - last) > fourteenDays && intel.trackMetadata.containsKey(e.key) && !e.key.startsWith('onb_');
          }).toList()..sort((a, b) => b.value.compareTo(a.value));
          final forgottenFavorites = ffEntries.map((e) => intel.trackMetadata[e.key]!).where((s) => s.image.isNotEmpty).toList();

          // 3. Inject them into the state.
          //    "Right Now" is recomputed here rather than restored: it is local
          //    and instant (no network), and it is DAY-PART dependent — a rail
          //    cached at 2am must never still be showing at 9am. So any cached
          //    copy is dropped and a fresh one is prepended.
          final freshRightNow = _rightNowSections();
          state = state.copyWith(
            isLoading: false,
            quickPicks: quickPicks,
            feedSections: [
              ...freshRightNow,
              ...sections.where((s) => s.type != 'rightnow'),
            ],
            keepListening: _uniqueSongs(history),
            // Dedup by id AND title+artist so the same song under two video ids
            // (e.g. audio vs music-video version) isn't listed twice.
            speedDial: _uniqueSongs(speedDial),
            forgottenFavorites: _uniqueSongs(forgottenFavorites),
          );
          return;
        } catch (e) {
          print("WARN: Failed to parse cached home data: $e");
          // Continue to fresh fetch
        }
      }
    }
    
    print("Fetching fresh home data");
    state = state.copyWith(isLoading: true, usedTopics: {});

    final seenIds = <String>{};
    final history = ref.read(playerProvider).history;
    // Not final: re-read after awaiting hydration below, because the taste model
    // fills in asynchronously and this snapshot can be an empty placeholder.
    var intel = ref.read(intelligenceProvider);

    final initialKeep = <Song>[];
    final keepSeen = <String>{};
    for (var s in history) {
      if (!keepSeen.contains(s.id)) { initialKeep.add(s); keepSeen.add(s.id); }
      if (initialKeep.length >= 28) break; // Extended jump back in to 28
    }
    for (var s in initialKeep) seenIds.add(s.id);

    List<Song> picks = [];
    List<HomeSection> dailyMixes = [];

    // PRO FEATURE: Generate Daily Mixes from history
    if (intel.artistAffinities.isNotEmpty) {
      // Ranked as of TODAY — see IntelligenceNotifier.topArtistsNow. A mix named
      // after someone the listener has not played in a year is the clearest
      // possible symptom of a taste model that never forgets.
      final topArtists =
          ref.read(intelligenceProvider.notifier).topArtistsNow(limit: 8);

      // DAILY ROTATION (Discover-Weekly style): feature a DIFFERENT slice of the
      // user's favourites each day — shuffle the top-8 by a per-DAY seed so the
      // "Mix for X" picks change daily but stay stable within the day. Falls back
      // to the plain top-3 when the user has few artists.
      final daySeed = DateTime.now().difference(DateTime(2020, 1, 1)).inDays;
      final mixArtists = (topArtists.toList()..shuffle(Random(daySeed)))
          .take(3)
          .toList();
      
      // Follow search continuation pages so a mix's size tracks the artist's actual
      // catalogue rather than one fixed search page.
      final mixResults = await Future.wait(
        mixArtists.map((artist) async {
          final merged = <Song>[];
          final ids = <String>{};
          String? token;
          try {
            for (var page = 0; page < 4; page++) {
              final res = await _searchService.executeScopedSearch(
                artist,
                scope: SearchContextScope.tracks,
                continuationToken: token,
              );
              for (final s in res.items) {
                if (s.id.isNotEmpty && ids.add(s.id)) merged.add(s);
              }
              token = res.continuationToken;
              if (token == null || merged.length >= 60) break;
            }
          } catch (_) {}
          return merged;
        })
      );

      for (int i = 0; i < mixArtists.length; i++) {
        if (mixResults[i].isNotEmpty) {
          dailyMixes.add(HomeSection(
            title: "Mix for ${mixArtists[i]}",
            songs: scrubSongs(mixResults[i]), //  SCRUBBED
            type: 'mix'
          ));
        }
      }
    }

    List<Song> candidatesPool = [];

    try {
      final intelNotifier = ref.read(intelligenceProvider.notifier);

      // Wait for the taste model before judging it empty. IntelligenceNotifier starts
      // with empty maps and loads asynchronously, so `artistAffinities.isEmpty` can't
      // tell "new user" from "not loaded yet". Treating a loading profile as a new
      // user sent established users generic "Top Hits" picks. Bounded, and completes
      // on load failure too, so a corrupt store still reaches the real cold-start path.
      if (!intelNotifier.isHydrated) {
        await intelNotifier.hydrated
            .timeout(const Duration(seconds: 6), onTimeout: () {});
        intel = ref.read(intelligenceProvider); // re-read: it changed underneath
      }

      if (intel.artistAffinities.isNotEmpty) {
        // The candidate pool decides what Quick Picks can show. Three sources, each
        // different in character:
        //
        //   A. the user's own favourites, a rotating slice of them (the same per-day
        //      seed trick as the Daily Mixes), so the feed changes day to day.
        //   B. artists YouTube Music lists as related to those: the discovery axis.
        //   C. the region chart, which owes nothing to history.
        //
        // Favourites are ranked by today's taste, not lifetime totals.
        final ranked = intelNotifier.topArtistsNow(limit: 12);

        // Stable within a day, different between days. Same seed basis as the
        // Daily Mixes, so the two rotate together rather than fighting.
        final daySeed = DateTime.now().difference(DateTime(2020, 1, 1)).inDays;
        final seeds = (ranked.toList()..shuffle(Random(daySeed)))
            .take(4)
            .toList();

        final futures = <Future<List<Song>>>[];

        for (final artistName in seeds) {
          futures.add(() async {
            try {
              // resolveArtistCard, not `search(...).first`, so a pool for "Drake" can't be
              // built from Drake Bell's catalogue.
              final card = await _searchService.resolveArtistCard(artistName);
              if (card == null) return <Song>[];
              return await _searchService.getArtistTopTracks(card.id);
            } catch (_) {
              return <Song>[];
            }
          }());
        }

        // B — neighbours of the two strongest seeds. getRelatedArtists caches
        // for three days, so this is close to free after the first build.
        for (final artistName in seeds.take(2)) {
          futures.add(() async {
            try {
              final related = await _searchService.getRelatedArtists(artistName);
              final out = <Song>[];
              for (final r in related.take(2)) {
                if (r.id.isEmpty) continue;
                out.addAll(await _searchService.getArtistTopTracks(r.id));
              }
              return out;
            } catch (_) {
              return <Song>[];
            }
          }());
        }

        // C — the chart floor.
        futures.add(() async {
          try {
            final sections = await _searchService.getDiscoveryFeed(
                charts: true, newReleases: false, maxSectionsEach: 1);
            return sections.expand((sec) => sec.songs).toList();
          } catch (_) {
            return <Song>[];
          }
        }());

        // Log the pool (seeds, size, distinct artists) so its variety can be checked
        // from a log.
        print('QuickPicks: seeds=${seeds.join(", ")}');
        for (final res in await Future.wait(futures)) {
          candidatesPool.addAll(scrubSongs(res)); //  SCRUBBED
        }
        print('QuickPicks: pool=${candidatesPool.length} tracks from '
            '${candidatesPool.map((s) => s.artist.toLowerCase()).toSet().length} '
            'distinct artists');

        // 2. Mix in recent highly-played history tracks
        candidatesPool.addAll(history.take(15).where((s) => !seenIds.contains(s.id)));
      } else {
        // Genuine cold start: use YouTube Music's region chart (FEmusic_charts,
        // personalised when signed in) rather than text searches for generic phrases,
        // which return compilation albums named after the phrase.
        final chartSections = await _searchService.getDiscoveryFeed(
            charts: true, newReleases: false, maxSectionsEach: 2);
        candidatesPool = scrubSongs(
            chartSections.expand((s) => s.songs).toList()); //  SCRUBBED

        // Last resort only — charts can come back empty (region with no chart,
        // offline, a parse change). Compilation titles are dropped here because
        // this path is a phrase search and that is exactly what it attracts.
        if (candidatesPool.isEmpty) {
          final results = await Future.wait([
            _searchService.search("Top Hits", 'track'),
            _searchService.search("Global Pop", 'track'),
          ]);
          candidatesPool = scrubSongs([...results[0], ...results[1]])
              .where((s) => !_looksLikeCompilation(s.title))
              .toList();
        }
      }

      // Strict algorithmic scoring
      final scoredPicks = <({Song song, double score})>[];
      
      final seenCandidateIds = <String>{};
      for (var song in candidatesPool) {
        if (song.image.isEmpty || song.image.contains('lastfm')) continue;
        if (seenIds.contains(song.id) || intel.blacklistedIds.contains(song.id)) continue;
        if (seenCandidateIds.contains(song.id)) continue; // ← cross-artist dedup
        seenCandidateIds.add(song.id);
        
        // Score with the intelligence engine plus a small random nudge so pull-to-refresh
        // varies. getSongScore returns roughly −1..+1, so the nudge (0.06, about the
        // freshness weight) only reshuffles near-ties.
        final score = intelNotifier.getSongScore(song) + (Random().nextDouble() * 0.06);
        
        // Only accept content that the algorithm actively likes (> 0.0)
        if (score > 0.0 || intel.artistAffinities.isEmpty) { 
          scoredPicks.add((song: song, score: score));
        }
      }
      
      // Sort strictly by highest score descending
      scoredPicks.sort((a, b) => b.score.compareTo(a.score));

      // Selection with diversity
      final Map<String, int> artistCount = {};
      for (var item in scoredPicks) {
        if (picks.length >= 28) break; 
        
        final artistKey = item.song.artist.toLowerCase();
        final count = artistCount[artistKey] ?? 0;
        
        // At most three tracks per artist, so the breadth of the pool shows up as a
        // varied list.
        if (count < 3) {
          picks.add(item.song);
          seenIds.add(item.song.id);
          artistCount[artistKey] = count + 1;
        }
      }
      
      // Backfill: if the pool can't fill 28 under a cap of 3, relax to 5, not to
      // unlimited. A shorter varied list beats a long repetitive one.
      if (picks.length < 28) {
        for (var item in scoredPicks) {
          if (picks.length >= 28) break;
          if (picks.contains(item.song)) continue;
          final artistKey = item.song.artist.toLowerCase();
          final count = artistCount[artistKey] ?? 0;
          if (count >= 5) continue;
          picks.add(item.song);
          seenIds.add(item.song.id);
          artistCount[artistKey] = count + 1;
        }
      }
      
      // The SPREAD is the measurable outcome. "28 tracks" was true before the
      // fix too; "28 tracks / 5 artists" versus "28 tracks / 17 artists" is the
      // difference the change was made for, and it is one line to carry it.
      final spread = picks.map((s) => s.artist.toLowerCase()).toSet().length;
      print("Precision Quick Picks Generated: ${picks.length} tracks from "
          "$spread distinct artists");
      
    } catch (e) {
      print("ERROR: Error generating Quick Picks: $e");
    }

    // --- Speed Dial: genuinely most-played (>= 2 plays). ---
    // No "relax to any track" or "recent history" fallback: the section stays
    // short/empty until the user actually replays songs, instead of padding
    // itself with a single recently-played track. That force-fill (plus the
    // grid's pad-by-repeat) is what made one played track show up in every
    // section for brand-new users.
    final pcEntries = intel.playCounts.entries
        .where((e) =>
            e.value >= 2 &&
            intel.trackMetadata.containsKey(e.key) &&
            !e.key.startsWith('onb_'))
        .toList()..sort((a, b) => b.value.compareTo(a.value));

    final speedDial = pcEntries
        .map((e) => intel.trackMetadata[e.key]!)
        .where((s) => s.image.isNotEmpty)
        .toList();

    // --- Forgotten Favorites: liked/high-affinity tracks NOT played recently. ---
    // Requires genuinely "forgotten" tracks (>14 days since last play); no relax
    // or candidate/history fallback, so a new user with one recent play gets an
    // EMPTY section rather than that same track echoed here too.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const fourteenDays = 14 * 24 * 60 * 60 * 1000;

    final ffEntries = intel.trackAffinities.entries
        .where((e) {
          final last = intel.lastPlayTimestamps[e.key] ?? 0;
          return e.value > 1.0 &&
              (nowMs - last) > fourteenDays &&
              intel.trackMetadata.containsKey(e.key) &&
              !e.key.startsWith('onb_');
        })
        .toList()..sort((a, b) => b.value.compareTo(a.value));

    final forgottenFavorites = ffEntries
        .map((e) => intel.trackMetadata[e.key]!)
        .where((s) => s.image.isNotEmpty)
        .toList();

    // YouTube Music's own feeds: the curated home shelves (FEmusic_home), expanded
    // to tracks for the track-based home UI, plus the region charts
    // (FEmusic_charts) and this week's releases (FEmusic_new_releases_albums).
    // Fetched concurrently and each guarded, so a failing browse id only loses its
    // own section; the intelligence-built mixes below remain either way.
    List<HomeSection> ytmMixes = [];
    List<HomeSection> discovery = [];
    try {
      final results = await Future.wait([
        _searchService.getCuratedHomeMixes(maxSections: 3),
        _searchService.getDiscoveryFeed(maxSectionsEach: 1),
      ]);
      ytmMixes = results[0];
      discovery = results[1];
    } catch (_) {}
    final rightNow = _rightNowSections();

    // Order: "Right Now" first (most contextual), then the curated YTM home
    // shelves, then charts/releases, then the locally-built daily mixes.
    final baseSections = <HomeSection>[
      ...rightNow,
      ...ytmMixes,
      ...discovery,
      ...dailyMixes,
    ];

    try {
      final cacheData = {
        'quickPicks': picks.map((s) => s.toMap()).toList(),
        'sections': baseSections.map((s) => s.toJson()).toList(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await _cacheService.cacheHomeData(cacheData);
    } catch (e) {
      print("WARN: Failed to cache home data: $e");
    }

    state = state.copyWith(
      // Dedup by id AND title+artist so the same song under different video ids
      // doesn't appear twice in any of these rails.
      keepListening: _uniqueSongs(initialKeep),
      quickPicks: picks,
      speedDial: _uniqueSongs(speedDial),
      forgottenFavorites: _uniqueSongs(forgottenFavorites),
      seenIds: _pruneSeenIds(seenIds),
      isLoading: false,
      hasReachedEnd: false,
      usedTopics: {},
      feedSections: baseSections,
    );

    await fetchNextSection();
  }

  Future<void> fetchRandom() async {
    state = state.copyWith(isLoading: true, currentMood: "Random", usedTopics: {});
    
    List<HomeSection> randomSections = [];
    final allTopics = [..._getArtistTopics(), ..._getGenreTopics()]..shuffle();
    final updatedSeenIds = Set<String>.from(state.seenIds);
    final updatedTopics = <String>{};
    
    // Parallel Fetch for efficiency
    final selectedTopics = allTopics.take(5).toList();
    final futures = selectedTopics.map((t) => _searchService.search(t, 'track'));
    
    try {
      final resultsList = await Future.wait(futures);
  
      for (int i = 0; i < resultsList.length; i++) {
        final topic = selectedTopics[i];
        final results = scrubSongs(resultsList[i]); //  SCRUBBED
        
        // Filter duplicates BEFORE taking 8
        final uniqueResults = results.where((s) => !updatedSeenIds.contains(s.id)).take(8).toList();
        
        // Add to seenIds in batch
        updatedSeenIds.addAll(uniqueResults.map((s) => s.id));

        if (uniqueResults.isNotEmpty) {
          String type = _isArtistTopic(topic) ? 'artist' : 'genre';          
          randomSections.add(HomeSection(title: "Random: $topic", songs: uniqueResults, type: type));
          updatedTopics.add(topic);
        }
      }
    } catch (_) {}
    
    state = state.copyWith(
      isLoading: false,
      feedSections: randomSections,
      hasReachedEnd: false, 
      seenIds: _pruneSeenIds(updatedSeenIds),       
      usedTopics: updatedTopics,
    );
  }

  Future<void> setMood(String mood) async {
    if (mood == "All") {
      // Cache-first: switching back to "All" restores the cached home
      // instantly instead of clearing the cache and re-fetching everything.
      state = state.copyWith(currentMood: "All", usedTopics: {});
      await _initHome();
      return;
    }
    if (mood == "Random") {
      await fetchRandom();
      return;
    }

    state = state.copyWith(currentMood: mood, isLoading: true, usedTopics: {});
    
    final moodTopics = _moodTopics(mood);

    try {
      List<HomeSection> newSections = [];
      final updatedSeenIds = Set<String>.from(state.seenIds);
      final updatedTopics = <String>{};

      // The PERSONALISED terms are built first by _moodTopics and must lead, so
      // only the generic tail is shuffled for variety between taps.
      if (moodTopics.length > 2) {
        final tail = moodTopics.sublist(2)..shuffle();
        moodTopics.replaceRange(2, moodTopics.length, tail);
      }
      // 8 shelves, not 4. The searches below run in PARALLEL, so the extra
      // topics cost roughly one round trip rather than four.
      final selectedTopics = moodTopics.take(8).toList();

      // PARALLEL FETCH: Much faster than sequential
      final futures = selectedTopics.map((query) => _searchService.search(query, 'track'));
      final resultsList = await Future.wait(futures);

      for (int i = 0; i < resultsList.length; i++) {
        final query = selectedTopics[i];
        final results = scrubSongs(resultsList[i]); //  SCRUBBED
        final List<Song> sectionSongs = [];

        for (var s in results) {
          if (!updatedSeenIds.contains(s.id)) {
            sectionSongs.add(s);
            updatedSeenIds.add(s.id);
          }
          if (sectionSongs.length >= 14) break;
        }

        if (sectionSongs.isNotEmpty) {
           final type = _isArtistTopic(query) ? 'artist' : 'genre';
           // Mood queries are descriptive phrases ("chill music", "hip hop
           // chill"), so "Best of chill music" reads badly — title-case the
           // phrase instead and let the mood chip supply the context.
           final title = type == 'artist'
               ? "Best of $query"
               : query
                   .split(' ')
                   .where((w) => w.isNotEmpty)
                   .map((w) => w[0].toUpperCase() + w.substring(1))
                   .join(' ');
           newSections.add(HomeSection(title: title, songs: sectionSongs, type: type));
           updatedTopics.add(query);
        }
      }

      state = state.copyWith(
        isLoading: false, 
        feedSections: newSections,
        hasReachedEnd: false, 
        seenIds: updatedSeenIds,
        usedTopics: updatedTopics,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> fetchNextSection() async {
  final connectivity = ref.read(connectivityProvider);
  final searchService = _searchService;
  final taste = ref.read(intelligenceProvider); 
  
  if (connectivity.isOffline) {
    state = state.copyWith(hasReachedEnd: true);
    return;
  }
  
  final maxSections = min(connectivity.maxHomeSections, _personalizedSectionCap());
  if (state.isFetchingMore || state.hasReachedEnd || state.feedSections.length >= maxSections) {
    if (state.feedSections.length >= maxSections) state = state.copyWith(hasReachedEnd: true);
    return;
  }

  state = state.copyWith(isFetchingMore: true);

  //  STRICT FILTERING: Only show Genre sections if the user is in a specific mood filter!
  final isFiltered = state.currentMood != "All" && state.currentMood != "Random";
  
  final artistTopics = _getArtistTopics();
  final genreTopics = _getGenreTopics();
  final allTopics = isFiltered
      ? [...artistTopics, ...genreTopics]
      : [...artistTopics, ...genreTopics.take((genreTopics.length * 0.35).ceil())];                        
      
  final availableTopics = allTopics.where((t) => !state.usedTopics.contains(t)).toList();
  
  //  Time-Aware weighted sampling
  final weightedTopics = ref.read(intelligenceProvider.notifier).getWeightedTopics(availableTopics);
  
  String? query;
  bool isArtist = false;

  if (weightedTopics.isNotEmpty) {
    // 85% Intelligence-led, 15% Random exploration
    if (Random().nextDouble() < 0.85) {
      query = weightedTopics.first;
    } else {
      query = availableTopics[Random().nextInt(availableTopics.length)];
    }
    isArtist = _isArtistTopic(query);
  }
  
  if (query == null) {
    state = state.copyWith(isFetchingMore: false, hasReachedEnd: true);
    return;
  }

  //  Trigger Fatigue: Record that we are showing this topic now
  ref.read(intelligenceProvider.notifier).markTopicSeen(query);
  
    try {
      List<Song> results;

      if (isArtist) {
        final artistSearch = await searchService.search(query, 'artist');
        if (artistSearch.isNotEmpty) {
          results = await searchService.getArtistTopTracks(artistSearch.first.id);
        } else {
          results = await searchService.search(query, 'track');
        }
      } else {
        results = await searchService.search(query, 'track');
      }
      
    // Scrubbed before processing
    results = scrubSongs(results);

    final updatedSeenIds = Set<String>.from(state.seenIds);
    List<Song> uniqueTracks = [];

    final candidates = results.where((s) => 
      !updatedSeenIds.contains(s.id) && 
      !taste.blacklistedIds.contains(s.id)
    ).toList();

    // IMPROVED: Use intelligence-based scoring
    final intelNotifier = ref.read(intelligenceProvider.notifier);
    final scored = <({Song song, double score})>[];
    final historyIds = ref.read(playerProvider).history.map((h) => h.id).toSet();

    for (final song in candidates) {
      double score = intelNotifier.getSongScore(
        song,
        currentContext: isArtist ? query : null,
      );
      
      // Discovery boost for songs by loved artists that aren't in history, sized for
      // getSongScore's −1..+1 range so it tips close calls without overriding the
      // ranking.
      if (!historyIds.contains(song.id) && (taste.artistAffinities[song.artist] ?? 0) > 4) {
        score += 0.25;
      }

      scored.add((song: song, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    uniqueTracks = scored.take(6).map((s) => s.song).toList();

    // Mark these specific tracks as "Seen" for this session
    for (final song in uniqueTracks) {
      updatedSeenIds.add(song.id);
    }

     if (uniqueTracks.isNotEmpty) {
      final newSection = HomeSection(
        title: isArtist ? "For You: $query" : "Best of $query",
        songs: uniqueTracks,
        type: isArtist ? 'artist' : 'genre',
      );
      state = state.copyWith(
        feedSections: [...state.feedSections, newSection],
        seenIds: _pruneSeenIds(updatedSeenIds),
        usedTopics: {...state.usedTopics, query},
        isFetchingMore: false,
      );
    } else {
      // No unique tracks for this topic — mark it used and try up to 2
      // more topics in the SAME call rather than recursing
      final exhaustedTopics = {...state.usedTopics, query};
      state = state.copyWith(usedTopics: exhaustedTopics);
 
      final allTopics = [..._getArtistTopics(), ..._getGenreTopics()];
      final remaining = allTopics
          .where((t) => !exhaustedTopics.contains(t))
          .toList();
 
      bool found = false;
      for (final fallbackQuery in remaining.take(2)) {
        final fallbackIsArtist = _isArtistTopic(fallbackQuery);
        List<Song> fallbackResults;
 
        try {
          if (fallbackIsArtist) {
            final artistSearch =
                await searchService.search(fallbackQuery, 'artist');
            fallbackResults = artistSearch.isNotEmpty
                ? await searchService
                    .getArtistTopTracks(artistSearch.first.id)
                : await searchService.search(fallbackQuery, 'track');
          } else {
            fallbackResults =
                await searchService.search(fallbackQuery, 'track');
          }
        } catch (_) {
          fallbackResults = [];
        }
        
        // Scrubbed before processing
        fallbackResults = scrubSongs(fallbackResults);
 
        final fallbackCandidates = fallbackResults
            .where((s) =>
                !updatedSeenIds.contains(s.id) &&
                !taste.blacklistedIds.contains(s.id))
            .toList();
 
        final fallbackScored = fallbackCandidates.map((s) {
          final score = intelNotifier.getSongScore(
            s,
            currentContext: fallbackIsArtist ? fallbackQuery : null,
          );
          return (song: s, score: score);
        }).toList()
          ..sort((a, b) => b.score.compareTo(a.score));
 
        final fallbackTracks =
            fallbackScored.take(6).map((s) => s.song).toList();
 
        if (fallbackTracks.isNotEmpty) {
          for (final s in fallbackTracks) updatedSeenIds.add(s.id);
          final fallbackSection = HomeSection(
            title: fallbackIsArtist
                ? 'For You: $fallbackQuery'
                : 'Best of $fallbackQuery',
            songs: fallbackTracks,
            type: fallbackIsArtist ? 'artist' : 'genre',
          );
          state = state.copyWith(
            feedSections: [...state.feedSections, fallbackSection],
            seenIds: _pruneSeenIds(updatedSeenIds),
            usedTopics: {...state.usedTopics, fallbackQuery},
            isFetchingMore: false,
          );
          found = true;
          break;
        }
 
        state = state.copyWith(
            usedTopics: {...state.usedTopics, fallbackQuery});
      }
 
      if (!found) {
        state = state.copyWith(
          isFetchingMore: false,
          hasReachedEnd: remaining.isEmpty,
        );
      }
    }
  } catch (e) {
    state = state.copyWith(isFetchingMore: false);
  }
  }
}

final homeProvider = StateNotifierProvider<HomeNotifier, HomeState>((ref) {
  return HomeNotifier(ref);
});