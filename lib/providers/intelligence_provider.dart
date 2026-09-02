import 'package:auvy/services/listening_policy.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/cloud_sync_service.dart';
// Genre tags for the scorer. See [IntelligenceState.artistGenres].
import 'package:auvy/services/artist_metadata_service.dart';

/// Placeholder / category words that leak in from the app's OWN fallback labels
/// ("General" = unknown genre/context, "Top"/"Top songs" = shelf labels) and
/// from generic YouTube channels. They must never be used as recommendation
/// SEEDS (searching "General"/"Top" returns literal junk tracks) nor kept as
/// candidate tracks (a track/channel literally named "General"/"Top" would
/// otherwise get queued and played). Matched on the WHOLE trimmed value so real
/// songs like "Radio", "Music" or "General Admission" are NOT affected.
const Set<String> _kJunkMusicTerms = {
  // Genre / context / shelf placeholders
  'general', 'top', 'topic', 'top hits', 'top 50', 'top songs', 'top result',
  'top tracks', 'trending', 'trending radio', 'pop music', 'global pop',
  // Generic shelf / chart / discovery labels that were leaking into the home
  // feed and the queue. Matched on the WHOLE trimmed value, so a real song like
  // "Best Coast" won't match — only a bare placeholder equal to one of these.
  // NOTE: deliberately NOT including bare common words that are real song titles
  // ("Radio", "Music", "New", "Hot", "Mix", "Song") to avoid hiding real tracks.
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

/// The single source of truth for the "My Top 50" ranking, shared by BOTH the
/// library folder (its song-count subtitle) and the playlist page (the list it
/// opens to) so they can never diverge.
///
/// Ranked by ACTUAL listen count (`playCounts`), descending — not the blended
/// affinity score. The old ranking sorted by affinity and filtered on
/// `affinity > 0`, so a heavily-played song whose affinity dipped (e.g. from a
/// few skips) could be mis-ordered or disappear entirely, which is exactly why
/// Top 50 felt unreliable.
///
/// Ties break by FIRST-played (then id) — both immutable, so the order is
/// stable: a song moves up ONLY when its listen count actually passes the one
/// above it. (The old most-recently-played tiebreak reshuffled every
/// equal-count song on every single listen, which made the playlist feel like
/// it was constantly reorganizing itself.) Duplicate uploads of the same song
/// (same title+artist, different videoId) are collapsed to a single row so one
/// track can't fill several slots.
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
  /// Track id to the timestamps of its individual plays.
  ///
  /// The per-play LEDGER, as opposed to [playCounts], which is only a total.
  /// Wrapped-style questions ("how many plays in the last 30 days") need the
  /// stamps, because a total cannot be filtered by a window.
  ///
  /// Stamps are stored as whole SECONDS in older records and milliseconds in
  /// newer ones, so every reader normalises with the 10-digit test before
  /// comparing. See the window filter in the stats builder. Bounded together
  /// with playCounts; see the note on the pruning cap.
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

  /// Artist → the genre tags actually known for them, lowercased.
  ///
  /// Why the scorer needed a real source of genre
  ///
  /// Genre used to be inferred by keyword-matching a track's TITLE and ALBUM
  /// against an eight-entry list. Almost no real track carries its genre in its
  /// title, so the inference returned EMPTY for nearly every candidate, and the
  /// largest term in [PlayerIntelligenceNotifier.getSongScore], commented as the
  /// key queue fix, collapsed into a flat penalty applied to everything.
  ///
  /// Genre is an ARTIST property far more than a track one, so this is keyed by
  /// artist: one lookup per artist ever, cached and persisted, rather than work
  /// repeated per candidate inside a ranking loop.
  ///
  /// An artist with no tags is stored as an EMPTY list on purpose — it records
  /// "asked, found nothing", so the lookup is not retried on every play.
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

  /// Cap on [IntelligenceState.trackAffinities] — the per-track taste score.
  ///
  /// NOTHING BOUNDED THIS. recordPlay aligns playCounts / playHistory /
  /// firstPlayTimestamps / lastPlayTimestamps to _maxMetadataEntries and caps the
  /// artist timestamp map at 800, but trackInteraction — the other writer — capped
  /// neither affinity map. So both grew with every unique track and artist ever
  /// touched and were never pruned, while being written to prefs on every save and
  /// uploaded as their own backup blobs. A years-old library is tens of thousands
  /// of entries of pure carrying cost.
  ///
  /// 4000 is deliberately generous — well past what scoring actually consults (the
  /// top affinities), and several times the metadata cap, so a track can keep its
  /// score even after its metadata has been evicted.
  static const int _maxTrackAffinities = 4000;

  /// Same, for artist scores. Far fewer artists than tracks, and artistAffinities
  /// feeds the memoised top-5 lookup used by getSongScore.
  static const int _maxArtistAffinities = 1200;

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
    _loadState();
  }

  // Memoized "top-5 artists" set used by getSongScore. getSongScore runs in
  // tight loops over candidate lists, and previously re-sorted the entire
  // artistAffinities map on every call. The cache is keyed on the identity of
  // the artistAffinities map: every mutation site builds a brand-new map via
  // Map.from(...) before copyWith, so the reference changes exactly when the
  // affinities change. We also track length as a cheap extra safety check.
  // Result is byte-for-byte identical to the old inline computation.
  Set<String>? _topArtistsCache;
  Map<String, double>? _topArtistsCacheSource;
  int _topArtistsCacheLength = -1;

  Set<String> get _top5Artists {
    final affinities = state.artistAffinities;
    if (_topArtistsCache != null &&
        identical(_topArtistsCacheSource, affinities) &&
        _topArtistsCacheLength == affinities.length) {
      return _topArtistsCache!;
    }
    final computed = (affinities.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(5)
        .map((e) => e.key)
        .toSet();
    _topArtistsCache = computed;
    _topArtistsCacheSource = affinities;
    _topArtistsCacheLength = affinities.length;
    return computed;
  }

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

  /// Write a pending save NOW instead of waiting out the debounce.
  ///
  /// The five seconds before a close used to be thrown away
  ///
  /// THE BUG THIS FIXES, and it is worse than the cloud one it was found
  /// beside: this loses data LOCALLY. Thirteen call sites record taste through
  /// _saveStateDebounced — a play, a skip, a like, a genre boost, and each
  /// arms a 5-second timer. `dispose()` then CANCELLED that timer without
  /// writing. Close the app within five seconds of the last thing you did and
  /// it never reached prefs at all, so there was nothing for the cloud to be
  /// late about; it simply never existed.
  ///
  /// Called from the app-pause hook, which fires before dispose and while
  /// there is still time to finish a write.
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
    // WRITE, DO NOT DISCARD. Not awaited because dispose cannot be async;
    // issuing the prefs writes here is the last chance they get. The pause
    // hook above is the reliable path — this is the backstop for a dispose
    // that arrives without one.
    if (_pendingSave) {
      _pendingSave = false;
      _saveState();
    }
    super.dispose();
  }

  /// How well [song] fits what this listener wants right now. Higher is better.
  ///
  /// The percentages below are intent, NOT weights
  ///
  /// They read like a normalised blend and are not one. The affinity terms are
  /// scaled fractions of unbounded learned scores, while the Markov, momentum,
  /// top-5, freshness and skip terms are FLAT or fixed-multiplier: `+5` for a
  /// never-played track, `-8` for an overplayed one, `* 10.0` for the transition
  /// probability. Nothing sums to 1 and the total has no ceiling.
  ///
  /// That is fine for RANKING — only the order matters, and every candidate is
  /// scored by the same function, but it means the labels cannot be read as a
  /// balance, and a change of `0.20` to `0.30` does not do what it looks like.
  /// Left as intent markers rather than deleted, because they do record which
  /// signals were meant to dominate.
  ///
  /// Cheap enough to call per candidate: the top-5 set is memoised, the genre
  /// patterns are compiled once, and [_extractSongGenres] memoises per song id.
  /// Nothing here awaits, so it is safe inside a ranking loop.
  double getSongScore(Song song, {String? currentContext}) {
    final hour = DateTime.now().hour;
    double score = 0.0;

    // ── 1. Artist affinity (global long-term preference) ── 20%
    final artistAffinity = state.artistAffinities[song.artist] ?? 0.0;
    score += artistAffinity * 0.20;

    // ── 2. Track-specific affinity (liked / full-listens) ── 15%
    final trackAffinity = state.trackAffinities[song.id] ?? 0.0;
    if (trackAffinity > 0) score += trackAffinity * 0.15;

    // ── 3. Session momentum (what user is vibing with RIGHT NOW) ── 25%
    final sessionArtist  = state.sessionAffinities[song.artist]  ?? 0.0;
    final sessionGenre   = currentContext != null 
        ? (state.sessionAffinities[currentContext] ?? 0.0) 
        : 0.0;
    score += (sessionArtist + sessionGenre * 1.5) * 0.25;

    // ── 4. Genre coherence — THE KEY QUEUE FIX ────────────────── 30%
    // When currentContext (playing track's genre) is provided, songs matching
    // that genre get a 3× multiplier. This is how Spotify's radio/mix stays
    // genre-coherent rather than drifting based on global history alone.
    final inferredGenres = _extractSongGenres(song);
    double highestGenreScore = 0.0;
    for (final g in inferredGenres) {
      final gs = state.genreAffinities[g] ?? 0.0;
      if (gs > highestGenreScore) highestGenreScore = gs;
    }

    if (currentContext != null && currentContext.trim().isNotEmpty) {
      final ctx = currentContext.toLowerCase().trim();
      final contextScore = (state.genreAffinities[currentContext] ?? 0.0) +
                           (state.sessionAffinities[currentContext] ?? 0.0);

      // SET MEMBERSHIP, NOT SUBSTRINGS. This used to also accept
      // `song.artist.contains(ctx)` and `song.title.contains(ctx)`, so a context
      // of "pop" matched Popcaan and "rap" matched Rapsody and "Wrapped" — the
      // coherence reward firing on spelling accidents. Same mistake, and same
      // fix, as SearchService.resolveArtistIdForTrack.
      final songMatchesContext = inferredGenres.contains(ctx);

      if (inferredGenres.isEmpty) {
        // Not knowing is NOT a mismatch
        //
        // The else-branch below used to catch this case and dock 3 points. Genre
        // was inferred from the TITLE, which almost never names one, so the
        // "empty" branch was the common branch: the largest term in this
        // function resolved to a flat -3 on nearly every candidate — a constant,
        // which ranks nothing. Silence now costs nothing either way, and
        // [IntelligenceState.artistGenres] is what turns silence into signal.
      } else if (songMatchesContext) {
        // Stays in the current vibe.
        score += (contextScore * 3.0 + highestGenreScore).clamp(0, 50) * 0.30;
      } else {
        // A KNOWN and DIFFERENT genre — the only case that has earned a penalty.
        score += highestGenreScore * 0.05;
        score -= 3.0;
      }
    } else {
      score += highestGenreScore * 0.10;
    }

    // ── 5. Time-of-day relevance ── 5%
    final timeCtx = state.timeOfDayAffinities[hour] ?? {};
    score += ((timeCtx[song.artist] ?? 0.0) + (timeCtx[currentContext ?? ''] ?? 0.0)) * 0.05;

    // ── 6. Freshness / overplay ──────────────────────────────────── 5%
    final plays = state.playCounts[song.id] ?? 0;
    if (plays == 0)        score += 5.0;   // discovery bonus
    else if (plays <= 3)   score += 2.0;   // mild boost
    else if (plays > 25)   score -= 8.0;   // heavy overplay
    else if (plays > 10)   score -= 3.0;   // mild overplay

    // Track affinity skip penalty
    if (trackAffinity < -2.0) score -= 15.0;
    else if (trackAffinity > 8.0) score -= 6.0; // overplayed favorite

    // ── 7. Top-5 artist bonus ────────────────────────────────────── 5%
    // Uses the memoized top-5 set (see _top5Artists) so this no longer re-sorts
    // the whole artistAffinities map on every getSongScore call.
    if (_top5Artists.contains(song.artist)) score += 5.0;

    // 7b. NEXT-TRACK PREDICTION (Markov transition)
    // "After the artist you just played, how often do you reach for THIS
    // artist?" A learned transition probability — the scary part of autoplay.
    score += _artistTransitionScore(song.artist) * 10.0;

    // ── 7c. MOMENTUM ── boost artists whose play-rate is RISING right now
    // (you're getting into them), gently penalise fading ones.
    score += _risingScore(song.artist) * 6.0;

    // ── 7d. DAY-PART CONTEXT ── your taste for this slice of the week
    // (e.g. "weekend-night" vs "weekday-morning"), finer than hour alone.
    final dp = state.dayPartAffinities[_dayPartKey()] ?? const {};
    score += ((dp[song.artist] ?? 0.0) +
              (currentContext != null ? (dp[currentContext] ?? 0.0) : 0.0)) * 0.08;

    // 8. Hard blacklist
    if (state.blacklistedIds.contains(song.id)) return -1000.0;

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

  // "RIGHT NOW" — day-part aware listening signature
  // Auvy's distinctive feature, and it needs no new tracking, backend or
  // network: `dayPartAffinities` has been accumulating "what you play in THIS
  // slice of the week" all along, and was only ever used as a ×0.08 nudge inside
  // getSongScore.
  //
  // The insight that makes this more than a second "favourites" list: rank by
  // **LIFT**, not by weight. An artist you play constantly is not interesting —
  // they'd top every day part. What's interesting is who you play
  // DISPROPORTIONATELY right now versus your own baseline: your 2am artist, your
  // Sunday-morning artist. That's a TF-IDF-shaped ratio over data nobody else
  // has, because Spotify and Apple Music don't keep a per-day-part profile.

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

  /// The artists/contexts you play disproportionately in the CURRENT day part,
  /// strongest lift first. Each entry: `{name, weight, lift}`.
  ///
  /// `lift` = this day part's weight / the mean weight across every day part
  /// where the name appears. >1 means "more here than is typical for you".
  /// Entries seen in only ONE day part are capped rather than treated as
  /// infinitely distinctive — a single late-night play is noise, not a habit.
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

  /// A ready-to-play "Right Now" mix, assembled ENTIRELY from tracks already in
  /// `trackMetadata`, so it is instant, works fully offline, and can never
  /// surface something you've never heard. Ordered by day-part lift, then by how
  /// much you like the individual track; capped to [perArtist] per artist so it
  /// stays a mix rather than one artist's discography.
  ///
  /// Returns [] when there isn't enough history yet — callers must treat an
  /// empty list as "don't show the rail", never as an error.
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

  /// Everything the Wrapped story needs, computed in ONE pass so the cards never
  /// recompute while swiping.
  ///
  /// [sinceMs] bounds the window (null = all time). Honesty rules baked in:
  ///
  ///  * `minutesAreEstimated` is ALWAYS true. Auvy records play COUNTS, never
  ///    listened duration, so minutes are `plays × track length`. The UI must say
  ///    "about", never present this as measured.
  ///  * `historyWasPaused` reports whether crediting is currently off
  ///    ([ListeningPolicy.pauseListeningHistory]) — a recap that silently omits
  ///    paused periods would be lying by omission.
  ///  * `hasEnoughData` gates the whole feature; a Wrapped built from nine plays
  ///    is worse than none.
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

    // Top genre + longest streak
    final rankedGenres = state.genreAffinities.entries.toList()
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
  double _artistTransitionScore(String toArtist) {
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
  double _risingScore(String artist) {
    final ts = state.artistPlayTimestamps[artist];
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

  /// Replace the in-session affinity map (the "vibe shift" boost).
  ///
  /// Exists because the caller used to reach in and assign
  /// `intelligenceProvider.notifier.state = ...` directly. That works at runtime
  /// — Dart does not enforce `@protected`, but it skipped `_saveStateDebounced`,
  /// so a vibe shift was only ever written to disk if some UNRELATED
  /// intelligence mutation happened to fire afterwards and flush the whole state
  /// with it. The analyzer had been warning about it the whole time.
  void setSessionAffinities(Map<String, double> affinities) {
    state = state.copyWith(sessionAffinities: affinities);
    _saveStateDebounced();
  }

  void bumpLastPlayTimestamp(String songId) {
    if (songId.isEmpty) return;
    // THE PAUSE SWITCH IS ENFORCED HERE, AT THE SINK. See _refuseIfPaused.
    if (_refuseIfPaused('bumpLastPlayTimestamp')) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final newTs = Map<String, int>.from(state.lastPlayTimestamps);
    newTs[songId] = now;
    state = state.copyWith(lastPlayTimestamps: newTs);
    _saveStateDebounced();
  }

  /// Artists that go WITH [currentArtist] in this user's listening.
  ///
  /// THIS USED TO IGNORE ITS OWN ARGUMENT. The old body looped over every
  /// artist in `artistAffinities`, scored them by global + session affinity, and
  /// used [currentArtist] for one thing only: excluding it. Its comment said
  /// "Calculate co-occurrence scores" and no co-occurrence was involved. So it
  /// returned the SAME global top-N for every input, and every caller asking
  /// "what goes with X" got back "your favourite artists" instead.
  ///
  /// That is what made playlist suggestions feel untethered from the playlist:
  /// the playlist page seeds searches with the complements of its OWN artists, and
  /// each of those seeds resolved to the same handful of overall favourites, so a
  /// focused playlist and a random one produced nearly the same candidates. The
  /// suggestions were user-tailored, just not playlist-tailored.
  ///
  /// `artistTransitions` — the fromArtist → toArtist → count graph that has been
  /// recorded all along — is the actual co-occurrence signal, and it is used BOTH
  /// WAYS. "Played after A" and "played before A" are equally evidence of two
  /// artists belonging together; only counting one direction halves the data and
  /// biases toward whatever happens to be later in a session.
  ///
  /// Global affinity survives as a light tie-breaker (a neighbour you actually
  /// like beats one you tolerate) and as the LAST RESORT when the graph has never
  /// seen this artist — a brand-new artist has no neighbours, and returning
  /// nothing would leave callers with no seeds at all.
  List<String> getComplementaryArtists(String currentArtist, {int limit = 5}) {
    final artist = currentArtist.trim();
    if (artist.isEmpty) return const [];

    final co = <String, double>{};
    void add(String other, int count) {
      final o = other.trim();
      if (o.isEmpty || o == artist) return;
      co[o] = (co[o] ?? 0) + count.toDouble();
    }

    // Forward: what gets played AFTER this artist.
    final forward = state.artistTransitions[artist];
    if (forward != null) {
      forward.forEach(add);
    }
    // Reverse: what this artist gets played AFTER.
    state.artistTransitions.forEach((from, row) {
      final n = row[artist];
      if (n != null) add(from, n);
    });

    if (co.isNotEmpty) {
      // Normalise the counts so the affinity tie-break stays a tie-break rather
      // than swamping a genuine but low-count neighbour.
      final maxCo = co.values.reduce(max);
      final ranked = co.entries.map((e) {
        final strength = maxCo <= 0 ? 0.0 : e.value / maxCo;
        final affinity = (state.artistAffinities[e.key] ?? 0.0).clamp(0.0, 1.0);
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
    final timeArtists = timeContext.keys.toList()
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

  /// True only when this is genuinely a new listener.
  ///
  /// Guarded on hydration, AND that guard is the whole point.
  ///
  /// The counts below come from [state], which is empty until [_loadState]
  /// finishes, so an established user reads `0 < 20` and looks brand new for as
  /// long as the SharedPreferences read takes. Every caller then injects generic
  /// content: [refreshAutoplay] text-searches "Trending Radio", and getSmartSeeds
  /// pads with cold-start seeds. That is the same defect that put "Elvis Presley's
  /// Greatest Hits" in Quick Picks, and it is the reason this is fixed HERE rather
  /// than at each call site — one guard covers all of them, and the next thing
  /// added won't have to remember.
  ///
  /// Returning FALSE when we do not yet know is the safe direction: it withholds
  /// generic filler for a few milliseconds from a real new user, instead of
  /// serving it to someone with months of history. A missing recommendation is
  /// recoverable on the next refresh; "why is my app showing me Elvis" is not.
  bool get isInColdStart {
    if (!isHydrated) return false;
    final totalInteractions =
        state.artistAffinities.length + state.trackAffinities.length;
    return totalInteractions < 20; // First 20 interactions
  }

  // getColdStartSeeds() lived here: a hardcoded list of 15 chart artists
  // (Drake, Taylor Swift, …) shuffled as a starting point. REMOVED — nothing
  // called it. It was also the wrong idea: those names are not a taste model,
  // they are a guess about a stranger, and had anything started calling it the
  // hydration race above would have served them to established users too.

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
    
    // FIX: Save the metadata so the Hidden Page can display it!
    final newMetadata = Map<String, Song>.from(state.trackMetadata);
    newMetadata[song.id] = song;
    
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

  /// Remove from blacklist and reset penalties
  /// Un-hide MANY tracks with ONE state write and ONE save.
  ///
  /// WHY THIS EXISTS RATHER THAN A LOOP OVER THE SINGLE VERSION. "Restore
  /// all" on the hidden-content page called [removeFromNotInterested] once per
  /// song, and each call copies the whole blacklist AND the whole
  /// trackAffinities map, replaces the state — rebuilding every watcher — and
  /// then runs `_saveState`, which is the UNDEBOUNCED full write: it
  /// re-serialises play counts, track metadata, time-of-day affinities and
  /// genre boosts, then makes a dozen prefs writes.
  ///
  /// So restoring fifty tracks meant fifty complete serialisations of a profile
  /// that holds hundreds of entries, for one button press. This does the same
  /// work once.
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
    _saveState();
    print(' Removed ${ids.length} track(s) from not interested');
  }

  void removeFromNotInterested(Song song) {
    final newBlacklist = Set<String>.from(state.blacklistedIds)..remove(song.id);
    
    final newTracks = Map<String, double>.from(state.trackAffinities);
    newTracks.remove(song.id);
    
    state = state.copyWith(
      blacklistedIds: newBlacklist,
      trackAffinities: newTracks,
    );
    
    _saveState();
    print(" Removed from not interested: ${song.title}");
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
    
    // 5. Listening intensity (tracks per day average)
    // FIXED: Was using lastBoostUpdate (reset on every genre-boost recalculation),
    // producing a nonsensically short denominator for daily average.
    // Now uses firstUseDate — set once on first install and never changed.
    final daysSinceInstall = DateTime.now().difference(state.firstUseDate).inDays;
    final avgTracksPerDay = totalPlays / max(1, daysSinceInstall);
    patterns['tracks_per_day'] = avgTracksPerDay;
    
    print("Listening Pattern Analysis:");
    print("   Diversity: ${diversityScore.toStringAsFixed(1)}%");
    print("   Mood: ${patterns['current_mood']}");
    print("   Active Boosts: ${patterns['active_boosts']}");
    
    return patterns;
  }

  /// Genre words that appear in a TITLE or ALBUM often enough to be worth
  /// reading, matched on WORD BOUNDARIES.
  ///
  /// Substring matching was the bug here: "pop" hit Popcaan, "rap" hit Rapsody
  /// and "Wrapped", "house" hit "Housewarming". The same mistake, and the same
  /// fix, as `SearchService.resolveArtistIdForTrack`, which documents at length
  /// why identity matching cannot be `contains`.
  ///
  /// This is a WEAK signal and always was: a title-cased song name rarely names
  /// its genre. It survives only because it genuinely catches the compilation and
  /// mix naming that carries one ("Lo-Fi Beats to Study To", "90s R&B Mix"). The
  /// real source is [IntelligenceState.artistGenres].
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

  /// Compiled once. Per candidate this used to build a 12-entry map and run up to
  /// 30 `contains` calls, inside a loop over every song being ranked.
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

  /// The genres a song belongs to — the one answer, for every caller.
  ///
  /// Public because home_provider builds its feed topics from the same question
  /// and used to carry its OWN copy of the rule: a bare `contains` over title,
  /// album AND artist against a 30-word list. That made Metallica "metal",
  /// Popcaan "pop" and Rapsody "rap", and those became real shelves on the home
  /// screen. One rule, one place.
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

  /// Ceiling on how many artists carry a remembered genre list.
  ///
  /// This map was UNBOUNDED. One entry per distinct artist ever played, kept
  /// for the life of the install, written into prefs and re-parsed at every
  /// startup. 33 artists were learned in a single day of ordinary use, so a
  /// year of it is thousands of entries that nothing ever removed.
  ///
  /// 2000 is far past any real library and still only ~120KB of JSON. Entries
  /// are cheap to lose: an evicted artist costs one Last.fm lookup the next time
  /// it is played, which is the same request that created it.
  static const int _maxArtistGenres = 2000;

  /// Trim to [_maxArtistGenres], dropping the OLDEST entries.
  ///
  /// Dart maps keep insertion order, so `keys.first` is the oldest — the same
  /// FIFO the loudness and low-quality caches use. Not an LRU, because there is
  /// no access timestamp here and adding one would cost more than an occasional
  /// re-lookup of a long-unplayed artist.
  ///
  /// Applied on LOAD as well as on learn, so an install that already overflowed
  /// is brought back inside the cap rather than staying over it forever.
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

  /// Is [tag] a GENRE, or is it one of the other things Last.fm tags carry?
  ///
  /// Last.fm tags are user-generated, AND it shows
  ///
  /// The top tags for two artists, straight off the device on 2026-08-31:
  ///
  ///     Fifth Harmony  -> pop, best of 2016, ratchet music, rnb, 2016
  ///     Justin Bieber  -> pop, justin bieber, love at first listen, acoustic,
  ///                       ed sheeran
  ///
  /// Four of ten are genres. The rest are a year, a personal listmaking tag, a
  /// phrase, the artist's OWN name, and a DIFFERENT artist's name. Storing those
  /// as genres teaches `genreAffinities` that "2016" and "ed sheeran" are genres,
  /// and then the queue's coherence check can match on them.
  ///
  /// This cannot be perfect without a real taxonomy, and does not try to be. It
  /// removes the four shapes that are reliably not genres and leaves anything it
  /// is unsure about, because a stray tag is a weak wrong signal while dropping a
  /// real one ("uk drill") loses the distinction that makes the feature worth
  /// having.
  /// Public only for the test that runs it against the tags a real account
  /// actually returned. Same treatment as [accentFromRgba] in theme_provider:
  /// a rule worth pinning to real data should be reachable from a test.
  @visibleForTesting
  bool isGenreLikeTag(String tag, String artist) {
    if (tag.isEmpty || tag.length > 24) return false;

    // 1. The artist's own name, or any artist this listener already knows. Both
    //    are extremely common as tags and neither is a genre.
    //
    //    WHOLE WORDS, NOT SUBSTRINGS, and the first version of this got it
    //    wrong in both directions. `a.contains(tag)` drops the genuine tag "pop"
    //    for Popcaan, and `tag.contains(a)` is true for EVERY tag when the artist
    //    name is empty, because Dart's contains('') always is. Matching the tag
    //    against the artist's WORDS keeps "pop" for Popcaan (not a word of it)
    //    while still dropping "bieber" for Justin Bieber (a word of it).
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

  /// Learn and remember [artist]'s genres, once ever.
  ///
  /// Fire-and-forget by design: the score that wants this runs synchronously over
  /// hundreds of candidates and must never await a network call. The first play of
  /// a new artist therefore scores WITHOUT genre and every later one scores with
  /// it, which is the right trade, because the alternative is either a blocking
  /// lookup or no genre at all (what the title-keyword inference amounted to).
  ///
  /// Stores an EMPTY list when Last.fm knows nothing, so "asked, nothing there"
  /// is recorded and not re-asked forever.
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
    () async {
      final svc = ArtistMetadataService();
      var tags = await svc.getArtistTags(artist);
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
          // see [_isGenreLikeTag].
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
              '${viaTrack ? " (via its track)" : ""}: '
              '${genres.isEmpty ? "none known" : genres.join(", ")}');
          _saveStateDebounced();
        })
        .catchError((_) {})
        .whenComplete(() => _genreLookupsInFlight.remove(key));
  }

  void recordPlay(Song song) {
    if (song.id.startsWith('dummy') || song.id.startsWith('onb_')) return;
    // THE PAUSE SWITCH IS ENFORCED HERE, AT THE SINK. See _refuseIfPaused.
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

    // The TIMESTAMP ledger must be written HERE, by the same rule and at the
    // same instant as the count.
    //
    // It used to be written only by `trackInteraction` (from playNext, when a
    // track FINISHED, gated on its own `percent >= 0.25`) while the count came
    // from here (the scrobble threshold, ~30s/50%). Two ledgers, two different
    // definitions of "a play", so a track heard past the threshold and then
    // SKIPPED got a count but no timestamp, and every time-based view built on
    // the stamps (the stats Listening Clock, Active Days, day streak, busiest
    // day, and Wrapped's windowing) silently under-counted relative to the play
    // numbers shown beside them. Recording both together makes them agree by
    // construction.
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

    // ── MOMENTUM: append this play to the artist's recent-play ledger (cap 60).
    final newArtistTs = Map<String, List<int>>.from(state.artistPlayTimestamps);
    if (artistOk) {
      final list = List<int>.from(newArtistTs[artist] ?? const []);
      list.add(now);
      if (list.length > 60) list.removeAt(0);
      newArtistTs[artist] = list;
    }

    // ── MARKOV TRANSITION: record "the artist you just played → this artist".
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

    // ── DAY-PART CONTEXT: reinforce this artist + its genres for this slice.
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

  /// Fold play counts out of another app's backup into this profile.
  ///
  /// RAISES ONLY, NEVER LOWERS. An imported count is taken only when it is
  /// HIGHER than what this profile already holds — the alternative is that
  /// restoring a months-old backup quietly resets real listening history, and
  /// this data drives Top 50, Quick Picks and Wrapped.
  ///
  /// Deliberately narrow: counts, metadata and a first-play stamp. It does NOT
  /// touch artist momentum, Markov transitions or day-part affinities, because
  /// those describe WHEN and in WHAT ORDER this user listened, and a foreign
  /// backup carries no such evidence — inventing it would poison the
  /// recommendations with another person's sequencing.
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

    // Real dates when the backup has them
    //
    // An import used to stamp every track "now", which made months of listening
    // look like it all happened this afternoon, and everything time-based reads
    // those stamps: the listening clock, active days, the day streak, "discovered
    // on", Wrapped's windowing. A backup with an event log carries the actual
    // dates, so they are used, and only the tracks it has nothing for fall back
    // to now.
    //
    // EARLIEST first-play wins and LATEST last-play wins, so importing an old
    // backup can extend the history backwards without ever moving a real, later
    // play earlier than it happened.
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

    // The three affinities that actually steer recommendations
    //
    // COUNTS AND DATES ALONE BARELY MOVE WHAT THE APP RECOMMENDS. Look at what
    // getSongScore weighs: genre coherence 30%, artist affinity 20%, track
    // affinity 15%, and play count only ~5% (as a freshness/overplay term). An
    // import that filled counts and timestamps and nothing else was therefore
    // restoring the user's HISTORY without restoring their TASTE — Quick Picks,
    // the home feed and the queue would still behave like a brand-new profile.
    //
    // All three are aggregations of the same imported plays, so deriving them
    // invents nothing. The per-play weights are matched to the live ones
    // (trackInteraction: a full listen is 1.5, a partial 0.4) at HALF strength,
    // because an imported play is hearsay — this app never saw whether it was
    // finished or skipped, and hearsay should not outrank evidence.
    //
    // Deliberately NOT derived: Markov transitions, day-part affinities, artist
    // momentum and time-of-day. Those describe the ORDER and the HOURS someone
    // listened; a count is no evidence of either, and fabricating them would
    // steer recommendations with data that does not exist.
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

  /// "pause listening history" did NOT pause the taste model
  ///
  /// THE BUG THIS FIXES, and it is a privacy one. ListeningPolicy documents the
  /// switch as "Auvy keeps playing normally but stops feeding the taste model,
  /// stats and Top 50". It did not. The check lived at CALL SITES, and only one
  /// of the four had it: the two in player_queue — a skip, and a track played to
  /// the end — recorded into the taste model, the play counts and Top 50 with
  /// the switch on and a private session active.
  ///
  /// Which is the predictable outcome of guarding callers: every new call site is
  /// a chance to forget, and forgetting is silent. The three methods that WRITE
  /// are the three places worth guarding, because a caller cannot reach the data
  /// except through them.
  ///
  /// Nothing already recorded is touched — that is Settings → clear/delete, and
  /// it is why Top 50 may still redraw from counts it already had.
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
    // THE PAUSE SWITCH IS ENFORCED HERE, AT THE SINK. See _refuseIfPaused.
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

    // The playHistory stamp that used to be written HERE has moved to
    // `recordPlay`, so the timestamp ledger and `playCounts` share one
    // definition of "a play". Writing it in both places would DOUBLE-count every
    // finished track (2 stamps, 1 count) and inflate the time-of-day charts.
    // `countsAsPlay` still gates the affinity/mood learning below, which is a
    // different question from "did this count as a play".
    if (countsAsPlay) {
      // (intentionally no ledger write. See above)
    }

    final newArtists = Map<String, double>.from(state.artistAffinities);
    newArtists[song.artist] = (newArtists[song.artist] ?? 0.0) + weight;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final newTracks = Map<String, double>.from(state.trackAffinities);
    
    //  REMOVED PlayCounts logic from here! Handled instantly by recordPlay()
    
    final delta = isHardSkip ? -4.0 : isBoredomSkip ? -0.5 : (isFullListen ? 1.5 : 0.8);
    final lastPlayMs = state.lastPlayTimestamps[song.id] ?? nowMs;
    final daysDelta = (nowMs - lastPlayMs) / 86400000.0;
    final decayFactor = pow(0.995, daysDelta.clamp(0, 365)); 
    final decayedExisting = (newTracks[song.id] ?? 0.0) * decayFactor;
    newTracks[song.id] = decayedExisting + delta;

    final newGenres = Map<String, double>.from(state.genreAffinities);
    final genre = genreContext ?? "General";
    newGenres[genre] = (newGenres[genre] ?? 0.0) + weight;

    final extractedGenres = _extractSongGenres(song);
    for (final extractedGenre in extractedGenres) {
      newGenres[extractedGenre] = (newGenres[extractedGenre] ?? 0.0) + (weight * 0.5);
    }

    final newSession = Map<String, double>.from(state.sessionAffinities);
    newSession.forEach((key, value) => newSession[key] = value * 0.9);
    final genreBoostMultiplier = getGenreBoostMultiplier(genre);
    newSession[genre] = (newSession[genre] ?? 0.0) + (weight * genreBoostMultiplier);
    newSession[song.artist] = (newSession[song.artist] ?? 0.0) + (weight * 0.5);

    final newTimeMap = Map<int, Map<String, double>>.from(state.timeOfDayAffinities);
    final hourMap = Map<String, double>.from(newTimeMap[hour] ?? {});

    if (isHardSkip) {
      newArtists[song.artist] = ((newArtists[song.artist] ?? 0.0) - 2.0).clamp(-10.0, double.infinity);
      if (genreContext != null) {
        final currentVibe = newSession[genreContext] ?? 0.0;
        newSession[genreContext] = (currentVibe - 5.0).clamp(-20.0, 20.0);
      }
    }
    
    hourMap[genre] = (hourMap[genre] ?? 0.0) + weight;
    newTimeMap[hour] = hourMap;

    final List<Song> updatedHistory = state.listeningHistory.isEmpty || state.listeningHistory.first.id != song.id 
        ? [song, ...state.listeningHistory].take(500).toList() 
        : state.listeningHistory;

    state = state.copyWith(
      // Bounded here rather than at each of the several mutation sites: this is
      // the one write they all funnel through. See _capAffinities.
      artistAffinities: _capAffinities(newArtists, _maxArtistAffinities),
      trackAffinities: _capAffinities(newTracks, _maxTrackAffinities),
      genreAffinities: newGenres,
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

    // Drop placeholder topics ("General"/"Unknown"/"Top"...) so they can never be
    // used as recommendation seeds.
    final sorted = pool.where((t) => !isJunkMusicTerm(t)).toList();
    sorted.sort((a, b) {
      // 1. Base Score = Artist Affinity + Genre Affinity
      double scoreA = (state.artistAffinities[a] ?? 0.0) + (state.genreAffinities[a] ?? 0.0);
      double scoreB = (state.artistAffinities[b] ?? 0.0) + (state.genreAffinities[b] ?? 0.0);

      // 2. Time-of-Day Boost (3x multiplier for current hour relevance)
      scoreA += (timeContext[a] ?? 0.0) * 3.0;
      scoreB += (timeContext[b] ?? 0.0) * 3.0;

      // 3. Fatigue Penalty (Heavy penalty if recently suggested)
      if (state.recentTopics.contains(a)) scoreA -= 10.0;
      if (state.recentTopics.contains(b)) scoreB -= 10.0;

      return scoreB.compareTo(scoreA);
    });
    
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

  void updateBlacklist(Set<String> ids) {
    state = state.copyWith(blacklistedIds: ids);
    _saveStateDebounced();
  }

  /// Track which genres pair well together for better recommendations
  void trackGenrePairing(String genre1, String genre2) {
    // This can be used later for cross-genre recommendations
    final newGenres = Map<String, double>.from(state.genreAffinities);
    
    // Boost both genres slightly when they appear together
    newGenres[genre1] = (newGenres[genre1] ?? 0.0) + 0.1;
    newGenres[genre2] = (newGenres[genre2] ?? 0.0) + 0.1;
    
    state = state.copyWith(genreAffinities: newGenres);
    _saveState();
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

      // ── Scary-smart signals: Markov transitions, per-artist momentum, day-part.
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

        // One-time: forget the empty answers the first version recorded
        //
        // v1 of the learner asked `track.getTopTags` and cached the result per
        // ARTIST. Track tags are sparse, so an untagged track wrote an empty list
        // that the containsKey guard then treats as settled — the artist could
        // never be asked again. v2 asks `artist.getTopTags` first, which answers
        // for almost everyone, but only for artists not already written off.
        //
        // Dropping just the EMPTY entries re-opens exactly those and keeps every
        // real answer. Version-stamped rather than unconditional: an artist that
        // genuinely has no tags must still be recorded as such, or it is
        // re-requested on every launch forever.
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
  ///
  /// AN EMPTY AFFINITY MAP MEANS "NOT LOADED YET" JUST AS OFTEN AS IT MEANS
  /// "NEW USER", AND THE TWO NEED OPPOSITE BEHAVIOUR.
  ///
  /// `_loadState()` is fire-and-forget from the constructor, so this notifier is
  /// live with completely empty state for as long as the SharedPreferences read
  /// takes. Anything that treats `artistAffinities.isEmpty` as "cold start" will
  /// therefore do so intermittently for an established user, depending purely on
  /// whether it got there first.
  ///
  /// That is what put "Elvis Presley's Greatest Hits" and "Radio Top Hits" in
  /// Quick Picks for a user with months of history: HomeProvider hit the
  /// cold-start branch and text-searched "Top Hits". It looked random because it
  /// WAS a race. Await this before reading affinities to decide anything.
  final Completer<void> _hydration = Completer<void>();
  Future<void> get hydrated => _hydration.future;
  bool get isHydrated => _hydration.isCompleted;

  /// Reads the state once, synchronously, before the first await.
  ///
  /// Two reasons, and the second only became reachable when dispose() started
  /// flushing instead of discarding:
  ///
  ///   • this method awaits between writes, and it used to re-read `state` after
  ///     each one. A play or a skip landing mid-save therefore produced a TORN
  ///     snapshot — some keys from before the change, some from after.
  ///   • reading `state` on a DISPOSED StateNotifier throws. The save issued
  ///     from dispose() outlives the notifier by design, so every read after the
  ///     first await would have thrown StateError and silently abandoned the
  ///     write — turning the fix into the bug it was meant to close.
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
    // Mirror this snapshot to the cloud (debounced) so it survives a reinstall.
    CloudSyncService.instance.scheduleBackup();
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

  /// Forget everything LEARNED, keeping everything RECORDED.
  ///
  /// Distinct from [clearListeningHistory] on purpose: history is the record of
  /// what was played, this is the set of conclusions drawn from it. Someone whose
  /// recommendations have gone stale — a phase they've grown out of, or a
  /// borrowed phone skewing the model — wants the conclusions gone, NOT their
  /// play counts, stats and Wrapped.
  ///
  /// So play counts, timestamps, listening history and first-seen dates all
  /// survive; only the affinity maps and the temporary genre boosts/streaks are
  /// cleared. Recommendations then rebuild from real listening within a session.
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
        print(" Genre Boost Activated: $genre (${multiplier.toStringAsFixed(1)}x) - ${newStreaks[genre]} song streak!");
      }
    } else {
      // Reset streak on skip
      newStreaks[genre] = 0;
    }
    
    // TIME-BASED BOOST: Boost genres consistently played at certain times
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