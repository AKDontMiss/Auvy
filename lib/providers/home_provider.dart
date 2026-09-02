import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/page_cache_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

/// Builds the home feed: the rails of songs on the first screen.
///
/// The feed is assembled, NOT fetched
///
/// YouTube Music supplies some shelves; the rest are composed here from the
/// listener's own taste (see intelligence_provider) and cached to disk, because
/// a feed that rebuilds from scratch on every open is both slow and jittery —
/// the same rails in a different order every time reads as instability.
///
/// Section titles are GENERATED here and parsed back in home_page: an artist
/// shelf is titled "For You: `<name>`", a genre one "Best of `<name>`". That coupling
/// is real and easy to break — home_page's `_kSectionPrefixes` must know every
/// prefix this file can emit, or tapping the shelf cannot resolve what it is
/// about. test/ui_honesty_test.dart pins the two together.
///
/// Anything user-visible here is de-duplicated against `seenIds` so the feed does
/// not show the same track in three rails.

List<Song> scrubSongs(List<Song> rawList) {
  final generalRegex = RegExp(r'\bgeneral\b', caseSensitive: false);
  return rawList.where((item) {
    return !generalRegex.hasMatch(item.title) && !generalRegex.hasMatch(item.artist);
  }).toList();
}

/// A COMPILATION title rather than a track — "Elvis Presley's Greatest Hits",
/// "Radio Top Hits", "Now That's What I Call Music".
///
/// ONLY FOR THE GENERIC-SEARCH FALLBACK POOL, NOT A GLOBAL FILTER. A record
/// can legitimately be called "Best Of" and a user may well want it; deleting it
/// everywhere would be worse than the problem. It is applied where the candidates
/// came from searching a generic PHRASE, because that search returns records
/// named after the phrase, which is the actual reason Quick Picks was offering
/// greatest-hits compilations.
///
/// `scrubSongs` did not catch these: it only ever filtered the word "general".
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

// Notifier class that manages home screen content and infinite scrolling logic.
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

  // Both topic lists are memoised, AND the reason is the call count
  //
  // These read as cheap getters and are used like them: eleven call sites,
  // several of them a `.contains()` INSIDE a per-topic loop. The 2026-08-30
  // transcript shows the result — 26 artist-topic builds and 11 genre-topic
  // builds across five launches, each one re-sorting the whole list to answer
  // a single membership question.
  //
  // The genre build is the expensive one: it walks 50 history entries
  // extracting keywords, then sorts with a comparator that calls
  // getGenreBoostMultiplier TWICE PER COMPARISON — O(n log n) provider calls
  // to produce a list that cannot have changed since the last time it was asked
  // for, moments earlier in the same feed build.
  //
  // Keyed on the IDENTITY of the state they are derived from. Both are pure
  // functions of that state plus final seed lists, so an identical input state
  // can only produce an identical list, and any real change replaces the state
  // object, which invalidates the memo by construction. No timer, no manual
  // invalidation to forget.
  //
  // THE RETURNED LIST IS SHARED NOW, SO IT MUST NOT BE MUTATED. Every
  // caller spreads it or asks `.contains`; none sorts or adds in place, and a
  // future one must copy first.
  // Keyed on the maps they read, NOT on the whole state object.
  //
  // The first version of this memo compared the IntelligenceState instance,
  // which was conservative and useless: the state is replaced by any write at
  // all — a play count, a timestamp, so on device the memo missed every time.
  // Measured during one home-feed scroll: ten rebuilds of both lists inside
  // four seconds, each walking 50 history entries and re-sorting, exactly while
  // frames mattered.
  //
  // These functions are pure in the maps named below plus final seed lists, so
  // an identical map means an identical answer, and a write that touches
  // something else no longer invalidates anything. The maps are always REPLACED
  // rather than edited (checked by grep over the notifier), so identity is
  // sound here for the same reason it is in the library save.
  //
  // THE LENGTH IS CHECKED TOO, and _top5Artists in the intelligence notifier
  // does the same for the same map — an in-place `[k] = v` would keep the
  // identity while changing the answer, and a size change is the cheapest way
  // to notice. It is a backstop, not the contract: the contract is that these
  // maps are replaced, and a test enforces it.
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

  /// A time bound, because one input is NOT in any map.
  ///
  /// getGenreBoostMultiplier returns 1.0 once a boost EXPIRES, and expiry is a
  /// clock reading — the boosts map is unchanged when it happens. Keying purely
  /// on the map would therefore pin a stale ordering until the next unrelated
  /// write. Half a minute keeps the burst collapsed (that is the whole cost)
  /// while bounding how late an expiry can show up.
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
    final topArtists = intel.artistAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    // Combine seed artists with user's top artists
    final userArtists = topArtists
      .where((e) => e.value > 0.0) 
      .take(20)
      .map((e) => e.key)
      .toList();
    
    // Drop placeholder artists ("General"/"Unknown"/"Artist"/...) so they're
    // never searched or shown as home topics.
    final combined = <String>{...userArtists, ..._seedArtistTopics}
        .where((a) => !isJunkMusicTerm(a))
        .toList();

    // Sort by intelligence affinity
    combined.sort((a, b) {
      final affinityA = intel.artistAffinities[a] ?? 0.0;
      final affinityB = intel.artistAffinities[b] ?? 0.0;
      return affinityB.compareTo(affinityA);
    });
    
    print("Dynamic Artist Topics: ${combined.take(10).join(', ')}");
    _artistTopicsFromAffinities = intel.artistAffinities;
    _artistTopicsFromLength = intel.artistAffinities.length;
    _artistTopicsMemo = combined;
    _artistTopicsSet = combined.toSet();
    return combined;
  }

  List<String> _getGenreTopics() {
    final intel = ref.read(intelligenceProvider);
    // The NOTIFIER as well as the state: genre inference is one rule and it lives
    // there. This file used to carry a second copy. See [genresFor].
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

    // Sort by affinity + boost.
    //
    // SCORED ONCE PER GENRE, NOT ONCE PER COMPARISON. The comparator used to
    // call getGenreBoostMultiplier for BOTH sides on every comparison, so a
    // 30-genre list made ~300 provider-notifier calls to order 30 items — for a
    // value that depends only on the genre. A decorate-then-sort costs 30.
    final notifier = ref.read(intelligenceProvider.notifier);
    final score = <String, double>{
      for (final g in combined)
        g: (intel.genreAffinities[g] ?? 0.0) *
            notifier.getGenreBoostMultiplier(g),
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

    // fireImmediately is REQUIRED here, not a nicety.
    //
    // ref.listen fires only on a CHANGE, so `keepListening` — the entire "Jump
    // back in" mosaic — stayed EMPTY until the user played something new AFTER
    // this notifier was constructed. Whether the mosaic had content on launch
    // therefore came down to whether playerProvider.history was restored before
    // or after this listener registered: a race. That is the mosaic being
    // "delayed very much, or not showing at all". Seeding from the current value
    // removes the race entirely.
    //
    // The `next.isNotEmpty` guard is gone too: it meant clearing playback history
    // left the mosaic still displaying the trail that had just been cleared.
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

  /// Search terms for a mood chip, PERSONALISED first.
  ///
  /// The old lists hardcoded other people's artists — "SZA" under Relax,
  /// "Hans Zimmer" under Focus, "Drake" under Energize, so tapping a mood could
  /// surface an artist with no connection to the listener OR to the mood. That's
  /// the "filters show artists that aren't really in that genre" complaint.
  ///
  /// Now: pure mood/genre descriptors (never artist names), and the first
  /// entries combine the mood with the listener's OWN top genres, so "Relax"
  /// means *your* chill music. Falls back to the generic descriptors alone when
  /// there's no taste data yet.
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

  ///"RIGHT NOW" — the one rail no other player can build: what you listen to
  /// in THIS slice of the week specifically, ranked by day-part LIFT rather than
  /// raw play counts (see `IntelligenceNotifier.dayPartSignature`).
  ///
  /// Assembled offline from tracks already in `trackMetadata`, so it costs no
  /// network and renders instantly. Returns an EMPTY list until there's enough
  /// history — in which case the rail simply isn't shown, never a thin one.
  ///
  /// Deliberately never restored from the home cache: it depends on the current
  /// day part, so a cached copy would be wrong within hours.
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

  /// Coalesced, so overlapping callers do not each load the feed
  ///
  /// `_initHome` has several callers that do not know about each other: the
  /// constructor, refreshHome's offline branch, and setMood("All"). None of them
  /// is wrong to ask, and two arriving together would each do the work — parsing
  /// the cached feed twice with a warm cache, or issuing two
  /// `/youtubei/v1/browse` requests with a cold one, which are the largest
  /// requests the app makes (measured repeatedly above 1 MB).
  ///
  /// NOT ADDED BECAUSE A DOUBLE LOAD WAS OBSERVED — it was not. The log looked
  /// like one:
  ///
  ///   21:33:46   Using cached home data (0 days old)
  ///   21:33:46   Using cached home data (0 days old)
  ///
  /// but that is ONE load printed by two layers (PageCacheService announced the
  /// hit and this provider announced it again). The duplicate print is gone now.
  /// The guard stays on its own merit: the overlap it prevents is real and
  /// cheap to rule out, and a log that reads like a bug should not be the only
  /// thing standing between two callers and duplicated work.
  ///
  /// A forced refresh always runs — the user asking is never redundant.
  Future<void> _initHome({bool forceRefresh = false}) async {
    if (!forceRefresh) {
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
          
          // The cache layer already announced the hit (see PageCacheService) —
          // printing it again here made ONE load look like two in the log, which
          // is exactly how a phantom bug gets investigated. The age is the only
          // extra detail and the cache layer carries it too.
          
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
      final topArtists = intel.artistAffinities.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // DAILY ROTATION (Discover-Weekly style): feature a DIFFERENT slice of the
      // user's favourites each day — shuffle the top-8 by a per-DAY seed so the
      // "Mix for X" picks change daily but stay stable within the day. Falls back
      // to the plain top-3 when the user has few artists.
      final daySeed = DateTime.now().difference(DateTime(2020, 1, 1)).inDays;
      final mixArtists = (topArtists.take(8).map((e) => e.key).toList()
            ..shuffle(Random(daySeed)))
          .take(3)
          .toList();
      
      // Follow search continuation pages so the mix size tracks the artist's
      // actual catalog. One search page is a fixed ~20 rows (and a second
      // query overlaps it heavily), which is why every mix used to converge
      // on the same count.
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

      // Wait for the taste model before judging it empty.
      //
      // `intel` was captured while IntelligenceNotifier may still have been
      // reading SharedPreferences — it starts with every map empty and fills in
      // asynchronously. So `artistAffinities.isEmpty` below answers "is this a
      // new user?" and "did I just get here first?" identically, and the
      // cold-start branch text-searches "Top Hits" / "Global Pop".
      //
      // That is why Quick Picks intermittently served "Elvis Presley's Greatest
      // Hits" and "Radio Top Hits" to a user with months of listening history: a
      // race, not a bad recommendation. Nothing about the scoring was wrong; it
      // was scoring the wrong pool.
      //
      // Bounded, because a hang here would leave the home feed empty forever —
      // and completes on load FAILURE too, so a corrupt store still falls through
      // to the genuine cold-start path rather than stalling.
      if (!intelNotifier.isHydrated) {
        await intelNotifier.hydrated
            .timeout(const Duration(seconds: 6), onTimeout: () {});
        intel = ref.read(intelligenceProvider); // re-read: it changed underneath
      }

      if (intel.artistAffinities.isNotEmpty) {
        // 1. Gather a large pool of candidates from their top 5 artists
        final topArtists = intel.artistAffinities.keys.toList()
          ..sort((a, b) => (intel.artistAffinities[b] ?? 0.0).compareTo(intel.artistAffinities[a] ?? 0.0));
        
        final futures = topArtists.take(5).map((artistName) async {
          try {
            final searchRes = await _searchService.search(artistName, 'artist');
            if (searchRes.isNotEmpty) {
              return await _searchService.getArtistTopTracks(searchRes.first.id);
            }
          } catch (_) {}
          return <Song>[];
        });
        final results = await Future.wait(futures);
        
        for (var res in results) {
          candidatesPool.addAll(scrubSongs(res)); //  SCRUBBED
        }
        
        // 2. Mix in recent highly-played history tracks
        candidatesPool.addAll(history.take(15).where((s) => !seenIds.contains(s.id)));
      } else {
        // Genuine cold start
        //
        // NO TEXT SEARCHES FOR GENERIC PHRASES. This used to run
        // `search("Top Hits")` + `search("Global Pop")`, and a catalogue search
        // for a phrase returns records NAMED after the phrase, which is
        // literally where "Radio Top Hits" and "Elvis Presley's Greatest Hits"
        // came from. It was not a bad ranking of good candidates; the pool itself
        // was compilation albums.
        //
        // FEmusic_charts is YouTube Music's real region chart, and it is
        // personalized for free when signed in because the catalogue calls
        // already carry the session. So even the first-run pool is closer to this
        // listener than a global phrase search could be.
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
        
        // Run it through the intelligence engine
        // Added slight randomness to the score so pull-to-refresh yields varied results
        final score = intelNotifier.getSongScore(song) + (Random().nextDouble() * 0.8);
        
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
        
        // Vastly relaxed maximum diversity to allow up to 6 songs per artist 
        // to guarantee we don't choke the list and can reach 28
        if (count < 6) {
          picks.add(item.song);
          seenIds.add(item.song.id);
          artistCount[artistKey] = count + 1;
        }
      }
      
      // BACKFILL: If we still somehow didn't hit 28 (due to lack of distinct artists in history), 
      // just force-fill the remaining spots with the highest scored tracks regardless of artist.
      if (picks.length < 28) {
        for (var item in scoredPicks) {
          if (picks.length >= 28) break;
          if (!picks.contains(item.song)) {
            picks.add(item.song);
            seenIds.add(item.song.id);
          }
        }
      }
      
      print(" Precision Quick Picks Generated: ${picks.length} tracks (Strictly Top-Scoring)");
      
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

    // Real YouTube Music home feed (FEmusic_home) → genuine curated sections,
    // expanded to tracks so they fit the track-based home UI. Guarded: any
    // failure falls back to the intelligence-built mixes below.
    // YouTube Music's own DISCOVERY feeds alongside the curated home shelves:
    // real region charts (FEmusic_charts) and this week's releases
    // (FEmusic_new_releases_albums). Auvy previously synthesised both from
    // Last.fm searches. Fetched CONCURRENTLY with the home feed — it's a second
    // browse round-trip, not a second wait, and each is independently guarded,
    // so a dead browse id costs nothing but its own section.
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
      
      //  Discovery Boost: Heavily promote songs by loved artists that AREN'T in history
      if (!historyIds.contains(song.id) && (taste.artistAffinities[song.artist] ?? 0) > 4) {
        score += 5.0; 
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