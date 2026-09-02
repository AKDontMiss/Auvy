// lib/services/search_service.dart

import 'dart:async';
import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/services/database_service.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/mood_shelf.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum SearchContextScope { tracks, albums, artists, playlists }

class SearchCategoricalResult {
  final List<Song> items;
  final String? continuationToken;

  SearchCategoricalResult({required this.items, this.continuationToken});
}

class SearchService {
  /// Global "process videos" switch. When false (default) music-video
  /// (OMV/UGC) results are dropped so only the original AUDIO versions ever
  /// surface. Mirrors PlayerState.processVideosEnabled — the player pushes the
  /// persisted value here on startup and whenever the settings toggle flips.
  static bool processVideos = false;

  final CatalogApiClient _innerTubeClient = CatalogApiClient();
  final DatabaseService _databaseService = DatabaseService();

  /// The EXACT release date of a track as "YYYY-MM-DD", or null when YouTube
  /// doesn't publish one.
  ///
  /// The catalog endpoints only ever expose a YEAR (it's the last run of an
  /// item's subtitle), which is why release info app-wide used to read "2019".
  /// The real calendar date lives in the player response's microformat, so this
  /// goes there. Memoized for a week, and already warm for anything you've
  /// played (stream resolution seeds the same cache).
  Future<String?> getTrackReleaseDate(String videoId) =>
      _innerTubeClient.getPublishDate(videoId);

  // Verified YouTube Music search filter params — opaque base64 values YouTube's
  // own web client sends, confirmed by observing its requests.
  String _getParamForScope(SearchContextScope scope) {
    switch (scope) {
      case SearchContextScope.tracks:
        return 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D'; // Songs
      case SearchContextScope.albums:
        return 'EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D'; // Albums
      case SearchContextScope.artists:
        return 'EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D'; // Artists
      case SearchContextScope.playlists:
        return 'EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D'; // Featured playlists
    }
  }

  Future<SearchCategoricalResult> executeScopedSearch(
    String query, {
    required SearchContextScope scope,
    String? continuationToken,
  }) async {
    // The video mode is part of the key so the audio-only and video-allowed
    // result sets are cached separately (the FILTERED list is what's stored).
    // Key on the RAW query/token, NOT their hashCode: hashCode collisions were
    // serving a DIFFERENT query's cached results (rare, and near-impossible to
    // diagnose in the field). The DB key column is TEXT, so length is fine.
    final cacheKey = "search:${scope.name}:${processVideos ? 'v' : 'a'}:$query:${continuationToken ?? 'init'}";

    // NOTE: history is intentionally NOT written here. executeScopedSearch is
    // called from dozens of internal call sites (artist lookups, smart-radio
    // seeds, home-feed generation, onboarding, album→artist navigation), and
    // writing every one of those to history polluted the search page with
    // terms the user never typed. History is now written ONLY from the search
    // box (search_page.dart) via SearchNotifier.saveSearch.

    if (continuationToken == null) {
      final cachedData = await _databaseService.readPageCache(cacheKey);
      // Fixed Empty Cache Trap: Forces network validation if cached profiles return 0 elements
      if (cachedData != null && cachedData['items'] != null && (cachedData['items'] as List).isNotEmpty) {
        final List<dynamic> list = cachedData['items'];
        return SearchCategoricalResult(
          items: list.map((e) => _mapJsonToSong(Map<String, dynamic>.from(e as Map))).toList(),
          continuationToken: cachedData['continuation'],
        );
      }
    }

    try {
      Map<String, dynamic> rawResponse;

      if (continuationToken != null) {
        rawResponse = await _innerTubeClient.searchContinuation(continuationToken);
      } else {
        // Send the scope filter so we get the correct result type (was computed
        // but never passed before — the cause of mixed/incorrect search hits).
        rawResponse = await _innerTubeClient.search(query, params: _getParamForScope(scope));
      }

      List<dynamic> itemsList = rawResponse['items'] ?? [];
      final String? nextToken = rawResponse['continuation'];

      // Song searches: only show the clean AUDIO version — the user should NOT
      // see music VIDEOS unless they explicitly searched for a video. Videos are
      // dropped entirely when an audio result exists. The filtered list is what
      // gets cached, so it sticks.
      if (scope == SearchContextScope.tracks) {
        // Audio-only mode is STRICT: no videos ever surface, not even when the
        // query contains the word "video" (that keyword bypass was the leak
        // that let music videos through with the setting off).
        itemsList = _filterPreferAudio(
            itemsList.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            allowVideos: processVideos);
      }

      final List<Map<String, dynamic>> rawMaps = [];
      final List<Song> stronglyTypedSongs = [];

      for (var item in itemsList) {
        final itemMap = Map<String, dynamic>.from(item as Map);
        final String possibleId = itemMap['id'] ?? '';
        if (possibleId.isEmpty) continue; // Skip incomplete layout nodes safely

        rawMaps.add(itemMap);
        stronglyTypedSongs.add(_mapJsonToSong(itemMap));

        if (itemMap['type'] == 'track') {
          await _databaseService.cacheSong(itemMap);
        }
      }

      if (continuationToken == null && rawMaps.isNotEmpty) {
        await _databaseService.writePageCache(cacheKey, {
          'items': rawMaps,
          'continuation': nextToken,
        });
      }

      return SearchCategoricalResult(items: stronglyTypedSongs, continuationToken: nextToken);
    } catch (e) {
      print("WARN: Search Service execution error: $e");
      return SearchCategoricalResult(items: [], continuationToken: null);
    }
  }

  /// True when a raw parser item is a music VIDEO (OMV/UGC watch type).
  /// Non-track items (albums/artists/playlists) are never "videos".
  static bool isVideoItem(Map m) {
    if (m['type'] != 'track') return false;
    final t = (m['musicVideoType'] ?? '').toString();
    return t.contains('OMV') || t.contains('UGC');
  }

  /// The one audio-only gate. When [processVideos] is false (the settings
  /// toggle ON) music-video items are dropped from ANY raw item list — search,
  /// home feed, artist pages, playlists, so a video never surfaces anywhere.
  static List<Map<String, dynamic>> applyAudioOnly(List<Map<String, dynamic>> items) {
    if (processVideos) return hideShorts ? dropShorts(items) : items;
    // Audio-only already removes every video, and a Short IS a video, so the
    // Shorts filter is deliberately not applied again here. It only has work to
    // do on the videos-allowed path above.
    return items.where((m) => !isVideoItem(m)).toList();
  }

  /// Whether to hide YouTube Shorts when videos are allowed. Persisted as
  /// `auvy_hide_shorts`, mirrored here from settings like [processVideos].
  static bool hideShorts = true;

  /// A Short is a VIDEO item of at most 60 seconds, or one that says so in its
  /// title. Shorts pollute browse and search once videos are allowed: they are
  /// vertical clips, frequently a snippet of the real track, and playing one
  /// gives you a few seconds of audio where a song was expected.
  ///
  /// Conservative on purpose:
  ///  • [isVideoItem] gates it, so a genuinely short AUDIO track (an interlude,
  ///    a skit, an intro) can never be caught — those are ATV, not UGC/OMV.
  ///  • An UNKNOWN duration (0) is never treated as a Short. Length is missing
  ///    from some shelves, and guessing there would silently delete real tracks —
  ///    the failure mode is invisible, so it has to be the safe one.
  static bool isShortItem(Map m) {
    if (!isVideoItem(m)) return false;
    final title = (m['title'] ?? '').toString().toLowerCase();
    if (title.contains('#short')) return true;
    final ms = (m['durationMs'] as num?)?.toInt() ?? 0;
    return ms > 0 && ms <= 60000;
  }

  static List<Map<String, dynamic>> dropShorts(List<Map<String, dynamic>> items) =>
      items.where((m) => !isShortItem(m)).toList();

  // A "hide explicit tracks" filter used to live here. REMOVED, for two reasons:
  //
  //  1. It never worked on SEARCH. This choke point is only reached by the home
  //     feed, artist pages and a couple of browse paths — the search path filters
  //     through `_filterPreferAudio` instead, so the toggle appeared to do
  //     nothing where users actually looked.
  //  2. More importantly it's the wrong model. YouTube publishes explicit and
  //     clean edits as SEPARATE uploads with different video ids and no mapping
  //     between them, so nothing here can "switch a track to its clean version".
  //     A filter could only make tracks VANISH, which is worse than showing both
  //     editions and marking which is which.
  //
  // Replaced by always-on labelling: `ExplicitBadge` (which already existed but
  // was wired to nothing) now renders in search rows from `Song.isExplicit`.

  /// Audio-first track results. In audio-only mode (allowVideos=false) music
  /// VIDEOS (OMV/UGC) are dropped COMPLETELY — no keyword bypass, no fallback:
  /// the user asked for audio versions only, so a video never surfaces even if
  /// that leaves fewer (or zero) results. With videos allowed they're merely
  /// sorted after the audio versions.
  List<Map<String, dynamic>> _filterPreferAudio(List<Map<String, dynamic>> items,
      {bool allowVideos = false}) {
    final audio = <Map<String, dynamic>>[];
    final video = <Map<String, dynamic>>[];
    for (final m in items) {
      (isVideoItem(m) ? video : audio).add(m);
    }
    // Applied HERE as well as in applyAudioOnly: search does not pass through
    // that choke point (see the removed explicit-filter note above), and a filter
    // that works everywhere except search is the exact mistake that made the old
    // "hide explicit" toggle look broken.
    if (allowVideos) {
      return [...audio, ...(hideShorts ? dropShorts(video) : video)];
    }
    // STRICT audio-only: videos are never shown, not even as a fallback.
    return audio;
  }

  Song _mapJsonToSong(Map<String, dynamic> json) {
    final String trackId = json['id'] ?? json['videoId'] ?? 'unknown_id';
    // Strip video decorations ("(Official Video)", "… official music video",
    // "(Lyric Video)", "(Visualizer)", …) from the DISPLAY title at fetch time —
    // free, no network, so lists show the clean song name everywhere, not the
    // YouTube video title. Falls back to the raw title if a strip empties it.
    final String trackTitle = cleanDisplayTitle(json['title'] ?? 'Unknown Title');
    final String trackAlbum = json['album'] ?? 'Single';
    final String trackThumbnail = getHighResImage(json['thumbnail'] ?? json['image'] ?? '');
    final int durationMs = json['durationMs'] ?? 0;

    final int totalSeconds = (durationMs / 1000).round();
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    final String durationString = "$minutes:${seconds.toString().padLeft(2, '0')}";

    final artistRefs = (json['artists'] as List? ?? [])
        .whereType<Map>()
        .map((m) => SongArtist(
              name: (m['name'] ?? '').toString(),
              id: (m['id'] ?? '').toString(),
            ))
        .where((a) => a.name.isNotEmpty)
        .toList();

    // The parser emits an EMPTY STRING (not null) when it can't find an artist,
    // so `json['artist'] ?? ...` doesn't catch it. Treat empty as missing and
    // fall back to the per-artist credits before the generic placeholder.
    final String rawArtist = (json['artist'] ?? '').toString().trim();
    final String trackArtist = rawArtist.isNotEmpty
        ? rawArtist
        : (artistRefs.isNotEmpty
            ? artistRefs.map((a) => a.name).join(', ')
            : 'Unknown Artist');

    return Song(
      id: trackId,
      title: trackTitle,
      artist: trackArtist,
      image: trackThumbnail,
      audioUrl: json['audioUrl'] ?? '',
      albumId: json['albumId'] ?? '',
      albumTitle: trackAlbum,
      releaseDate: (json['releaseDate'] ?? '').toString(),
      // EMPTY when unknown — never a plausible-looking placeholder.
      //
      // This used to fall back to '3:45', which was wrong in three places at once:
      //  • Song details displayed "3:45" as if it were the track's real length.
      //  • The playlist header summed it into the collection's total runtime, so
      //    the total was silently inflated instead of being marked approximate
      //    (`_totalDurationLabel` prefixes "~" precisely when a track contributes
      //    nothing).
      //  • Worst: `resolveAudioEquivalent`'s ±5s duration guard compared
      //    candidates against a FABRICATED 225 seconds, so it could reject the
      //    correct audio match — the very check added to stop wrong cover art.
      //
      // Every consumer already handles an empty duration ('' parses to 0, which
      // means "don't constrain"), so absence is both honest and safe.
      duration: durationMs <= 0 ? '' : durationString,
      // 0 = UNKNOWN, and for YouTube rows it always is. This used to default
      // to 50, which broke two things at once:
      //
      //  • Song details reported "50% worldwide" for EVERY YouTube track — a
      //    fabricated statistic that passed the `popularity > 0` guard, so the row
      //    was always shown and always wrong. With 0 the row correctly disappears
      //    when there is nothing to report.
      //  • `_scoreAndRankRecommendations` reads
      //    `popularity > 0 ? popularity : <positional decay>`. With every
      //    candidate pinned at 50, the decay never ran and each one contributed an
      //    identical 20.0 — a constant that cancels out in ranking. The whole
      //    popularity term of the recommender was inert.
      //
      // Real values still arrive from Spotify (`item.popularity`), Deezer (rank)
      // and Last.fm (listener counts) where those services are the source.
      popularity: json['popularity'] ?? 0,
      loudness: json['loudness']?.toDouble() ?? -8.5,
      isExplicit: json['isExplicit'] == true,
      songCount: json['songCount'] ?? json['trackCount'] ?? 0,
      artists: artistRefs,
      viewCount: (json['viewCount'] ?? '').toString(),
      musicVideoType: (json['musicVideoType'] ?? '').toString(),
    );
  }

  Future<List<Song>> search(String query, [String? type]) async {
    SearchContextScope fallbackScope = SearchContextScope.tracks;
    if (type != null) {
      final t = type.toLowerCase();
      if (t.contains('artist')) fallbackScope = SearchContextScope.artists;
      else if (t.contains('album')) fallbackScope = SearchContextScope.albums;
      else if (t.contains('playlist')) fallbackScope = SearchContextScope.playlists;
    }
    final result = await executeScopedSearch(query, scope: fallbackScope);
    return result.items;
  }

  /// Normalize a track title for matching: lower-case, strip common music-video
  /// decorations ("(Official Video)", "[MV]", "(Official Music Video)", …) and
  /// featured-artist tails, then collapse to alphanumerics.
  /// Qualifiers that make a track a DIFFERENT RECORDING rather than a different
  /// presentation of the same one.
  ///
  /// Deliberately excludes `remaster`, `version`, `mix` and a bare `edit`:
  /// a remaster is the same performance, and the other three are too generic
  /// ("Single Version", "Album Mix") to reject on without blocking legitimate
  /// swaps. `radio edit` is matched as a whole phrase for that reason.
  static final RegExp _recordingVariant = RegExp(
      r'\b(remix|instrumental|acoustic|live|unplugged|karaoke|cover|'
      r'sped\s*up|slowed|reverb|radio\s*edit|extended|demo|mashup|vip|bootleg)\b',
      caseSensitive: false);

  /// Featured artists named in a title, e.g. "(feat. Juice WRLD)" → {juice wrld}.
  static Set<String> _featuredIn(String title) {
    final out = <String>{};
    for (final m in RegExp(r'(?:feat|ft|featuring|with)\.?\s+([^)\]\-–]+)',
            caseSensitive: false)
        .allMatches(title)) {
      for (final part in (m.group(1) ?? '')
          .split(RegExp(r'\s*(?:,|&|\+|and|x|×)\s*', caseSensitive: false))) {
        final p = part.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();
        if (p.isNotEmpty) out.add(p);
      }
    }
    return out;
  }

  /// Whether two tracks are the SAME RECORDING as far as their titles admit.
  ///
  /// THIS IS WHY A REMIX USED TO PLAY THE ORIGINAL. [_normalizeTitleForMatch]
  /// strips "(feat. …)" — correct for a video titled "X (feat. Y)" whose audio is
  /// plain "X", and catastrophic when the feature marks a different recording.
  /// Verified on device: "Without Me (feat. Juice WRLD)" normalised to
  /// "without me", matched Halsey's original (Tk7WFyHUr1E, 202s — within the 5s
  /// duration tolerance), and the audio-only swap substituted it. The remix then
  /// shared the original's id, so tapping it PAUSED the original as though they
  /// were one track.
  ///
  /// Both directions matter. Asking for the remix must not play the original, and
  /// asking for the original must not play the remix.
  static bool _sameRecording(String titleA, String titleB) {
    Set<String> variants(String t) =>
        _recordingVariant.allMatches(t).map((m) => m.group(0)!.toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ')).toSet();
    if (!_setEquals(variants(titleA), variants(titleB))) return false;
    return _setEquals(_featuredIn(titleA), _featuredIn(titleB));
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  // Compiled once, NOT once per title
  //
  // `RegExp(...)` compiles its pattern every time the expression is evaluated,
  // and both normalisers below run per TRACK. [cleanDisplayTitle] is called from
  // _mapJsonToSong, so a 200-result search compiled roughly 1,200 identical
  // patterns, and a home browse (hundreds of rows) more again. The patterns are
  // literals — nothing about them varies with the input, so hoisting them
  // removes that work outright with no behavioural change at all.
  //
  // `_recordingVariant` above was already written this way; these were not.
  static final RegExp _mBracketVideo =
      RegExp(r'[\(\[](?:official\s+)?(?:music\s+|lyric\s+)?video[\)\]]');
  static final RegExp _mOfficialVideo =
      RegExp(r'\bofficial\s+(?:music\s+)?video\b');
  static final RegExp _mDecorWords =
      RegExp(r'\b(?:mv|hd|4k|visualizer|lyrics?)\b');
  static final RegExp _mBracketFeat =
      RegExp(r'[\(\[](?:feat|ft)\.?[^\)\]]*[\)\]]');
  static final RegExp _mNonAlnum = RegExp(r'[^a-z0-9]+');

  static String _normalizeTitleForMatch(String title) {
    var t = title.toLowerCase();
    t = t.replaceAll(_mBracketVideo, ' ');
    t = t.replaceAll(_mOfficialVideo, ' ');
    t = t.replaceAll(_mDecorWords, ' ');
    t = t.replaceAll(_mBracketFeat, ' ');
    t = t.replaceAll(_mNonAlnum, ' ').trim();
    return t;
  }

  /// DISPLAY-clean a track title: remove music-video / lyric-video / audio /
  /// visualizer decorations while PRESERVING the real title's case and spacing
  /// (unlike [_normalizeTitleForMatch], which collapses to alphanumerics for
  /// matching). Used at map time so lists never show "… (Official Video)".
  /// Conservative — only strips well-known decoration phrases, and returns the
  /// original title unchanged if a strip would leave it empty.
  /// The decoration patterns, compiled once. See the note above
  /// [_normalizeTitleForMatch]. This method is the hot one: `_mapJsonToSong`
  /// calls it for every row of every response.
  static final RegExp _dBracketDecor = RegExp(
      r'\s*[\(\[]\s*(?:official\s+)?(?:hd\s+|4k\s+|full\s+)?'
      r'(?:music\s+|lyrics?\s+|lyric\s+|performance\s+|audio\s+)?'
      r'(?:video|audio|visuali[sz]er|m/?v|lyric\s+video|lyrics?)\s*[\)\]]',
      caseSensitive: false);
  static final RegExp _dTrailingOfficialVideo = RegExp(
      r'\s*[-–|]?\s*\bofficial\s+(?:music\s+|lyrics?\s+|lyric\s+)?video\b\s*$',
      caseSensitive: false);
  static final RegExp _dTrailingLyricVideo = RegExp(
      r'\s*[-–|]?\s*\b(?:lyrics?\s+video|lyric\s+video|visuali[sz]er)\b\s*$',
      caseSensitive: false);
  static final RegExp _dDanglingSep = RegExp(r'[\s\-–|]+$');
  static final RegExp _dDanglingBracket = RegExp(r'[\(\[]\s*$');

  static String cleanDisplayTitle(String title) {
    var t = title;
    // Bracketed decorations: (Official Music Video), [Official Video],
    // (Lyric Video), (Official Audio), (Visualizer), (MV), (HD)/(4K) video, …
    t = t.replaceAll(_dBracketDecor, '');
    // Trailing un-bracketed decorations, optionally after a - – | separator:
    //   "… official (music) video", "… lyric video", "… visualizer".
    t = t.replaceAll(_dTrailingOfficialVideo, '');
    t = t.replaceAll(_dTrailingLyricVideo, '');
    t = t.trim();
    // Tidy a dangling separator/opening bracket left behind.
    t = t.replaceAll(_dDanglingSep, '').replaceAll(_dDanglingBracket, '').trim();
    return t.isEmpty ? title.trim() : t;
  }

  /// Audio-only conform: given a music-VIDEO [song], find its pure-AUDIO song
  /// equivalent on YouTube Music. Search is already audio-only gated (OMV/UGC
  /// dropped while [processVideos] is false), so its results are audio songs.
  /// Returns the best title+artist match, or null when nothing convincingly
  /// matches (the caller then falls back to the video's own audio, or skips it).
  /// [strict] (used when the input's type is UNKNOWN — empty musicVideoType, not
  /// a confirmed video) requires an EXACT normalized-title match so a genuine
  /// audio track is never mis-swapped to a same-named different song. For a
  /// CONFIRMED video (isMusicVideo) the looser contains-match is allowed, since
  /// the video's title often carries extra decorations.
  /// Seconds from a duration string: "m:ss", "h:mm:ss", or raw seconds.
  /// 0 when it can't be read — callers treat that as "unknown", never as zero
  /// length.
  static int _parseDurationSeconds(String raw) {
    final d = raw.trim();
    if (d.isEmpty) return 0;
    if (!d.contains(':')) return int.tryParse(d) ?? 0;
    final parts = d.split(':').map((p) => int.tryParse(p.trim()) ?? -1).toList();
    if (parts.any((p) => p < 0)) return 0;
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  Future<Song?> resolveAudioEquivalent(Song song, {bool strict = false}) async {
    final wantTitle  = _normalizeTitleForMatch(song.title);
    final wantArtist = song.artist.toLowerCase().trim();
    // Primary artist only (drop "feat."/collab tails) — the video's credit line
    // is often "A, B & C" while the audio song is filed under just "A", so a
    // cleaner query + a looser artist test find the studio version more often.
    final primaryArtist = song.artist
        .split(RegExp(r'\s*(?:,|;|&|\+|/|feat\.?|ft\.?|featuring|x|×)\s*',
            caseSensitive: false))
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => song.artist.trim());

    bool artistMatches(Song r) {
      final a = r.artist.toLowerCase().trim();
      if (wantArtist.isEmpty) return true; // nothing to compare against
      // An EMPTY artist on the candidate used to count as a match
      // (`if (a.isEmpty || ...) return true`). Absence of evidence is not
      // evidence of a match: combined with the title-only fallback query below,
      // any result that happened to carry no artist and the same title was
      // accepted, which is how a common title like "Warrior" could conform to a
      // completely different song and display ITS cover art.
      if (a.isEmpty) return false;
      final pa = primaryArtist.toLowerCase().trim();
      return a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a) ||
          (pa.isNotEmpty && (a.contains(pa) || pa.contains(a)));
    }

    // DURATION is the decisive disambiguator, and there was no check at all.
    //
    // Two different recordings that share a title are almost always different
    // lengths, while a video and its audio counterpart are within a second or two
    // of each other. Without this, title+artist alone let "Warrior" match another
    // "Warrior" and the swap replaced the displayed artwork with that song's.
    //
    // Unknown durations do NOT block the match — an absent value is not a
    // mismatch, and blocking on it would disable conform for every result whose
    // duration the parser didn't carry.
    final wantSeconds = _parseDurationSeconds(song.duration);
    bool durationMatches(Song r) {
      final rs = _parseDurationSeconds(r.duration);
      if (wantSeconds <= 0 || rs <= 0) return true;
      return (wantSeconds - rs).abs() <= 5;
    }

    Song? bestMatch(List<Song> results) {
      // 1) Exact normalized title + artist + duration match (best).
      for (final r in results) {
        if (r.isMusicVideo || r.id == song.id) continue;
        // The recording gate comes first AND applies to both steps.
        //
        // A normalized-title "exact" match is NOT proof of the same recording:
        // the normaliser strips "(feat. …)" by design, so a remix collapses onto
        // its original and duration alone cannot separate them when they are
        // within seconds. See _sameRecording for the device capture.
        if (!_sameRecording(song.title, r.title)) continue;
        if (_normalizeTitleForMatch(r.title) == wantTitle &&
            artistMatches(r) &&
            durationMatches(r)) {
          return r;
        }
      }
      // 2) Title contains / contained-by + artist match (extra tails, remaster…).
      // Skipped in strict mode — the input might genuinely be audio, so only an
      // exact title match is trustworthy enough to swap.
      if (strict) return null;
      for (final r in results) {
        if (r.isMusicVideo || r.id == song.id) continue;
        // The loosest test in the file, so the recording gate matters MOST here:
        // "without me" is contained by "without me feat juice wrld" under the
        // normaliser, which is precisely how the original got swapped in. This is
        // also the branch that actually ran for the reported case, because
        // `strict` is false for a CONFIRMED music video.
        if (!_sameRecording(song.title, r.title)) continue;
        final rt = _normalizeTitleForMatch(r.title);
        if (rt.isEmpty) continue;
        // Substring title matching is the loosest test here, so the duration
        // agreement is REQUIRED rather than optional: "warrior" is a substring of
        // plenty of unrelated titles.
        if ((rt.contains(wantTitle) || wantTitle.contains(rt)) &&
            artistMatches(r) &&
            durationMatches(r)) {
          return r;
        }
      }
      return null;
    }

    try {
      // Query with the CLEANED title (strips "[Official Music Video]" etc. that
      // skew search ranking) + primary artist. Then fall back to a title-only
      // search — sometimes the artist token buries the audio song.
      for (final q in <String>[
        '$wantTitle $primaryArtist'.trim(),
        wantTitle.trim(),
      ]) {
        if (q.isEmpty) continue;
        final results = await search(q, 'track')
            .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[]);
        final m = bestMatch(results);
        if (m != null) return m;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // Shared video→audio conform cache
  // A video is looked up AT MOST ONCE, ever. Both the list-display overlay
  // (conform_provider) and the play-time swap (player_playback) go through
  // [conformToAudioCached], so scrolling a playlist and then PLAYING one of its
  // tracks never spends a second lookup. `null` is cached too ("looked up, no
  // audio equivalent") so genuine video-only tracks aren't retried forever.
  static final Map<String, Song?> _conformCache = {};
  static final Map<String, Future<Song?>> _conformInFlight = {};

  /// Merge a conformed audio track back onto the row the user actually opened.
  ///
  /// SWAP THE AUDIO, KEEP THE EDITION. Callers used to substitute the
  /// conformed Song wholesale, which handed over its `image`, `albumTitle` and
  /// `albumId` too, and those came from a SEARCH RESULT, not from the album
  /// being played. A track played out of "After Hours (Deluxe)" could therefore
  /// pick up the standard edition's cover and album id (or a video thumbnail),
  /// flipping the artwork mid-play and sending a later "view album" to the wrong
  /// edition. Exactly the cross-edition bleed the album tracklist was fixed for,
  /// arriving by a second route.
  ///
  /// The audio identity — the id that actually plays, and its duration — comes
  /// from [audio]. Everything describing WHICH RELEASE this is stays with
  /// [original], and only fills from [audio] where the original is blank.
  ///
  /// Universal by design: it makes no reference to "deluxe" or any edition name,
  /// so it holds for remasters, anniversary editions, explicit/clean pairs and
  /// any number of versions.
  ///
  /// But a music video has no edition to keep, AND its artwork is the wrong
  /// SHAPE.
  ///
  /// The first version of this kept `original.image` unconditionally, which broke
  /// the very thing conform exists for: a music-video row's picture is a 16:9
  /// VIDEO THUMBNAIL, so swapping the video for its studio audio while keeping
  /// the video's thumbnail left the wrong artwork on screen — a letterboxed
  /// frame where a square sleeve belongs. A video row also carries no trustworthy
  /// album identity (it is a video, not a release), so preserving its album
  /// fields preserved nothing.
  ///
  /// So the rule is conditional on WHERE the row came from:
  ///  • an ALBUM/PLAYLIST row (not a video) → keep its release identity; that is
  ///    the edition the user navigated into.
  ///  • a MUSIC VIDEO row → take the audio's identity wholesale; it is strictly
  ///    better information, and getting the proper cover is half the point.
  static Song mergeConformedAudio(Song original, Song audio) {
    // A video row has nothing worth preserving — take the audio as it is.
    if (original.isMusicVideo) return audio;

    return audio.copyWith(
      title: original.title.isNotEmpty ? original.title : audio.title,
      artist: original.artist.isNotEmpty ? original.artist : audio.artist,
      image: original.image.isNotEmpty ? original.image : audio.image,
      albumId: original.albumId.isNotEmpty ? original.albumId : audio.albumId,
      albumTitle: original.albumTitle.isNotEmpty
          ? original.albumTitle
          : audio.albumTitle,
      releaseDate: original.releaseDate.isNotEmpty
          ? original.releaseDate
          : audio.releaseDate,
    );
  }

  /// Forget the memoized conform for [id], so the next lookup goes out again.
  ///
  /// Exists for the manual "Refetch track details" action. The cache above is
  /// deliberately permanent — a video is resolved AT MOST ONCE, ever, including
  /// the `null` "there is no audio equivalent" answer, which is exactly right for
  /// the automatic path and exactly wrong for a user saying "this is not the right
  /// track, go and look again". Without this a refetch would replay the same
  /// cached wrong answer forever and appear to do nothing at all.
  static void forgetConform(String id) {
    if (id.isEmpty) return;
    _conformCache.remove(id);
    _conformInFlight.remove(id);
  }

  /// Cached [resolveAudioEquivalent]. Returns the conformed audio [Song], or
  /// null when there is no convincing audio equivalent. Memoized + de-duped by
  /// videoId across the whole app.
  /// The mapping is permanent; the cache was NOT
  ///
  /// A videoId's audio equivalent does not change — the ids are immutable. Yet
  /// this cache lived only in memory, so every launch re-resolved the same
  /// videos, and each resolve is a SEARCH. On a library with a few hundred video
  /// rows that is a few hundred requests re-spent for answers the app had
  /// already worked out.
  ///
  /// This is also the answer to "convert at fetch time instead of at runtime":
  /// converting at fetch is not cheaper, it is the same lookups moved earlier and
  /// done for rows nobody plays — the reason ConformNotifier was changed from a
  /// bulk prefetch to a viewport lookahead in the first place (its own note
  /// records opening a 60-row playlist firing up to 60 requests). Persisting the
  /// ANSWER makes the second encounter free, whenever it happens, which is
  /// strictly better than either.
  ///
  /// Negative results are stored too, with a timestamp: a video with no audio
  /// twin is the expensive case (a full search that finds nothing) and by far
  /// the most wasteful to repeat. They expire, because a twin can be published
  /// later.
  static const String _kConformKey = 'auvy_conform_v1';
  /// Sized against the prefs file, NOT against ambition.
  ///
  /// Each entry is a serialised Song, so this is roughly 300 bytes apiece, and
  /// SharedPreferences is ONE file that is rewritten whole on every write — the
  /// library blob measured on device is already 840KB of it. 400 entries is
  /// ~120KB, which buys the entire practical working set (a library with more
  /// than 400 distinct video rows is unusual) without doubling what every prefs
  /// write has to move.
  static const int _conformDiskCap = 400;
  static const Duration _negativeTtl = Duration(days: 14);
  static bool _conformLoaded = false;
  static Timer? _conformSaveDebounce;

  /// Read the persisted video→audio map. Call once at startup.
  static Future<void> loadConformCache() async {
    if (_conformLoaded) return;
    _conformLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kConformKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch;
      var positive = 0, negative = 0, expired = 0;
      map.forEach((videoId, v) {
        if (v is! Map) return;
        final ts = (v['t'] as num?)?.toInt() ?? 0;
        final audio = v['a'];
        if (audio == null) {
          if (now - ts > _negativeTtl.inMilliseconds) {
            expired++;
            return; // re-check it; a twin may exist now
          }
          _conformCache[videoId] = null;
          negative++;
          return;
        }
        try {
          _conformCache[videoId] = Song.fromMap(Map<String, dynamic>.from(audio));
          positive++;
        } catch (_) {}
      });
      print('conform cache: $positive known audio version(s), '
          '$negative known-missing, $expired expired — '
          'that many lookups this session will not need to happen');
    } catch (e) {
      print('WARN: could not read the conform cache: $e');
    }
  }

  static void _saveConformCacheDebounced() {
    _conformSaveDebounce?.cancel();
    // Batched: a scroll through a video-heavy list resolves several in a burst,
    // and each write re-encodes the whole map.
    _conformSaveDebounce = Timer(const Duration(seconds: 6), _saveConformCache);
  }

  static Future<void> _saveConformCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <String, dynamic>{};
      for (final e in _conformCache.entries) {
        if (out.length >= _conformDiskCap) break;
        out[e.key] = {'t': now, 'a': e.value?.toMap()};
      }
      await prefs.setString(_kConformKey, jsonEncode(out));
    } catch (e) {
      print('WARN: could not save the conform cache: $e');
    }
  }

  Future<Song?> conformToAudioCached(Song song, {bool strict = false}) {
    final id = song.id;
    if (id.isEmpty) return Future.value(null);
    if (_conformCache.containsKey(id)) return Future.value(_conformCache[id]);
    final existing = _conformInFlight[id];
    if (existing != null) return existing;
    final fut = resolveAudioEquivalent(song, strict: strict).then((r) {
      _conformCache[id] = r;
      _conformInFlight.remove(id);
      // Learned once, kept for good. See _kConformKey.
      _saveConformCacheDebounced();
      print(r == null
          ? 'no audio version exists for "${song.title}" — remembered, so it '
              'will not be searched for again'
          : 'conformed "${song.title}" → audio ${r.id}');
      // Bound the cache so a long session can't grow it without limit.
      if (_conformCache.length > 500) {
        _conformCache.remove(_conformCache.keys.first);
      }
      return r;
    }).catchError((_) {
      _conformInFlight.remove(id);
      return null;
    });
    _conformInFlight[id] = fut;
    return fut;
  }

  /// A real album/playlist browse id (MPRE…/OLAK…/MPLA…/VL…/PL…/RDCLAK…), NOT a
  /// videoId. When a track has no album, callers wrongly pass the 11-char
  /// videoId here; browsing that returns an UNRELATED album (the "wrong album"
  /// bug). Reject anything that isn't a recognizable collection id so the
  /// AlbumPage falls back to showing the single track instead.
  bool _isAlbumBrowseId(String id) {
    if (id.isEmpty) return false;
    if (id.length == 11) return false; // a videoId, never an album id
    const prefixes = ['MPRE', 'OLAK', 'MPLA', 'VL', 'PL', 'RDCLAK', 'OLA'];
    return prefixes.any((p) => id.startsWith(p));
  }

  /// Resolve a real album browse id from the album NAME, for tracks whose
  /// stored albumId is missing/invalid (the parser only carries an album id
  /// when the subtitle had a linked album). Searches the albums scope and
  /// matches by title (+artist to disambiguate). Returns null if no match.
  Future<String?> resolveAlbumIdByName(String albumTitle, String artist) async {
    final title = albumTitle.trim();
    if (title.isEmpty) return null;
    try {
      final q = artist.trim().isNotEmpty ? '$title $artist' : title;
      final res = await executeScopedSearch(q, scope: SearchContextScope.albums);
      final needle = title.toLowerCase().trim();
      final artistNeedle = artist.trim().toLowerCase();
      String strip(String id) => id.replaceFirst('album_', '');
      // A candidate must be BY the right artist when we know one. Title-only
      // matching returned same-named albums by OTHER artists (covers, karaoke,
      // tributes) — the "View Album opens the wrong album" bug. Rows that omit
      // the artist aren't rejected (a missing field can't disprove a match),
      // and multi-artist credits pass via the containment check either way.
      bool artistOk(dynamic a) {
        if (artistNeedle.isEmpty) return true;
        final aa = a.artist.toString().trim().toLowerCase();
        if (aa.isEmpty) return true;
        return aa.contains(artistNeedle) || artistNeedle.contains(aa);
      }
      // Edition qualifiers that distinguish RELEASES of the same record.
      // The old two-pass match had a version trap: searching "After Hours
      // (Deluxe Edition)" would exact-miss (suffix wording varies), then the
      // loose `needle.contains(t)` pass matched plain "After Hours" first —
      // silently landing on the WRONG edition. Candidates are now scored so
      // the one whose edition tokens match the request wins.
      const editionTokens = [
        'deluxe', 'expanded', 'extended', 'remaster', 'anniversary',
        'edition', 'bonus', 'live', 'acoustic', 'instrumental', 'karaoke',
        'commentary', 'super', 'complete', 'tour', 'version',
      ];
      Set<String> editionsOf(String t) =>
          editionTokens.where((e) => t.contains(e)).toSet();
      final wantedEditions = editionsOf(needle);
      int score(String candidate) {
        final t = candidate.toLowerCase().trim();
        if (!(t == needle || t.contains(needle) || needle.contains(t))) {
          return -1; // not this record at all
        }
        final has = editionsOf(t);
        var s = 0;
        if (t == needle) s += 100; // literal exact
        // Same edition set = the same release, however the suffix is worded.
        if (has.length == wantedEditions.length && has.containsAll(wantedEditions)) {
          s += 60;
        } else {
          // Wrong edition: penalize BOTH directions (deluxe requested but
          // standard found, and vice versa), softer than a full reject so a
          // catalogue that only carries one edition still resolves.
          s -= 40;
        }
        // Closer title lengths = fewer unrelated extra words.
        s -= (t.length - needle.length).abs();
        return s;
      }
      String? bestId;
      var bestScore = -1;
      for (final a in res.items) {
        if (!artistOk(a)) continue;
        final s = score(a.title.toString());
        if (s > bestScore) {
          bestScore = s;
          bestId = strip(a.id);
        }
      }
      if (bestId != null && bestScore >= 0) return bestId;
      // No plausible match. Returning the first result regardless (the old
      // behaviour) gambled on an arbitrary album AND cached the wrong pick;
      // null lets getAlbumTracksSmart fall through to the track-based resolver,
      // which reads the album id off the actual track — far more accurate.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Finds the album a TRACK belongs to by looking the track up in song search
  /// and reading the matched result's albumId. Recovers the real album for
  /// tracks whose album metadata was lost (e.g. the player-page title tap, where
  /// the playing Song often has no albumId/albumTitle) — instead of showing the
  /// track alone as a fake "single" named after the track.
  Future<String?> resolveAlbumIdForTrack(String trackTitle, String artist) async {
    final t = trackTitle.trim();
    if (t.isEmpty) return null;
    try {
      final q = artist.trim().isNotEmpty ? '$t $artist' : t;
      final res = await executeScopedSearch(q, scope: SearchContextScope.tracks);
      String strip(String id) => id.replaceFirst('album_', '');
      // Strip decorations ("Song (Official Video)", "Song [Remastered]") so the
      // playing track, which often carries a decorated title — still matches its
      // catalogue entry. Without this, "view album" fell through to showing the
      // single track even when the full album exists (the reported bug).
      String clean(String s) => s
          .toLowerCase()
          .replaceAll(
              RegExp(r'\((?:official|lyric|lyrics|audio|video|visualizer|remaster|explicit).*?\)'),
              '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .split('(')
          .first
          .trim();
      final needle = clean(t);
      final aNeedle = artist.trim().toLowerCase();
      bool artistOk(dynamic s) {
        if (aNeedle.isEmpty) return true;
        final sa = s.artist.toString().toLowerCase();
        return sa.isEmpty || sa.contains(aNeedle) || aNeedle.contains(sa);
      }

      // 1) Title AND artist match carrying a real album id — the most accurate.
      for (final s in res.items) {
        if (_isAlbumBrowseId(s.albumId) &&
            artistOk(s) &&
            clean(s.title).contains(needle)) {
          return strip(s.albumId);
        }
      }
      // 2) Title match carrying a real album id (artist field missing/loose).
      for (final s in res.items) {
        if (_isAlbumBrowseId(s.albumId) && clean(s.title).contains(needle)) {
          return strip(s.albumId);
        }
      }
      // NO arbitrary "first result with any album id" fallback: it opened a
      // DIFFERENT (often same-artist) album for the tapped track — e.g. "Real
      // Nigga" landing on "Heroes & Villains". A wrong album is worse than
      // showing the single track, so give up rather than guess.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Finds the SPECIFIC artist channel behind a track — disambiguating same-named
  /// artists (e.g. two different "Xenia"s). A track credited only by a plain-text
  /// artist name (album rows, some search rows) carries NO channel id, so tapping
  /// the artist used to fall back to an artist NAME search and open whichever
  /// same-named artist ranked first. This looks the TRACK up, matches the row
  /// that IS this track, and returns the channel id of the artist actually
  /// credited on it. Returns null when nothing links a channel — the caller then
  /// name-searches as a last resort.
  /// Significant words of an artist name, for comparing two spellings of the
  /// same artist. Case, punctuation and `&`/`and` are folded, and the suffixes
  /// YouTube adds to channel names are dropped so "The Weeknd - Topic" and
  /// "TheWeekndVEVO" still reduce to the artist. Used by the name matching in
  /// [resolveArtistIdForTrack]. See the comment there for why matching must be
  /// exact rather than substring-based.
  static final RegExp _artistNoiseWord =
      RegExp(r'^(vevo|official|topic|channel|records|recordings)$');

  /// Does [candidate] name the same artist as [want]?
  ///
  /// PROMOTED FROM A LOCAL CLOSURE so every caller uses ONE rule. It lived
  /// inside resolveArtistIdForTrack, so the careful matching applied there and
  /// nowhere else: the artist-page navigations in album_page, home_page,
  /// player_page, stats_page and artist_provider all did `search(name).first`
  /// and trusted the ranking. That is how tapping one artist opens another —
  /// the exact failure this rule was written to stop.
  ///
  /// Covered by test/artist_match_verify.dart, which CALLS this method — it
  /// used to hold a copy of the rule and therefore could not fail when the
  /// real one drifted. Keep it calling the implementation.
  static bool artistNameMatches(String want, String candidate) {
    if (want.trim().isEmpty) return true;
    final w = _artistNameWords(want);
    final g = _artistNameWords(candidate);
    if (w.isEmpty || g.isEmpty) return false;
    if (w.length == g.length && w.containsAll(g)) return true;
    // Fused vs spaced. See the long note in resolveArtistIdForTrack.
    final wk = (w.toList()..sort()).join();
    final gk = (g.toList()..sort()).join();
    return wk == gk;
  }

  /// The search result that really IS [want], or null.
  ///
  /// Returning null is deliberate: a caller that cannot identify the artist
  /// should say so rather than open a page for someone else.
  static T? pickArtistMatch<T>(
      Iterable<T> results, String want, String Function(T) nameOf) {
    for (final r in results) {
      if (artistNameMatches(want, nameOf(r))) return r;
    }
    return null;
  }

  // Compiled once. See the note above [_normalizeTitleForMatch]. These matter
  // more than they look: [pickArtistMatch] loops over the search results and
  // [artistNameMatches] normalises BOTH sides per candidate, so twenty results
  // meant forty passes through here. The unicode class is also the most
  // expensive pattern in the file to compile.
  static final RegExp _aFusedVevo = RegExp(r'vevo\b');
  static final RegExp _aNonWordUnicode =
      RegExp(r'[^\p{L}\p{N}\s]+', unicode: true);
  static final RegExp _aWhitespace = RegExp(r'\s+');

  static Set<String> _artistNameWords(String s) => s
      .toLowerCase()
      .replaceAll('&', ' and ')
      // "+" is a real conjunction in artist names (Florence + The Machine) and
      // must fold the same way "&" does, or the two spellings never match.
      .replaceAll('+', ' and ')
      // Strip a trailing "VEVO" fused onto the name (ArtistVEVO) before the
      // word split can no longer see it.
      .replaceAll(_aFusedVevo, ' ')
      // Unicode-aware: keep letters/digits of ANY script. An ASCII-only class
      // ([^a-z0-9\s]) erased Hangul, Cyrillic and kana names entirely, leaving an
      // empty word set that could never match, so those artists would never
      // resolve at all.
      .replaceAll(_aNonWordUnicode, ' ')
      .split(_aWhitespace)
      .where((w) => w.isNotEmpty && !_artistNoiseWord.hasMatch(w))
      .toSet();

  Future<String?> resolveArtistIdForTrack(String trackTitle, String artistName) async {
    final t = trackTitle.trim();
    final a = artistName.trim();
    if (t.isEmpty && a.isEmpty) return null;
    final aNeedle = a.toLowerCase();
    // WHY THIS IS SET EQUALITY AND NOT `contains`.
    //
    // This used to be `c == aNeedle || c.contains(aNeedle) || aNeedle.contains(c)`,
    // which matched in both directions and so accepted a DIFFERENT artist:
    // `c.contains` let "Drake" resolve to "Drake Bell", and `aNeedle.contains`
    // let "The Weeknd" resolve to a channel merely named "Weeknd" — a tribute or
    // karaoke upload. That is the onboarding picker showing the wrong face for a
    // name, because the resolved channel's header art was genuinely someone else's.
    //
    // Comparing WORD SETS (punctuation folded, channel-suffix noise dropped) keeps
    // the forms that are really the same artist — "Tyler, The Creator" vs "Tyler
    // The Creator", "The Weeknd - Topic", "ArtistVEVO" — while rejecting a
    // candidate that adds or drops a real name word.
    //
    // Being strict is the safe direction: an unresolved name returns null, and
    // every caller then keeps the image it already had, rather than confidently
    // painting a stranger.
    // Delegates to the shared rule above — one implementation, one test.
    bool nameMatches(String candidate) =>
        aNeedle.isEmpty ? true : artistNameMatches(a, candidate);

    try {
      // 1) Track search — the row that IS this track links the real artist. Read
      //    the credited artist channel whose NAME matches the one we tapped.
      if (t.isNotEmpty) {
        final q = a.isNotEmpty ? '$t $a' : t;
        final res = await executeScopedSearch(q, scope: SearchContextScope.tracks);
        final needle = t.toLowerCase().split('(').first.trim();
        // Prefer a title-matching row first, then any row, always requiring a
        // linked (UC…) channel whose name matches the tapped artist.
        for (final titleMustMatch in [true, false]) {
          for (final s in res.items) {
            if (titleMustMatch && !s.title.toLowerCase().contains(needle)) continue;
            for (final ar in s.artists) {
              if (ar.id.startsWith('UC') && nameMatches(ar.name)) return ar.id;
            }
          }
        }
      }
      // 2) Artist-scoped search matched by name (results' ids ARE channel ids).
      if (a.isNotEmpty) {
        final res = await search(a, 'artist');
        for (final r in res) {
          if (r.id.startsWith('UC') && nameMatches(r.title)) return r.id;
        }
        // NO blind "take the first result" fallback here.
        //
        // It used to `return res.first.id` when nothing matched by name, which is
        // how a search for one artist resolved to whatever channel YouTube happened
        // to rank first — the other half of the wrong-artist-picture bug. Returning
        // null lets the caller keep the name and image it already has.
        if (res.isNotEmpty) {
          print('resolveArtistId: no name match for "$a" among '
              '${res.take(3).map((r) => r.title).toList()} — not guessing');
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Loads a track's album robustly: a valid browse id is used directly; an
  /// invalid/empty id with a real album NAME is resolved by name; otherwise the
  /// album is recovered from the TRACK via song search. Only a genuine single
  /// with no recoverable album returns empty (page then shows just the track).
  Future<List<Song>> getAlbumTracksSmart(
    String id, String albumTitle, String artist,
    {bool isSingle = false, String expectTrackTitle = ''}) async {
    print('getAlbumTracksSmart id="$id" title="$albumTitle" artist="$artist" '
        'single=$isSingle expect="$expectTrackTitle" → validBrowseId=${_isAlbumBrowseId(id)}');

    // Does a tracklist actually contain the track the album was opened FROM?
    bool hasExpected(List<Song> tracks) {
      final needle = expectTrackTitle.toLowerCase().split('(').first.trim();
      if (needle.isEmpty) return true; // nothing to verify against
      return tracks.any((s) => s.title.toLowerCase().contains(needle));
    }

    List<Song> result = const [];
    if (_isAlbumBrowseId(id)) {
      result = await getAlbumTracks(id);
    } else if (!isSingle && albumTitle.trim().isNotEmpty) {
      // A real album NAME → resolve its browse id by name.
      final resolved = await resolveAlbumIdByName(albumTitle, artist);
      if (resolved != null && _isAlbumBrowseId(resolved)) {
        result = await getAlbumTracks(resolved);
      }
    }
    // Nothing yet → recover the album from the TRACK via search (player title tap
    // passes the track's own title as `albumTitle`).
    if (result.isEmpty && albumTitle.trim().isNotEmpty) {
      final viaTrack = await resolveAlbumIdForTrack(albumTitle, artist);
      if (viaTrack != null && _isAlbumBrowseId(viaTrack)) result = await getAlbumTracks(viaTrack);
    }
    // STILL nothing, but we were opened FROM a known track whose real title
    // differs from `albumTitle`. That happens when `albumTitle` is not an album
    // at all but a PLAYLIST / context name (e.g. "Favorite Songs") that leaked
    // onto the queued song — resolving by that name found no album, and the
    // step above searched for a *track* by that wrong name. Recover the real
    // album from the genuine track title. resolveAlbumIdForTrack only returns a
    // real browse id on a title match, so a true single safely stays empty →
    // the AlbumPage shows the track itself (never a bogus "Favorite Songs"
    // single). Fixes "View Album from the queue opens a 1-track album named
    // after the playlist / the track".
    if (result.isEmpty &&
        expectTrackTitle.trim().isNotEmpty &&
        expectTrackTitle.trim().toLowerCase() != albumTitle.trim().toLowerCase()) {
      final viaTrack = await resolveAlbumIdForTrack(expectTrackTitle, artist);
      if (viaTrack != null && _isAlbumBrowseId(viaTrack)) {
        result = await getAlbumTracks(viaTrack);
      }
    }

    // GUARD (#11): we opened an album — usually straight off the track's own
    // albumId — that does NOT contain the tapped track. That means the track's
    // metadata pointed at the wrong record (a collab album the same artists both
    // appear on, e.g. "Real Nigga"). Re-resolve from the TRACK itself and prefer
    // the album that actually contains it.
    if (result.isNotEmpty && !hasExpected(result)) {
      final stripped = id.replaceFirst('album_', '');
      final viaTrack = await resolveAlbumIdForTrack(expectTrackTitle, artist);
      if (viaTrack != null && _isAlbumBrowseId(viaTrack) && viaTrack != stripped) {
        final corrected = await getAlbumTracks(viaTrack);
        if (hasExpected(corrected)) {
          print('album "$albumTitle" missing "$expectTrackTitle" — corrected to id=$viaTrack');
          return corrected;
        }
      }
      print('album "$albumTitle" missing "$expectTrackTitle" — no better match found, keeping it');
    }
    return result;
  }

  Future<List<Song>> getAlbumTracks(String albumId) async =>
      // Albums usually fit one browse page, but OLAK audio-playlists, deluxe
      // editions and compilations can exceed the ~100-row page — follow the
      // continuation chain (no-op when there is none) so nothing is cut off.
      _browseCollectionTracks(albumId, isPlaylist: false, maxPages: 3);

  // YOUTUBE MUSIC RADIO — native "song radio" continuation
  // The watch-next / RDAMVM feed is YouTube Music's OWN recommendation for a
  // given track (collaborative filtering over YouTube's data, personalized when
  // signed in). It is a much smarter autoplay seed than genre / similar-artist
  // search. Cached briefly per
  // seed so repeated top-ups on the same track don't re-hit the network; bounded.
  static final Map<String, List<Song>> _radioCache = {};
  static final Map<String, DateTime> _radioCacheAt = {};

  /// The YouTube-Music radio queue seeded by [videoId] (the seed track itself
  /// excluded). Returns [] on any failure so callers fall back to the old
  /// Last.fm/search engine. Only for real 11-char videoIds (not http/local).
  Future<List<Song>> getSongRadio(String videoId) async {
    final v = videoId.trim();
    if (v.isEmpty || v.startsWith('http') || v.length != 11) return const [];
    final at = _radioCacheAt[v];
    if (at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _radioCache[v] ?? const [];
    }
    try {
      final response = await _innerTubeClient
          .getNext(v, playlistId: 'RDAMVM$v')
          .timeout(const Duration(seconds: 10));
      final List<dynamic> itemsList = response['items'] ?? [];
      final songs = itemsList
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((m) => m['type'] == 'track')
          .map(_mapJsonToSong)
          .where((s) => s.id.isNotEmpty && s.id != v) // drop the seed itself
          .toList();
      if (songs.isNotEmpty) {
        if (_radioCache.length > 40) {
          final oldest = _radioCache.keys.first;
          _radioCache.remove(oldest);
          _radioCacheAt.remove(oldest);
        }
        _radioCache[v] = songs;
        _radioCacheAt[v] = DateTime.now();
      }
      return songs;
    } catch (e) {
      print('getSongRadio failed for $v: $e');
      return const [];
    }
  }

  /// OTHER EDITIONS of an album — the deluxe next to the standard, and back.
  ///
  /// This costs no network, AND the data was already being thrown away.
  ///
  /// An album browse response carries more than its tracklist: YouTube Music
  /// includes an "Other versions" shelf naming exactly this album's other
  /// editions. [_browseCollectionTracks] parses the whole response and then keeps
  /// only `type == 'track'`, so those entries were fetched and discarded on every
  /// album open.
  ///
  /// That matters because the artist page is NOT a reliable route to a deluxe: it
  /// routinely lists one edition only, and an album search does not dependably
  /// surface the other. This shelf is the source's own explicit link between
  /// editions, so it finds them when neither of those does.
  ///
  /// `maxPages: 3` matches [_browseCollectionTracks] exactly so this reads the
  /// SAME cached browse entry rather than issuing a second request.
  Future<List<Album>> getAlbumOtherVersions(String albumId) async {
    final id = albumId.replaceFirst('album_', '');
    if (id.isEmpty || id.startsWith('http')) return [];
    try {
      final response = await _innerTubeClient.getBrowse(id, maxPages: 3);
      final selfTitle = (response['headerTitle'] ?? '').toString();
      // Without a title to anchor on, every filter below is guesswork.
      // Show nothing rather than a list of unrelated albums.
      if (selfTitle.trim().isEmpty) return [];

      final selfBase = albumBaseTitle(selfTitle);
      if (selfBase.isEmpty) return [];
      final selfFull = normalizeAlbumTitle(selfTitle);

      final items = (response['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => m['type'] == 'album')
          .where((m) => (m['id'] ?? '').toString().isNotEmpty);

      final out = <Album>[];
      final seenIds = <String>{id};
      final seenTitles = <String>{selfFull};

      for (final m in items) {
        final candidateId = (m['id'] ?? '').toString().replaceFirst('album_', '');
        final candidateTitle = (m['title'] ?? '').toString();
        if (candidateTitle.trim().isEmpty) continue;

        // ONLY EDITIONS OF *THIS* ALBUM.
        //
        // An album browse response is not just "other versions" — it also carries
        // "More from this artist" and recommendation shelves, and the parser
        // flattens EVERY shelf into one untitled item list, so shelf identity is
        // not available to filter on. Taking all album-typed items therefore
        // dragged in unrelated records.
        //
        // The base title is the reliable anchor instead: an edition of "After
        // Hours" is still called "After Hours" once the edition decoration is
        // stripped, while "Dawn FM" never is.
        if (albumBaseTitle(candidateTitle) != selfBase) continue;

        // One row per distinct edition name.
        //
        // The same release appears under several browse ids (regional variants,
        // and repeats across shelves), so an id-only dedupe let the album list
        // ITSELF half a dozen times. Keying on the normalised full title collapses
        // those to one, while still keeping genuinely different editions apart:
        // "After Hours" and "After Hours (Deluxe)" normalise differently.
        // seenTitles is pre-seeded with this album's own title, which is what
        // stops the page offering itself.
        if (!seenIds.add(candidateId)) continue;
        if (!seenTitles.add(normalizeAlbumTitle(candidateTitle))) continue;

        out.add(_itemToAlbum(m));
      }
      return out;
    } catch (_) {
      // A missing shelf is the normal case for most albums — not an error.
      return [];
    }
  }

  /// Public so test/album_versions_verify.dart can exercise the real filter
  /// rather than a copy of it.
  ///
  /// An album title with edition decoration REMOVED, for deciding whether two
  /// titles name the same underlying release.
  ///
  /// "After Hours (Deluxe)", "After Hours — Deluxe Edition" and "After Hours
  /// (Remastered 2019)" all reduce to "afterhours".
  static String albumBaseTitle(String raw) {
    var t = raw.toLowerCase();
    // Bracketed suffixes carry the edition almost every time.
    t = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
    // …and when they don't, the edition follows a dash or a colon.
    t = t.replaceAll(
        RegExp(
            r'[\-–—:]\s*(deluxe|expanded|remaster(ed)?|anniversary|special|'
            r'collector.?s?|extended|complete|super\s*deluxe|explicit|clean|'
            r'bonus|edition|version|mix)\b.*$'),
        ' ');
    // Trailing bare words, e.g. "Album Deluxe".
    t = t.replaceAll(
        RegExp(r'\b(deluxe|expanded|remaster(ed)?|anniversary|edition|'
            r'version|explicit|clean)\b'),
        ' ');
    return t.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  /// A title normalised for equality only — edition decoration KEPT, so two
  /// different editions never collapse into one another.
  static String normalizeAlbumTitle(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Future<List<Song>> _browseCollectionTracks(String albumId,
      {required bool isPlaylist, required int maxPages, bool authenticated = false}) async {
    if (!_isAlbumBrowseId(albumId)) return [];
    try {
      // Playlists routinely exceed one browse page (~100 rows); follow the
      // continuation chain so long lists aren't silently truncated. Albums
      // always fit in one page.
      final response = await _innerTubeClient.getBrowse(albumId,
          maxPages: maxPages, authenticated: authenticated);
      final List<dynamic> itemsList = response['items'] ?? [];
      // Album track rows usually have NO per-track thumbnail (they share the
      // album cover in the header), which left the track list with blank
      // artwork. Backfill every track's image with the album header cover.
      final rawHeader = (response['headerThumbnail'] ?? '').toString();
      final albumCover = getHighResImage(rawHeader);
      // _mapJsonToSong runs every thumbnail through getHighResImage, which returns
      // the ambient-background PLACEHOLDER (not '') when a row has no art. So a
      // plain `image.isEmpty` test never fires for art-less album rows — treat the
      // placeholder as "missing" too, otherwise tracks render the grey ambient img.
      final bool headerUsable = rawHeader.isNotEmpty && !_isPlaceholderImage(albumCover);
      // The REAL album/playlist name from the browse header. Album track rows
      // carry only the track title, so stamp this onto each track's albumTitle —
      // otherwise the album page shows the track-name fallback it was navigated
      // with instead of the actual album name.
      final albumName = (response['headerTitle'] ?? '').toString().trim();
      // Album track rows frequently omit the artist (it's implied by the header).
      // Stamp the header artist onto any track that came back without one so the
      // tile/player don't show a blank or "Unknown Artist" subtitle.
      final albumArtist = (response['headerArtist'] ?? '').toString().trim();
      // The album's release year from the browse header — stamp it onto each
      // track so the album page can show the real year even when it was opened
      // without one (e.g. the player title tap), instead of "Unknown".
      final albumYear = (response['headerYear'] ?? '').toString().trim();
      var trackMaps = itemsList
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((m) => m['type'] == 'track') // tracklist only, not "related"
          .toList();
      // Audio-only mode must NOT prune collection CONTENT: an album's or
      // playlist's rows are its literal entries. Most album rows are ATV, but
      // some albums carry OMV/UGC-typed rows (video-linked tracks) — pruning
      // those showed a partial album ("album only shows some songs", the same
      // bug that once collapsed playlists to 3-4 rows). Every row still PLAYS
      // as audio: the stream resolver only ever picks audio formats. The
      // audio-only setting keeps applying where it belongs — search results,
      // home shelves, artist pages — never inside an opened collection.
      return trackMaps
          .map(_mapJsonToSong)
          .where((s) => s.id.isNotEmpty)
          // Cover art follows where you navigated
          //
          // AN ALBUM STAMPS ITS COVER ON EVERY ROW. A PLAYLIST NEVER DOES.
          //
          // This used to apply the album cover only to rows whose own thumbnail
          // was missing or a placeholder, letting a row's own art win otherwise.
          // A track that exists on more than one edition carries whichever cover
          // the row happened to reference, so inside "After Hours" some tracks
          // showed the DELUXE sleeve, and inside "After Hours (Deluxe)" some
          // showed the standard one. Both covers are legitimately "official" for
          // that recording, which is exactly why the track cannot be trusted to
          // pick: only the page the user opened knows which edition they meant.
          //
          // A PLAYLIST is the opposite case and must keep per-row art: it is a
          // collection of different releases, so each track's own cover IS the
          // correct one and stamping the playlist's picture over them would erase
          // real information.
          .map((s) {
            if (!headerUsable) return s;
            if (isPlaylist) {
              // Only fill in a genuine blank.
              return (s.image.isEmpty || _isPlaceholderImage(s.image))
                  ? s.copyWith(image: albumCover)
                  : s;
            }
            return s.copyWith(image: albumCover);
          })
          .map((s) => albumName.isNotEmpty ? s.copyWith(albumTitle: albumName) : s)
          // Stamp the browsed ALBUM's own id onto rows that don't link one
          // (album rows rarely do — the album is the page itself). This is what
          // makes a later "view album" from the track land on EXACTLY this
          // edition (deluxe vs standard) instead of re-resolving by name.
          .map((s) => !isPlaylist && s.albumId.isEmpty ? s.copyWith(albumId: albumId) : s)
          .map((s) => _isMissingArtist(s.artist) && albumArtist.isNotEmpty
              ? s.copyWith(artist: albumArtist)
              : s)
          .map((s) => albumYear.isNotEmpty && s.releaseDate.isEmpty
              ? s.copyWith(releaseDate: albumYear)
              : s)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Full playlist contents. [maxPages] bounds continuation-following
  /// (~100 rows/page); callers that only need a preview pass 1.
  /// [authenticated] browses with the signed-in user's cookies — REQUIRED for
  /// the user's own private playlists / Liked Music (library import).
  Future<List<Song>> getPlaylistTracks(String playlistId,
      {int maxPages = 6, bool authenticated = false}) async {
    // Playlist track lists are browsed with a "VL" prefix on the playlist id.
    final id = playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
    return _browseCollectionTracks(id,
        isPlaylist: true, maxPages: maxPages, authenticated: authenticated);
  }

  /// Real YouTube Music home feed (FEmusic_home), expanded into track sections
  /// so it fits the track-based home UI. Curated playlist carousels are expanded
  /// into their tracks; personalized track shelves (when logged in) are used
  /// directly. Fully guarded — returns [] on any failure so home can fall back.
  Future<List<HomeSection>> getCuratedHomeMixes({int maxSections = 3}) async {
    try {
      final sections = await _innerTubeClient.getHomeSections();

      // Expand each section's playlist in parallel (preserves order).
      final futures = sections.take(maxSections).map((sec) async {
        // Audio-only mode: drop music-video cards from home shelves.
        final items = applyAudioOnly((sec['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList());

        // Prefer real track shelves; otherwise expand the first playlist/album.
        var tracks = items
            .where((i) => i['type'] == 'track')
            .map(_mapJsonToSong)
            .where((s) => s.id.isNotEmpty)
            .toList();

        // The playlist behind this shelf, when there is one. Carried on the
        // section so the section PAGE can fetch the complete track list on
        // open — the home rail itself only ever pays for one browse page.
        String sourceId = '';
        if (tracks.isEmpty) {
          final container = items.firstWhere(
            (i) => i['type'] == 'playlist' || i['type'] == 'album',
            orElse: () => <String, dynamic>{},
          );
          if (container.isNotEmpty) {
            sourceId = container['id'].toString();
            tracks = await getPlaylistTracks(sourceId, maxPages: 1);
          }
        }

        if (tracks.isEmpty) return null;
        // A shelf backed by a FIXED playlist (e.g. "All Hits") used to return the
        // same first 25 tracks on every rebuild — static, unlike the personalized
        // mixes. Shuffle so each home (re)load surfaces a DIFFERENT slice of the
        // shelf, making it feel dynamic like the rest. The section PAGE still
        // fetches the full, correctly-ordered playlist via sourceId, so nothing
        // downstream depends on this rail's order.
        final varied = List<Song>.of(tracks)..shuffle();
        return HomeSection(
          title: sec['title'].toString(),
          songs: varied.take(25).toList(),
          type: 'mix',
          sourceId: sourceId,
        );
      });

      final result = await Future.wait(futures);
      return result.whereType<HomeSection>().toList();
    } catch (_) {
      return [];
    }
  }

  /// YouTube Music's own DISCOVERY feeds as home-style sections.
  ///
  /// Auvy has always built discovery from Last.fm charts + genre searches, which
  /// is a decent proxy but not what YouTube Music actually promotes. These are
  /// the real thing: `FEmusic_charts` (Top Songs / Trending, region-localized)
  /// and `FEmusic_new_releases_albums` (this week's releases). Signed in, they're
  /// personalized for free — the catalog calls already carry the session.
  ///
  /// Same expand-and-guard shape as [getCuratedHomeMixes]: a playlist/album-backed
  /// shelf carries its `sourceId` so the section PAGE can fetch the full list on
  /// open while the rail itself pays for one browse page. Returns [] on any
  /// failure so the caller's feed simply doesn't gain the section.
  Future<List<HomeSection>> getDiscoveryFeed({
    bool charts = true,
    bool newReleases = true,
    int maxSectionsEach = 2,
  }) async {
    final out = <HomeSection>[];
    Future<void> add(Future<List<Map<String, dynamic>>> feed, String type) async {
      try {
        final sections = await feed;
        for (final sec in sections.take(maxSectionsEach)) {
          final section = await _sectionFromShelf(sec, type);
          if (section != null) out.add(section);
        }
      } catch (_) {
        // A dead/renamed browse id must never take the whole feed down.
      }
    }

    await Future.wait([
      if (charts) add(_innerTubeClient.getCharts(), 'chart'),
      if (newReleases) add(_innerTubeClient.getNewReleases(), 'release'),
    ]);
    return out;
  }

  /// YouTube Music's mood/genre categories — `{title, browseId, params, color}`.
  /// [] on failure so the caller just doesn't show the grid.
  Future<List<Map<String, dynamic>>> getMoodCategories() async {
    try {
      return await _innerTubeClient.getMoodCategories();
    } catch (_) {
      return const [];
    }
  }

  /// The playlist shelves inside one mood/genre category, as home-style sections.
  Future<List<HomeSection>> getMoodCategorySections(
      String browseId, String params) async {
    try {
      final sections = await _innerTubeClient.getCategorySections(browseId, params);
      final out = <HomeSection>[];
      for (final sec in sections) {
        final s = await _sectionFromShelf(sec, 'mood');
        if (s != null) out.add(s);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// A mood/genre category as SHELVES THAT KEEP THEIR CONTENTS — the replacement
  /// for [getMoodCategorySections] on the mood pages.
  ///
  /// The old path ran every shelf through `_sectionFromShelf`, whose songs-only
  /// return type meant a shelf of playlists had to be collapsed: it took the
  /// FIRST playlist and substituted that playlist's tracks for the entire row.
  /// Nine out of ten playlists vanished and the row's heading no longer
  /// described what was under it. Here each playlist/album stays a tile of its
  /// own, so a row titled "Chill hits" lists the actual chill-hits playlists.
  ///
  /// Note there is NO per-item network call: the old collapse had to fetch the
  /// chosen playlist's tracks (`getPlaylistTracks`) just to fill the row, one
  /// request per shelf. Tiles need only what the browse response already
  /// carries, so this is also strictly cheaper — the tracks are fetched when the
  /// user actually opens a playlist.
  Future<List<MoodShelf>> getMoodCategoryShelves(
      String browseId, String params) async {
    try {
      final sections =
          await _innerTubeClient.getCategorySections(browseId, params);
      final out = <MoodShelf>[];
      for (final sec in sections) {
        final raw = (sec['items'] as List? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        // applyAudioOnly strips music VIDEOS when the user is in audio-only
        // mode; it only ever concerns 'track' items, so collections pass through.
        final items = <MoodItem>[];
        for (final i in applyAudioOnly(raw)) {
          final type = (i['type'] ?? '').toString();
          final id = (i['id'] ?? '').toString();
          if (id.isEmpty) continue;
          if (type == 'track') {
            final s = _mapJsonToSong(i);
            if (s.id.isNotEmpty) items.add(MoodItem.fromSong(s));
          } else if (type == 'playlist' || type == 'album') {
            items.add(MoodItem(
              id: id,
              type: type,
              title: (i['title'] ?? '').toString(),
              // Playlists frequently have no artist run; the type reads better
              // than an empty line, and it also tells the user what the tile is.
              subtitle: (i['artist'] ?? '').toString().trim().isNotEmpty
                  ? i['artist'].toString()
                  : (type == 'album' ? 'Album' : 'Playlist'),
              image: getHighResImage((i['thumbnail'] ?? '').toString()),
            ));
          }
          // 'artist' items are deliberately skipped — a mood category is about
          // what to listen to, and an artist tile here would lead away from it.
        }
        if (items.isEmpty) continue;
        out.add(MoodShelf(title: (sec['title'] ?? '').toString(), items: items));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// One parsed browse shelf → a [HomeSection], or null when it holds no
  /// playable tracks. Shared by the discovery feeds.
  Future<HomeSection?> _sectionFromShelf(
      Map<String, dynamic> sec, String type) async {
    final items = applyAudioOnly((sec['items'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList());

    var tracks = items
        .where((i) => i['type'] == 'track')
        .map(_mapJsonToSong)
        .where((s) => s.id.isNotEmpty)
        .toList();

    String sourceId = '';
    if (tracks.isEmpty) {
      final container = items.firstWhere(
        (i) => i['type'] == 'playlist' || i['type'] == 'album',
        orElse: () => <String, dynamic>{},
      );
      if (container.isNotEmpty) {
        sourceId = container['id'].toString();
        tracks = await getPlaylistTracks(sourceId, maxPages: 1);
      }
    }
    if (tracks.isEmpty) return null;

    // Charts and release dates are MEANINGFULLY ORDERED (#1 is #1, newest is
    // newest), so unlike the home mixes these are never shuffled.
    return HomeSection(
      title: sec['title'].toString(),
      songs: tracks.take(25).toList(),
      type: type,
      sourceId: sourceId,
    );
  }

  // getHighResImage substitutes this ambient-background image for empty/invalid
  // URLs, so callers can't rely on `isEmpty` to detect "no real artwork".
  bool _isPlaceholderImage(String url) =>
      url.isEmpty || url.contains('avatar_ambient_background');

  // A track's artist is "missing" when it's blank or the generic placeholder, in
  // which case album/playlist callers backfill it with the header artist.
  bool _isMissingArtist(String artist) {
    final a = artist.trim().toLowerCase();
    return a.isEmpty || a == 'unknown artist' || a == 'unknown';
  }

  String getHighResImage(String url) {
    if (url.isEmpty || !url.startsWith('http')) {
      return 'https://music.youtube.com/img/avatar_ambient_background.png';
    }

    // Profile / placeholder URLs always return 400
    if (url.contains('/profile/picture/') ||
        (url.contains('googleusercontent.com/a/') && url.contains('='))) {
      return 'https://music.youtube.com/img/avatar_ambient_background.png';
    }

    if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
      // Find the FIRST occurrence of a CDN size parameter (=wN, =sN, =hN).
      // Using firstMatch + substring is immune to chained params like
      // =w120-h120-l90-rj=s800 which broke the old regex approach.
      final match = RegExp(r'=[wsh]\d').firstMatch(url);
      if (match != null) {
        return '${url.substring(0, match.start)}=s800';
      }
      // No size param found — URL-safe base64 IDs never contain '='
      // so we can safely append directly.
      return '${url.trimRight()}=s800';
    }

    // ytimg.com — prefer maxresdefault thumbnail
    if (url.contains('ytimg.com')) {
      return url.replaceAll(
        RegExp(r'/(?:default|hqdefault|mqdefault|sddefault)\.jpg'),
        '/maxresdefault.jpg',
      );
    }

    return url;
  }

  List<Song> filterCleanVersions(List<Song> songs) {
    return songs.where((song) {
      final titleLower = song.title.toLowerCase();
      return !titleLower.contains('clean') && !titleLower.contains('radio edit') && !titleLower.contains('censored');
    }).toList();
  }

  Future<Map<String, dynamic>> getArtist(String artistId) async {
    if (artistId.isEmpty || !artistId.startsWith('UC')) {
      return {'id': artistId, 'name': artistId, 'type': 'artist', 'thumbnail': ''};
    }
    try {
      final response = await _innerTubeClient.getBrowse(artistId);
      final items = (response['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      // Derive the artist name from the most common artist across their tracks,
      // and a thumbnail from the first item (the channel header isn't parsed).
      final nameCounts = <String, int>{};
      String thumb = '';
      for (final i in items) {
        final a = (i['artist'] ?? '').toString();
        if (a.isNotEmpty) nameCounts[a] = (nameCounts[a] ?? 0) + 1;
        if (thumb.isEmpty && (i['thumbnail'] ?? '').toString().isNotEmpty) {
          thumb = i['thumbnail'].toString();
        }
      }
      final name = nameCounts.isEmpty
          ? 'Artist'
          : (nameCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
      return {'id': artistId, 'name': name, 'thumbnail': getHighResImage(thumb), 'type': 'artist'};
    } catch (_) {
      return {'id': artistId, 'name': 'Unknown Artist', 'type': 'artist'};
    }
  }

  Future<List<Song>> getArtistTopTracks(String artistId) async {
    if (artistId.isEmpty) return [];

    // Browse the artist channel (UC…) or album/playlist id and pull its songs.
    try {
      final response = await _innerTubeClient.getBrowse(artistId);
      final items = applyAudioOnly((response['items'] as List? ?? [])
              .map((i) => Map<String, dynamic>.from(i as Map))
              .where((m) => m['type'] == 'track')
              .toList())
          .map(_mapJsonToSong)
          .where((s) => s.id.isNotEmpty)
          .toList();
      if (items.isNotEmpty) return items;
    } catch (_) {}

    // Fallback: only meaningful if the id is actually a name/text query, never
    // for a raw UC channel id (which is not a useful search term).
    if (!artistId.startsWith('UC')) {
      try {
        final results = await executeScopedSearch(artistId, scope: SearchContextScope.tracks);
        return results.items;
      } catch (_) {}
    }
    return [];
  }
  /// YouTube Music's own query completions for a partially typed search.
  ///
  /// Straight passthrough — the caching and parsing live in the client. Callers
  /// must debounce; see [searchSuggestionsProvider].
  Future<List<String>> getSearchSuggestions(String input) =>
      _innerTubeClient.getSearchSuggestions(input);

  /// Artists YouTube Music itself puts under "Fans might also like".
  ///
  /// THIS WAS `async => []`, AND IT SILENTLY EMPTIED A QUARTER OF THE
  /// Recommendation pool.
  ///
  /// `_getSeedFromRelatedArtists` calls this from three places in player_smart,
  /// one of them commented "25% - Discovery". Because the stub returned an empty
  /// list, that function hit its `if (relatedArtists.isEmpty) return []` guard
  /// every single time, so the discovery share of every generated queue was
  /// always zero, and the pool fell back to the user's existing favourites. It
  /// looks like the recommender is working, only narrower than intended, which is
  /// exactly why a stub is worse here than a missing method: a missing method
  /// would not have compiled.
  ///
  /// Implemented against YouTube Music's own shelf rather than a similarity
  /// heuristic of our own. It is the same source the artist page already renders,
  /// which means the app agrees with itself about who is related.
  ///
  /// Accepts a channel id OR a bare artist NAME — [getArtistData] resolves a name
  /// to a `UC…` channel and re-enters, and its result is cached for three days,
  /// so repeated calls for the current artist cost nothing.
  Future<List<Song>> getRelatedArtists(String artistIdOrName) async {
    // Placeholder-name screening is the CALLER's job (player_smart already has
    // isJunkMusicTerm to hand). Importing that from intelligence_provider would
    // point a service at a provider, which is the wrong direction.
    final key = artistIdOrName.trim();
    if (key.isEmpty) return const [];
    try {
      final data =
          await getArtistData(key, fallbackName: key, fallbackImage: '');
      return data.relatedArtists;
    } catch (e) {
      print('getRelatedArtists("$key") failed: $e');
      return const [];
    }
  }

  // getArtistDiscography() and getArtistPlaylists() were stubs here too, both
  // `async => []`, and REMOVED rather than implemented: nothing called either of
  // them. The real discography and playlist shelves already come back from
  // getArtistData, so these were duplicate names for work that is done properly
  // elsewhere — the kind of API surface that reads like a feature and is not one.

  Album _itemToAlbum(Map<String, dynamic> m) => Album(
        id: (m['id'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        image: getHighResImage((m['thumbnail'] ?? m['image'] ?? '').toString()),
        releaseDate: (m['releaseDate'] ?? '').toString(),
        recordType: (m['recordType'] ?? 'album').toString(),
        subtitle: (m['subtitle'] ?? '').toString(),
      );

  /// Builds the full artist page (one browse request) split into the discography
  /// sections the UI renders: top songs, albums, singles & EPs, live, "featured
  /// on", artist/community playlists and "fans might also like" (related
  /// artists). YouTube Music groups these into titled shelves; we classify each
  /// shelf by its title and, within album shelves, by each item's recordType
  /// (pageType is ALBUM for both albums and singles, so the subtitle word is the
  /// only reliable single/EP signal. See CatalogApiParser._recordTypeFromRuns).
  /// Whether a release title marks it as a LIVE recording.
  ///
  /// WORD BOUNDARY, NOT `contains('live')`. The substring form filed every
  /// album whose title merely contains those four letters under "Live
  /// performances" — "Alive", "Living Proof", "Delivered", "Olive", so the album
  /// vanished from the Albums section and looked like a missing release rather
  /// than a misfiled one. That is the "full discography is not shown" report.
  ///
  /// Word-boundary matching keeps the true positives ("Live at Wembley", "Made
  /// in Japan (Live)", "Live") and drops the accidents. The extra markers are
  /// the conventional ones publishers use for concert records.
  static final RegExp _liveTitle =
      RegExp(r'\blive\b|\bunplugged\b|\bin concert\b|\ben vivo\b');

  static bool _isLiveRelease(String title) =>
      _liveTitle.hasMatch(title.toLowerCase());

  Future<ArtistData> getArtistData(
    String artistId, {
    String fallbackName = '',
    String fallbackImage = '',
  }) async {
    if (!artistId.startsWith('UC')) {
      // WHY ARTIST PICTURES LOOKED "NOT THE OFFICIAL ONE".
      //
      // Only the `UC…` path below reads YouTube Music's own artist-channel header
      // thumbnail, which IS the picture on the artist's official page. Everything
      // that arrived here without a channel id (a track whose rows carry no
      // linked artist, a liked-artist row saved before ids were stored, a
      // name-only "View artist") fell straight through to `fallbackImage`: a
      // search-result thumbnail, a Deezer picture, or in the worst case the
      // track's album cover. Same for the page CONTENT — no albums, no singles.
      //
      // So resolve the channel from the NAME first and re-enter through the real
      // path. `resolveArtistIdForTrack` with an empty title falls through to its
      // artist-scoped search, which returns channel ids. One extra request, once
      // per artist (the provider caches ArtistData), in exchange for the official
      // portrait and a complete page.
      //
      // No recursion risk: the retry is only taken with a `UC…` id, which takes
      // the branch below.
      final name =
          fallbackName.trim().isNotEmpty ? fallbackName.trim() : artistId.trim();
      if (name.isNotEmpty) {
        final resolved = await resolveArtistIdForTrack('', name);
        if (resolved != null && resolved.startsWith('UC')) {
          print('getArtistData: upgraded "$name" → channel $resolved '
              '(official header art + full page)');
          return getArtistData(resolved,
              fallbackName: fallbackName, fallbackImage: fallbackImage);
        }
      }
      // Genuinely unresolvable (no network, or an artist YouTube Music doesn't
      // have a channel for): best-effort top tracks only, as before.
      final tracks = await getArtistTopTracks(artistId);
      return ArtistData(
        name: fallbackName,
        image: fallbackImage,
        topTracks: tracks,
        albums: const [],
        singles: const [],
        relatedArtists: const [],
        playlists: const [],
        liveAlbums: const [],
        featuredAlbums: const [],
      );
    }

    // Guard the network fetch: a flaky network / schema change here used to
    // throw straight out of the provider and ERROR the whole artist page (unlike
    // every sibling fetch, which degrades gracefully). Fall back to best-effort
    // top tracks so the page still renders.
    Map<String, dynamic> page;
    List<Map<String, dynamic>> sections;
    try {
      page = await _innerTubeClient.getArtistPage(artistId);
      sections = (page['sections'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      print('WARN: getArtistData: artist page fetch failed ($artistId): $e');
      final tracks =
          await getArtistTopTracks(artistId).catchError((_) => <Song>[]);
      return ArtistData(
        name: fallbackName,
        image: fallbackImage,
        topTracks: tracks,
        albums: const [],
        singles: const [],
        relatedArtists: const [],
        playlists: const [],
        liveAlbums: const [],
        featuredAlbums: const [],
      );
    }

    final topTracks = <Song>[];
    final albums = <Album>[];
    final singles = <Album>[];
    final live = <Album>[];
    final featured = <Album>[];
    final playlists = <Song>[];
    final related = <Song>[];

    void classifyAlbum(Map<String, dynamic> m) {
      final album = _itemToAlbum(m);
      final rt = album.recordType;
      if (_isLiveRelease(album.title)) {
        live.add(album);
      } else if (rt == 'single' || rt == 'ep') {
        singles.add(album);
      } else {
        albums.add(album);
      }
    }

    for (final section in sections) {
      final title = (section['title'] ?? '').toString().toLowerCase();
      // applyAudioOnly: in audio-only mode the artist "Videos" shelf (and any
      // stray OMV/UGC card) is dropped before shelves are classified below.
      final items = applyAudioOnly((section['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => (m['id'] ?? '').toString().isNotEmpty)
          .toList());
      if (items.isEmpty) continue;

      // A carousel shelf only PREVIEWS ~10 items with a "Show all" button. For
      // Albums / Singles & EPs, follow that button to the FULL grid so the whole
      // discography is shown (the user's "all singles and EPs" ask). One extra
      // (cached) browse per shelf; falls back to the preview on any failure.
      final moreBrowseId = (section['moreBrowseId'] ?? '').toString();
      final moreParams = (section['moreParams'] ?? '').toString();
      Future<List<Map<String, dynamic>>> expanded() async {
        if (moreBrowseId.isEmpty) return items;
        try {
          final resp = await _innerTubeClient.getBrowse(moreBrowseId,
              params: moreParams, maxPages: 3);
          final full = applyAudioOnly((resp['items'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((m) => (m['id'] ?? '').toString().isNotEmpty)
              .toList());
          return full.length > items.length ? full : items;
        } catch (_) {
          return items;
        }
      }

      if (title.contains('fan') || title.contains('similar') || title.contains('related')) {
        related.addAll(items.where((m) => m['type'] == 'artist').map(_mapJsonToSong));
      } else if (title.contains('featured')) {
        featured.addAll((await expanded()).map(_itemToAlbum));
      }
      //'album' IS TESTED BEFORE 'single'/'ep', AND THE ORDER IS THE FIX.
      //
      // This used to read `title.contains('single') || title.contains('ep')`
      // first. YouTube Music labels some artists' shelf "Albums and EPs", which
      // contains 'ep', so every real album on those artists was filed under
      // Singles & EPs and the Albums section came up empty. Checking 'album'
      // first sends that shelf to classifyAlbum, which splits it by the
      // authoritative recordType instead of by the shelf's wording.
      //
      // 'ep' is also matched on a WORD BOUNDARY now. As a bare substring it hits
      // any shelf title containing those two letters in sequence.
      else if (title.contains('album')) {
        for (final m in await expanded()) {
          classifyAlbum(m);
        }
      } else if (RegExp(r'\bsingles?\b|\beps?\b').hasMatch(title)) {
        singles.addAll((await expanded()).map(_itemToAlbum));
      } else if (title.contains('playlist')) {
        playlists.addAll(items.where((m) => m['type'] == 'playlist').map(_mapJsonToSong));
      } else if (title.contains('song') || title.contains('video') || title.contains('top')) {
        topTracks.addAll(items.where((m) => m['type'] == 'track').map(_mapJsonToSong));
      } else {
        // Unknown shelf title — route by item type so nothing is lost.
        for (final m in items) {
          switch (m['type']) {
            case 'track':
              topTracks.add(_mapJsonToSong(m));
              break;
            case 'album':
              classifyAlbum(m);
              break;
            case 'playlist':
              playlists.add(_mapJsonToSong(m));
              break;
            case 'artist':
              related.add(_mapJsonToSong(m));
              break;
          }
        }
      }
    }

    final headerName = (page['name'] ?? '').toString();
    final headerThumb = (page['thumbnail'] ?? '').toString();

    // Fill discography gaps from search
    //
    // The channel grid above is followed all the way through its "Show all"
    // continuation, so it is complete AS PUBLISHED, but YouTube Music's artist
    // page routinely lists only ONE edition of a release. "After Hours" appears
    // and "After Hours (Deluxe)" does not, even though the deluxe is a real,
    // browsable album whose tracks turn up in search. That is a hole in the
    // source, not in the parsing, so no amount of paging fixes it.
    //
    // An artist-scoped album search sees those editions. It is additive only:
    // nothing already found is replaced or reordered, and the channel grid keeps
    // its own order at the front.
    //
    // STRICTLY FILTERED, because a bare album search WILL return other
    // artists' records with similar names — that is the same trap that once put a
    // film's poster and synopsis on Jennifer Lopez's page. An entry is only
    // accepted when its own subtitle names THIS artist.
    await _supplementDiscography(
      artistName: headerName.isNotEmpty ? headerName : fallbackName,
      albums: albums,
      singles: singles,
      live: live,
    );

    return ArtistData(
      name: headerName.isNotEmpty ? headerName : fallbackName,
      image: headerThumb.isNotEmpty ? getHighResImage(headerThumb) : fallbackImage,
      topTracks: topTracks,
      albums: albums,
      singles: singles,
      relatedArtists: related,
      playlists: playlists,
      liveAlbums: live,
      featuredAlbums: featured,
      description: (page['description'] ?? '').toString(),
      subscriberCount: (page['subscriberCount'] ?? '').toString(),
    );
  }

  /// Adds releases the artist's channel grid omitted, found via an album search.
  ///
  /// Mutates [albums] / [singles] / [live] in place, append-only. See the call
  /// site in [getArtistData] for why this is needed at all.
  ///
  /// Silent on any failure: the channel discography is already a complete answer,
  /// and a flaky supplementary request must never take the artist page down with
  /// it.
  Future<void> _supplementDiscography({
    required String artistName,
    required List<Album> albums,
    required List<Album> singles,
    required List<Album> live,
  }) async {
    final artist = artistName.trim();
    if (artist.isEmpty) return;
    try {
      final found = await search(artist, 'album')
          .timeout(const Duration(seconds: 6));
      if (found.isEmpty) return;

      // Every id already on the page, so nothing is added twice. Album search
      // results carry the app's `album_` prefix; the channel grid does not.
      String bareId(String id) => id.replaceFirst('album_', '');
      final known = <String>{
        for (final a in [...albums, ...singles, ...live]) bareId(a.id),
      };

      final wanted = _canonicalArtistKey(artist);
      var added = 0;
      for (final s in found) {
        final id = bareId(s.id);
        if (id.isEmpty || !known.add(id)) continue;

        // THE OWNERSHIP TEST. A search for "The Weeknd" also returns tribute
        // records, karaoke versions and unrelated artists whose name merely
        // contains the query. Require the result's OWN artist line to name this
        // artist before it is allowed onto their page.
        if (_canonicalArtistKey(s.artist) != wanted) continue;

        final album = Album(
          id: s.id,
          title: s.title,
          image: s.image,
          releaseDate: s.releaseDate,
          // Search does not label single vs album reliably, and guessing wrong
          // would file a record under the wrong heading. Everything accepted
          // here is treated as an album, which is what the missing editions are.
          recordType: 'album',
          subtitle: s.artist,
        );
        if (_isLiveRelease(album.title)) {
          live.add(album);
        } else {
          albums.add(album);
        }
        added++;
      }
      if (added > 0) {
        print('discography: +$added release(s) for "$artist" that the '
            'channel grid omitted');
      }
    } catch (_) {
      // Nothing to do — the page is already populated.
    }
  }

  /// Artist name reduced to a comparable key: lower-case, no leading "the",
  /// alphanumerics only. So "The Weeknd", "the weeknd" and "Weeknd" all match,
  /// while "Weeknd Tribute Band" does not.
  static String _canonicalArtistKey(String raw) {
    var t = raw.toLowerCase().trim();
    // Search subtitles are often "Album • The Weeknd • 2020" — take the part
    // that looks like a name if a bullet list came through.
    if (t.contains('•')) {
      final parts = t.split('•').map((p) => p.trim()).toList();
      t = parts.length > 1 ? parts[1] : parts.first;
    }
    t = t.replaceFirst(RegExp(r'^the\s+'), '');
    return t.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  // fetchSearchSuggestions() lived here: a JSONP call to
  // suggestqueries.google.com/complete/search?client=youtube. REMOVED, for two
  // independent reasons.
  //
  // 1. It was DEAD. Its only caller was SearchNotifier.updateSuggestions, which
  //    nothing called, writing into a SearchState.suggestions field no widget
  //    ever read.
  // 2. It was the WRONG SOURCE. That endpoint is YouTube VIDEO autocomplete, so
  //    it completes toward videos and channels rather than music. Suggestions now
  //    come from music/get_search_suggestions, YouTube Music own endpoint, via
  //    CatalogApiClient.getSearchSuggestions and searchSuggestionsProvider.
  //
  // It also removed a direct third-party host from the app is network surface.

  /// Row-key prefix for one search surface's history.
  ///
  /// SCOPES USE A DIFFERENT PREFIX, NOT A LONGER ONE. The music history is
  /// read with `LIKE 'history:%'`, so a nested key like `history:podcast:x` would
  /// be picked up by that query and shown as a MUSIC search, and worse, deleting
  /// it from the music list would silently reach into another surface's history.
  /// `hist_podcast:` cannot collide with `history:` under any LIKE pattern here.
  ///
  /// Music keeps the bare `history:` prefix so every row already on disk survives.
  static String _historyPrefix(String scope) =>
      scope.isEmpty ? 'history:' : 'hist_$scope:';

  /// Recent queries, newest first. [scope] '' is music; 'podcast' and 'radio'
  /// keep their own lists so one surface's searches never appear in another's.
  Future<List<String>> fetchSearchHistory({String scope = ''}) async {
    try {
      final prefix = _historyPrefix(scope);
      final db = await _databaseService.database;
      final List<Map<String, dynamic>> maps = await db.query('page_caches',
          where: 'cacheKey LIKE ?',
          whereArgs: ['$prefix%'],
          orderBy: 'timestamp DESC');
      return maps
          .map((m) => m['cacheKey'].toString().replaceFirst(prefix, ''))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addQueryToHistory(String query, {String scope = ''}) async {
    if (query.trim().isEmpty) return;
    try {
      await _databaseService.writePageCache(
          '${_historyPrefix(scope)}${query.trim()}', {'query': query});
    } catch (_) {}
  }

  Future<void> deleteHistoryItem(String query, {String scope = ''}) async {
    try {
      final db = await _databaseService.database;
      await db.delete('page_caches',
          where: 'cacheKey = ?',
          whereArgs: ['${_historyPrefix(scope)}${query.trim()}']);
    } catch (_) {}
  }

  Future<void> clearAllSearchHistory({String scope = ''}) async {
    try {
      final db = await _databaseService.database;
      await db.delete('page_caches',
          where: 'cacheKey LIKE ?', whereArgs: ['${_historyPrefix(scope)}%']);
    } catch (_) {}
  }
}