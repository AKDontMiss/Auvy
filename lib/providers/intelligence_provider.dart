import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/logic/track_identity.dart' show primaryArtistOf;
import 'package:auvy/services/event_log.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/play_tally.dart';
import 'package:auvy/services/set_log.dart';
// Genre tags for the scorer. See [IntelligenceState.artistGenres].
import 'package:auvy/services/artist_metadata_service.dart';

/// Placeholder / category words from the app's own fallback labels ("General" for
/// unknown genre, "Top"/"Top songs" shelf labels) and generic YouTube channels.
/// Never used as recommendation seeds or kept as candidate tracks. Matched on the
/// whole trimmed value, so real songs like "Radio", "Music" or "General
/// Admission" are unaffected.
const Set<String> _kJunkMusicTerms = {
  // Genre / context / shelf placeholders
  'general', 'top', 'topic', 'top hits', 'top 50', 'top songs', 'top result',
  'top tracks', 'trending', 'trending radio', 'pop music', 'global pop',
  // Generic shelf, chart and discovery labels, matched on the whole trimmed value
  // (so "Best Coast" doesn't match). Common words that are real song titles
  // ("Radio", "Music", "New", "Hot", "Mix", "Song") are deliberately left out.
  'hits', 'top charts', 'charts', 'billboard hot 100',
  'popular', 'popular songs', 'popular music', 'most popular',
  'best', 'best songs', 'best of', 'best hits', 'greatest hits', 'the best',
  'mainstream', 'hot hits', 'new music', 'new releases',
  'recommended', 'recommended for you', 'for you', 'featured', 'essentials',
  'daily mix', 'my mix', 'discover', 'trending now',
  // "Unknown*" fallbacks used across the parser / models / services
  'unknown', 'unknown artist', 'unknown title', 'unknown song', 'unknown album',
  'unknown station', 'unknown podcast', 'unknown episode', 'artist',
  // "Various*" generic-compilation channels
  'various', 'various artist', 'various artists',
  // Album / title placeholders and app-internal labels
  'single', 'untitled', 'auvy downloads', 'auvy',
  // Empty-ish sentinels
  'na', 'n/a', 'null', 'none', '-', '--',
};

/// True when [s], normalized, is one of the placeholder/category words above —
/// i.e. not a real artist / track / seed. A trailing YouTube " - Topic" channel
/// suffix is stripped before checking (that suffix alone shouldn't disqualify a
/// real artist).
bool isJunkMusicTerm(String? s) {
  if (s == null) return true;
  var t = s.trim().toLowerCase();
  if (t.isEmpty) return true;
  if (t.endsWith(' - topic')) t = t.substring(0, t.length - ' - topic'.length).trim();
  return _kJunkMusicTerms.contains(t);
}

/// The single "My Top 50" ranking, shared by the library folder (its count) and
/// the playlist page, so they always agree.
///
/// Ranked by actual listen count (`playCounts`), not the blended affinity score,
/// so a heavily played song doesn't drop out after a few skips. Ties break by
/// first-played date, then id; both are fixed, so a song only moves when its
/// count passes the one above. Duplicate uploads of one song (same title and
/// artist, different id) collapse into one row.
List<Song> computeTop50(
  Map<String, int> playCounts,
  Map<String, Song> trackMetadata, [
  Map<String, int> firstPlayTimestamps = const {},
]) {
  int plays(String id) => playCounts[id] ?? 0;

  final ranked = trackMetadata.values
      .where((s) =>
          !s.id.startsWith('onb_') &&
          !s.id.startsWith('dummy') &&
          s.title.isNotEmpty &&
          plays(s.id) > 0)
      .toList()
    ..sort((a, b) {
      final byPlays = plays(b.id).compareTo(plays(a.id));
      if (byPlays != 0) return byPlays;
      // Oldest-known song keeps the higher slot; 1<<50 sinks entries that
      // predate first-play tracking below tracked ones (deterministically).
      final byFirst = (firstPlayTimestamps[a.id] ?? (1 << 50))
          .compareTo(firstPlayTimestamps[b.id] ?? (1 << 50));
      if (byFirst != 0) return byFirst;
      return a.id.compareTo(b.id);
    });

  final seen = <String>{};
  final deduped = <Song>[];
  for (final s in ranked) {
    final key = '${s.title.trim().toLowerCase()}|${s.artist.trim().toLowerCase()}';
    if (seen.add(key)) deduped.add(s);
  }
  return deduped.take(50).toList();
}

class IntelligenceState {
  final Map<String, int> playCounts;
  /// Track id to the timestamps of its individual plays: the per-play ledger,
  /// unlike [playCounts], which is only a total. Windowed questions ("plays in the
  /// last 30 days") need the stamps. Older records store seconds, newer ones
  /// milliseconds, so readers normalise with the 10-digit test (see the stats
  /// builder). Capped together with playCounts.
  final Map<String, List<int>> playHistory;
  final Map<String, double> artistAffinities;
  final Map<String, double> genreAffinities;
  final Map<String, double> sessionAffinities;
  final Map<String, double> trackAffinities;
  final List<String> recentTopics;
  final Map<int, Map<String, double>> timeOfDayAffinities;
  final Set<String> blacklistedIds;
  final Map<String, GenreBoost> genreBoosts; 
  final Map<String, int> genreStreakTracker; 
  final Map<String, int> lastPlayTimestamps;
  final Map<String, int> firstPlayTimestamps;
  final DateTime lastBoostUpdate;
  final DateTime firstUseDate;
  final List<Song> listeningHistory;
  final Map<String, Song> trackMetadata;

  // "Scary-smart" signals
  /// Markov transition graph: fromArtist → (toArtist → count). Learns "after A
  /// you tend to play B" so autoplay can predict the NEXT craving.
  final Map<String, Map<String, int>> artistTransitions;
  /// Per-artist recent play timestamps (epoch ms, capped) → momentum/velocity
  /// ("rising" vs "fading" tastes).
  final Map<String, List<int>> artistPlayTimestamps;
  /// Context affinity keyed by day-part bucket ("weekday-morning",
  /// "weekend-night", …) → genre/artist → score. Finer than hour-only.
  final Map<String, Map<String, double>> dayPartAffinities;

  /// Artist → known genre tags, lowercased. Genre is mostly an artist property, so
  /// it's looked up once per artist and saved, rather than guessed from track
  /// titles (which rarely name a genre). An artist with no tags is stored as an
  /// empty list, meaning "asked, found nothing", so it isn't retried on every play.
  final Map<String, List<String>> artistGenres;

  IntelligenceState({
    this.firstPlayTimestamps = const {},
    this.playCounts = const {},
    this.playHistory = const {},
    this.artistAffinities = const {},
    this.genreAffinities = const {},
    this.trackAffinities = const {},
    this.sessionAffinities = const {},
    this.timeOfDayAffinities = const {},
    this.blacklistedIds = const {},
    this.recentTopics = const [],
    this.genreBoosts = const {},
    this.genreStreakTracker = const {},
    this.lastPlayTimestamps = const {},
    DateTime? lastBoostUpdate,
    DateTime? firstUseDate,
    this.listeningHistory = const [],
    this.trackMetadata = const {},
    this.artistTransitions = const {},
    this.artistPlayTimestamps = const {},
    this.dayPartAffinities = const {},
    this.artistGenres = const {},
  }) : lastBoostUpdate = lastBoostUpdate ?? DateTime.now(),
       firstUseDate = firstUseDate ?? DateTime.now();

  IntelligenceState copyWith({
    Map<String, int>? firstPlayTimestamps,
    Map<String, int>? playCounts,
    Map<String, List<int>>? playHistory,
    Map<String, double>? artistAffinities,
    Map<String, double>? genreAffinities,
    Map<String, double>? sessionAffinities,
    List<String>? recentTopics,
    Map<String, double>? trackAffinities,
    Map<int, Map<String, double>>? timeOfDayAffinities,
    Set<String>? blacklistedIds,
    Map<String, GenreBoost>? genreBoosts,
    Map<String, int>? genreStreakTracker,
    Map<String, int>? lastPlayTimestamps,
    DateTime? lastBoostUpdate,
    DateTime? firstUseDate,
    List<Song>? listeningHistory,
    Map<String, Song>? trackMetadata,
    Map<String, Map<String, int>>? artistTransitions,
    Map<String, List<int>>? artistPlayTimestamps,
    Map<String, Map<String, double>>? dayPartAffinities,
    Map<String, List<String>>? artistGenres,
  }) {
    return IntelligenceState(
      firstPlayTimestamps: firstPlayTimestamps ?? this.firstPlayTimestamps,
      playCounts: playCounts ?? this.playCounts,
      playHistory: playHistory ?? this.playHistory,
      artistAffinities: artistAffinities ?? this.artistAffinities,
      genreAffinities: genreAffinities ?? this.genreAffinities,
      sessionAffinities: sessionAffinities ?? this.sessionAffinities,
      recentTopics: recentTopics ?? this.recentTopics,
      trackAffinities: trackAffinities ?? this.trackAffinities,
      timeOfDayAffinities: timeOfDayAffinities ?? this.timeOfDayAffinities,
      blacklistedIds: blacklistedIds ?? this.blacklistedIds,
      lastPlayTimestamps: lastPlayTimestamps ?? this.lastPlayTimestamps,
      genreBoosts: genreBoosts ?? this.genreBoosts,
      genreStreakTracker: genreStreakTracker ?? this.genreStreakTracker,
      lastBoostUpdate: lastBoostUpdate ?? this.lastBoostUpdate,
      firstUseDate: firstUseDate ?? this.firstUseDate,
      listeningHistory: listeningHistory ?? this.listeningHistory,
      trackMetadata: trackMetadata ?? this.trackMetadata,
      artistTransitions: artistTransitions ?? this.artistTransitions,
      artistPlayTimestamps: artistPlayTimestamps ?? this.artistPlayTimestamps,
      dayPartAffinities: dayPartAffinities ?? this.dayPartAffinities,
      artistGenres: artistGenres ?? this.artistGenres,
    );
  }
}

// Genre boost tracking
class GenreBoost {
  final double multiplier;
  final DateTime expiresAt;
  final String reason; // "streak", "time_preference", "mood_shift"
  
  GenreBoost({
    required this.multiplier,
    required this.expiresAt,
    required this.reason,
  });
  
  bool get isExpired => DateTime.now().isAfter(expiresAt);
  
  Map<String, dynamic> toJson() => {
    'multiplier': multiplier,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'reason': reason,
  };
  
  factory GenreBoost.fromJson(Map<String, dynamic> json) => GenreBoost(
    multiplier: json['multiplier'] ?? 1.0,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] ?? 0),
    reason: json['reason'] ?? 'unknown',
  );
}

class IntelligenceNotifier extends StateNotifier<IntelligenceState> {
  Timer? _saveTimer;

  // Hard cap on how many Song objects we keep in trackMetadata. Without this it
  // grew forever (every track ever interacted with stayed in RAM), so a long
  // session leaked tens of MB. Oldest-inserted entries are pruned first.
  static const int _maxMetadataEntries = 1500;

  /// Cap on [IntelligenceState.trackAffinities], the per-track taste score.
  /// Generous (well past what scoring reads, several times the metadata cap) but
  /// bounded, since this map is saved and backed up on every write.
  static const int _maxTrackAffinities = 4000;

  /// Same, for artist scores. Far fewer artists than tracks, and artistAffinities
  /// feeds the memoised top-5 lookup used by getSongScore.
  static const int _maxArtistAffinities = 1200;

  /// Same, for genres. This map had no bound at all, so it grew a row for every
  /// genre ever inferred and was re-serialised whole on each save. There are
  /// only so many genres a person listens to; a few hundred is already generous
  /// and the weakest rows carry no signal.
  static const int _maxGenreAffinities = 400;

  /// Per hour bucket, across all 24. Artists are recorded here as well as genres,
  /// so it's capped.
  static const int _maxTimeOfDayPerHour = 150;

  /// Drop the WEAKEST entries once [m] exceeds [limit].
  ///
  /// Weakest by absolute value, so a strong dislike is preserved exactly like a
  /// strong like — a −20 "never play this" signal is as load-bearing as a +10, and
  /// pruning by raw value would throw away every dislike first.
  static Map<String, double> _capAffinities(Map<String, double> m, int limit) {
    if (m.length <= limit) return m;
    final entries = m.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    return {for (final e in entries.take(limit)) e.key: e.value};
  }

  IntelligenceNotifier() : super(IntelligenceState()) {
    _loadReady = _loadState();

    // A cross-device merge has to reach LIVE STATE, not just disk — the same
    // save-before-load race the history merge hit. Both of these live in
    // memory here and _saveState writes memory back over the file.
    CloudSyncService.onBlacklistMerged = applyMergedBlacklist;
    CloudSyncService.readPlayCounts = () async {
      await _loadReady;
      return state.playCounts;
    };
    CloudSyncService.onPlayCountsMerged = applyMergedPlayCounts;
  }

  /// Completes when [_loadState] has loaded the saved intelligence into `state`.
  ///
  /// The cross-device merge awaits this: it runs on cloud activation and races the
  /// async load. Merging against the empty initial state would lose the merge, and
  /// could freeze a zero play-count baseline for the whole account (which is
  /// irreversible). PlayTally.baseline also refuses an empty freeze as a second
  /// safeguard.
  late final Future<void> _loadReady;

  // Caps trackMetadata at [_maxMetadataEntries], dropping the oldest-inserted
  // entries first.

  /// Returns a copy of [metadata] trimmed to [_maxMetadataEntries] by dropping
  /// the oldest-inserted entries (Dart maps preserve insertion order).
  Map<String, Song> _capMetadata(Map<String, Song> metadata) {
    if (metadata.length <= _maxMetadataEntries) return metadata;
    final trimmed = Map<String, Song>.from(metadata);
    final overflow = trimmed.length - _maxMetadataEntries;
    for (final key in trimmed.keys.take(overflow).toList()) {
      trimmed.remove(key);
    }
    return trimmed;
  }

  void _saveStateDebounced() {
    _pendingSave = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () {
      _pendingSave = false;
      _saveState();
    });
  }

  /// True while a debounced save is armed but has not written yet.
  bool _pendingSave = false;

  /// Writes a pending save now instead of waiting out the debounce. Taste changes
  /// are saved on a 5-second debounce, so closing the app right after a play, skip
  /// or like would otherwise lose it. Called from the app-pause hook, which runs
  /// before dispose with time to finish the write.
  Future<void> flushPendingSave() async {
    if (!_pendingSave) return;
    _pendingSave = false;
    _saveTimer?.cancel();
    _saveTimer = null;
    print('flushing taste/history to disk before the app leaves the '
        'foreground (the 5s debounce does not survive a close)');
    await _saveState();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Write, don't discard. Not awaited because dispose can't be async; the pause
    // hook above is the reliable path and this is the backstop.
    if (_pendingSave) {
      _pendingSave = false;
      _saveState();
    }
    // Leaving these bound to a disposed notifier would have the next
    // cross-device merge write into dead state.
    if (CloudSyncService.onBlacklistMerged == applyMergedBlacklist) {
      CloudSyncService.onBlacklistMerged = null;
      CloudSyncService.readPlayCounts = null;
      CloudSyncService.onPlayCountsMerged = null;
    }
    super.dispose();
  }

  /// Mean of a map's top five values: the scale used to normalise every signal
  /// before it's weighted.
  ///
  /// The affinity maps are unbounded accumulators (a two-year favourite reaches
  /// hundreds while genre scores stay in single digits), so raw values times fixed
  /// weights would let whichever map holds the biggest numbers win. Dividing by the
  /// top-five mean gives each signal the same meaning: 1.0 is "as strong as this
  /// listener's typical favourite". Five rather than the max, so one runaway artist
  /// doesn't flatten everyone else. Recomputed only when a map is replaced, in one
  /// O(n) pass.
  static double _topMean(Map<String, double> m) {
    if (m.isEmpty) return 1.0;
    final top = <double>[];
    for (final v in m.values) {
      if (v <= 0) continue;
      if (top.length < 5) {
        top.add(v);
        top.sort();
      } else if (v > top.first) {
        top[0] = v;
        top.sort();
      }
    }
    if (top.isEmpty) return 1.0;
    final mean = top.reduce((a, b) => a + b) / top.length;
    // Floored at 1: early on the numbers are tiny, and dividing by 0.3 would
    // make a single play look like a lifetime favourite.
    return mean < 1.0 ? 1.0 : mean;
  }

  /// Identity hashes, not the maps themselves: caching the map objects would keep
  /// the previous generation of every affinity map in memory.
  int _artistSrcId = 0;
  int _trackSrcId = 0;
  int _genreSrcId = 0;
  int _sessionSrcId = 0;
  int _timeSrcId = 0;
  double _artistScale = 1.0;
  double _trackScale = 1.0;
  double _genreScale = 1.0;
  double _sessionScale = 1.0;
  double _timeScale = 1.0;

  void _refreshScales() {
    final a = identityHashCode(state.artistAffinities);
    if (a != _artistSrcId) {
      _artistSrcId = a;
      _artistScale = _topMean(state.artistAffinities);
    }
    final t = identityHashCode(state.trackAffinities);
    if (t != _trackSrcId) {
      _trackSrcId = t;
      _trackScale = _topMean(state.trackAffinities);
    }
    final g = identityHashCode(state.genreAffinities);
    if (g != _genreSrcId) {
      _genreSrcId = g;
      _genreScale = _topMean(state.genreAffinities);
    }
    final ses = identityHashCode(state.sessionAffinities);
    if (ses != _sessionSrcId) {
      _sessionSrcId = ses;
      _sessionScale = _topMean(state.sessionAffinities);
    }
    // Hour and day-part buckets count plays (+1.0 each), a different scale
    // again, so they get their own denominator rather than borrowing one.
    final tm = identityHashCode(state.dayPartAffinities);
    if (tm != _timeSrcId) {
      _timeSrcId = tm;
      _timeScale = _topMean(state.dayPartAffinities[_dayPartKey()] ?? const {});
    }
  }

  /// A raw accumulator as a share of "a typical favourite", clamped to -1..1.
  static double _unit(double raw, double scale) =>
      (raw / scale).clamp(-1.0, 1.0);

  /// How much of [raw] is still current, given when it was last reinforced.
  ///
  /// trackInteraction decays a stored score before adding to it, but only when the
  /// track is played again, so an untouched favourite would keep its old score
  /// forever. This applies decay from the last play to now at ranking time. The two
  /// cover different intervals, so nothing is counted twice.
  ///
  /// Same half-life as the write (0.995/day, ~16% left after a year), capped at a
  /// year to avoid floating-point underflow, and skipped under a day old.
  static double _decayedToNow(double raw, int? lastAtMs, int nowMs) {
    if (raw == 0 || lastAtMs == null || lastAtMs <= 0) return raw;
    final days = ((nowMs - lastAtMs) / 86400000.0).clamp(0.0, 365.0);
    if (days < 1.0) return raw;
    return raw * pow(0.995, days).toDouble();
  }

  /// The most recent play recorded for [artist], or null.
  int? _lastArtistPlayMs(String artist) {
    final ts = state.artistPlayTimestamps[artist];
    return (ts == null || ts.isEmpty) ? null : ts.last;
  }

  /// The one spelling of an artist used as a map key (trimmed), so every map uses
  /// the same key and cross-map lookups (decay, momentum, transitions) don't miss
  /// on stray whitespace.
  static String artistKeyOf(String raw) => raw.trim();

  /// How well [song] fits this listener right now, in roughly −1..+1.
  ///
  /// The percentages are real weights: 20% artist, 15% track, 25% momentum, 30%
  /// genre, 5% time, 5% freshness. Each signal is mapped to −1..+1 against "a
  /// typical favourite" (see [_topMean] and [_unit]) before its weight applies, so
  /// the percentages are the actual mix and scores compare across users and ages
  /// of install. Anything added must be normalised the same way; a raw accumulator
  /// or flat bonus would silently skew the ranking. `test/song_score_blend_test.dart`
  /// guards these properties.
  ///
  /// Cheap enough per candidate: scale denominators are cached per map generation,
  /// genre patterns are compiled once, and [_extractSongGenres] memoises per song.
  /// Nothing here awaits, so it's safe inside a ranking loop.
  double getSongScore(Song song, {String? currentContext}) {
    // First, because nothing below can rescue a banned track and the caller
    // only needs to know that it is banned.
    if (state.blacklistedIds.contains(song.id)) return -1000.0;

    _refreshScales();
    final artistName = artistKeyOf(song.artist);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // 1. Artist affinity (long-term preference), 20%. Decayed to now (see
    // [_decayedToNow]), so an artist abandoned years ago doesn't outrank one found
    // last month.
    final artist = _unit(
        _decayedToNow(state.artistAffinities[artistName] ?? 0.0,
            _lastArtistPlayMs(artistName), nowMs),
        _artistScale);

    // 2. Track-specific affinity (likes, full listens), 15%. The raw value still
    // decides the dislike veto below: a track skipped to death stays vetoed however
    // long ago.
    final trackRaw = state.trackAffinities[song.id] ?? 0.0;
    final track = _unit(
        _decayedToNow(trackRaw, state.lastPlayTimestamps[song.id], nowMs),
        _trackScale);

    // 3. Momentum: what they're reaching for right now, 25%. Four signals blended
    // within −1..1: the session counters, the rising-momentum score and the Markov
    // transition ("after the artist you just played, how often do you pick this
    // one"), the sharpest signal here.
    final sessionArtist =
        _unit(state.sessionAffinities[artistName] ?? 0.0, _sessionScale);
    final sessionGenre = currentContext == null
        ? 0.0
        : _unit(state.sessionAffinities[currentContext] ?? 0.0, _sessionScale);
    final momentum = (sessionArtist * 0.40 +
            sessionGenre * 0.20 +
            _artistTransitionScore(artistName) * 0.25 +
            _risingScore(artistName) * 0.15)
        .clamp(-1.0, 1.0);

    // 4. Genre coherence, 30%: the largest weight, because it keeps a queue or radio
    // sounding like one thing.
    final inferredGenres = _extractSongGenres(song);
    double bestGenre = 0.0;
    for (final g in inferredGenres) {
      final gs = _unit(state.genreAffinities[g] ?? 0.0, _genreScale);
      if (gs > bestGenre) bestGenre = gs;
    }

    double genre;
    if (currentContext != null && currentContext.trim().isNotEmpty) {
      final ctx = currentContext.toLowerCase().trim();
      final ctxScore = _unit(
          (state.genreAffinities[currentContext] ?? 0.0) +
              (state.sessionAffinities[currentContext] ?? 0.0),
          _genreScale);

      // Set membership, not substrings, so a context of "pop" doesn't match Popcaan or
      // "rap" match Rapsody.
      if (inferredGenres.isEmpty) {
        // Unknown genre isn't a mismatch: genre is often unknown, and a flat penalty
        // would rank nothing.
        genre = 0.0;
      } else if (inferredGenres.contains(ctx)) {
        // In the current vibe. The floor of 0.5 is the reward for matching at
        // all; the rest scales with how much this listener actually likes it.
        genre = (0.5 + (ctxScore + bestGenre) * 0.25).clamp(0.0, 1.0);
      } else {
        // A KNOWN and DIFFERENT genre — the only case that has earned a penalty.
        genre = -0.6;
      }
    } else {
      genre = bestGenre;
    }

    // 5. When they listen, 5%.
    final timeCtx = state.timeOfDayAffinities[DateTime.now().hour] ?? const {};
    final dayPart = state.dayPartAffinities[_dayPartKey()] ?? const {};
    final time = _unit(
        (timeCtx[artistName] ?? 0.0) + (dayPart[artistName] ?? 0.0),
        _timeScale);

    // 6. Freshness / overplay, 5%: reward discovery and hold back what's been heard
    // many times, on the same scale as everything else.
    final plays = state.playCounts[song.id] ?? 0;
    final double freshness = plays == 0
        ? 1.0
        : plays <= 3
            ? 0.4
            : plays <= 10
                ? 0.0
                : plays <= 25
                    ? -0.5
                    : -1.0;

    double score = artist * 0.20 +
        track * 0.15 +
        momentum * 0.25 +
        genre * 0.30 +
        time * 0.05 +
        freshness * 0.05;

    // A track they have actively rejected is a veto, not a weight. Bounded, so
    // it cannot swing an unrelated candidate the way a flat −15 did.
    if (trackRaw < -2.0) score -= 0.5;

    return score;
  }

  // "Scary-smart" scoring helpers
  String? _lastRecordedArtist; // the artist of the most recent recorded play

  /// Day-part bucket key, e.g. "weekend-night". Buckets: morning (5-11),
  /// afternoon (12-16), evening (17-21), night (else); weekday vs weekend.
  String _dayPartKey([DateTime? at]) {
    final now = at ?? DateTime.now();
    final h = now.hour;
    final part = h >= 5 && h < 12
        ? 'morning'
        : h >= 12 && h < 17
            ? 'afternoon'
            : h >= 17 && h < 22
                ? 'evening'
                : 'night';
    final weekend = now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
    return '${weekend ? 'weekend' : 'weekday'}-$part';
  }

  // "Right now": a day-part listening signature built from `dayPartAffinities`,
  // which records what is played in each slice of the week. Ranked by lift rather
  // than weight: an artist played constantly would top every day part, so what's
  // interesting is who is played disproportionately now compared with the
  // listener's own baseline (the 2am artist, the Sunday-morning artist).

  /// Human label for the current slice of the week, e.g. "Friday night",
  /// "Weekday mornings", "Sunday afternoon".
  String dayPartLabel([DateTime? at]) {
    final now = at ?? DateTime.now();
    final h = now.hour;
    final part = h >= 5 && h < 12
        ? 'morning'
        : h >= 12 && h < 17
            ? 'afternoon'
            : h >= 17 && h < 22
                ? 'evening'
                : 'night';
    final weekend =
        now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
    if (weekend) {
      const names = {6: 'Saturday', 7: 'Sunday'};
      return '${names[now.weekday]} $part';
    }
    // Weekday nights/mornings feel like a habit rather than one day.
    return 'Weekday ${part}s';
  }

  /// The artists/contexts played disproportionately in the current day part,
  /// strongest lift first. Each entry is `{name, weight, lift}`, where `lift` = this
  /// day part's weight / the mean weight across day parts where the name appears
  /// (>1 means more than usual). Entries seen in only one day part are capped, since
  /// a single late-night play is noise.
  List<Map<String, dynamic>> dayPartSignature({int limit = 12}) {
    final key = _dayPartKey();
    final here = state.dayPartAffinities[key];
    if (here == null || here.isEmpty) return const [];

    // Baseline: mean weight for each name across all day parts that mention it.
    final totals = <String, double>{};
    final counts = <String, int>{};
    for (final part in state.dayPartAffinities.values) {
      part.forEach((name, w) {
        totals[name] = (totals[name] ?? 0) + w;
        counts[name] = (counts[name] ?? 0) + 1;
      });
    }

    final out = <Map<String, dynamic>>[];
    here.forEach((name, weight) {
      if (name.isEmpty || weight <= 0) return;
      final n = counts[name] ?? 1;
      final mean = (totals[name] ?? weight) / n;
      // n == 1 → only ever played here. Distinctive, but unproven: give it a
      // fixed modest lift instead of a divide-by-baseline blowup.
      final lift = n <= 1 ? 1.6 : (mean > 0 ? (weight / mean) : 1.0);
      out.add({'name': name, 'weight': weight, 'lift': lift.clamp(0.0, 6.0)});
    });

    // Rank by lift, then weight — distinctiveness first, popularity as tiebreak.
    out.sort((a, b) {
      final c = (b['lift'] as double).compareTo(a['lift'] as double);
      return c != 0 ? c : (b['weight'] as double).compareTo(a['weight'] as double);
    });
    return out.take(limit).toList();
  }

  /// A ready-to-play "Right now" mix built only from tracks in `trackMetadata`, so
  /// it's instant, works offline, and never shows anything unheard. Ordered by
  /// day-part lift, then track affinity, at most [perArtist] per artist. Returns []
  /// when there isn't enough history; callers then hide the rail.
  List<Song> rightNowMix({int limit = 25, int perArtist = 3}) {
    final signature = dayPartSignature(limit: 20);
    if (signature.isEmpty) return const [];

    // name → lift, for the artists in this day part's signature.
    final lift = <String, double>{
      for (final e in signature)
        (e['name'] as String).toLowerCase(): e['lift'] as double,
    };

    final byArtist = <String, List<Song>>{};
    for (final song in state.trackMetadata.values) {
      // Radio/podcast entries aren't part of a music taste profile.
      if (song.id.startsWith('http') || song.albumTitle == 'Podcast') continue;
      final a = song.artist.toLowerCase().trim();
      if (a.isEmpty || !lift.containsKey(a)) continue;
      if (state.blacklistedIds.contains(song.id)) continue;
      byArtist.putIfAbsent(a, () => []).add(song);
    }
    if (byArtist.isEmpty) return const [];

    // Best-liked tracks first within each artist.
    for (final list in byArtist.values) {
      list.sort((x, y) =>
          (state.trackAffinities[y.id] ?? 0).compareTo(state.trackAffinities[x.id] ?? 0));
    }

    // Interleave: strongest-lift artists lead, but round-robin so the top
    // artist doesn't own the whole rail.
    final artistsByLift = byArtist.keys.toList()
      ..sort((x, y) => (lift[y] ?? 0).compareTo(lift[x] ?? 0));
    final picked = <Song>[];
    final seenIds = <String>{};
    for (var round = 0; round < perArtist; round++) {
      for (final a in artistsByLift) {
        final list = byArtist[a]!;
        if (round >= list.length) continue;
        final song = list[round];
        if (seenIds.add(song.id)) picked.add(song);
        if (picked.length >= limit) return picked;
      }
    }
    return picked;
  }

  // AUVY WRAPPED — the yearly recap

  /// Everything the recap story needs, computed in one pass so cards don't
  /// recompute while swiping.
  ///
  /// [sinceMs] bounds the window (null = all time). Honesty rules:
  ///  * `minutesAreEstimated` is always true: Auvy records play counts, not
  ///    listened time, so minutes are `plays × track length` and the UI says
  ///    "about".
  ///  * `historyWasPaused` reports whether crediting is currently off
  ///    ([ListeningPolicy.pauseListeningHistory]).
  ///  * `hasEnoughData` gates the feature; a recap from nine plays is worse than
  ///    none.
  Map<String, dynamic> wrappedStats({int? sinceMs}) {
    bool inWindow(int ms) => sinceMs == null || ms >= sinceMs;

    // Plays in the window, from the exact per-track stamp ledger
    final playsPerTrack = <String, int>{};
    var totalPlays = 0;
    state.playHistory.forEach((id, stamps) {
      var n = 0;
      for (final raw in stamps) {
        if (raw <= 0) continue;
        final ms = raw < 10000000000 ? raw * 1000 : raw;
        if (inWindow(ms)) n++;
      }
      if (n > 0) {
        playsPerTrack[id] = n;
        totalPlays += n;
      }
    });
    // Fall back to lifetime counts when the stamp ledger is thin (older installs
    // only kept aggregate counts), so a long-time user still gets a recap.
    if (totalPlays < 10 && sinceMs == null) {
      playsPerTrack
        ..clear()
        ..addAll(state.playCounts);
      totalPlays = state.playCounts.values.fold(0, (s, v) => s + v);
    }

    // Estimated minutes: plays × parsed track duration
    var estMinutes = 0.0;
    playsPerTrack.forEach((id, plays) {
      final meta = state.trackMetadata[id];
      final secs = _durationSeconds(meta?.duration ?? '');
      // 3:30 is the global median pop track — a sane stand-in when a track's
      // duration was never captured, rather than dropping it from the total.
      estMinutes += plays * ((secs > 0 ? secs : 210) / 60.0);
    });

    // Top tracks
    final rankedTracks = playsPerTrack.entries
        .where((e) => state.trackMetadata.containsKey(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topTracks = rankedTracks
        .take(5)
        .map((e) => {'song': state.trackMetadata[e.key]!, 'plays': e.value})
        .toList();

    // Top artists (summed over their tracks, so it matches the plays)
    final artistPlays = <String, int>{};
    playsPerTrack.forEach((id, plays) {
      final a = state.trackMetadata[id]?.artist.trim() ?? '';
      if (a.isEmpty) return;
      artistPlays[a] = (artistPlays[a] ?? 0) + plays;
    });
    final rankedArtists = artistPlays.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topArtists = rankedArtists
        .take(5)
        .map((e) => {'name': e.key, 'plays': e.value})
        .toList();

    // Top genre + longest streak. Placeholder genres ("General", "Unknown", "Top")
    // are filtered out, as everywhere else a genre is shown.
    final rankedGenres = state.genreAffinities.entries
        .where((e) => e.value > 0 && !isJunkMusicTerm(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final streaks = state.genreStreakTracker.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // THE DIFFERENTIATOR: the day part you're most distinctive in
    // Ranked by LIFT (see dayPartSignature), so this names your 2am artist
    // rather than repeating your overall favourite.
    final dayPartKeys = state.dayPartAffinities.keys.toList();
    String? peakPartKey;
    var peakWeight = 0.0;
    for (final k in dayPartKeys) {
      final w = state.dayPartAffinities[k]!.values.fold<double>(0, (s, v) => s + v);
      if (w > peakWeight) {
        peakWeight = w;
        peakPartKey = k;
      }
    }
    final nightSignature = _signatureForPart('night');

    // Discovery: artists heard for the FIRST time inside the window
    var newArtists = 0;
    final seenFirst = <String>{};
    state.firstPlayTimestamps.forEach((id, ms) {
      if (!inWindow(ms)) return;
      final a = state.trackMetadata[id]?.artist.trim().toLowerCase() ?? '';
      if (a.isEmpty || !seenFirst.add(a)) return;
      newArtists++;
    });

    return {
      'totalPlays': totalPlays,
      'estimatedMinutes': estMinutes.round(),
      'minutesAreEstimated': true,
      'historyWasPaused': ListeningPolicy.historyPaused,
      'uniqueTracks': playsPerTrack.length,
      'uniqueArtists': artistPlays.length,
      'newArtists': newArtists,
      'topTracks': topTracks,
      'topArtists': topArtists,
      'topGenre': rankedGenres.isNotEmpty ? rankedGenres.first.key : '',
      'streakGenre': streaks.isNotEmpty ? streaks.first.key : '',
      'streakLength': streaks.isNotEmpty ? streaks.first.value : 0,
      'peakDayPart': peakPartKey ?? '',
      'nightArtist': nightSignature,
      // 25 plays across 5 tracks is the floor for a recap that says anything.
      'hasEnoughData': totalPlays >= 25 && playsPerTrack.length >= 5,
    };
  }

  /// Highest-lift name in any day part matching [partSuffix] ('night',
  /// 'morning', …). '' when there's nothing distinctive.
  String _signatureForPart(String partSuffix) {
    final totals = <String, double>{};
    final counts = <String, int>{};
    for (final part in state.dayPartAffinities.values) {
      part.forEach((n, w) {
        totals[n] = (totals[n] ?? 0) + w;
        counts[n] = (counts[n] ?? 0) + 1;
      });
    }
    String best = '';
    var bestLift = 0.0;
    state.dayPartAffinities.forEach((key, bucket) {
      if (!key.endsWith(partSuffix)) return;
      bucket.forEach((name, weight) {
        final n = counts[name] ?? 1;
        if (n <= 1) return; // unproven — one play isn't a habit
        final mean = (totals[name] ?? weight) / n;
        final lift = mean > 0 ? weight / mean : 0.0;
        if (lift > bestLift) {
          bestLift = lift;
          best = name;
        }
      });
    });
    return bestLift > 1.15 ? best : '';
  }

  /// "3:45" / "1:02:03" / raw seconds → seconds. 0 when unparseable.
  static int _durationSeconds(String d) {
    final s = d.trim();
    if (s.isEmpty) return 0;
    if (!s.contains(':')) return int.tryParse(s) ?? 0;
    final parts = s.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  /// P(next artist == [toArtist] | last played artist), from the Markov graph.
  /// 0 when we have no transition data from the last artist.
  double _artistTransitionScore(String rawTo) {
    final toArtist = artistKeyOf(rawTo);
    final from = _lastRecordedArtist;
    if (from == null || from.isEmpty || from == toArtist) return 0.0;
    final row = state.artistTransitions[from];
    if (row == null || row.isEmpty) return 0.0;
    final total = row.values.fold<int>(0, (s, v) => s + v);
    if (total <= 0) return 0.0;
    return (row[toArtist] ?? 0) / total; // 0..1
  }

  /// Momentum in [-1, 1]: (recent plays − prior plays) / total over a 14-day
  /// window (last 7 days vs the 7 before). Positive = rising taste.
  double _risingScore(String rawArtist) {
    final ts = state.artistPlayTimestamps[artistKeyOf(rawArtist)];
    if (ts == null || ts.length < 2) return 0.0;
    final now = DateTime.now().millisecondsSinceEpoch;
    const week = 7 * 86400000;
    int recent = 0, prior = 0;
    for (final t in ts) {
      final age = now - t;
      if (age <= week) {
        recent++;
      } else if (age <= 2 * week) {
        prior++;
      }
    }
    final total = recent + prior;
    if (total == 0) return 0.0;
    return (recent - prior) / total; // -1..1
  }
  
  void trackLike(Song song, {required bool isLiked}) {
    final newTracks = Map<String, double>.from(state.trackAffinities);
    final newArtists = Map<String, double>.from(state.artistAffinities);
    
    if (isLiked) {
      // Massive boost for liked songs
      newTracks[song.id] = (newTracks[song.id] ?? 0.0) + 10.0;
      newArtists[song.artist] = (newArtists[song.artist] ?? 0.0) + 3.0;
      print("Liked: ${song.title} by ${song.artist}");
    } else {
      // Remove like boost
      newTracks[song.id] = (newTracks[song.id] ?? 0.0) - 10.0;
      newArtists[song.artist] = (newArtists[song.artist] ?? 0.0) - 3.0;
      print("Unliked: ${song.title}");
    }
    
    state = state.copyWith(
      trackAffinities: newTracks,
      artistAffinities: newArtists,
    );
    
    _saveStateDebounced();
  }

  /// Replaces the in-session affinity map (the "vibe shift" boost) through the
  /// notifier, so the change is saved.
  void setSessionAffinities(Map<String, double> affinities) {
    state = state.copyWith(sessionAffinities: affinities);
    _saveStateDebounced();
  }

  void bumpLastPlayTimestamp(String songId) {
    if (songId.isEmpty) return;
    // The history-pause switch is enforced here, where data is written. See
    // _refuseIfPaused.
    if (_refuseIfPaused('bumpLastPlayTimestamp')) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final newTs = Map<String, int>.from(state.lastPlayTimestamps);
    newTs[songId] = now;
    state = state.copyWith(lastPlayTimestamps: newTs);
    _saveStateDebounced();
  }

  /// Artists that go with [currentArtist] in this user's listening, from the
  /// `artistTransitions` graph (fromArtist → toArtist → count), used in both
  /// directions: "played after A" and "played before A" are equal evidence.
  ///
  /// Global affinity is a light tie-breaker, and the fallback when the graph has
  /// never seen this artist, so callers always get some seeds.
  List<String> getComplementaryArtists(String currentArtist, {int limit = 5}) {
    final artist = currentArtist.trim();
    if (artist.isEmpty) return const [];

    // Case-insensitive: artistTransitions is keyed by `song.artist.trim()` in its
    // original case, and callers don't always pass the same casing.
    final needle = artist.toLowerCase();
    final co = <String, double>{};
    void add(String other, int count) {
      final o = other.trim();
      if (o.isEmpty || o.toLowerCase() == needle) return;
      co[o] = (co[o] ?? 0) + count.toDouble();
    }

    // One pass, both directions: what gets played AFTER this artist, and what
    // this artist gets played after.
    state.artistTransitions.forEach((from, row) {
      final fromIsTarget = from.toLowerCase() == needle;
      row.forEach((to, count) {
        if (fromIsTarget) add(to, count);
        if (to.toLowerCase() == needle) add(from, count);
      });
    });

    if (co.isNotEmpty) {
      _refreshScales();
      // Normalise the counts so the affinity tie-break stays a tie-break rather
      // than swamping a genuine but low-count neighbour.
      final maxCo = co.values.reduce(max);
      final ranked = co.entries.map((e) {
        final strength = maxCo <= 0 ? 0.0 : e.value / maxCo;
        // NOT `.clamp(0.0, 1.0)` ON A RAW AFFINITY. These accumulate ~1.5 per
        // full listen, so every artist heard through more than once pinned at
        // exactly 1.0 — the comment above promises a tie-break and the clamp
        // made it a constant, contributing nothing to the ordering. Normalised
        // against a typical favourite, it is the tie-break it claims to be.
        final affinity =
            _unit(state.artistAffinities[e.key] ?? 0.0, _artistScale)
                .clamp(0.0, 1.0);
        return (name: e.key, score: strength * 0.8 + affinity * 0.2);
      }).toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      return ranked.take(limit).map((e) => e.name).toList();
    }

    // Nothing recorded next to this artist — fall back to overall taste. Weaker,
    // and honestly labelled as such, but better than no seed.
    final fallback = <String, double>{};
    for (final a in state.artistAffinities.keys) {
      if (a == artist) continue;
      fallback[a] = ((state.artistAffinities[a] ?? 0.0) * 0.6) +
          ((state.sessionAffinities[a] ?? 0.0) * 0.4);
    }
    final sorted = fallback.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// Smart recommendation mixing - returns diverse seed artists
  List<String> getSmartSeeds({required String currentArtist, required int count}) {
    final seeds = <String>[];
    final seenArtists = <String>{};
    
    // Normalize artist name for comparison
    final normalizedCurrent = currentArtist.toLowerCase().trim();
    
    // 1. Include current artist (20% of seeds - reduced for more diversity).
    // Skip when the "artist" is a placeholder ("General"/"Unknown"/...) — seeding
    // a search with it returns literal junk tracks.
    final currentArtistCount = max(1, (count * 0.2).ceil());
    if (!isJunkMusicTerm(currentArtist)) {
      for (int i = 0; i < currentArtistCount && seeds.length < count; i++) {
        seeds.add(currentArtist);
        seenArtists.add(normalizedCurrent);
      }
    }
    
    // 2. Add complementary artists (40% of seeds)
    final complementary = getComplementaryArtists(currentArtist, limit: 10);
    final complementaryCount = (count * 0.4).ceil();
    for (final artist in complementary) {
      final normalized = artist.toLowerCase().trim();
      if (seeds.length >= currentArtistCount + complementaryCount) break;
      if (!seenArtists.contains(normalized) && !isJunkMusicTerm(artist)) {
        seeds.add(artist);
        seenArtists.add(normalized);
      }
    }
    
    // 3. Add time-aware wildcards (20% of seeds)
    final hour = DateTime.now().hour;
    final timeContext = state.timeOfDayAffinities[hour] ?? {};
    // ARTISTS ONLY. This bucket holds genres as well, so taking its keys wholesale
    // would seed the catalogue search with genre names as though they were bands.
    final timeArtists = timeContext.keys
        .where((k) => state.artistAffinities.containsKey(k))
        .toList()
      ..sort((a, b) => (timeContext[b] ?? 0.0).compareTo(timeContext[a] ?? 0.0));
    
    final timeCount = (count * 0.2).ceil();
    for (final artist in timeArtists) {
      if (seeds.length >= currentArtistCount + complementaryCount + timeCount) break;
      final normalized = artist.toLowerCase().trim();
      if (!seenArtists.contains(normalized) && !isJunkMusicTerm(artist)) {
        seeds.add(artist);
        seenArtists.add(normalized);
      }
    }
    
    // 4. Fill remaining with top global affinities (20% of seeds)
    final topArtists = state.artistAffinities.keys.toList()
      ..sort((a, b) => (state.artistAffinities[b] ?? 0.0).compareTo(state.artistAffinities[a] ?? 0.0));
    
    for (final artist in topArtists) {
      if (seeds.length >= count) break;
      final normalized = artist.toLowerCase().trim();
      if (!seenArtists.contains(normalized) && !isJunkMusicTerm(artist)) {
        seeds.add(artist);
        seenArtists.add(normalized);
      }
    }
    
    // 5. Cold-start diverse fill — ONLY for a brand-new user with no collected
    // listening data yet. Once the user has history/affinities, seeding is driven
    // purely by their own intelligence (never these hardcoded names).
    if (seeds.length < count && isInColdStart) {
      final emergencyArtists = [
        "Tory Lanez", "Taylor Swift", "The Weeknd", "Ariana Grande", "Bad Bunny",
        "Ed Sheeran", "Billie Eilish", "Post Malone", "Dua Lipa", "Travis Scott"
      ];
      for (final artist in emergencyArtists) {
        if (seeds.length >= count) break;
        final normalized = artist.toLowerCase().trim();
        if (!seenArtists.contains(normalized)) {
          seeds.add(artist);
          seenArtists.add(normalized);
        }
      }
    }
    
    print("Smart Seeds Generated:");
    print("   Total: ${seeds.length}");
    print("   Unique: ${seenArtists.length}");
    print("   Seeds: ${seeds.take(5).join(', ')}${seeds.length > 5 ? '...' : ''}");
    
    return seeds;
  }

  /// True only for a genuinely new listener. Returns false until the saved state
  /// has loaded: before then the counts read zero and an established user would
  /// look new, and callers would inject generic filler. Guarding here covers every
  /// caller.
  bool get isInColdStart {
    if (!isHydrated) return false;
    final totalInteractions =
        state.artistAffinities.length + state.trackAffinities.length;
    return totalInteractions < 20; // First 20 interactions
  }


  void markAsNotInterested(Song song) {
    // Add to blacklist
    final newBlacklist = Set<String>.from(state.blacklistedIds)..add(song.id);
    
    // Strong negative affinity for artist
    final newArtists = Map<String, double>.from(state.artistAffinities);
    newArtists[song.artist] = (newArtists[song.artist] ?? 0.0) - 10.0;
    
    // Negative track affinity
    final newTracks = Map<String, double>.from(state.trackAffinities);
    newTracks[song.id] = -20.0; // Strong negative signal
    
    // Negative session affinity
    final newSession = Map<String, double>.from(state.sessionAffinities);
    newSession[song.artist] = (newSession[song.artist] ?? 0.0) - 5.0;
    
    // Keep the track's metadata so the Hidden Content page can show it.
    final newMetadata = Map<String, Song>.from(state.trackMetadata);
    newMetadata[song.id] = song;
    
    // Hidden, with the moment — so un-hiding on one device is not undone
    // by an older hide on another. See SetLog.
    SetLog.instance.record(SetLog.blacklist, song.id, member: true);
    state = state.copyWith(
      blacklistedIds: newBlacklist,
      artistAffinities: newArtists,
      trackAffinities: newTracks,
      sessionAffinities: newSession,
      trackMetadata: _capMetadata(newMetadata), // Save metadata (bounded)
    );
    
    _saveStateDebounced();
    print("STOP: Marked as not interested: ${song.title} by ${song.artist}");
  }

  /// Un-hides many tracks with one state write and one save (the single version
  /// copies the blacklist and affinity map and does a full save per call).
  void removeManyFromNotInterested(Iterable<Song> songs) {
    final ids = songs.map((s) => s.id).toSet();
    if (ids.isEmpty) return;
    final newBlacklist = Set<String>.from(state.blacklistedIds)
      ..removeAll(ids);
    final newTracks = Map<String, double>.from(state.trackAffinities)
      ..removeWhere((k, _) => ids.contains(k));
    state = state.copyWith(
      blacklistedIds: newBlacklist,
      trackAffinities: newTracks,
    );
    for (final id in ids) {
      SetLog.instance.record(SetLog.blacklist, id, member: false);
    }
    _saveState();
    print('Removed ${ids.length} track(s) from not interested');
  }

  /// Removes [song] from the blacklist and resets its penalties.
  void removeFromNotInterested(Song song) {
    final newBlacklist = Set<String>.from(state.blacklistedIds)..remove(song.id);
    SetLog.instance.record(SetLog.blacklist, song.id, member: false);
    
    final newTracks = Map<String, double>.from(state.trackAffinities);
    newTracks.remove(song.id);
    
    state = state.copyWith(
      blacklistedIds: newBlacklist,
      trackAffinities: newTracks,
    );
    
    _saveState();
    print("Removed from not interested: ${song.title}");
  }

  Map<String, dynamic> analyzeListeningPatterns() {
    final patterns = <String, dynamic>{};
    
    // 1. Peak listening hours
    final hourlyActivity = <int, double>{};
    state.timeOfDayAffinities.forEach((hour, genres) {
      hourlyActivity[hour] = genres.values.fold(0.0, (sum, val) => sum + val);
    });
    
    final sortedHours = hourlyActivity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    patterns['peak_hours'] = sortedHours.take(3).map((e) => {
      'hour': e.key,
      'activity': e.value,
      'label': _getTimeLabel(e.key),
    }).toList();
    
    // 2. Favorite genres with boost info
    final topGenres = state.genreAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    patterns['top_genres'] = topGenres.take(5).map((e) => {
      'genre': e.key,
      'affinity': e.value,
      'boost': getGenreBoostMultiplier(e.key),
      'streak': state.genreStreakTracker[e.key] ?? 0,
    }).toList();
    
    // 3. Artist diversity score
    final artistCount = state.artistAffinities.length;
    final totalPlays = state.trackAffinities.values.fold(0.0, (sum, val) => sum + val);
    final diversityScore = artistCount > 0 ? (artistCount / max(totalPlays, 1.0)) * 100 : 0.0;
    
    patterns['diversity_score'] = diversityScore.clamp(0.0, 100.0);
    
    // 4. Current mood and session info
    patterns['current_mood'] = detectCurrentMood();
    patterns['active_boosts'] = getActiveBoosts();
    
    // 5. Listening intensity: average tracks per day since first use
    // (firstUseDate is set once and never changes).
    final daysSinceInstall = DateTime.now().difference(state.firstUseDate).inDays;
    final avgTracksPerDay = totalPlays / max(1, daysSinceInstall);
    patterns['tracks_per_day'] = avgTracksPerDay;
    
    print("Listening Pattern Analysis:");
    print("   Diversity: ${diversityScore.toStringAsFixed(1)}%");
    print("   Mood: ${patterns['current_mood']}");
    print("   Active Boosts: ${patterns['active_boosts']}");
    
    return patterns;
  }

  /// Genre words worth reading in a title or album, matched on word boundaries (so
  /// "pop" doesn't match Popcaan or "house" match "Housewarming"). A weak signal
  /// that mainly catches compilation and mix names ("Lo-Fi Beats to Study To",
  /// "90s R&B Mix"); the real source is [IntelligenceState.artistGenres].
  static final Map<String, List<String>> _titleGenreWords = {
    'pop': ['pop'],
    'rock': ['rock', 'alternative', 'punk', 'metal'],
    'hip-hop': ['hip-hop', 'hiphop', 'rap', 'trap', 'drill'],
    'r&b': ['r&b', 'rnb', 'soul'],
    'electronic': ['electronic', 'edm', 'house', 'techno', 'dubstep', 'garage'],
    'jazz': ['jazz', 'blues'],
    'lo-fi': ['lo-fi', 'lofi', 'chill', 'chillhop'],
    'ambient': ['ambient', 'atmospheric'],
    'afrobeats': ['afrobeat', 'afrobeats', 'amapiano'],
    'country': ['country', 'folk', 'americana'],
    'classical': ['classical', 'orchestral', 'piano'],
    'reggae': ['reggae', 'dancehall', 'dub'],
  };

  /// Compiled once, since this runs for every song being ranked.
  static final Map<String, RegExp> _titleGenrePatterns = {
    for (final e in _titleGenreWords.entries)
      e.key: RegExp(
          r'(?<![\w-])(?:' +
              e.value.map(RegExp.escape).join('|') +
              r')(?![\w-])',
          caseSensitive: false),
  };

  /// song id → its genres, for one ranking pass.
  ///
  /// [getSongScore] is called once per candidate and a feed build ranks hundreds,
  /// so this is the difference between twelve regex evaluations per song and one.
  /// Cleared when [IntelligenceState.artistGenres] learns something new, because
  /// that changes the answer for every song by that artist.
  final Map<String, List<String>> _songGenreMemo = {};

  /// The genres a song belongs to: the single answer used by every caller,
  /// including home_provider's feed topics.
  List<String> genresFor(Song song) => _extractSongGenres(song);

  /// The genres a song belongs to: what is KNOWN about its artist, plus anything
  /// its own title says.
  ///
  /// Artist tags come first because they are the reliable half — a real taxonomy
  /// from Last.fm rather than a guess at a song name.
  List<String> _extractSongGenres(Song song) {
    final memo = _songGenreMemo[song.id];
    if (memo != null) return memo;

    final genres = <String>{};

    final learned = state.artistGenres[song.artist.trim().toLowerCase()];
    if (learned != null) genres.addAll(learned);

    final searchText = '${song.title} ${song.albumTitle}';
    _titleGenrePatterns.forEach((genre, pattern) {
      if (pattern.hasMatch(searchText)) genres.add(genre);
    });

    final out = genres.toList();
    if (_songGenreMemo.length > 800) _songGenreMemo.clear();
    _songGenreMemo[song.id] = out;
    return out;
  }

  /// Maximum number of artists with a remembered genre list. 2000 is far beyond a
  /// real library and about 120 KB of JSON; an evicted artist just costs one Last.fm
  /// lookup when it's next played.
  static const int _maxArtistGenres = 2000;

  /// Trims to [_maxArtistGenres], dropping the oldest entries (Dart maps keep
  /// insertion order, so `keys.first` is the oldest, as in the loudness and
  /// low-quality caches). Applied on load as well as on learn, so an oversized
  /// install is brought back under the cap.
  static Map<String, List<String>> _cappedGenres(
      Map<String, List<String>> m) {
    if (m.length <= _maxArtistGenres) return m;
    final out = Map<String, List<String>>.from(m);
    for (final k in m.keys.take(m.length - _maxArtistGenres)) {
      out.remove(k);
    }
    return out;
  }

  // Instantly tracks a play the moment the user clicks a song
  /// Artists a genre lookup is in flight for, so a repeat play cannot start a
  /// second one. Not persisted — an interrupted lookup should simply be retried
  /// on the next play rather than remembered as done.
  final Set<String> _genreLookupsInFlight = {};

  /// How many genre lookups this process may make. Bounds a first-run library
  /// scan: 40 new artists in one session is 40 requests, which is fine, and 400
  /// is not. What is missed is picked up on later launches.
  static const int _maxGenreLookupsPerSession = 60;
  int _genreLookupsThisSession = 0;

  /// Whether [tag] is a genre or one of the other things Last.fm tags contain.
  ///
  /// Last.fm tags are user-generated: a typical list mixes a genre or two with a
  /// year, a list-making phrase, the artist's own name and other artists' names.
  /// Storing those as genres would feed the coherence check junk. This removes the
  /// four shapes that are reliably not genres and keeps anything uncertain (a stray
  /// tag is a weak wrong signal; dropping a real one like "uk drill" loses real
  /// information).
  ///
  /// Public for the test that runs it against tags a real account returned.
  @visibleForTesting
  bool isGenreLikeTag(String tag, String artist) {
    if (tag.isEmpty || tag.length > 24) return false;

    // 1. The artist's own name, or any artist this listener already knows; both are
    //    common as tags and neither is a genre. Matched against whole words of the
    //    name, so "pop" stays for Popcaan but "bieber" is dropped for Justin Bieber.
    //    (Substring matching also made every tag match an empty artist name.)
    final a = artist.trim().toLowerCase();
    final artistWords = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
    if (a.isNotEmpty && (tag == a || artistWords.contains(tag))) return false;
    if (state.artistAffinities.keys
        .any((known) => known.trim().toLowerCase() == tag)) {
      return false;
    }

    // 2. Years and decades — "2016", "00s", "1990s". A release period is real
    //    information, but it is not what the coherence check is asking about.
    if (RegExp(r'^(19|20)\d{2}s?$').hasMatch(tag)) return false;
    if (RegExp(r"^\d{2}s$|^\d{4}s$").hasMatch(tag)) return false;

    // 3. Listmaking and personal-reaction tags. These say something about the
    //    tagger, not the music.
    const listish = [
      'best of', 'favorite', 'favourite', 'top ', 'my ', 'love at',
      'listen', 'seen live', 'albums i own', 'want to', 'check out',
      'awesome', 'beautiful', 'amazing', 'good', 'great', 'cool',
    ];
    if (listish.any(tag.contains)) return false;

    // 4. Anything long enough to be a sentence. Genre names are one to three
    //    words ("neo soul", "melodic dubstep"); four is a phrase.
    if (tag.split(RegExp(r'\s+')).length > 3) return false;

    return true;
  }

  /// Learns and remembers [artist]'s genres, once ever. Fire-and-forget: scoring
  /// runs synchronously over many candidates and can't await the network, so the
  /// first play of a new artist scores without genre and later ones with it. Stores
  /// an empty list when Last.fm knows nothing, so it isn't asked again.
  void _learnGenresForArtist(String artist, String trackTitle) {
    final key = artist.trim().toLowerCase();
    if (key.isEmpty || key == 'unknown artist') return;
    if (state.artistGenres.containsKey(key)) return;
    if (_genreLookupsInFlight.contains(key)) return;
    if (_genreLookupsThisSession >= _maxGenreLookupsPerSession) return;

    _genreLookupsInFlight.add(key);
    _genreLookupsThisSession++;
    // ARTIST tags first, the track only as a fallback. Asking about one track
    // and caching the answer per artist is how "Major Lazer: none known" got
    // recorded. See [ArtistMetadataService.getArtistTags].
    var viaTrack = false;
    var viaPrimary = false;
    () async {
      final svc = ArtistMetadataService();
      var tags = await svc.getArtistTags(artist);
      // A collaboration credit ("A, B") isn't an artist name any tag service knows,
      // and empty answers are cached, so ask again with the primary artist (in its
      // original spelling). Only when it differs, so single-artist credits still cost
      // one call.
      if (tags.isEmpty) {
        final primary = primaryArtistOf(artist);
        if (primary.isNotEmpty &&
            primary.toLowerCase() != artist.trim().toLowerCase()) {
          tags = await svc.getArtistTags(primary);
          viaPrimary = tags.isNotEmpty;
        }
      }
      if (tags.isEmpty && trackTitle.trim().isNotEmpty) {
        tags = await svc.getTrackTags(trackTitle, artist);
        viaTrack = tags.isNotEmpty;
      }
      return tags;
    }()
        .then((tags) {
          if (!mounted) return;
          // Keep the tag NAMES rather than folding them into a few buckets:
          // "uk drill", "bedroom pop" and "neo soul" are exactly the distinctions
          // that make a queue feel coherent, and genreAffinities learns whatever
          // names it is given. Which is also why they have to be filtered first —
          // see [isGenreLikeTag].
          final genres = tags
              .map((t) => t.toLowerCase().trim())
              .where((t) => isGenreLikeTag(t, artist))
              .toSet()
              .take(4)
              .toList();
          state = state.copyWith(
              artistGenres: _cappedGenres({
            ...state.artistGenres,
            key: genres,
          }));
          _songGenreMemo.clear(); // a new artist changes past answers
          // Names the SOURCE, because "none known" meant two very different
          // things before: Last.fm genuinely has nothing on this artist, or the
          // one track asked about happened to be untagged.
          print('genres learned for "$artist"'
              '${viaPrimary ? " (via its primary artist)" : viaTrack ? " (via its track)" : ""}: '
              '${genres.isEmpty ? "none known" : genres.join(", ")}');
          _saveStateDebounced();
        })
        .catchError((_) {})
        .whenComplete(() => _genreLookupsInFlight.remove(key));
  }

  void recordPlay(Song song) {
    if (song.id.startsWith('dummy') || song.id.startsWith('onb_')) return;
    // The history-pause switch is enforced here, where data is written. See
    // _refuseIfPaused.
    if (_refuseIfPaused('recordPlay')) return;
    // One lookup per artist, ever. Hung off a real play rather than off the
    // scorer so it costs nothing per candidate.
    _learnGenresForArtist(song.artist, song.title);
    final now = DateTime.now().millisecondsSinceEpoch;

    final newPlayCounts  = Map<String, int>.from(state.playCounts);
    final newMetadata    = Map<String, Song>.from(state.trackMetadata);
    final newFirstTs     = Map<String, int>.from(state.firstPlayTimestamps);
    final newLastTs      = Map<String, int>.from(state.lastPlayTimestamps);

    newPlayCounts[song.id] = (newPlayCounts[song.id] ?? 0) + 1;

    // Also count the play for this device alone. `playCounts` is cumulative, so
    // summing it across devices would double-count exchanged plays; per-device
    // tallies don't overlap, so their sum stays exact. See PlayTally.
    PlayTally.instance.increment(song.id);

    // Write the timestamp ledger here, at the same moment and by the same rule as
    // the count, so time-based views (listening clock, active days, streaks, recap
    // windows) agree with the play counts.
    final newPlayHistory = Map<String, List<int>>.from(state.playHistory);
    final stamps = List<int>.from(newPlayHistory[song.id] ?? const []);
    stamps.add(now);
    // Cap per track: these serialise into prefs on every save. 120 covers a
    // year of weekly plays; older stamps only affect long-window charts, and
    // `playCounts` remains the authoritative lifetime total.
    if (stamps.length > 120) stamps.removeRange(0, stamps.length - 120);
    newPlayHistory[song.id] = stamps;

    newMetadata[song.id] = song;
    newFirstTs.putIfAbsent(song.id, () => now);
    newLastTs[song.id] = now;

    final artist = song.artist.trim();
    final artistOk = artist.isNotEmpty && !isJunkMusicTerm(artist);

    // Momentum: add this play to the artist's recent-play ledger (capped at 60).
    final newArtistTs = Map<String, List<int>>.from(state.artistPlayTimestamps);
    if (artistOk) {
      final list = List<int>.from(newArtistTs[artist] ?? const []);
      list.add(now);
      if (list.length > 60) list.removeAt(0);
      newArtistTs[artist] = list;
    }

    // Markov transition: record "the artist you just played → this artist".
    var txToSave = state.artistTransitions;
    final prev = _lastRecordedArtist;
    if (prev != null && prev.isNotEmpty && artistOk && prev != artist && !isJunkMusicTerm(prev)) {
      final tx = <String, Map<String, int>>{
        for (final e in state.artistTransitions.entries) e.key: Map<String, int>.from(e.value)
      };
      final row = tx.putIfAbsent(prev, () => <String, int>{});
      row[artist] = (row[artist] ?? 0) + 1;
      if (row.length > 40) {
        final top = (row.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(40);
        tx[prev] = {for (final e in top) e.key: e.value};
      }
      txToSave = tx;
    }

    // Day-part context: reinforce this artist and its genres for this slice of the
    // week.
    final newDayPart = <String, Map<String, double>>{
      for (final e in state.dayPartAffinities.entries) e.key: Map<String, double>.from(e.value)
    };
    final bucket = newDayPart.putIfAbsent(_dayPartKey(), () => <String, double>{});
    if (artistOk) bucket[artist] = (bucket[artist] ?? 0.0) + 1.0;
    for (final g in _extractSongGenres(song)) {
      bucket[g] = (bucket[g] ?? 0.0) + 0.5;
    }

    // Bound the id-keyed intelligence maps to the (already-capped) metadata.
    // playCounts / first- & last-play timestamps were UNBOUNDED — growing for
    // months and re-serialised to prefs on every save. A count/timestamp for a
    // track no longer in metadata is a dead ghost (nothing can render or
    // recommend it), so aligning to the surviving 1500 tracks is both a size cap
    // and a cleanup. The artist-keyed momentum ledger is capped separately.
    final cappedMeta = _capMetadata(newMetadata);
    Map<String, V> alignToMeta<V>(Map<String, V> m) =>
        m.length <= _maxMetadataEntries
            ? m
            : {
                for (final e in m.entries)
                  if (cappedMeta.containsKey(e.key)) e.key: e.value
              };
    Map<String, List<int>> capArtists(Map<String, List<int>> m) {
      if (m.length <= 800) return m;
      final trimmed = Map<String, List<int>>.from(m);
      for (final k in trimmed.keys.take(m.length - 800).toList()) {
        trimmed.remove(k);
      }
      return trimmed;
    }

    state = state.copyWith(
      playCounts:           alignToMeta(newPlayCounts),
      // Same rule, same instant as the count above. See the note there.
      playHistory:          alignToMeta(newPlayHistory),
      trackMetadata:        cappedMeta,
      firstPlayTimestamps:  alignToMeta(newFirstTs),
      lastPlayTimestamps:   alignToMeta(newLastTs),
      artistPlayTimestamps: capArtists(newArtistTs),
      artistTransitions:    txToSave,
      dayPartAffinities:    newDayPart,
    );
    if (artistOk) _lastRecordedArtist = artist;
    _saveStateDebounced();
  }

  /// Merges play counts from another app's backup. Raises only: a count is taken
  /// only when higher than what's already here, so an old backup can't reset real
  /// listening history. Limited to counts, metadata and first-play dates; it
  /// doesn't touch momentum, transitions or day-part data, which describe when and
  /// in what order this user listened.
  void mergeImportedPlayCounts(
    Map<String, int> counts,
    Map<String, Song> metadata, {
    Map<String, List<int>> playStamps = const {},
    Map<String, int> firstPlayMs = const {},
    Map<String, int> lastPlayMs = const {},
  }) {
    if (counts.isEmpty && metadata.isEmpty) return;
    final newCounts = Map<String, int>.from(state.playCounts);
    final newMeta = Map<String, Song>.from(state.trackMetadata);
    final newFirstTs = Map<String, int>.from(state.firstPlayTimestamps);
    final newLastTs = Map<String, int>.from(state.lastPlayTimestamps);
    final newHistory = Map<String, List<int>>.from(state.playHistory);
    final newArtists = Map<String, double>.from(state.artistAffinities);
    var changed = false;

    metadata.forEach((id, song) {
      if (id.isEmpty || song.title.isEmpty) return;
      if (!newMeta.containsKey(id)) {
        newMeta[id] = song;
        changed = true;
      }
    });
    counts.forEach((id, n) {
      if (id.isEmpty || n <= 0) return;
      // Only for tracks we can actually render — a count with no metadata is a
      // ghost that nothing can show or recommend (see the cap in recordPlay).
      if (!newMeta.containsKey(id)) return;
      if ((newCounts[id] ?? 0) >= n) return;
      newCounts[id] = n;
      changed = true;
    });
    if (!changed) return;

    // Use real dates when the backup has them (from its event log); only tracks
    // without one fall back to now. Earliest first-play and latest last-play win,
    // so an old backup can extend history backwards without moving a real later
    // play.
    firstPlayMs.forEach((id, ms) {
      if (ms <= 0) return;
      final existing = newFirstTs[id];
      if (existing == null || ms < existing) newFirstTs[id] = ms;
    });
    lastPlayMs.forEach((id, ms) {
      if (ms <= 0) return;
      if ((newLastTs[id] ?? 0) < ms) newLastTs[id] = ms;
    });
    playStamps.forEach((id, stamps) {
      if (stamps.isEmpty) return;
      final merged = <int>{...(newHistory[id] ?? const <int>[]), ...stamps}
          .where((t) => t > 0)
          .toList()
        ..sort();
      // Same per-track cap recordPlay uses: these serialise into prefs on every
      // save, and older stamps only affect long-window charts.
      if (merged.length > 120) merged.removeRange(0, merged.length - 120);
      newHistory[id] = merged;
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in newCounts.keys) {
      newFirstTs.putIfAbsent(id, () => now);
    }

    // The three affinities that steer recommendations. getSongScore weighs genre
    // 30%, artist 20% and track 15%, and play count only ~5%, so an import that only
    // filled counts would restore history but not taste. All three are derived from
    // the imported plays at half the live per-play weights (a full listen is 1.5, a
    // partial 0.4), since this app never saw whether a play finished. Markov
    // transitions, day-part data, momentum and time-of-day aren't derived: counts are
    // no evidence of order or hours.
    final newGenres = Map<String, double>.from(state.genreAffinities);
    final newTracks = Map<String, double>.from(state.trackAffinities);
    counts.forEach((id, n) {
      if (n <= 0) return;
      final song = newMeta[id];
      if (song == null) return;
      final w = n * 0.5;
      final artist = song.artist.split(',').first.trim();
      if (artist.isNotEmpty && !isJunkMusicTerm(artist)) {
        newArtists[artist] = (newArtists[artist] ?? 0) + w;
      }
      // Per-track score, on the same scale trackInteraction uses. A heavily
      // played track therefore also inherits the OVERPLAY penalty in scoring,
      // which is correct: the app should not keep pushing what they have already
      // heard forty times.
      newTracks[id] = (newTracks[id] ?? 0) + w;
      // Genre is the heaviest term in scoring, and it is inferred from the track
      // itself, so an imported play teaches it exactly as a real play would.
      for (final g in _extractSongGenres(song)) {
        newGenres[g] = (newGenres[g] ?? 0) + (w * 0.5);
      }
    });

    final cappedMeta = _capMetadata(newMeta);
    Map<String, V> alignToMeta<V>(Map<String, V> m) => {
          for (final e in m.entries)
            if (cappedMeta.containsKey(e.key)) e.key: e.value
        };
    state = state.copyWith(
      playCounts: alignToMeta(newCounts),
      trackMetadata: cappedMeta,
      firstPlayTimestamps: alignToMeta(newFirstTs),
      lastPlayTimestamps: alignToMeta(newLastTs),
      playHistory: alignToMeta(newHistory),
      // Capped exactly as the live writers cap them, so an import cannot be the
      // one path that grows these maps without bound.
      artistAffinities: _capAffinities(newArtists, _maxArtistAffinities),
      trackAffinities: _capAffinities(newTracks, _maxTrackAffinities),
      genreAffinities: newGenres,
    );
    print('import: taste profile now holds ${newCounts.length} counted '
        'track(s), ${newArtists.length} artist(s), ${newGenres.length} genre(s)');
    _saveStateDebounced();
  }

  /// Refuses to record when listening history is paused or a private session is
  /// on. Enforced inside the three methods that write taste data rather than at
  /// call sites, so no caller can forget it. Nothing already recorded is touched
  /// (that's Settings → clear/delete).
  bool _refuseIfPaused(String what) {
    if (!ListeningPolicy.historyPaused) {
      // Re-arm, so a SECOND pause later in the session announces itself too.
      // Without this the log would name the first pause of the day and stay
      // silent about every one after it.
      if (_pauseAnnounced) {
        _pauseAnnounced = false;
        print('history recording resumed');
      }
      return false;
    }
    // Once per switch-on, not per track: this fires on every skip and every
    // finished song, and a listener who paused history for an evening would
    // otherwise find the log full of it.
    if (!_pauseAnnounced) {
      _pauseAnnounced = true;
      print('history is paused'
          '${ListeningPolicy.privateSession ? ' (private session)' : ''}'
          ' — $what and everything like it will not record until it is resumed');
    }
    return true;
  }

  bool _pauseAnnounced = false;

  void trackInteraction(Song song, {double percent = 0.0, String? genreContext}) {
    if (song.id.startsWith('dummy') || song.id.startsWith('onb_')) return;
    // The history-pause switch is enforced here, where data is written. See
    // _refuseIfPaused.
    if (_refuseIfPaused('trackInteraction')) return;
    final hour = DateTime.now().hour;
    final previousMood = detectCurrentMood();
    
    final bool isRadio = song.id.startsWith('http') && song.albumTitle != 'Podcast';
    final bool isPodcast = song.albumTitle == 'Podcast';

    bool isHardSkip;
    bool isBoredomSkip;
    bool isFullListen;

    if (isRadio) {
      isHardSkip = false;
      isBoredomSkip = false;
      isFullListen = true;
    } else if (isPodcast) {
      isHardSkip = percent < 0.02;
      isBoredomSkip = percent >= 0.02 && percent < 0.1;
      isFullListen = percent >= 0.1; 
    } else {
      isHardSkip = percent < 0.05; 
      isBoredomSkip = percent >= 0.05 && percent < 0.25;
      isFullListen = percent > 0.8;
    }

    double weight = isHardSkip ? -3.0 : (isBoredomSkip ? -1.0 : (isFullListen ? 1.5 : 0.4));

    final bool countsAsPlay = isRadio
    || (isPodcast && percent >= 0.10)
    || (!isRadio && !isPodcast && percent >= 0.25);

    // The playHistory stamp is written in `recordPlay`, together with the count;
    // writing it here too would double-count finished tracks. `countsAsPlay` still
    // gates the affinity/mood learning below.
    if (countsAsPlay) {
      // (intentionally no ledger write. See above)
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Decay from the real previous play, taken from playHistory (recordPlay has just
    // appended this play, so the entry before it is the previous one).
    // `lastPlayTimestamps` can't be used: recordPlay updates it mid-track, so by now
    // it says "seconds ago".
    double decayFrom(List<int>? stamps, int fallbackMs) {
      final previous = (stamps != null && stamps.length >= 2)
          ? stamps[stamps.length - 2]
          : fallbackMs;
      final days = ((nowMs - previous) / 86400000.0).clamp(0, 365).toDouble();
      return pow(0.995, days).toDouble();
    }

    // Artist affinity decays too, with the same half-life as tracks, measured from
    // the artist's previous play (artistPlayTimestamps). Otherwise an artist played
    // heavily years ago would keep their score forever and nothing new could
    // overtake them. Trimmed, matching recordPlay (see [artistKeyOf]).
    final artistName = artistKeyOf(song.artist);
    final newArtists = Map<String, double>.from(state.artistAffinities);
    final artistDecay =
        decayFrom(state.artistPlayTimestamps[artistName], nowMs);
    final decayedArtist = (newArtists[artistName] ?? 0.0) * artistDecay;
    newArtists[artistName] = decayedArtist + weight;

    final newTracks = Map<String, double>.from(state.trackAffinities);

    // Play counts are recorded by recordPlay(), not here.

    final delta = isHardSkip ? -4.0 : isBoredomSkip ? -0.5 : (isFullListen ? 1.5 : 0.8);
    final decayedExisting =
        (newTracks[song.id] ?? 0.0) * decayFrom(state.playHistory[song.id], nowMs);
    newTracks[song.id] = decayedExisting + delta;

    final newGenres = Map<String, double>.from(state.genreAffinities);
    // No "General" genre is written: genreContext is null for most plays, and a
    // catch-all bucket would outweigh every real genre. Real genres are learned from
    // the track itself below.
    final genre = genreContext ?? '';
    if (genre.isNotEmpty) {
      newGenres[genre] = (newGenres[genre] ?? 0.0) + weight;
    }

    final extractedGenres = _extractSongGenres(song);
    for (final extractedGenre in extractedGenres) {
      newGenres[extractedGenre] = (newGenres[extractedGenre] ?? 0.0) + (weight * 0.5);
    }

    final newSession = Map<String, double>.from(state.sessionAffinities);
    newSession.forEach((key, value) => newSession[key] = value * 0.9);
    if (genre.isNotEmpty) {
      // A boost amplifies a like, never a dislike: `weight` is signed (a hard skip is
      // -3.0), and multiplying it by a boost would punish a favoured genre extra hard.
      final genreBoostMultiplier =
          weight > 0 ? getGenreBoostMultiplier(genre) : 1.0;
      newSession[genre] = (newSession[genre] ?? 0.0) + (weight * genreBoostMultiplier);
    }
    newSession[artistName] = (newSession[artistName] ?? 0.0) + (weight * 0.5);

    final newTimeMap = Map<int, Map<String, double>>.from(state.timeOfDayAffinities);
    final hourMap = Map<String, double>.from(newTimeMap[hour] ?? {});

    if (isHardSkip) {
      newArtists[artistName] = ((newArtists[artistName] ?? 0.0) - 2.0).clamp(-10.0, double.infinity);
      if (genreContext != null) {
        final currentVibe = newSession[genreContext] ?? 0.0;
        newSession[genreContext] = (currentVibe - 5.0).clamp(-20.0, 20.0);
      }
    }
    
    // Record the artist in this bucket as well as its genres. Its readers look up
    // artists (getSongScore's time-of-day term, the autoplay scorer, and
    // getSmartSeeds, which uses the keys as artist names), matching how
    // dayPartAffinities is recorded.
    if (artistName.isNotEmpty && !isJunkMusicTerm(artistName)) {
      hourMap[artistName] = (hourMap[artistName] ?? 0.0) + weight;
    }
    if (genre.isNotEmpty) {
      hourMap[genre] = (hourMap[genre] ?? 0.0) + weight;
    }
    // Bounded per bucket. This map had no limit at all — 24 buckets, each
    // growing a row for every artist and genre ever played in that hour, all
    // re-serialised into prefs on every save.
    newTimeMap[hour] = _capAffinities(hourMap, _maxTimeOfDayPerHour);

    final List<Song> updatedHistory = state.listeningHistory.isEmpty || state.listeningHistory.first.id != song.id 
        ? [song, ...state.listeningHistory].take(500).toList() 
        : state.listeningHistory;

    state = state.copyWith(
      // Bounded here rather than at each of the several mutation sites: this is
      // the one write they all funnel through. See _capAffinities.
      artistAffinities: _capAffinities(newArtists, _maxArtistAffinities),
      trackAffinities: _capAffinities(newTracks, _maxTrackAffinities),
      // Capped like the other two, so it can't grow a row per genre forever (and
      // re-save the whole map every time).
      genreAffinities: _capAffinities(newGenres, _maxGenreAffinities),
      sessionAffinities: newSession,
      timeOfDayAffinities: newTimeMap,
      listeningHistory: updatedHistory,
    );
    
    if (genreContext != null) {
      trackGenreBoost(genreContext, song, listenPercent: percent);
    }
    
    final newMood = detectCurrentMood();
    if (previousMood != newMood) {
      adjustForMoodShift(previousMood, newMood);
    }
    
    _saveStateDebounced();
  }

  /// Sorts a pool of items based on current global and time-specific affinity.
  List<String> getWeightedTopics(List<String> pool) {
    if (pool.isEmpty) return [];

    final hour = DateTime.now().hour;
    final timeContext = state.timeOfDayAffinities[hour] ?? {};

    // Drop placeholder topics ("General"/"Unknown"/"Top"...) so they're never used
    // as seeds. Decorate, then sort: compute each item's score once, using today's
    // artist affinity (as topArtistsNow does) rather than the raw lifetime value.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sorted = pool.where((t) => !isJunkMusicTerm(t)).toList();
    final weight = <String, double>{
      for (final t in sorted)
        t: // 1. Base = artist affinity AS OF TODAY + genre affinity
            _decayedToNow(state.artistAffinities[t] ?? 0.0,
                    _lastArtistPlayMs(t), nowMs) +
                (state.genreAffinities[t] ?? 0.0) +
                // 2. Time-of-day boost (3x for the current hour)
                (timeContext[t] ?? 0.0) * 3.0 -
                // 3. Fatigue penalty if recently suggested
                (state.recentTopics.contains(t) ? 10.0 : 0.0),
    };
    sorted.sort((a, b) => weight[b]!.compareTo(weight[a]!));
    
    return sorted;
  }

  void markTopicSeen(String topic) {
    final updatedTopics = List<String>.from(state.recentTopics);
    // Add new topic to the front and keep only the last 15 to prevent permanent blocking
    updatedTopics.insert(0, topic);
    if (updatedTopics.length > 15) updatedTopics.removeLast(); 
    
    state = state.copyWith(recentTopics: updatedTopics);
    _saveStateDebounced(); // Persist the fatigue list
  }

  /// Applies the merged cross-device blacklist. Decisions carry timestamps and the
  /// newest wins, so un-hiding a track on one phone sticks (a plain union would
  /// bring it back). See SetLog. A hide needs nothing fetched, so ids from another
  /// device apply immediately.
  Future<void> applyMergedBlacklist(
      Map<String, Map<String, ({bool member, int atMs})>> mergedLog) async {
    await _loadReady; // empty is "not loaded yet", see _loadReady
    final r = SetLog.resolve(
      mergedLog: mergedLog,
      collection: SetLog.blacklist,
      localIds: state.blacklistedIds.toList(),
    );
    final next = {...r.keepIds, ...r.missingIds};
    if (next.length == state.blacklistedIds.length &&
        next.containsAll(state.blacklistedIds)) {
      return;
    }
    logEvent('intel: merged blacklist ${state.blacklistedIds.length} → '
        '${next.length} hidden track(s)');
    state = state.copyWith(blacklistedIds: next);
    _saveStateDebounced();
  }

  /// Apply merged play totals — this account's frozen baseline plus every
  /// device's own tally. See PlayTally for why the totals could not simply be
  /// synced as a number.
  Future<void> applyMergedPlayCounts(Map<String, int> merged) async {
    await _loadReady; // empty is "not loaded yet", see _loadReady
    // Same pruning rule as recordPlay: counts are only read for tracks the app can
    // describe (trackMetadata, which is capped). Under the cap everything is kept;
    // over it, ids without metadata go first.
    final aligned = merged.length <= _maxMetadataEntries
        ? merged
        : {
            for (final e in merged.entries)
              if (state.trackMetadata.containsKey(e.key)) e.key: e.value,
          };
    var changed = aligned.length != state.playCounts.length;
    if (!changed) {
      for (final e in aligned.entries) {
        if (state.playCounts[e.key] != e.value) {
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;

    final before = state.playCounts.values.fold(0, (s, v) => s + v);
    final after = aligned.values.fold(0, (s, v) => s + v);
    logEvent('intel: merged play counts — $before → $after plays across '
        '${aligned.length} track(s)');
    state = state.copyWith(playCounts: aligned);
    _saveStateDebounced();
  }

  /// Get genres that work well with the current genre
  List<String> getComplementaryGenres(String currentGenre) {
    final allGenres = state.genreAffinities.keys.toList();
    if (allGenres.isEmpty) return [];
    
    // Sort by affinity score
    allGenres.sort((a, b) {
      final scoreA = state.genreAffinities[a] ?? 0.0;
      final scoreB = state.genreAffinities[b] ?? 0.0;
      return scoreB.compareTo(scoreA);
    });
    
    // Return top 3-5 genres (excluding current)
    return allGenres.where((g) => g != currentGenre).take(5).toList();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();

    // --- Safe Parsing Helpers (Prevents the Null Type Error) ---
    Map<String, int> parseIntMap(String? raw) {
      if (raw == null || raw == 'null') return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0));
      } catch (_) {}
      return {};
    }

    Map<String, double> parseDoubleMap(String? raw) {
      if (raw == null || raw == 'null') return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), (v as num?)?.toDouble() ?? 0.0));
      } catch (_) {}
      return {};
    }

    try {
      final firstPlayTimestamps = parseIntMap(prefs.getString('intel_first_timestamps'));
      final playCounts = parseIntMap(prefs.getString('intel_play_counts'));
      final artistData = parseDoubleMap(prefs.getString('intel_artists'));
      final genreData = parseDoubleMap(prefs.getString('intel_genres'));
      final trackData = parseDoubleMap(prefs.getString('intel_tracks'));
      final timestamps = parseIntMap(prefs.getString('intel_timestamps'));
      final streaksTracker = parseIntMap(prefs.getString('intel_genre_streaks'));
      
      final blacklist = prefs.getStringList('intel_blacklist') ?? [];
      final lastSaved = prefs.getInt('intel_last_save_time') ?? 0;
      final firstUseSaved = prefs.getInt('intel_first_use_date') ?? 0;
      final firstUseDate = firstUseSaved > 0 ? DateTime.fromMillisecondsSinceEpoch(firstUseSaved) : DateTime.now();

      final hoursSinceLastSession = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastSaved)).inHours;

      // Safe Parse Play History Ledger
      final Map<String, List<int>> playHistory = {};
      try {
        final historyRaw = prefs.getString('intel_play_history');
        if (historyRaw != null && historyRaw != 'null') {
          final decoded = jsonDecode(historyRaw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is List) playHistory[k.toString()] = v.map((e) => (e as num).toInt()).toList();
            });
          }
        }
      } catch (_) {}

      final Map<String, GenreBoost> boosts = {};
      try {
        final boostsRaw = prefs.getString('intel_genre_boosts');
        if (boostsRaw != null && boostsRaw != 'null') {
          final decoded = jsonDecode(boostsRaw);
          if (decoded is Map) decoded.forEach((g, d) { if (d is Map) boosts[g.toString()] = GenreBoost.fromJson(Map<String, dynamic>.from(d)); });
        }
      } catch (_) {}

      final Map<int, Map<String, double>> timeData = {};
      try {
        final timeDataRaw = prefs.getString('intel_time_context');
        if (timeDataRaw != null && timeDataRaw != 'null') {
          final decoded = jsonDecode(timeDataRaw);
          if (decoded is Map) decoded.forEach((h, d) { if (d is Map) timeData[int.tryParse(h.toString()) ?? 0] = d.map((k, v) => MapEntry(k.toString(), (v as num?)?.toDouble() ?? 0.0)); });
        }
      } catch (_) {}

      if (hoursSinceLastSession > 2) {
        // Started unawaited by the constructor, so the notifier may be disposed by now
        // (a rebuild on sign-in or restore); writing state would throw.
        if (!mounted) return;
        state = state.copyWith(sessionAffinities: {});
      }

      List<Song> history = [];
      try {
        final historyRaw = prefs.getString('intel_history');
        if (historyRaw != null && historyRaw != 'null') {
          final decoded = jsonDecode(historyRaw);
          if (decoded is List) history = decoded.whereType<Map>().map((m) => Song.fromMap(Map<String, dynamic>.from(m))).toList();
        }
      } catch (_) {}

      final Map<String, Song> metadata = {};
      try {
        final metadataRaw = prefs.getString('intel_metadata');
        if (metadataRaw != null && metadataRaw != 'null') {
          final decoded = jsonDecode(metadataRaw);
          if (decoded is Map) decoded.forEach((k, v) { if (v is Map) metadata[k.toString()] = Song.fromMap(Map<String, dynamic>.from(v)); });
        }
      } catch (_) {}

      // Richer signals: Markov transitions, per-artist momentum, day-part affinities.
      final Map<String, Map<String, int>> artistTransitions = {};
      try {
        final raw = prefs.getString('intel_artist_transitions');
        if (raw != null && raw != 'null') {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((from, row) {
              if (row is Map) {
                artistTransitions[from.toString()] =
                    row.map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0));
              }
            });
          }
        }
      } catch (_) {}

      final Map<String, List<int>> artistPlayTs = {};
      try {
        final raw = prefs.getString('intel_artist_ts');
        if (raw != null && raw != 'null') {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is List) artistPlayTs[k.toString()] = v.map((e) => (e as num).toInt()).toList();
            });
          }
        }
      } catch (_) {}

      // Artist genre tags. Stored per artist so the scorer never has to guess
      // genre from a track title. See [IntelligenceState.artistGenres].
      final Map<String, List<String>> artistGenres = {};
      try {
        final raw = prefs.getString('intel_artist_genres');
        if (raw != null && raw != 'null') {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is List) {
                artistGenres[k.toString()] =
                    v.map((e) => e.toString()).toList();
              }
            });
          }
        }

        // One-time: forget the empty answers the first version recorded. v1 asked
        // `track.getTopTags` (sparse) and cached empty results per artist as settled. v2
        // asks `artist.getTopTags` first, so only the empty entries are dropped and
        // re-asked; real answers are kept. Version-stamped so an artist that genuinely
        // has no tags isn't re-requested every launch.
        if (prefs.getInt('intel_artist_genres_v') != 2) {
          final stale = artistGenres.entries.where((e) => e.value.isEmpty).length;
          artistGenres.removeWhere((_, v) => v.isEmpty);
          await prefs.setInt('intel_artist_genres_v', 2);
          if (stale > 0) {
            print('genre cache: cleared $stale artist(s) recorded as "no genres" '
                'by the old track-only lookup — they will be re-asked once');
          }
        }
      } catch (_) {}

      final Map<String, Map<String, double>> dayPart = {};
      try {
        final raw = prefs.getString('intel_daypart');
        if (raw != null && raw != 'null') {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is Map) {
                dayPart[k.toString()] =
                    v.map((kk, vv) => MapEntry(kk.toString(), (vv as num?)?.toDouble() ?? 0.0));
              }
            });
          }
        }
      } catch (_) {}



      // Started unawaited by the constructor, so the notifier may be disposed by now
      // (a rebuild on sign-in or restore); writing state would throw.
      if (!mounted) return;
      state = state.copyWith(
        firstPlayTimestamps: firstPlayTimestamps,
        playCounts: playCounts,
        playHistory: playHistory,
        artistAffinities: artistData,
        genreAffinities: genreData,
        trackAffinities: trackData,
        timeOfDayAffinities: timeData,
        blacklistedIds: blacklist.toSet(),
        genreBoosts: boosts,
        genreStreakTracker: streaksTracker,
        lastPlayTimestamps: timestamps,
        lastBoostUpdate: DateTime.fromMillisecondsSinceEpoch(lastSaved),
        firstUseDate: firstUseDate,
        listeningHistory: history,
        trackMetadata: metadata,
        artistTransitions: artistTransitions,
        artistPlayTimestamps: artistPlayTs,
        dayPartAffinities: dayPart,
        artistGenres: _cappedGenres(artistGenres),
      );
    } catch (e) {
      print("WARN: Intelligence load error: $e");
    } finally {
      // In `finally`, not after the assignment: a load that THREW must still
      // release the waiters or the home feed would hang instead of falling back.
      if (!_hydration.isCompleted) _hydration.complete();
    }
  }

  /// Completes the first time [_loadState] finishes, successfully or not.
  /// `_loadState()` runs fire-and-forget from the constructor, so until then state
  /// is empty, and an empty affinity map can mean "not loaded yet" as easily as
  /// "new user". Await this before deciding anything from affinities.
  final Completer<void> _hydration = Completer<void>();
  Future<void> get hydrated => _hydration.future;
  bool get isHydrated => _hydration.isCompleted;

  /// Reads the state once, synchronously, before the first await: re-reading after
  /// each await could produce a torn snapshot if a play lands mid-save, and reading
  /// `state` on a disposed notifier throws (the save issued from dispose() outlives
  /// it).
  Future<void> _saveState() async {
    final snap = state;
    final prefs = await SharedPreferences.getInstance();
    final metadataToSave = snap.trackMetadata.map((k, v) => MapEntry(k, v.toMap()));
    
    final Map<String, dynamic> timeDataToSave = {};
    snap.timeOfDayAffinities.forEach((hour, data) {
      timeDataToSave[hour.toString()] = data;
    });

    final Map<String, dynamic> boostsToSave = {};
    snap.genreBoosts.forEach((genre, boost) {
      if (!boost.isExpired) boostsToSave[genre] = boost.toJson();
    });

    await prefs.setString('intel_first_timestamps', jsonEncode(snap.firstPlayTimestamps));
    await prefs.setString('intel_play_counts', jsonEncode(snap.playCounts));
    await prefs.setString('intel_play_history', jsonEncode(snap.playHistory));
    await prefs.setString('intel_artists', jsonEncode(snap.artistAffinities));
    await prefs.setString('intel_history', jsonEncode(snap.listeningHistory.map((s) => s.toMap()).toList()));
    await prefs.setString('intel_tracks', jsonEncode(snap.trackAffinities));
    await prefs.setString('intel_timestamps', jsonEncode(snap.lastPlayTimestamps));
    await prefs.setString('intel_genres', jsonEncode(snap.genreAffinities));
    await prefs.setString('intel_metadata', jsonEncode(metadataToSave));
    await prefs.setString('intel_time_context', jsonEncode(timeDataToSave));
    await prefs.setStringList('intel_blacklist', snap.blacklistedIds.toList());
    await prefs.setString('intel_genre_boosts', jsonEncode(boostsToSave));
    await prefs.setString('intel_genre_streaks', jsonEncode(snap.genreStreakTracker));
    // Scary-smart signals (Markov transitions, per-artist momentum, day-part).
    await prefs.setString('intel_artist_transitions', jsonEncode(snap.artistTransitions));
    await prefs.setString('intel_artist_ts', jsonEncode(snap.artistPlayTimestamps));
    await prefs.setString('intel_daypart', jsonEncode(snap.dayPartAffinities));
    await prefs.setString('intel_artist_genres', jsonEncode(snap.artistGenres));
    await prefs.setInt('intel_last_save_time', DateTime.now().millisecondsSinceEpoch);
    if (!prefs.containsKey('intel_first_use_date')) {
      await prefs.setInt('intel_first_use_date', snap.firstUseDate.millisecondsSinceEpoch);
    }
    // Mirror this snapshot to the cloud (debounced). Listening telemetry, so it uses
    // the relaxed rate floor: it runs on every finished track, rebuilds itself from
    // listening, and going to the background forces a push anyway. See
    // [BackupUrgency].
    CloudSyncService.instance
        .scheduleBackup(urgency: BackupUrgency.listening);
  }

  /// Re-read all persisted state from SharedPreferences. Called after a cloud
  /// restore overwrites the local blobs so the in-memory state matches.
  Future<void> reloadFromStorage() => _loadState();

  void logListeningStats() {
    final stats = analyzeListeningPatterns();
    print("=== LISTENING STATS ===");
    print("Peak Hours: ${stats['peak_hours']}");
    print("Top Genres: ${stats['top_genres']}");
    print("Diversity Score: ${stats['diversity_score']}");
    print("Current Mood: ${stats['current_mood']}");
    print("Active Boosts: ${stats['active_boosts']}");
  }

  /// Artists ranked by affinity as it stands today (decayed), strongest first, so
  /// feeds and seeds agree with the scorer about who the top artists are. Junk
  /// names like "Unknown" are dropped here.
  List<String> topArtistsNow({int limit = 12}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ranked = state.artistAffinities.entries
        .map((e) => MapEntry(
            e.key, _decayedToNow(e.value, _lastArtistPlayMs(e.key), now)))
        .where((e) => e.value > 0 && !isJunkMusicTerm(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.take(limit).map((e) => e.key).toList();
  }

  /// Fraction of the user's tracks played only once — a proxy for how
  /// adventurous they are (high = explores a lot, low = replays favourites).
  double getDiscoveryRatio() {
    final counts = state.playCounts.values;
    if (counts.isEmpty) return 0.0;
    final oneOff = counts.where((c) => c == 1).length;
    return oneOff / counts.length;
  }

  /// Artists whose play-rate is currently rising (momentum > threshold).
  List<String> getRisingArtists({int limit = 5}) {
    final scored = <MapEntry<String, double>>[];
    for (final a in state.artistPlayTimestamps.keys) {
      final r = _risingScore(a);
      if (r > 0.34) scored.add(MapEntry(a, r));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  /// Predicted next artists from the Markov graph, given the last one you played.
  List<String> getPredictedNextArtists({int limit = 3}) {
    final from = _lastRecordedArtist;
    if (from == null) return const [];
    final row = state.artistTransitions[from];
    if (row == null || row.isEmpty) return const [];
    final e = row.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return e.take(limit).map((x) => x.key).toList();
  }

  String _tastePersonality(double discovery, int genreBreadth) {
    if (discovery > 0.6) return genreBreadth >= 4 ? 'Explorer' : 'Novelty Seeker';
    if (discovery < 0.25) return genreBreadth >= 4 ? 'Devoted Eclectic' : 'Loyalist';
    return genreBreadth >= 5 ? 'Eclectic' : 'Balanced';
  }

  /// A rich, human-facing snapshot of the user's taste — powers a "Your Taste"
  /// screen. Everything is derived from the collected signals.
  Map<String, dynamic> getTasteProfile() {
    final topArtists = (state.artistAffinities.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => e.key)
        .where((a) => !isJunkMusicTerm(a))
        .take(10)
        .toList();
    final topGenres = (state.genreAffinities.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => e.key)
        .where((g) => !isJunkMusicTerm(g))
        .take(6)
        .toList();

    final fading = <MapEntry<String, double>>[];
    for (final a in state.artistPlayTimestamps.keys) {
      final r = _risingScore(a);
      if (r < -0.34) fading.add(MapEntry(a, r));
    }
    fading.sort((a, b) => a.value.compareTo(b.value));

    final mostReplayed = (state.playCounts.entries.where((e) => e.value >= 2).toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => state.trackMetadata[e.key])
        .whereType<Song>()
        .take(8)
        .toList();

    final hourly = <int, double>{};
    state.timeOfDayAffinities.forEach((h, g) => hourly[h] = g.values.fold(0.0, (s, v) => s + v));
    final peakHour = hourly.isEmpty
        ? -1
        : (hourly.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    final dpTotals = <String, double>{};
    state.dayPartAffinities.forEach((k, m) => dpTotals[k] = m.values.fold(0.0, (s, v) => s + v));
    final topDayPart = dpTotals.isEmpty
        ? ''
        : (dpTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    final discovery = getDiscoveryRatio();
    return {
      'topArtists': topArtists,
      'topGenres': topGenres,
      'risingArtists': getRisingArtists(),
      'fadingArtists': fading.take(5).map((e) => e.key).toList(),
      'mostReplayed': mostReplayed,
      'predictedNext': getPredictedNextArtists(),
      'discoveryScore': (discovery * 100).round(),
      'personality': _tastePersonality(discovery, topGenres.length),
      'currentMood': detectCurrentMood(),
      'peakHour': peakHour,
      'topDayPart': topDayPart,
      'totalTracks': state.playCounts.length,
      'totalArtists': state.artistAffinities.length,
      'daysListening': DateTime.now().difference(state.firstUseDate).inDays,
    };
  }

  String detectCurrentMood() {
    final recentHistory = state.artistAffinities.entries
      .where((e) => e.value > 0)
      .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    if (recentHistory.isEmpty) return "neutral";
    
    // Analyze session patterns to detect mood
    final sessionGenres = state.sessionAffinities.entries
      .where((e) => e.value > 5.0)
      .map((e) => e.key.toLowerCase())
      .toList();
    
    // Mood indicators based on genre patterns
    if (sessionGenres.any((g) => g.contains('sad') || g.contains('melancholic') || g.contains('blues'))) {
      return "melancholic";
    } else if (sessionGenres.any((g) => g.contains('energetic') || g.contains('workout') || g.contains('pump'))) {
      return "energetic";
    } else if (sessionGenres.any((g) => g.contains('chill') || g.contains('relax') || g.contains('ambient'))) {
      return "relaxed";
    } else if (sessionGenres.any((g) => g.contains('party') || g.contains('dance') || g.contains('club'))) {
      return "party";
    } else if (sessionGenres.any((g) => g.contains('focus') || g.contains('study') || g.contains('concentration'))) {
      return "focused";
    }
    
    return "neutral";
  }

  /// Weight for an artist the user NAMED. Slightly above a full listen (1.5),
  /// because saying "this is one of my artists" is a stronger statement than
  /// finishing one track — and far below repeated listening, so real behaviour
  /// overtakes a declaration within days rather than being stuck behind it.
  static const double _kPickedArtistWeight = 2.0;

  /// Weight for an artist merely SIMILAR to a picked one. Deliberately below a
  /// single full listen: this is a hint the app worked out, not something the
  /// user said, and it exists so the first mix is not five artists on repeat.
  /// One skip is enough to cancel it.
  static const double _kSimilarArtistWeight = 0.4;

  /// Weight for a genre carried by a picked artist.
  static const double _kSeededGenreWeight = 1.5;

  /// How many similar artists to accept per pick, and in total. A halo, not a
  /// second library — an unbounded expansion would drown the five names the
  /// user actually chose.
  static const int _kSimilarPerPick = 6;
  static const int _kSimilarTotal = 24;

  /// Seeds the taste model from artists picked in onboarding.
  ///
  /// A pick is a declaration, not a play, so this writes the affinity maps
  /// directly by name. Nothing fake is created: no track row, play count, timestamp
  /// or history entry, so picks never show up in recently played, listening totals
  /// or the recap.
  ///
  /// Picked artists go into [artistAffinities] synchronously, since the seed
  /// generator may be asked for recommendations moments later. Then, best-effort,
  /// each pick's genre tags go to [genreAffinities] and [artistGenres] (pre-warming
  /// the scorer's genre cache), and a bounded set of similar artists gets a much
  /// lower weight. A failed lookup only costs that artist's genres.
  ///
  /// Not gated on the history-pause switch: that means "stop recording what I do",
  /// and this is an answer the user gave on purpose.
  Future<void> seedTasteFromPickedArtists(List<String> pickedArtists) async {
    final picks = pickedArtists
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();
    if (picks.isEmpty) {
      print('onboarding: no artists picked — taste model left empty, which is '
          'honest; it fills itself from real plays');
      return;
    }

    // Phase 1: the picks themselves, immediately.
    final artists = Map<String, double>.from(state.artistAffinities);
    for (final a in picks) {
      artists[a] = (artists[a] ?? 0.0) + _kPickedArtistWeight;
    }
    state = state.copyWith(artistAffinities: artists);
    _saveStateDebounced();
    print('onboarding: seeded ${picks.length} picked artist(s) at '
        '$_kPickedArtistWeight — ${picks.join(", ")}');

    // Phase 2: genres and a set of similar artists.
    final svc = ArtistMetadataService();
    final genres = Map<String, double>.from(state.genreAffinities);
    final learnedGenres = Map<String, List<String>>.from(state.artistGenres);
    final halo = Map<String, double>.from(state.artistAffinities);
    var similarAdded = 0;
    var genresAdded = 0;

    for (final a in picks) {
      try {
        final tags = (await svc.getArtistTags(a))
            .map((t) => t.toLowerCase().trim())
            .where((t) => isGenreLikeTag(t, a))
            .toSet()
            .take(4)
            .toList();
        if (tags.isNotEmpty) {
          learnedGenres[a.toLowerCase()] = tags;
          for (final t in tags) {
            genres[t] = (genres[t] ?? 0.0) + _kSeededGenreWeight;
            genresAdded++;
          }
        }
      } catch (_) {
        // One artist's tags failing is not a reason to abandon the rest.
      }
      if (similarAdded < _kSimilarTotal) {
        try {
          final similar = await svc.getSimilarArtists(a, limit: _kSimilarPerPick);
          for (final s in similar) {
            final name = s.artist.trim().isNotEmpty ? s.artist.trim() : s.title.trim();
            if (name.isEmpty) continue;
            // Never let the halo overwrite a pick's own, higher weight.
            if (picks.contains(name)) continue;
            if (similarAdded >= _kSimilarTotal) break;
            halo[name] = (halo[name] ?? 0.0) + _kSimilarArtistWeight;
            similarAdded++;
          }
        } catch (_) {}
      }
    }

    if (!mounted) return;
    state = state.copyWith(
      genreAffinities: genres,
      artistGenres: _cappedGenres(learnedGenres),
      artistAffinities: halo,
    );
    _songGenreMemo.clear(); // new artist→genre entries change past answers
    _saveStateDebounced();
    print('onboarding: seeded $genresAdded genre signal(s) and $similarAdded '
        'similar artist(s) at $_kSimilarArtistWeight — the first mix now has '
        '${halo.length} artist(s) to draw on instead of a chart fallback');
  }

  void pruneOnboardingData() {
    final isOnb = (String id) => id.startsWith('onb_') || id.startsWith('dummy');

    final newMeta      = Map<String, Song>.from(state.trackMetadata)..removeWhere((id, _) => isOnb(id));
    final newCounts    = Map<String, int>.from(state.playCounts)..removeWhere((id, _) => isOnb(id));
    final newHistory   = Map<String, List<int>>.from(state.playHistory)..removeWhere((id, _) => isOnb(id));
    final newAffinities = Map<String, double>.from(state.trackAffinities)..removeWhere((id, _) => isOnb(id));
    final newLast      = Map<String, int>.from(state.lastPlayTimestamps)..removeWhere((id, _) => isOnb(id));
    final newFirst     = Map<String, int>.from(state.firstPlayTimestamps)..removeWhere((id, _) => isOnb(id));

    state = state.copyWith(
      trackMetadata:       newMeta,
      playCounts:          newCounts,
      playHistory:         newHistory,
      trackAffinities:     newAffinities,
      lastPlayTimestamps:  newLast,
      firstPlayTimestamps: newFirst,
      listeningHistory:    state.listeningHistory.where((s) => !isOnb(s.id)).toList(),
    );
    _saveStateDebounced();
  }

  void adjustForMoodShift(String previousMood, String newMood) {
    if (previousMood == newMood) return;
    
    print("Mood Shift Detected: $previousMood → $newMood");
    
    // When mood shifts, boost new mood genres and decay old ones
    final newSession = Map<String, double>.from(state.sessionAffinities);
    
    // Decay all current session affinities by 50% on mood shift
    newSession.forEach((key, value) => newSession[key] = value * 0.5);
    
    // Apply mood-specific boosts
    final moodGenres = _getMoodGenres(newMood);
    for (final genre in moodGenres) {
      newSession[genre] = (newSession[genre] ?? 0.0) + 10.0;
    }
    
    state = state.copyWith(sessionAffinities: newSession);
    _saveStateDebounced();
  }

  List<String> _getMoodGenres(String mood) {
    switch (mood) {
      case "energetic":
        return ["workout", "pump up", "energetic", "upbeat", "high energy"];
      case "relaxed":
        return ["chill", "ambient", "relax", "lofi", "calm"];
      case "melancholic":
        return ["sad", "emotional", "melancholic", "blues", "ballad"];
      case "party":
        return ["party", "dance", "club", "edm", "pop"];
      case "focused":
        return ["focus", "study", "concentration", "instrumental", "classical"];
      default:
        // Neutral mood → no generic-placeholder genre boost. Injecting
        // "general"/"popular"/"mainstream" here polluted genreAffinities and let
        // those placeholder words surface as home topics / queue seeds.
        return const [];
    }
  }

  void clearListeningHistory() {
    state = state.copyWith(listeningHistory: []);
    _saveState();
  }

  /// Forgets everything learned while keeping everything recorded. Unlike
  /// [clearListeningHistory], play counts, timestamps, history and first-seen dates
  /// survive; only affinity maps and temporary genre boosts/streaks are cleared, so
  /// stale recommendations reset without losing stats. They rebuild from real
  /// listening within a session.
  Future<void> resetTasteModel() async {
    state = state.copyWith(
      artistAffinities: {},
      genreAffinities: {},
      sessionAffinities: {},
      trackAffinities: {},
      timeOfDayAffinities: {},
      genreBoosts: {},
      genreStreakTracker: {},
    );
    _saveState();
  }

  void trackGenreBoost(String genre, Song song, {required double listenPercent}) {
    final now = DateTime.now();
    final newBoosts = Map<String, GenreBoost>.from(state.genreBoosts);
    final newStreaks = Map<String, int>.from(state.genreStreakTracker);
    
    // Clean up expired boosts
    newBoosts.removeWhere((key, boost) => boost.isExpired);
    
    // Track genre listening streaks
    if (listenPercent > 0.5) { // Only count if listened more than 50%
      newStreaks[genre] = (newStreaks[genre] ?? 0) + 1;
      
      //  STREAK BONUS: After 3 songs in same genre, boost it temporarily
      if (newStreaks[genre]! >= 3) {
        final multiplier = 1.5 + (min(newStreaks[genre]!, 10) * 0.1); // Max 2.5x boost
        newBoosts[genre] = GenreBoost(
          multiplier: multiplier,
          expiresAt: now.add(const Duration(hours: 2)), // Boost lasts 2 hours
          reason: 'streak',
        );
        print("Genre Boost Activated: $genre (${multiplier.toStringAsFixed(1)}x) - ${newStreaks[genre]} song streak!");
      }
    } else {
      // Reset streak on skip
      newStreaks[genre] = 0;
    }
    
    // Time-based boost for genres consistently played at this hour.
    final hour = now.hour;
    final timeContext = state.timeOfDayAffinities[hour] ?? {};
    if ((timeContext[genre] ?? 0.0) > 10.0) { // Strong time association
      if (!newBoosts.containsKey(genre) || newBoosts[genre]!.reason != 'time_preference') {
        newBoosts[genre] = GenreBoost(
          multiplier: 1.3,
          expiresAt: now.add(const Duration(hours: 3)),
          reason: 'time_preference',
        );
        print("Time-Based Boost: $genre is your ${_getTimeLabel(hour)} favorite");
      }
    }
    
    state = state.copyWith(
      genreBoosts: newBoosts,
      genreStreakTracker: newStreaks,
      lastBoostUpdate: now,
    );
    
    _saveStateDebounced();
  }

  String _getTimeLabel(int hour) {
    if (hour >= 5 && hour < 12) return "morning";
    if (hour >= 12 && hour < 17) return "afternoon";
    if (hour >= 17 && hour < 22) return "evening";
    return "night";
  }

  double getGenreBoostMultiplier(String genre) {
    final boost = state.genreBoosts[genre];
    if (boost == null || boost.isExpired) return 1.0;
    return boost.multiplier;
  }

  Map<String, String> getActiveBoosts() {
    final active = <String, String>{};
    state.genreBoosts.forEach((genre, boost) {
      if (!boost.isExpired) {
        final remaining = boost.expiresAt.difference(DateTime.now());
        active[genre] = "${boost.multiplier.toStringAsFixed(1)}x (${remaining.inMinutes}m left)";
      }
    });
    return active;
  }
}

final intelligenceProvider = StateNotifierProvider<IntelligenceNotifier, IntelligenceState>((ref) {
  return IntelligenceNotifier();
});
/// One entry per play, newest first: the listening record.
///
/// `playCounts` is a total and `lastPlayTimestamps` one moment per track, so a
/// history built from them shows each song once. The per-play stamps in
/// [IntelligenceState.playHistory] are flattened here instead.
///
/// A provider rather than a loop in the widget, because flattening costs
/// O(tracks × stamps) and Riverpod recomputes it only when `playHistory` changes
/// (once per play). Capped after sorting, so the most recent history is kept.
final playLedgerProvider = Provider<List<PlayEvent>>((ref) {
  final history = ref.watch(intelligenceProvider.select((s) => s.playHistory));
  final meta = ref.watch(intelligenceProvider.select((s) => s.trackMetadata));

  final out = <PlayEvent>[];
  history.forEach((id, stamps) {
    final song = meta[id];
    // A stamp with no metadata cannot be rendered — no title, no artist, no
    // cover. Reported as a count elsewhere rather than shown as a blank row.
    if (song == null) return;
    if (id.startsWith('onb_') || id.startsWith('dummy')) return;
    for (final raw in stamps) {
      if (raw <= 0) continue;
      // Seconds in older records, milliseconds in newer ones. See the note on
      // playHistory: every reader normalises with the 10-digit test.
      final ms = raw < 10000000000 ? raw * 1000 : raw;
      out.add(PlayEvent(song, DateTime.fromMillisecondsSinceEpoch(ms)));
    }
  });

  out.sort((a, b) => b.playedAt.compareTo(a.playedAt));
  const cap = 4000;
  return out.length > cap ? out.sublist(0, cap) : out;
});

/// A single play: which track, and when.
class PlayEvent {
  final Song song;
  final DateTime playedAt;
  const PlayEvent(this.song, this.playedAt);
}
