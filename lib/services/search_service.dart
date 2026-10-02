// lib/services/search_service.dart

import 'dart:async';
import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/services/database_service.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/mood_shelf.dart';
import 'dart:convert';
import 'package:auvy/services/event_log.dart';
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

  /// The exact release date of a track as "YYYY-MM-DD", or null when YouTube
  /// doesn't publish one. Catalogue endpoints only expose a year; the full date is
  /// in the player response's microformat. Cached for a week, and already warm for
  /// anything played (stream resolution fills the same cache).
  Future<String?> getTrackReleaseDate(String videoId) =>
      _innerTubeClient.getPublishDate(videoId);

  // YouTube Music search filter params: opaque base64 values its own web client
  // sends.
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

    // History isn't written here: executeScopedSearch is called from many internal
    // places (artist lookups, radio seeds, home feed, onboarding, album→artist
    // navigation), and recording those showed terms the user never typed. History
    // is written only from the search box (search_page.dart) via
    // SearchNotifier.saveSearch.

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

  /// A Short is a video item of at most 60 seconds, or one whose title says so.
  /// Once videos are allowed, Shorts (vertical clips, often a snippet of the real
  /// track) clutter browse and search.
  ///
  /// Conservative on purpose:
  ///  • [isVideoItem] gates it, so a short audio track (interlude, skit, intro) is
  ///    never caught.
  ///  • An unknown duration (0) is never treated as a Short; some shelves omit
  ///    length, and guessing would silently remove real tracks.
  static bool isShortItem(Map m) {
    if (!isVideoItem(m)) return false;
    final title = (m['title'] ?? '').toString().toLowerCase();
    if (title.contains('#short')) return true;
    final ms = (m['durationMs'] as num?)?.toInt() ?? 0;
    return ms > 0 && ms <= 60000;
  }

  static List<Map<String, dynamic>> dropShorts(List<Map<String, dynamic>> items) =>
      items.where((m) => !isShortItem(m)).toList();

  // There is no "hide explicit" filter: YouTube publishes explicit and clean
  // edits as separate uploads with no mapping between them, so a filter could
  // only make tracks disappear. Explicit tracks are labelled instead
  // (`ExplicitBadge`, from `Song.isExplicit`).

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
      // Empty when unknown, never a plausible placeholder. A fake length would show
      // in Song details, inflate playlist totals, and skew the duration guard in
      // resolveAudioEquivalent. Every consumer treats '' as "unknown".
      duration: durationMs <= 0 ? '' : durationString,
      // 0 means unknown, which is always the case for YouTube rows. A fake default
      // would show a made-up "50% worldwide" in Song details and flatten the
      // recommender's popularity term. Real values come from Spotify
      // (`item.popularity`), Deezer (rank) and Last.fm (listener counts).
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

  /// Qualifiers that make a track a different recording rather than a different
  /// presentation of the same one. Excludes `remaster` (same performance) and
  /// `version`, `mix` and a bare `edit` (too generic: "Single Version", "Album
  /// Mix"); `radio edit` is matched as a whole phrase for that reason.
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

  /// Whether two tracks are the same recording as far as their titles show.
  /// [_normalizeTitleForMatch] strips "(feat. …)", which is right for a video
  /// titled "X (feat. Y)" whose audio is plain "X", but wrong when the feature
  /// marks a different recording (a remix). Checked in both directions: asking
  /// for the remix must not play the original, and vice versa.
  static bool _sameRecording(String titleA, String titleB) {
    Set<String> variants(String t) =>
        _recordingVariant.allMatches(t).map((m) => m.group(0)!.toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ')).toSet();
    if (!_setEquals(variants(titleA), variants(titleB))) return false;
    return _setEquals(_featuredIn(titleA), _featuredIn(titleB));
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  // Compiled once rather than per title; both normalisers below run for every
  // track in every response.
  static final RegExp _mBracketVideo =
      RegExp(r'[\(\[](?:official\s+)?(?:music\s+|lyric\s+)?video[\)\]]');
  static final RegExp _mOfficialVideo =
      RegExp(r'\bofficial\s+(?:music\s+)?video\b');
  static final RegExp _mDecorWords =
      RegExp(r'\b(?:mv|hd|4k|visualizer|lyrics?)\b');
  static final RegExp _mBracketFeat =
      RegExp(r'[\(\[](?:feat|ft)\.?[^\)\]]*[\)\]]');
  static final RegExp _mNonAlnum = RegExp(r'[^a-z0-9]+');

  /// Normalises a track title for matching: lower-case, strip common
  /// music-video decorations ("(Official Video)", "[MV]", …) and featured-artist
  /// tails, then collapse to alphanumerics.
  static String _normalizeTitleForMatch(String title) {
    var t = title.toLowerCase();
    t = t.replaceAll(_mBracketVideo, ' ');
    t = t.replaceAll(_mOfficialVideo, ' ');
    t = t.replaceAll(_mDecorWords, ' ');
    t = t.replaceAll(_mBracketFeat, ' ');
    t = t.replaceAll(_mNonAlnum, ' ').trim();
    return t;
  }

  /// The decoration patterns for [cleanDisplayTitle], compiled once; it runs for
  /// every row of every response.
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

  /// Cleans a track title for display: removes music-video / lyric-video /
  /// audio / visualizer decorations while keeping the real title's case and
  /// spacing. Only strips well-known phrases, and returns the original if a
  /// strip would leave it empty.
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

  /// Seconds from a duration string: "m:ss", "h:mm:ss", or raw seconds. 0 when it
  /// can't be read; callers treat that as "unknown", never as zero length.
  static int parseDurationSeconds(String raw) {
    final d = raw.trim();
    if (d.isEmpty) return 0;
    if (!d.contains(':')) return int.tryParse(d) ?? 0;
    final parts = d.split(':').map((p) => int.tryParse(p.trim()) ?? -1).toList();
    if (parts.any((p) => p < 0)) return 0;
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  /// Audio-only swap: given a music-video [song], finds its audio-song
  /// equivalent on YouTube Music. Returns the best title+artist match, or null
  /// when nothing convincingly matches (the caller then plays the video's own
  /// audio).
  ///
  /// [strict] (used when the input's type is unknown rather than a confirmed
  /// video) requires an exact normalised-title match, so a real audio track is
  /// never swapped for a same-named different song. A confirmed video allows
  /// the looser contains-match, since video titles carry extra decorations.
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
      // A candidate with no artist doesn't count as a match: with the title-only
      // fallback query below, that let a common title ("Warrior") match an unrelated
      // song.
      if (a.isEmpty) return false;
      final pa = primaryArtist.toLowerCase().trim();
      return a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a) ||
          (pa.isNotEmpty && (a.contains(pa) || pa.contains(a)));
    }

    // Duration is the decisive check: two recordings sharing a title almost always
    // differ in length, while a video and its audio are within a second or two.
    // Unknown durations don't block the match (absence isn't a mismatch).
    final wantSeconds = parseDurationSeconds(song.duration);
    bool durationMatches(Song r) {
      final rs = parseDurationSeconds(r.duration);
      if (wantSeconds <= 0 || rs <= 0) return true;
      return (wantSeconds - rs).abs() <= 5;
    }

    /// Whether [r] is the same edition of the recording, not just the same song.
    ///
    /// YouTube publishes explicit masters and clean edits as separate uploads with
    /// the same title, artist and nearly the same duration, so the other checks all
    /// pass. Picking the wrong one gives censored audio under an EXPLICIT badge, and
    /// lyrics that drift (a clean edit is re-cut around the censored words). The
    /// explicit badge decides first; title markers are a backstop, since clean
    /// uploads are usually titled identically.
    bool renditionMatches(Song r) {
      // Symmetric: the row the listener opened (badged or not) says which edition
      // they want, so both directions matter.
      //
      // `isExplicit` is nullable, and null means "the catalogue didn't say", not
      // "clean". An unknown candidate isn't credited with the wanted edition. When
      // the source edition is unknown, prefer the explicit master (the original, and
      // what lyrics are timed to). This only decides the preferred pass; the
      // fallback pass accepts either.
      final want = song.isExplicit;
      final got = r.isExplicit == true;
      // A row that explicitly showed NO badge is a distinct clean entry and
      // wants the edit. Everything else — badged, or unlabelled — wants the
      // master. Titles that announce themselves ("(Clean)", "Radio Edit") are
      // the backstop, not the primary signal: a clean upload is usually titled
      // identically to the master, which is why the badge leads.
      return want == false ? !got : got;
    }

    /// An unknown duration isn't a matching duration. `durationMatches` returns true
    /// when either side is unknown (so a missing value can't disable matching), which
    /// means the ±5 s guard doesn't apply to a candidate without a duration. So the
    /// preferred pass requires a duration it can check; the fallback pass stays
    /// lenient so a track whose candidates all lack durations still plays.
    bool durationKnown(Song r) =>
        wantSeconds > 0 && parseDurationSeconds(r.duration) > 0;

    /// [sameRendition] runs the edition preference. Called twice: once
    /// demanding the same edition, then once without, so a track that genuinely
    /// has no explicit upload still resolves instead of failing to play. The
    /// preference changes WHICH match wins, never WHETHER one is found.
    Song? bestMatch(List<Song> results, {required bool sameRendition}) {
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
        if (sameRendition && !renditionMatches(r)) continue;
        if (sameRendition && !durationKnown(r)) continue;
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
        // The loosest test here, so the recording check matters most: under the
        // normaliser "without me" is contained in "without me feat juice wrld". This is
        // also the branch used for a confirmed music video (`strict` is false).
        if (!_sameRecording(song.title, r.title)) continue;
        if (sameRendition && !renditionMatches(r)) continue;
        if (sameRendition && !durationKnown(r)) continue;
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
        final m = bestMatch(results, sameRendition: true) ??
            bestMatch(results, sameRendition: false);
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

  /// Merges a matched audio track back onto the row the user opened.
  ///
  /// The audio identity (the id that plays and its duration) comes from [audio].
  /// What describes the release (cover, album title, album id) stays with
  /// [original] and only fills from [audio] where blank, so a track played from a
  /// deluxe album keeps the deluxe cover and album link. It makes no reference to
  /// edition names, so it works for any number of versions.
  ///
  /// Exception: a music-video row has no edition to keep and its artwork is a 16:9
  /// video still, so a video row takes the audio's identity wholesale, including
  /// the proper square cover.
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

  /// Forgets the cached match for [id] so the next lookup searches again. Used by
  /// "Refetch track details": the cache is otherwise permanent (including "no audio
  /// equivalent" answers), so a refetch would replay the same wrong answer.
  static void forgetConform(String id) {
    if (id.isEmpty) return;
    _conformCache.remove(id);
    _conformInFlight.remove(id);
  }

  /// Matches are also saved to disk. A video's audio equivalent never changes, and
  /// each lookup is a search, so without persistence every launch re-resolved the
  /// same videos. Saving the answer makes every later encounter free, whereas
  /// converting at fetch time would just do the same lookups earlier, for rows
  /// nobody plays.
  ///
  /// Negative results are stored too, with a timestamp: a search that finds
  /// nothing is the most wasteful to repeat. They expire, since an audio version
  /// can be published later.
  // Bumped to v2 when the matcher learned about editions. Answers are kept for
  // good, so a matcher fix doesn't apply to tracks already resolved; a new key
  // retires the old answers (one re-lookup per track actually played). Bump again
  // whenever the matching rules change.
  static const String _kConformKey = 'auvy_conform_v2';
  /// Sized against the prefs file: each entry is a serialised Song (~300 bytes),
  /// and SharedPreferences is one file rewritten on every write. 400 entries is
  /// ~120 KB, which covers the practical working set.
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

  /// Cached [resolveAudioEquivalent]: the matched audio [Song], or null when
  /// there is no convincing equivalent. Cached in memory and on disk and
  /// de-duplicated per video id across the app.
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
      logEvent(r == null
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

  /// A real album/playlist browse id (MPRE…/OLAK…/MPLA…/VL…/PL…/RDCLAK…), not a
  /// video id. Callers sometimes pass a track's 11-character video id when it has
  /// no album, and browsing that returns an unrelated album. Anything unrecognised
  /// is rejected so AlbumPage shows the single track instead.
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
      // A candidate must be by the right artist when we know one; title-only matching
      // found same-named albums by other artists (covers, karaoke, tributes). Rows
      // without an artist aren't rejected, and multi-artist credits pass via the
      // containment check.
      bool artistOk(dynamic a) {
        if (artistNeedle.isEmpty) return true;
        final aa = a.artist.toString().trim().toLowerCase();
        if (aa.isEmpty) return true;
        return aa.contains(artistNeedle) || artistNeedle.contains(aa);
      }
      // Edition qualifiers that distinguish releases of the same record. Candidates
      // are scored so the one whose edition tokens match the request wins (otherwise
      // "After Hours (Deluxe Edition)" could land on plain "After Hours").
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
      // playing track still matches its catalogue entry and "view album" finds the
      // full album.
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

  /// Significant words of an artist name, for comparing two spellings of the same
  /// artist. Case, punctuation and `&`/`and` are folded, and suffixes YouTube adds
  /// to channel names are dropped, so "The Weeknd - Topic" and "TheWeekndVEVO"
  /// reduce to the artist. See [resolveArtistIdForTrack] for why matching is exact
  /// rather than substring-based.
  static final RegExp _artistNoiseWord =
      RegExp(r'^(vevo|official|topic|channel|records|recordings)$');

  /// Whether [candidate] names the same artist as [want]. The single rule every
  /// caller uses, so tapping one artist never opens another.
  ///
  /// Covered by test/artist_match_verify.dart, which calls this method directly;
  /// keep it that way rather than copying the rule into the test.
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

  /// An artist's channel id and picture, for callers that need only those (e.g.
  /// the onboarding grid). The artist-scoped search already returns both, so this
  /// stops there instead of browsing the whole artist page (several hundred KB).
  ///
  /// Matched with [artistNameMatches] ("Drake" must not settle for "Drake Bell").
  /// Null when nothing matches, so the caller keeps what it had.
  Future<({String id, String image})?> resolveArtistCard(String name) async {
    final want = name.trim();
    if (want.isEmpty) return null;
    try {
      final results = await search(want, 'artist');
      final match = pickArtistMatch<Song>(
          results.where((r) => r.id.startsWith('UC')), want, (r) => r.title);
      if (match == null) return null;
      // Keep an empty image empty: getHighResImage turns a blank URL into a generic
      // avatar, which would pass every `isEmpty` check.
      return (
        id: match.id,
        image: match.image.isEmpty ? '' : getHighResImage(match.image),
      );
    } catch (_) {
      return null;
    }
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
  static final RegExp _aCreditSeparator = RegExp(r'\s*[,&]\s*');

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

  /// For a multi-artist credit ("mgk, blackbear", as taste seeds are keyed), which
  /// might never equal one artist's name: the credited artist to open, or null.
  ///
  /// Only when [candidates] name at least two of the credited artists, which shows
  /// a real collaboration rather than one name containing a comma or "&". Then the
  /// first credited artist found. One credited name alone isn't enough: "Earth"
  /// from "Earth, Wind & Fire" would open a different artist.
  static String? collaborationLead(String credit, List<String> candidates) {
    final credited = credit
        .split(_aCreditSeparator)
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    if (credited.length < 2) return null;
    final present = [
      for (final c in credited)
        if (candidates.any((name) => artistNameMatches(c, name))) c,
    ];
    return present.length >= 2 ? present.first : null;
  }

  /// Finds the specific artist channel behind a track, telling same-named
  /// artists apart. A track credited only by a plain-text name has no channel
  /// id, so this looks the track up, matches the row that is this track, and
  /// returns the credited artist's channel id. Null when nothing links a
  /// channel; the caller then searches by name as a last resort.
  Future<String?> resolveArtistIdForTrack(String trackTitle, String artistName) async {
    final t = trackTitle.trim();
    final a = artistName.trim();
    if (t.isEmpty && a.isEmpty) return null;
    final aNeedle = a.toLowerCase();
    // Set equality of name words, not `contains`: substring matching accepted
    // different artists ("Drake" → "Drake Bell", "The Weeknd" → a channel named
    // "Weeknd"). Comparing word sets keeps real variants ("Tyler, The Creator" vs
    // "Tyler The Creator", "The Weeknd - Topic", "ArtistVEVO") and rejects a
    // candidate that adds or drops a name word. Strict is the safe direction: an
    // unresolved name returns null and callers keep their existing image.
    // Delegates to [artistNameMatches].
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
        final lead = collaborationLead(
            a, [for (final r in res) if (r.id.startsWith('UC')) r.title]);
        if (lead != null) {
          for (final r in res) {
            if (r.id.startsWith('UC') && artistNameMatches(lead, r.title)) return r.id;
          }
        }
        // No "take the first result" fallback: that resolved a search to whatever
        // channel ranked first. Returning null lets the caller keep its name and image.
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
    // Still nothing, but we came from a known track whose title differs from
    // `albumTitle`. That happens when `albumTitle` is really a playlist or context
    // name (e.g. "Favorite Songs") attached to the queued song. Recover the real
    // album from the track title; resolveAlbumIdForTrack only returns a real
    // browse id on a title match, so a true single stays empty and AlbumPage shows
    // the track itself.
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

  // YouTube Music radio: the watch-next / RDAMVM feed, YouTube's own
  // recommendations for a track (personalised when signed in). A much better
  // autoplay seed than genre or similar-artist search. Cached briefly per seed,
  // bounded.
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

  /// Other editions of an album (the deluxe next to the standard, and back), at no
  /// network cost: an album browse response already includes an "Other versions"
  /// shelf, which the tracklist parse would otherwise discard. The artist page often lists
  /// only one edition, so this shelf is the most reliable link between them.
  ///
  /// `maxPages: 3` matches [_browseCollectionTracks] so this reads the same cached
  /// browse entry instead of making a second request.
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

        // Only editions of this album. The parser flattens every shelf (including "More
        // from this artist" and recommendations) into one list, so the base title is the
        // filter: an edition of "After Hours" is still "After Hours" once the edition
        // decoration is stripped.
        if (albumBaseTitle(candidateTitle) != selfBase) continue;

        // One row per distinct edition name. The same release appears under several
        // browse ids (regional variants, repeated shelves), so dedupe on the normalised
        // full title; "After Hours" and "After Hours (Deluxe)" still differ. seenTitles
        // starts with this album's own title so the page never offers itself.
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

  /// An album title with edition decoration removed, for deciding whether two
  /// titles name the same release: "After Hours (Deluxe)", "After Hours — Deluxe
  /// Edition" and "After Hours (Remastered 2019)" all reduce to "afterhours".
  /// Public so test/album_versions_verify.dart can test the real function.
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
      // Don't prune video-typed rows inside an opened collection: an album's or
      // playlist's rows are its actual entries, and some albums contain OMV/UGC rows.
      // Every row still plays as audio (the resolver only picks audio formats). The
      // audio-only setting applies to search, home shelves and artist pages.
      return trackMaps
          .map(_mapJsonToSong)
          .where((s) => s.id.isNotEmpty)
          // Cover art follows where you navigated: an album stamps its cover on every
          // row, a playlist never does. A track on several editions can reference either
          // edition's cover, and only the page the user opened knows which edition they
          // meant. A playlist collects different releases, so each track keeps its own
          // cover.
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
        // Shuffle so a shelf backed by a fixed playlist shows a different slice on each
        // home load. The section page still fetches the full, ordered playlist via
        // sourceId.
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

  /// The region chart and the new-releases shelf, cached for half an hour.
  /// getDiscoveryFeed is called twice per home refresh (for the Quick Picks pool
  /// and for the discovery shelves) with different arguments over the same two
  /// shelves, so caching here, below it, lets both share one fetch.
  static const Duration _shelfMemoTtl = Duration(minutes: 30);
  List<Map<String, dynamic>>? _chartsMemo;
  DateTime? _chartsMemoAt;
  List<Map<String, dynamic>>? _releasesMemo;
  DateTime? _releasesMemoAt;

  Future<List<Map<String, dynamic>>> _chartsCached() async {
    final at = _chartsMemoAt;
    final memo = _chartsMemo;
    if (memo != null && at != null &&
        DateTime.now().difference(at) < _shelfMemoTtl) {
      return memo;
    }
    final fresh = await _innerTubeClient.getCharts();
    // Only a real answer is cached: an empty list from a dead browse id must not
    // pin "no charts" in place for half an hour.
    if (fresh.isNotEmpty) {
      _chartsMemo = fresh;
      _chartsMemoAt = DateTime.now();
    }
    return fresh;
  }

  Future<List<Map<String, dynamic>>> _newReleasesCached() async {
    final at = _releasesMemoAt;
    final memo = _releasesMemo;
    if (memo != null && at != null &&
        DateTime.now().difference(at) < _shelfMemoTtl) {
      return memo;
    }
    final fresh = await _innerTubeClient.getNewReleases();
    if (fresh.isNotEmpty) {
      _releasesMemo = fresh;
      _releasesMemoAt = DateTime.now();
    }
    return fresh;
  }

  /// YouTube Music's own discovery feeds as home sections: `FEmusic_charts`
  /// (region-localised top songs / trending) and `FEmusic_new_releases_albums`.
  /// Personalised when signed in. Playlist/album-backed shelves carry a
  /// `sourceId` so the section page can fetch the full list on open. Returns
  /// [] on failure, so the feed simply lacks the section.
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
      if (charts) add(_chartsCached(), 'chart'),
      if (newReleases) add(_newReleasesCached(), 'release'),
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

  /// A mood/genre category as shelves of tiles, for the mood pages: each playlist
  /// or album stays its own tile under the shelf's heading. No per-item request;
  /// tracks are fetched when the user opens a playlist.
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

  /// The size stamped on every Google CDN artwork URL at ingestion. AuvyImage
  /// rewrites it to a smaller size whenever it knows the painted size, so this
  /// only matters where the size is unknown, mainly the player page's
  /// full-screen cover. 1200 covers a ~1080 px-wide screen with headroom without
  /// reaching full-size multi-MB artwork.
  static const String _sourceSizeParam = 's1200';

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
      // Find the first CDN size parameter (=wN, =sN, =hN). firstMatch + substring
      // also handles chained params like =w120-h120-l90-rj=s1200.
      final match = RegExp(r'=[wsh]\d').firstMatch(url);
      if (match != null) {
        return '${url.substring(0, match.start)}=$_sourceSizeParam';
      }
      // No size param found — URL-safe base64 IDs never contain '='
      // so we can safely append directly.
      return '${url.trimRight()}=$_sourceSizeParam';
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

  /// Artists YouTube Music lists under "Fans might also like", the same shelf the
  /// artist page shows, so the app agrees with itself about who is related. Feeds
  /// the "discovery" share of recommendation pools (see
  /// _getSeedFromRelatedArtists in player_smart).
  ///
  /// Accepts a channel id or an artist name: [getArtistData] resolves a name to a
  /// `UC…` channel, and its result is cached for three days.
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


  Album _itemToAlbum(Map<String, dynamic> m) => Album(
        id: (m['id'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        image: getHighResImage((m['thumbnail'] ?? m['image'] ?? '').toString()),
        releaseDate: (m['releaseDate'] ?? '').toString(),
        recordType: (m['recordType'] ?? 'album').toString(),
        subtitle: (m['subtitle'] ?? '').toString(),
      );

  /// Whether a release title marks it as a live recording. Uses word boundaries,
  /// not `contains('live')`, which misfiled "Alive", "Living Proof", "Delivered"
  /// and "Olive" under live performances. The extra markers are the conventional
  /// ones for concert records.
  static final RegExp _liveTitle =
      RegExp(r'\blive\b|\bunplugged\b|\bin concert\b|\ben vivo\b');

  static bool _isLiveRelease(String title) =>
      _liveTitle.hasMatch(title.toLowerCase());

  /// The newest releases on an artist's page (the previews of its Albums and
  /// Singles & EPs shelves, newest first as YouTube Music lists them) and its
  /// "Fans might also like" artists. One request, for What's New; the full
  /// discography is [getArtistData].
  Future<({List<Album> releases, List<Song> related})> getArtistLatest(String artistId) async {
    final releases = <Album>[];
    final related = <Song>[];
    if (!artistId.startsWith('UC')) return (releases: releases, related: related);
    final page = await _innerTubeClient.getArtistPage(artistId);
    for (final raw in (page['sections'] as List? ?? const [])) {
      final section = Map<String, dynamic>.from(raw as Map);
      final title = (section['title'] ?? '').toString().toLowerCase();
      final items = [
        for (final e in (section['items'] as List? ?? const []))
          Map<String, dynamic>.from(e as Map)
      ].where((m) => (m['id'] ?? '').toString().isNotEmpty).toList();
      if (title.contains('fan') || title.contains('similar') || title.contains('related')) {
        related.addAll(items.where((m) => m['type'] == 'artist').map(_mapJsonToSong));
      } else if (!title.contains('featured') &&
          (title.contains('album') || RegExp(r'\bsingles?\b|\beps?\b').hasMatch(title))) {
        releases.addAll(items.map(_itemToAlbum).where((a) => !_isLiveRelease(a.title)));
      }
    }
    return (releases: releases, related: related);
  }

  /// The full artist page (one browse request), split into the sections the UI
  /// shows: top songs, albums, singles & EPs, live, "featured on", playlists and
  /// "fans might also like". Shelves are classified by title and, within album
  /// shelves, by each item's recordType (albums and singles share a page type;
  /// see CatalogApiParser._recordTypeFromRuns).
  Future<ArtistData> getArtistData(
    String artistId, {
    String fallbackName = '',
    String fallbackImage = '',
  }) async {
    if (!artistId.startsWith('UC')) {
      // Resolve the artist's channel from the name first. Only the `UC…` path below
      // reads the official channel header picture and the full discography; without
      // a channel id the page fell back to a search thumbnail or album cover and had
      // no albums or singles. One extra request per artist (ArtistData is cached).
      // No recursion risk: the retry only happens with a `UC…` id.
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

    // Guard the page fetch so a network error or format change degrades to
    // best-effort top tracks instead of failing the whole artist page.
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
      // 'album' is checked before 'single'/'ep', and 'ep' on a word boundary: some
      // artists' shelf is titled "Albums and EPs", which would otherwise send every
      // album to Singles & EPs. classifyAlbum then splits the shelf by each item's
      // recordType.
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

    // Fill discography gaps from search. The channel grid is complete as
    // published, but YouTube Music's artist page often lists only one edition of a
    // release ("After Hours" without "After Hours (Deluxe)"). An artist-scoped album
    // search finds those. Additive only: nothing found above is replaced or
    // reordered. Strictly filtered, because album searches also return other
    // artists' records with similar names; an entry must name this artist in its
    // own subtitle.
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

  /// Adds releases the channel grid omitted, found via an album search. Appends to
  /// [albums] / [singles] / [live] in place (see [getArtistData]). Silent on
  /// failure: the channel discography is already a complete answer.
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

        // Ownership test: a search for "The Weeknd" also returns tributes, karaoke and
        // artists whose name merely contains the query, so the result's own artist line
        // must name this artist.
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


  /// Row-key prefix for one search surface's history. Other scopes use a different
  /// prefix rather than a longer one: music history is read with
  /// `LIKE 'history:%'`, which would also match `history:podcast:x`.
  /// `hist_podcast:` can't collide. Music keeps the bare `history:` prefix so
  /// existing rows survive.
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