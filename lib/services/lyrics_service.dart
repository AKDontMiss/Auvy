// lib/services/lyrics_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/services/updater_service.dart' show UpdaterService;
import 'package:auvy/services/http_pool.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Abstract blueprint decoupling structural network execution from central logic controllers.
abstract class LyricsProvider {
  String get providerId;
  Future<LyricsData?> fetchLyrics(String title, String artist, {String? durationMs});
}

/// The edge cache in front of the lyric catalogues
///
/// Every device asked lrclib, NetEase, KuGou and lyrics.ovh directly, and the
/// scan below asks ALL of them for EVERY track — five candidates, of which
/// NetEase and KuGou need two round-trips each. The same popular song was
/// therefore fetched from four donated, community-run services once per listener.
/// Routing through the Worker means the second listener onward is answered by
/// Cloudflare and the upstream never hears about it.
///
/// It also makes the manual refetch fast: a refetch deliberately rotates to a
/// DIFFERENT source, which used to be the slowest path in the app because that
/// source had never been warmed.
///
/// THE DIRECT PATH IS DELIBERATELY KEPT. Making the Worker the only way to
/// reach lyrics would mean one misdeployed Cloudflare route silently kills lyrics
/// for everyone — exactly what happened to /covers. Worker first, upstream if it
/// cannot answer.
class _LyricsEdge {
  /// Only the FIRST failure pays the timeout. Without this, a Worker outage would
  /// add the edge timeout to every one of the five sources, on every track, for
  /// the whole session — turning a fast-enough scan into a visible stall.
  static bool _down = false;
  static DateTime? _downAt;
  static const Duration _retryAfter = Duration(minutes: 5);
  static const Duration _timeout = Duration(seconds: 3);

  static bool get _usable {
    if (!_down) return true;
    if (_downAt != null && DateTime.now().difference(_downAt!) > _retryAfter) {
      _down = false; // give the edge another chance later in a long session
      return true;
    }
    return false;
  }

  static void _markDown() {
    _down = true;
    _downAt = DateTime.now();
  }

  /// GET one lyric-catalogue call: the Worker's cached mirror first, then [direct].
  /// Returns the response body, or null when neither could answer.
  static Future<String?> get({
    required String source,
    required Map<String, String> params,
    required Uri direct,
    Map<String, String> directHeaders = const {},
    Duration directTimeout = const Duration(seconds: 6),
  }) async {
    if (_usable) {
      try {
        final uri = Uri.parse('https://${UpdaterService.updateHost}/lyrics')
            .replace(queryParameters: {'source': source, ...params});
        final res = await HttpPool().getClient().get(uri, headers: const {
          'Accept': 'application/json',
        }).timeout(_timeout);
        // 404 is a real "no lyrics here" answer from lrclib/lyrics.ovh — the
        // caller's own parse handles it. Only reaching for the upstream on a
        // TRANSPORT failure keeps a negative answer cached instead of doubling
        // every miss into two requests.
        if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
        if (res.statusCode == 404) return null;
      } catch (_) {
        _markDown();
      }
    }
    try {
      final res = await HttpPool().getClient().get(direct, headers: directHeaders).timeout(directTimeout);
      if (res.statusCode == 200) return res.body;
    } catch (_) {}
    return null;
  }
}

class LrcLibProvider implements LyricsProvider {
  @override
  String get providerId => "lrclib";

  @override
  Future<LyricsData?> fetchLyrics(String title, String artist, {String? durationMs}) async {
    try {
      final queryParams = {'track_name': title, 'artist_name': artist};
      final body = await _LyricsEdge.get(
        source: 'lrclib',
        params: queryParams,
        direct: Uri.parse("https://lrclib.net/api/get")
            .replace(queryParameters: queryParams),
        directHeaders: const {
          'User-Agent': 'AuvyMusicPlayer/1.0 (Mobile; Android)',
          'Accept': 'application/json',
        },
      );
      if (body != null) return LyricsData.fromJson(jsonDecode(body));
    } catch (_) {}
    return null;
  }
}

class KuGouProvider implements LyricsProvider {
  @override
  String get providerId => "kugou";

  @override
  Future<LyricsData?> fetchLyrics(String title, String artist, {String? durationMs}) async {
    try {
      // Kugou's search is case-sensitive, AND the scan hands it lowercase.
      //
      // `_cleanTitle`/`_cleanArtist` lowercase everything before the providers are
      // called, which is correct for lrclib and NetEase and fatal here. Measured
      // against the live endpoint:
      //
      //   "queen - bohemian rhapsody"        →  0 candidates
      //   "Queen - Bohemian Rhapsody"        → 10 candidates
      //   "the weeknd - blinding lights"     →  0 candidates
      //   "The Weeknd - Blinding Lights"     → 10 candidates
      //
      // And `_fetchScored`'s raw-query retry does NOT rescue it: that only fires
      // when the cleaned query differs from `raw.toLowerCase()`, which for an
      // already-tidy title it does not. So KuGou got one lowercase attempt and
      // returned nothing, for most tracks, silently.
      //
      // Both spellings are tried because neither wins everywhere — "ac/dc -
      // thunderstruck" finds 10 as-is and title-casing mangles it to "Ac/dc". The
      // second request only happens when the first found nothing.
      Future<String?> search(String keyword) => _LyricsEdge.get(
            source: 'kugou-search',
            params: {'keyword': keyword},
            direct: Uri.parse(
                'https://lyrics.kugou.com/search?ver=1&man=yes&client=pc'
                '&keyword=${Uri.encodeComponent(keyword)}'),
            directTimeout: const Duration(seconds: 5),
          );

      List? candidatesOf(String? body) {
        if (body == null) return null;
        try {
          final list = (jsonDecode(body) as Map)['candidates'] as List?;
          return (list == null || list.isEmpty) ? null : list;
        } catch (_) {
          return null;
        }
      }

      final asGiven = "$artist - $title";
      var candidates = candidatesOf(await search(asGiven));
      if (candidates == null) {
        final titled = _titleCase(asGiven);
        if (titled != asGiven) candidates = candidatesOf(await search(titled));
      }

      {
        if (candidates != null && candidates.isNotEmpty) {
          final id = candidates.first['id'];
          //`accesskey`, ALL LOWERCASE — TWICE. KuGou names the field
          // `accesskey` in /search, so reading `accessKey` gave null; and
          // /download only accepts the param spelled `accesskey`, answering
          // camelCase with HTTP 200 and `{"status":400,"info":"Bad Request"}`.
          // Both spellings were wrong here, which is why this source returned
          // nothing for every track ever played and never logged a thing.
          final accessKey =
              candidates.first['accesskey'] ?? candidates.first['accessKey'];
          if (accessKey == null) return null;
          // KuGou reports the matched song's duration (ms) — keep it so the
          // scorer can duration-match this candidate too.
          final durMs = candidates.first['duration'];

          final contentBody = await _LyricsEdge.get(
            source: 'kugou-download',
            params: {'id': '$id', 'accesskey': '$accessKey'},
            direct: Uri.parse('https://lyrics.kugou.com/download?ver=1&client=pc'
                '&id=$id&accesskey=$accessKey&fmt=lrc&charset=utf8'),
            directTimeout: const Duration(seconds: 5),
          );
          if (contentBody != null) {
            final contentData = jsonDecode(contentBody);
            final base64Content = contentData['content'] as String?;
            if (base64Content != null) {
              final rawLrc = utf8.decode(base64.decode(base64Content));
              return LyricsData.fromJson({
                // COERCED. KuGou's candidate id is a STRING ("768915945"),
                // LyricsData.fromJson wants an int, and the cast threw
                // `type 'String' is not a subtype of type 'int'` — straight into
                // the catch-all above. This was the LAST of three independent
                // faults on this provider (the other two: the `accesskey`
                // spelling, and the scan handing it a lowercase query), and it
                // meant KuGou never once produced lyrics even after the request
                // chain was fixed. Three bugs in a row, all silent, because one
                // `catch (_) {}` covered the whole method.
                'id': id is int ? id : (int.tryParse('$id') ?? '$id'.hashCode.abs()),
                'trackName': title,
                'artistName': artist,
                'albumName': 'KuGou Matrix',
                'duration': (durMs is num ? durMs / 1000.0 : 0),
                'instrumental': false,
                'plainLyrics': rawLrc.replaceAll(RegExp(r'\[\d+:\d+\.\d+\]'), '').trim(),
                'syncedLyrics': rawLrc
              });
            }
          }
        }
      }
    } catch (e) {
      // LOGGED, NOT SWALLOWED. This method had THREE independent bugs that all
      // ended here under a bare `catch (_) {}`, so the provider reported "no
      // lyrics for this track" for years instead of "I am broken". A source that
      // fails must be distinguishable from a source that found nothing.
      print('ERROR: kugou provider failed: $e');
    }
    return null;
  }

  /// "queen - bohemian rhapsody" → "Queen - Bohemian Rhapsody".
  ///
  /// Only the first letter of each whitespace-separated word, deliberately: this
  /// is undoing the scan's lowercasing for a case-sensitive upstream, not trying
  /// to guess an artist's real typography.
  static String _titleCase(String s) => s.replaceAllMapped(
        RegExp(r'(^|\s)(\S)'),
        (m) => '${m[1]}${m[2]!.toUpperCase()}',
      );
}

/// NetEase Cloud Music — a very strong SYNCED-lyrics catalogue (free, no key).
/// Search → resolve the song id → pull its LRC. Adds a distinct, independent
/// source so a refetch has a real alternative to rotate to, and so the scorer
/// has more synced candidates to choose the most reliable from.
class NetEaseProvider implements LyricsProvider {
  @override
  String get providerId => "netease";

  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36',
    'Referer': 'https://music.163.com',
    'Accept': 'application/json',
  };

  @override
  Future<LyricsData?> fetchLyrics(String title, String artist, {String? durationMs}) async {
    try {
      final s = "$title $artist";
      final searchBody = await _LyricsEdge.get(
        source: 'netease-search',
        params: {'s': s},
        // NOT `/api/search/get/web` — THAT ENDPOINT ANSWERS WITH CIPHERTEXT.
        // Called from outside China it returns `{"abroad":true,"result":"<hex>"}`
        // — an AES blob, not the song list. `sd['result']?['songs']` then indexed
        // a String, threw, and was swallowed by the catch, so NetEase contributed
        // zero candidates to every scan without ever logging a failure. The plain
        // `/api/search/get` (no `/web`) returns real JSON in every region.
        direct: Uri.parse("https://music.163.com/api/search/get"
            "?s=${Uri.encodeQueryComponent(s)}&type=1&offset=0&limit=5"),
        directHeaders: _headers,
        directTimeout: const Duration(seconds: 5),
      );
      if (searchBody == null) return null;

      final sd = jsonDecode(searchBody);
      // Defensive: `result` is an OBJECT here, but the region-encrypted variant of
      // this API returns it as a hex STRING. Checking the type means a future
      // upstream change degrades to "no NetEase candidate" instead of throwing
      // into the catch-all and looking identical to "this song has no lyrics".
      final result = sd is Map ? sd['result'] : null;
      final songs = result is Map ? result['songs'] as List? : null;
      if (songs == null || songs.isEmpty) return null;

      final song = songs.first;
      final id = song['id'];
      if (id == null) return null;
      final name = (song['name'] ?? title).toString();
      final artists = (song['artists'] as List?)
              ?.map((a) => (a['name'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .join(', ') ??
          artist;
      final durMs = song['duration'];

      final lyricBody = await _LyricsEdge.get(
        source: 'netease-lyric',
        params: {'id': '$id'},
        direct: Uri.parse("https://music.163.com/api/song/lyric?id=$id&lv=1&kv=1&tv=-1"),
        directHeaders: _headers,
        directTimeout: const Duration(seconds: 5),
      );
      if (lyricBody == null) return null;

      final ld = jsonDecode(lyricBody);
      final synced = (ld['lrc']?['lyric'] as String?) ?? '';
      final plainFallback = (ld['klyric']?['lyric'] as String?) ?? '';
      final hasSynced = synced.trim().isNotEmpty;
      if (!hasSynced && plainFallback.trim().isEmpty) return null;

      return LyricsData.fromJson({
        'id': id is int ? id : (id.hashCode),
        'trackName': name,
        'artistName': artists,
        'albumName': 'NetEase',
        'duration': (durMs is num ? durMs / 1000.0 : 0),
        'instrumental': false,
        'plainLyrics': hasSynced
            ? synced.replaceAll(RegExp(r'\[\d+:\d+(?:[.:]\d+)?\]'), '').trim()
            : plainFallback.trim(),
        'syncedLyrics': hasSynced ? synced : '',
      });
    } catch (_) {}
    return null;
  }
}

/// Plain-lyrics last resort (api.lyrics.ovh). No synced timing, but a wide
/// catalogue, so when the synced providers miss, a refetch can still surface
/// SOMETHING rather than depending on a single source.
class LyricsOvhProvider implements LyricsProvider {
  @override
  String get providerId => "lyrics.ovh";

  @override
  Future<LyricsData?> fetchLyrics(String title, String artist, {String? durationMs}) async {
    try {
      final body = await _LyricsEdge.get(
        source: 'ovh',
        params: {'artist': artist, 'title': title},
        direct: Uri.parse(
            "https://api.lyrics.ovh/v1/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}"),
      );
      if (body != null) {
        final data = jsonDecode(body);
        final plain = (data['lyrics'] as String?)?.trim();
        if (plain != null && plain.isNotEmpty) {
          return LyricsData.fromJson({
            'id': '$title-$artist'.hashCode.abs(),
            'trackName': title,
            'artistName': artist,
            'albumName': '',
            'duration': 0,
            'instrumental': false,
            'plainLyrics': plain,
            'syncedLyrics': '',
          });
        }
      }
    } catch (_) {}
    return null;
  }
}

/// A scored lyrics candidate: the fetched data, which source produced it, and
/// how good a match it is. The scan keeps the highest-scoring one.
class _ScoredLyrics {
  final LyricsData data;
  final String source;
  final double score;
  _ScoredLyrics(this.data, this.source, this.score);
}

class LyricsService {
  // Singleton Pattern
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  static const String _baseUrl = "https://lrclib.net/api";

  // All sources scanned CONCURRENTLY (not first-hit-wins). The scorer decides
  // the winner, so order here is irrelevant — it only affects tie-break trust.
  final List<LyricsProvider> _externalProviders = [
    LrcLibProvider(),
    NetEaseProvider(),
    KuGouProvider(),
    LyricsOvhProvider(),
  ];

  // Pseudo-source id for the lrclib /search candidate (kept distinct so refetch
  // can rotate past it too).
  static const String _searchSourceId = 'lrclib-search';

  // RAM Cache
  final Map<String, _CachedLyrics> _cache = {};

  // Track failed lookups to avoid retrying immediately
  final Set<String> _failedLookups = {};

  /// A scan that found nothing was repeated forever
  ///
  /// `_failedLookups` above is deliberately short-lived — 45 seconds, so a
  /// TRANSPORT failure retries and rotates sources rather than sticking. That is
  /// right for a network hiccup and wrong for the other answer entirely: a song
  /// with no lyrics ANYWHERE returns the same nothing every time, and a full
  /// scan is several requests across several providers.
  ///
  /// So it was re-scanned every 45 seconds of playback, and again on every
  /// launch, permanently. Measured in the live log: seven "Scanning all lyric
  /// sources" lines in one short window.
  ///
  /// A definitive miss — every source reachable and none of them had it — is a
  /// fact worth keeping. Kept on disk, with a TTL because lyrics DO get
  /// contributed later, and lrclib in particular is community-edited.
  static const String _kNoLyricsKey = 'auvy_lyrics_absent_v1';
  static const Duration _absentTtl = Duration(days: 30);
  static const int _absentCap = 600;
  Map<String, int> _absent = {};
  bool _absentLoaded = false;
  Timer? _absentSave;

  Future<void> _loadAbsent() async {
    if (_absentLoaded) return;
    _absentLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kNoLyricsKey);
      if (raw == null || raw.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      var kept = 0, dropped = 0;
      decoded.forEach((k, v) {
        final ts = (v as num?)?.toInt() ?? 0;
        if (now - ts > _absentTtl.inMilliseconds) {
          dropped++;
          return;
        }
        _absent[k] = ts;
        kept++;
      });
      print('lyrics: $kept song(s) known to have none '
          '(${dropped} expired and will be re-checked) — that many multi-source '
          'scans this session will not happen');
    } catch (_) {}
  }

  void _rememberAbsent(String cacheKey) {
    _absent[cacheKey] = DateTime.now().millisecondsSinceEpoch;
    while (_absent.length > _absentCap) {
      _absent.remove(_absent.keys.first);
    }
    _absentSave?.cancel();
    _absentSave = Timer(const Duration(seconds: 5), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kNoLyricsKey, jsonEncode(_absent));
      } catch (_) {}
    });
  }

  bool _knownAbsent(String cacheKey) {
    final ts = _absent[cacheKey];
    if (ts == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - ts > _absentTtl.inMilliseconds) {
      _absent.remove(cacheKey);
      return false;
    }
    return true;
  }

  // Track pending requests to avoid duplicate network calls
  final Map<String, Future<LyricsData?>> _pendingRequests = {};

  // Per-song memory of which sources have already been chosen, so a REFETCH
  // deliberately rotates to a DIFFERENT source instead of returning the same
  // pick again. Reset when it has cycled through everything or on cache clear.
  final Map<String, Set<String>> _rejectedSources = {};

  Future<void> clearCacheForSong(String songId, {String? title, String? artist}) async {
    print("Clearing lyrics cache for song: $songId");
    // Match ONLY this song's entries. The old predicate `contains(songId) ||
    // contains(':')` matched EVERY key (all keys are '$track:$artist', which
    // always contains ':'), so a single-song refetch wiped every song's cached
    // lyrics + all failed-lookups + all in-flight requests. Cache keys are
    // title-based, so match by songId OR the song's title.
    final String? t = title?.trim().toLowerCase();
    bool matches(String key) {
      final k = key.toLowerCase();
      return k.contains(songId.toLowerCase()) || (t != null && t.isNotEmpty && k.contains(t));
    }
    _cache.removeWhere((key, value) => matches(key));
    _failedLookups.removeWhere(matches);
    // AND THE PERSISTED MISS. Without this, "refetch lyrics" on a song the
    // app has recorded as having none would return instantly with nothing — a
    // button that does nothing, for a month.
    _absent.removeWhere((k, _) => matches(k));
    _pendingRequests.removeWhere((key, value) => matches(key)); // drop this song's in-flight/settled miss so refetch truly re-hits the network
    _rejectedSources.removeWhere((key, value) => matches(key)); // fresh source rotation for a re-opened song

    try {
      await AudioCacheManager().clearLyricsCache(songId);
    } catch (e) {
      print("WARN: Failed to clear disk lyrics cache: $e");
    }
  }

  void clearAllCache() {
    _cache.clear();
    _failedLookups.clear();
    _rejectedSources.clear();
    print("Cleared all lyrics cache");
  }

  String _cleanTitle(String title) {
    return title
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)\s*'), '')
      .replaceAll(RegExp(r'\[.*?\]\s*'), '')
      .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*-\s*official.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*explicit\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  }

  String _cleanArtist(String artist) {
    return artist
      .toLowerCase()
      .split(RegExp(r'\s+(feat\.?|ft\.?|featuring|with|&|,|x)\s+', caseSensitive: false))
      .first
      .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
      .trim();
  }

  // ---------------------------------------------------------------------------
  // MULTI-SOURCE SCAN + SCORING
  // ---------------------------------------------------------------------------

  /// Query EVERY (non-excluded) source concurrently, score each returned
  /// candidate, and return the single best. This is what makes lyrics reliable:
  /// instead of trusting whichever source answers first, we compare all of them
  /// and keep the most trustworthy synced/duration-matched result.
  Future<_ScoredLyrics?> _scanAllSources(
    String title,
    String artist, {
    String? durationMs,
    Set<String> exclude = const {},
  }) async {
    final cleanTitle = _cleanTitle(title);
    final cleanArtist = _cleanArtist(artist);
    final targetMs = int.tryParse(durationMs ?? '');

    final tasks = <Future<_ScoredLyrics?>>[];

    for (final p in _externalProviders) {
      if (exclude.contains(p.providerId)) continue;
      tasks.add(_fetchScored(p, cleanTitle, cleanArtist, title, artist, durationMs, targetMs));
    }
    if (!exclude.contains(_searchSourceId)) {
      tasks.add(_searchScored(cleanTitle, cleanArtist, title, artist, targetMs));
    }

    if (tasks.isEmpty) return null;

    // SPEED, without sacrificing correctness: settle as soon as a CLEARLY-correct
    // candidate arrives (synced + right title + matching duration ⇒ score ≥ 95),
    // else wait for ALL sources and pick the highest score. Uses Future.wait (the
    // proven path) but also races a "confident" short-circuit alongside it, so a
    // bug in the race can never swallow a result — Future.wait always resolves.
    const double confident = 95.0;
    final gathered = <_ScoredLyrics>[];
    final fast = Completer<void>();
    for (final t in tasks) {
      // ignore: unawaited_futures
      t.then((r) {
        if (r != null && r.score > 0) {
          gathered.add(r);
          if (r.score >= confident && !fast.isCompleted) fast.complete();
        }
      }).catchError((_) {});
    }
    // Whichever comes first: a confident hit, or every source finishing.
    final allDone = Future.wait(tasks).then((_) {});
    await Future.any([fast.future, allDone]);

    final results = List<_ScoredLyrics>.from(gathered)
      ..sort((a, b) => b.score.compareTo(a.score));
    if (results.isEmpty) return null;
    final best = results.first;
    if (best.score <= 0) return null;
    print("Lyrics chose '${best.source}' (${best.score.toStringAsFixed(0)}) for '$title'");
    return best;
  }

  Future<_ScoredLyrics?> _fetchScored(
    LyricsProvider provider,
    String cleanTitle,
    String cleanArtist,
    String rawTitle,
    String rawArtist,
    String? durationMs,
    int? targetMs,
  ) async {
    try {
      // Try the cleaned query first; fall back to the raw query within the SAME
      // source before giving up (both bounded by timeout).
      //
      // 10s, not 7s: a source now tries the Worker's cache before the upstream,
      // so the ONE request that discovers the edge is unreachable pays the edge
      // timeout PLUS the direct request. At 7s that first pass got cut off and
      // the track looked lyric-less; after it, `_LyricsEdge` remembers the outage
      // and every later source goes straight out. The 12s whole-scan cap still
      // bounds the visible wait, and a confident hit short-circuits both.
      var data = await provider
          .fetchLyrics(cleanTitle, cleanArtist, durationMs: durationMs)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (data == null && (cleanTitle != rawTitle.toLowerCase() || cleanArtist != rawArtist.toLowerCase())) {
        data = await provider
            .fetchLyrics(rawTitle, rawArtist, durationMs: durationMs)
            .timeout(const Duration(seconds: 7), onTimeout: () => null);
      }
      if (data == null) return null;

      final score = _score(data, rawTitle, rawArtist, provider.providerId, targetMs: targetMs);
      if (score <= 0) return null;
      return _ScoredLyrics(data, provider.providerId, score);
    } catch (_) {
      return null;
    }
  }

  /// lrclib's free-text `/search`, through the edge cache. Shared by the normal
  /// scan and the relaxed refetch pass so both hit the SAME cache key for the
  /// same query.
  Future<String?> _lrcLibSearch(String q) => _LyricsEdge.get(
        source: 'lrclib-search',
        params: {'q': q},
        direct: Uri.parse('$_baseUrl/search').replace(queryParameters: {'q': q}),
        directHeaders: const {'User-Agent': 'AuvyMusicPlayer/1.0 (Mobile; Android)'},
        directTimeout: const Duration(seconds: 7),
      );

  /// lrclib /search returns MANY matches — score them all and keep the best,
  /// as an extra recall source (catches tracks /get misses).
  Future<_ScoredLyrics?> _searchScored(
    String cleanTitle,
    String cleanArtist,
    String rawTitle,
    String rawArtist,
    int? targetMs,
  ) async {
    try {
      final body = await _lrcLibSearch('$cleanTitle $cleanArtist');
      if (body == null) return null;

      final List<dynamic> results = jsonDecode(body);
      _ScoredLyrics? best;
      for (final r in results.take(8)) {
        final rawName = (r['trackName'] ?? '').toString().toLowerCase();
        // Skip obviously-wrong censored variants.
        if (rawName.contains('clean') || rawName.contains('censored') || rawName.contains('radio edit')) {
          continue;
        }
        final data = LyricsData.fromJson(r as Map<String, dynamic>);
        final score = _score(data, rawTitle, rawArtist, _searchSourceId, targetMs: targetMs);
        if (score > 0 && (best == null || score > best.score)) {
          best = _ScoredLyrics(data, _searchSourceId, score);
        }
      }
      return best;
    } catch (_) {}
    return null;
  }

  /// LAST-RESORT pass for a manual refetch that found nothing: rotate the QUERY
  /// shape, not just the source. Tries title-only, dash-stripped title, and
  /// "artist title" against the widest source (lrclib /search) with a relaxed
  /// match threshold — a real user pressed Refetch, so a fuzzy hit beats none.
  Future<_ScoredLyrics?> _relaxedScan(String title, String artist, {int? targetMs}) async {
    final cleanTitle = _cleanTitle(title);
    final cleanArtist = _cleanArtist(artist);
    final dashless = cleanTitle.split(RegExp(r'\s+-\s+')).first.trim();
    final queries = <String>{
      cleanTitle,
      if (dashless.isNotEmpty && dashless != cleanTitle) '$dashless $cleanArtist',
      if (cleanArtist.isNotEmpty) '$cleanArtist $cleanTitle',
    };

    Future<_ScoredLyrics?> one(String q) async {
      try {
        final body = await _lrcLibSearch(q);
        if (body == null) return null;
        final List<dynamic> results = jsonDecode(body);
        _ScoredLyrics? best;
        for (final r in results.take(10)) {
          final data = LyricsData.fromJson(r as Map<String, dynamic>);
          final score = _score(data, title, artist, _searchSourceId,
              targetMs: targetMs, relaxed: true);
          if (score > 0 && (best == null || score > best.score)) {
            best = _ScoredLyrics(data, _searchSourceId, score);
          }
        }
        return best;
      } catch (_) {
        return null;
      }
    }

    final candidates =
        (await Future.wait(queries.map(one))).whereType<_ScoredLyrics>().toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.first;
  }

  /// Reliability/popularity score for a candidate. Higher = better:
  /// synced timing, matching duration, matching title/artist, completeness, and
  /// a small per-source trust weight break ties. Returns <=0 to reject.
  /// [relaxed] (manual-refetch last resort) lowers the title-match rejection bar.
  double _score(LyricsData d, String targetTitle, String targetArtist, String source, {int? targetMs, bool relaxed = false}) {
    final hasSynced = d.lines.isNotEmpty;
    final plain = d.plainLyrics.trim();
    if (!hasSynced && plain.isEmpty) return -1; // nothing usable
    if (d.instrumental && !hasSynced && plain.isEmpty) return -1;

    final tSim = _similarity(_cleanTitle(d.trackName), _cleanTitle(targetTitle));
    final aSim = _similarity(_cleanArtist(d.artistName), _cleanArtist(targetArtist));
    // Reject a clearly-wrong song when the source returns real metadata.
    if (d.trackName.trim().isNotEmpty && tSim < (relaxed ? 0.25 : 0.4)) return -1;

    // RELAXED MUST NOT MEAN "ANY SONG THAT STARTS THE SAME WAY".
    //
    // The relaxed bar dropped the TITLE floor to 0.25 and asked nothing of the
    // artist — it only contributed to the score. So a shared opening phrase was
    // enough to win when nothing better existed. Observed:
    //
    // Scanning all lyric sources for: Touch and Kiss by SLOWBURN (refetch)
    // Relaxed refetch matched 'Touch and Go ? [Would You?]' for 'Touch and Kiss'
    // Lyrics: chose 'lrclib-search' (score 70.1)
    //
    // Different song, different artist, accepted on "touch and".
    //
    // WRONG LYRICS ARE WORSE THAN NO LYRICS. A blank view is understood at a
    // glance; a confident wrong one is read as the app being broken, and it is
    // the one outcome the user cannot correct. So a loose title now has to be
    // backed by the ARTIST actually matching. Either signal alone still passes,
    // which keeps the cases relaxed mode exists for:
    //
    //   • same artist, renamed version (live/remix/remaster) → low tSim, high aSim
    //   • right song, messy artist metadata (compilations)   → high tSim, low aSim
    //
    // Only loose-on-BOTH is refused, which is exactly the wrong-song case.
    if (relaxed && tSim < 0.4 && aSim < 0.6) return -1;

    double s = 0;
    s += hasSynced ? 50.0 : 12.0; // synced lyrics are what users actually want
    s += tSim * 25.0;
    s += aSim * 12.0;

    if (targetMs != null && targetMs > 0) {
      final candMs = _durationMsOf(d);
      if (candMs > 0) {
        final diff = (candMs - targetMs).abs();
        if (diff <= 3000) {
          s += 30.0; // almost certainly the right version
        } else if (diff <= 8000) {
          s += 10.0;
        } else {
          s -= 10.0; // likely a different (live/extended/short) version
        }
      }
    }

    final lineCount = hasSynced
        ? d.lines.length
        : plain.split('\n').where((l) => l.trim().isNotEmpty).length;
    s += (lineCount > 40 ? 40 : lineCount) / 40.0 * 10.0;

    s += _sourceTrust(source);
    return s;
  }

  int _durationMsOf(LyricsData d) {
    if (d.duration > 0) return (d.duration * 1000).round();
    if (d.lines.isNotEmpty) return d.lines.last.startTime.inMilliseconds + 3000;
    return 0;
  }

  double _sourceTrust(String source) {
    switch (source) {
      case 'lrclib':
      case _searchSourceId:
        return 8.0;
      case 'netease':
        return 6.0;
      case 'kugou':
        return 5.0;
      case 'lyrics.ovh':
        return 2.0;
      default:
        return 3.0;
    }
  }

  // --- Podcast show-notes (unchanged) ---

  /// One episode's show notes from the Worker — the show lookup and the feed walk
  /// both happen at the edge.
  ///
  /// THIS REPLACES DOWNLOADING THE WHOLE FEED TO READ ONE PARAGRAPH. The direct
  /// path below does an iTunes search, then `HttpPool().getClient().get(feedUrl)` on the phone, then
  /// a regex sweep over the entire XML to find a single episode's description —
  /// with a `?_t=<timestamp>` cache-buster appended, so every open re-downloaded
  /// the lot with every HTTP cache deliberately defeated. Measured against The
  /// Daily's feed: 18,011 KB pulled to the device, versus 15 KB read at the edge
  /// (the reader stops the moment the episode matches) and a few KB returned.
  ///
  /// Returns null when the Worker cannot answer, so the direct parse still runs.
  ///
  /// The show is resolved here, on the device, AND the feed URL is passed in.
  /// The Worker used to do the iTunes lookup itself, which measured as 429 after
  /// about five requests — Apple throttles by source IP and every user shares one
  /// Cloudflare egress address. From a phone the same search always succeeds. So
  /// the cheap request (a 5-result iTunes search) stays local and only the
  /// expensive one (walking a multi-megabyte feed) is offloaded.
  Future<LyricsData?> _podcastNotesViaWorker(
      String track, String artist, String feedUrl) async {
    if (feedUrl.isEmpty) return null;
    try {
      final uri = Uri.parse('https://${UpdaterService.updateHost}/podcast/notes')
          .replace(queryParameters: {'url': feedUrl, 'episode': track});
      final res = await HttpPool().getClient().get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final ep = body['episode'];
      if (ep is! Map) return null;
      final notes = (ep['notes'] ?? '').toString().trim();
      if (notes.isEmpty) return null;
      // The Worker already stripped tags and decoded entities.
      final fakeSynced = notes
          .split('\n')
          .map((l) => l.trim().isEmpty ? '[00:00.00] ' : '[00:00.00] $l')
          .join('\n');
      return LyricsData.fromJson({
        'id': track.hashCode.abs(),
        'trackName': track,
        'artistName': artist,
        'albumName': 'Podcast',
        'duration': 0,
        'instrumental': false,
        'plainLyrics': notes,
        'syncedLyrics':
            '[00:00.00] EPISODE SHOW NOTES:\n[00:00.00] \n$fakeSynced',
      });
    } catch (_) {
      return null;
    }
  }

  Future<LyricsData?> _getPodcastDescription(String track, String artist) async {
    try {
      final uri = Uri.parse('https://itunes.apple.com/search?term=${Uri.encodeComponent(artist)}&media=podcast&limit=5');
      final response = await HttpPool().getClient().get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['results'] != null) {
          for (var result in data['results']) {
            final showName = result['collectionName'] ?? '';
            final showArtist = result['artistName'] ?? '';

            if (_similarEnough(showName, artist, threshold: 0.7) ||
                _similarEnough(showArtist, artist, threshold: 0.7)) {

              final feedUrl = result['feedUrl'];
              if (feedUrl != null) {
                // The feed walk goes to the edge
                //
                // The show is now resolved, so hand the feed URL to the Worker and
                // let it stream the feed and return just this episode's notes.
                // Everything below is the fallback for when it cannot answer, and
                // it is expensive: `HttpPool().getClient().get(feedUrl)` pulls the WHOLE feed to the
                // phone — 18,011 KB measured on The Daily — with a cache-buster
                // that defeats every HTTP cache on the way. The Worker reads ~15 KB
                // and stops.
                final viaWorker = await _podcastNotesViaWorker(
                    track, artist, feedUrl.toString());
                if (viaWorker != null) return viaWorker;

                final cacheBuster = DateTime.now().millisecondsSinceEpoch;
                final separator = feedUrl.contains('?') ? '&' : '?';
                final rssResp = await HttpPool().getClient().get(Uri.parse('$feedUrl${separator}_t=$cacheBuster')).timeout(const Duration(seconds: 10));

                if (rssResp.statusCode == 200) {
                  final xmlString = rssResp.body;

                  final itemRegex = RegExp(r'''<item>([\s\S]*?)<\/item>''', caseSensitive: false);
                  final titleRegex = RegExp(r'''<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>''', caseSensitive: false);
                  final descRegex = RegExp(r'''<description>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/description>''', caseSensitive: false);
                  final contentRegex = RegExp(r'''<content:encoded>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/content:encoded>''', caseSensitive: false);

                  final matches = itemRegex.allMatches(xmlString);

                  for (final match in matches) {
                    final itemXml = match.group(1) ?? '';
                    final titleMatch = titleRegex.firstMatch(itemXml);

                    if (titleMatch != null) {
                      final epTitle = _cleanPodcastHtml(titleMatch.group(1) ?? '');

                      bool isExactMatch = _similarEnough(epTitle, track, threshold: 0.8) ||
                                          (epTitle.length > 5 && track.length > 5 &&
                                          (epTitle.toLowerCase().contains(track.toLowerCase()) ||
                                           track.toLowerCase().contains(epTitle.toLowerCase())));

                      if (isExactMatch) {
                        final descMatch = contentRegex.firstMatch(itemXml) ?? descRegex.firstMatch(itemXml);
                        if (descMatch != null) {
                          final desc = descMatch.group(1) ?? "No description available.";
                          final cleanDesc = _cleanPodcastHtml(desc);

                          final fakeSyncedLyrics = cleanDesc.split('\n').map((line) {
                            return line.trim().isEmpty ? '[00:00.00] ' : '[00:00.00] $line';
                          }).join('\n');

                          return LyricsData.fromJson({
                            'id': track.hashCode.abs(),
                            'trackName': track,
                            'artistName': artist,
                            'albumName': 'Podcast',
                            'duration': 0,
                            'instrumental': false,
                            'plainLyrics': cleanDesc,
                            'syncedLyrics': '[00:00.00] EPISODE SHOW NOTES:\n[00:00.00] \n$fakeSyncedLyrics'
                          });
                        }
                      }
                    }
                  }
                }
                break;
              }
            }
          }
        }
      }
    } catch (e) {
      print("Podcast description fetch error: $e");
    }

    return LyricsData.fromJson({
      'id': track.hashCode.abs(),
      'trackName': track,
      'artistName': artist,
      'albumName': 'Podcast',
      'duration': 0,
      'instrumental': false,
      'plainLyrics': "No show notes available for this episode.",
      'syncedLyrics': '[00:00.00] No show notes available for this episode.'
    });
  }

  String _cleanPodcastHtml(String text) {
    return text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<\/p>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&apos;', "'")
      .replaceAll('&raquo;', '"')
      .replaceAll('&laquo;', '"')
      .replaceAll('&rsquo;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  }

  // --- Public entry point ---

  /// Fetch lyrics for [track]/[artist]. [forceRefresh] (the manual refetch)
  /// bypasses all caches AND rotates to a DIFFERENT source than last time.
  /// [trackDurationMs] (optional) sharpens matching to the correct version.
  /// The cache key for a lyric lookup.
  ///
  /// Normalised because one song arrives under several spellings, AND each
  /// Spelling was a separate network fetch.
  ///
  /// The raw `$track:$artist` meant "ordinary things (feat. Nonna)" by
  /// "Ariana Grande, Nonna" and the same song listed as "ordinary things" by
  /// "Ariana Grande" were two different keys, so the same lyrics were fetched
  /// and written to disk twice within a couple of minutes. Observed in a session
  /// log, with the RAM entry sitting unused under the other spelling.
  ///
  /// ONLY THE CACHE KEY IS NORMALISED. The lookup itself still goes out with
  /// the FULL title and artist, and the scoring that picks between candidates is
  /// untouched, so this cannot change which lyrics a fetch returns. It only
  /// decides whether an answer already in hand gets reused.
  ///
  /// The primary artist alone, because a featured credit is inconsistently
  /// attached by the endpoints but never changes the words.
  static String _cacheKeyFor(String track, String artist) {
    final t = track
        .toLowerCase()
        .replaceAll(RegExp(r's*[([]s*(feat|ft|with)[^)]]*[)]]'), '')
        .trim();
    final primary = artist
        .toLowerCase()
        .split(RegExp(r's*(,|&|feat.|ft.|/)s*'))
        .first
        .trim();
    return '$t:$primary';
  }

  Future<LyricsData?> getLyrics(String track, String artist,
      {String? album, String? songId, bool forceRefresh = false, int? trackDurationMs}) async {
    if (album == 'Podcast') {
       return await _getPodcastDescription(track, artist);
    }

    final cacheKey = _cacheKeyFor(track, artist);

    if (forceRefresh) {
      // A manual refetch must bypass EVERY short-circuit — the failure memo, RAM
      // cache, disk cache and any stale pending request, so it actually re-hits
      // the network and rotates through all sources instead of replaying the
      // last miss. NOTE: we intentionally KEEP _rejectedSources so it picks a
      // different source than the previous attempt.
      _failedLookups.remove(cacheKey);
      _cache.remove(cacheKey);
      _pendingRequests.remove(cacheKey);
      if (songId != null && !songId.startsWith('http')) {
        try { await AudioCacheManager().clearLyricsCache(songId); } catch (_) {}
      }
    } else {
      if (_failedLookups.contains(cacheKey)) return null;
      // The long-lived version of the same answer.
      await _loadAbsent();
      if (_knownAbsent(cacheKey)) return null;

      if (_cache.containsKey(cacheKey)) {
        final cached = _cache[cacheKey]!;
        if (!cached.isExpired) return cached.data;
        _cache.remove(cacheKey);
      }

      if (songId != null && !songId.startsWith('http')) {
        try {
          final diskLyricsJson = await AudioCacheManager().getLyrics(songId);
          if (diskLyricsJson != null) {
            final lyricsData = LyricsData.fromJson(diskLyricsJson);
            _cacheResult(cacheKey, lyricsData);
            return lyricsData;
          }
        } catch (e) {
          print("WARN: Disk lyrics read error: $e");
        }
      }
    }

    if (_pendingRequests.containsKey(cacheKey)) return await _pendingRequests[cacheKey]!;

    final fetchFuture = _fetchLyricsInternal(track, artist, album, cacheKey, songId,
        rotate: forceRefresh, trackDurationMs: trackDurationMs);
    _pendingRequests[cacheKey] = fetchFuture;

    try {
      return await fetchFuture;
    } finally {
      _pendingRequests.remove(cacheKey);
    }
  }

  Future<LyricsData?> _fetchLyricsInternal(
      String track, String artist, String? album, String cacheKey, String? songId,
      {bool rotate = false, int? trackDurationMs}) async {
    try {
      final durStr = (trackDurationMs != null && trackDurationMs > 0) ? trackDurationMs.toString() : null;
      print("Scanning all lyric sources for: $track by $artist${rotate ? ' (refetch → rotating source)' : ''}");

      // On a refetch, exclude sources already chosen so we surface a DIFFERENT one.
      final excluded = rotate ? (_rejectedSources[cacheKey] ?? <String>{}) : <String>{};

      _ScoredLyrics? best = await _scanAllSources(track, artist, durationMs: durStr, exclude: excluded)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);

      // Rotation exhausted (every source already tried, or the remaining ones
      // returned nothing) → reset and take the best available overall so the
      // refetch never comes back empty just because it ran out of alternatives.
      if (best == null && excluded.isNotEmpty) {
        _rejectedSources.remove(cacheKey);
        best = await _scanAllSources(track, artist, durationMs: durStr)
            .timeout(const Duration(seconds: 12), onTimeout: () => null);
      }

      // Manual refetch still empty-handed → rotate the QUERY, not just the
      // source: relaxed title-focused variants against the widest catalogue.
      // (Kept manual-only: running this on the automatic first fetch added up to
      // 10 s to every no-result song and made the lyrics view look stuck.)
      if (best == null && rotate) {
        best = await _relaxedScan(track, artist, targetMs: trackDurationMs)
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
        if (best != null) {
          print("Relaxed refetch matched '${best.data.trackName}' for '$track'");
        }
      }

      if (best != null) {
        // Remember the winner so the NEXT refetch rotates to a different source.
        final rejected = _rejectedSources.putIfAbsent(cacheKey, () => <String>{});
        rejected.add(best.source);
        // Once we've cycled through everything, start the rotation over.
        if (rejected.length >= _externalProviders.length + 1) rejected.clear();
        // Bound the map so it can't grow unbounded across a long session.
        if (_rejectedSources.length > 60) {
          _rejectedSources.remove(_rejectedSources.keys.first);
        }

        _cacheResult(cacheKey, best.data);
        if (songId != null && !songId.startsWith('http')) {
          await AudioCacheManager().saveLyrics(songId, best.data.toJson());
        }
        print("OK: Lyrics: chose '${best.source}' (score ${best.score.toStringAsFixed(1)}) for $track");
        return best.data;
      }

      // Short "recently failed" memo ONLY to avoid re-scanning on every position
      // tick — cleared after 45 s so a later attempt (re-open, refetch, or a
      // transient network miss) tries again and rotates sources, rather than
      // being stuck "not found" for minutes.
      _failedLookups.add(cacheKey);
      Future.delayed(const Duration(seconds: 45), () => _failedLookups.remove(cacheKey));
      // Every source was consulted and none had it. Kept across launches — see
      // _kNoLyricsKey, so this scan is not repeated for a month.
      _rememberAbsent(cacheKey);
      print('no lyrics for "$track" from any source — remembered, so it will '
          'not be scanned for again');
      return null;
    } catch (e) {
      print("ERROR: Lyrics scan exception: $e");
      return null;
    }
  }

  void _cacheResult(String key, LyricsData data) {
    _cache[key] = _CachedLyrics(data, DateTime.now());
    if (_cache.length > 50) {
      final sortedKeys = _cache.entries
          .map((e) => MapEntry(e.key, e.value.timestamp))
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (var i = 0; i < 10; i++) {
        _cache.remove(sortedKeys[i].key);
      }
    }
  }

  int _levenshteinDistance(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    List<int> prev = List.generate(s2.length + 1, (i) => i);
    List<int> curr = List.filled(s2.length + 1, 0);

    for (int i = 1; i <= s1.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= s2.length; j++) {
        int cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        curr[j] = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce((a, b) => a < b ? a : b);
      }
      prev = List.from(curr);
    }
    return prev[s2.length];
  }

  /// Numeric similarity (0..1) between two strings — max of Jaccard word overlap
  /// and Levenshtein fuzzy ratio, with a containment boost.
  double _similarity(String a, String b) {
    final cleanA = a.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    final cleanB = b.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();

    if (cleanA == cleanB) return 1.0;
    if (cleanA.isEmpty || cleanB.isEmpty) return 0.0;

    final wordsA = cleanA.split(' ').where((w) => w.length > 1).toSet();
    final wordsB = cleanB.split(' ').where((w) => w.length > 1).toSet();

    double jaccard = 0.0;
    if (wordsA.isNotEmpty && wordsB.isNotEmpty) {
      final intersection = wordsA.intersection(wordsB);
      final union = wordsA.union(wordsB);
      jaccard = intersection.length / union.length;
    }

    final maxLen = a.length > b.length ? a.length : b.length;
    final fuzzy = maxLen == 0 ? 0.0 : 1.0 - (_levenshteinDistance(cleanA, cleanB) / maxLen);

    var score = jaccard > fuzzy ? jaccard : fuzzy;
    if (cleanA.contains(cleanB) || cleanB.contains(cleanA)) {
      if (score < 0.85) score = 0.85;
    }
    return score;
  }

  bool _similarEnough(String a, String b, {double threshold = 0.75}) {
    return _similarity(a, b) >= threshold;
  }
}

class _CachedLyrics {
  final LyricsData data;
  final DateTime timestamp;
  _CachedLyrics(this.data, this.timestamp);
  bool get isExpired => DateTime.now().difference(timestamp) > const Duration(hours: 24);
}
