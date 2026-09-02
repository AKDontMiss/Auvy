// ============================================================
// lib/services/artist_metadata_service.dart
//
// Artist metadata from Last.fm: similar artists, bios, top tracks, charts.
// Replaced the old ExternalCatalogService — no OAuth, no premium tier, and
// artist.getSimilar is genuinely the best free source for it.
//
// There is no API key in this app, AND there must NOT be.
//
// This header used to say "get your API key at last.fm/api/account/create",
// which described a build that shipped the key inside the APK. Every request now
// goes to the Worker's /lastfm route, which holds the key and enforces a method
// allowlist; a keyless or misconfigured Worker answers non-200 and every method
// here degrades to an empty result. See _get, which is the one place that says so
// out loud.
//
// Deezer still covers what Last.fm has no equivalent for: album tracks, playlist
// tracks, artist discography, and cover art (Last.fm deprecated track images in
// 2018).
// ============================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/backend_config.dart';

class ArtistMetadataService {
  /// The key is no longer in the app at all
  ///
  /// History, because the reasoning matters: the key first shipped as a bundled
  /// `.env` asset, readable with `unzip`. It was then moved to a
  /// `--dart-define`, which bakes it into the AOT binary — better, because it
  /// removes the one-command extraction, but still PUBLICATION rather than
  /// storage. The value is in the file, so anyone holding the APK can recover it
  /// with standard tooling: anyone the owner shares a build with, and Google,
  /// since Play Protect may upload a sideloaded APK for analysis.
  ///
  /// So it is not here any more. Requests go to the Worker, which holds the key
  /// as a server-side secret and forwards to Last.fm (see handleLastfm — it
  /// allowlists the read-only methods rather than proxying anything asked of it).
  /// The client ships no key, and rotating it is a Worker secret update instead
  /// of a rebuild-and-redistribute.
  ///
  /// The dotenv/define path is GONE deliberately. Leaving it as a "local dev
  /// fallback" would mean the key still had to exist on developer machines and
  /// could still slip into a build — the whole point is that there is no code
  /// path that can put it in the binary.
  static String get _baseUrl => '${BackendConfig.workerBase}/lastfm';

  /// Shared by every default-constructed instance.
  ///
  /// This class is constructed at the CALL SITE, not held as a singleton —
  /// `ArtistMetadataService().getArtistBio(name)` runs once per artist
  /// (`artist_info_service.dart`), and `player_smart.dart` builds one per
  /// recommendation pass. A `http.Client()` per instance therefore meant a new
  /// connection pool per artist, none of them ever closed: idle keep-alive
  /// sockets holding the radio awake, and a fresh TLS handshake for every bio
  /// instead of reusing one connection.
  ///
  /// One process-lifetime client fixes both.
  ///
  /// THE POOL'S CLIENT, NOT A PRIVATE ONE, which also closes a second gap.
  /// Sharing a private client stopped the leak but left this traffic invisible to
  /// the data tracker, exactly as the catalog client's private client did (see
  /// CatalogApiClient._http). Every artist bio and every "similar artists" lookup
  /// went uncounted in Settings. Routing through the pool fixes the leak and the
  /// blind spot with one reference.
  ///
  /// A GETTER for the reason spelled out on CatalogApiClient._http: capturing the
  /// pool's client in a `static final` would freeze whatever it was at the time.
  static http.Client get _sharedClient => HttpPool().getClient();

  final http.Client? _injected;

  /// [client] stays injectable for tests; omitting it uses the pooled client
  /// rather than allocating a per-instance one.
  ArtistMetadataService([http.Client? client]) : _injected = client;

  http.Client get _client => _injected ?? _sharedClient;

  // Helpers

  /// Every Last.fm request goes through here.
  ///
  /// There is no local key to check any more: the Worker either holds one or
  /// answers 503, and every caller already treats non-200 as "no data". So a
  /// misconfigured Worker degrades exactly the way a keyless build used to —
  /// blank bios, no similar artists — without this needing to know anything
  /// about it.
  /// (Historically this returned a synthetic 401 when the compiled-in key was
  /// missing, to avoid spending a request on a call that could not succeed. With
  /// the key server-side that check has nothing to inspect.)
  ///
  /// And it says so when it degrades
  ///
  /// "Degrades exactly the way a keyless build used to" was true and was the
  /// problem: 460 lines of this service had no log line anywhere, and every
  /// method turns any failure into an empty list or a null. A 503 from a Worker
  /// with no key, a Last.fm rate limit, a route that was never deployed — all
  /// three look identical from the outside, which is blank bios and missing
  /// similar artists with nothing to explain them. This session already found one
  /// Last.fm method that had been dead for its whole life; it was found by reading
  /// the Worker, not from the app, because the app never said a word.
  ///
  /// Logged here because every request passes through this one method. The Last.fm
  /// method name is safe to print — it is `artist.getInfo`, not a credential, and
  /// no key is ever on this URL (the Worker adds it).
  /// The timeout is the CALLER's, applied here rather than around this call:
  /// a `.timeout()` on the outside throws outside the try below, so the most
  /// likely failure of all — a slow or unreachable Worker — was the one this
  /// could not see.
  Future<http.Response> _get(Uri uri,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final method = uri.queryParameters['method'] ?? 'unknown';
    try {
      final resp = await _client.get(uri).timeout(timeout);
      if (resp.statusCode != 200) {
        _noteFailure(method, 'HTTP ${resp.statusCode}');
      } else if (_failures.containsKey(method)) {
        // Worth one line: it tells a reader the outage ENDED, which a silence
        // cannot. Without it a transcript shows a failure and then nothing, and
        // "nothing" reads the same as "still broken".
        print('last.fm $method recovered after '
            '${_failures.remove(method)} failure(s)');
      }
      return resp;
    } catch (e) {
      _noteFailure(method, e.toString().split('\n').first);
      rethrow;
    }
  }

  /// Failures per Last.fm method this session.
  static final Map<String, int> _failures = {};

  /// Says it on the first failure and then sparingly. A Worker with no key fails
  /// EVERY call, so a line per failure would be hundreds of identical lines —
  /// which is how the 615-line re-resolve loop nearly hid in plain sight.
  static void _noteFailure(String method, String why) {
    final n = (_failures[method] ?? 0) + 1;
    _failures[method] = n;
    if (n == 1 || n % 20 == 0) {
      print('WARN: last.fm $method failed ($why) — attempt $n this session; '
          'bios / similar artists / top tracks degrade silently to empty');
    }
  }


  Uri _buildUri(Map<String, String> params) {
    // No `api_key` and no `format`: the Worker adds both, and ignores them if a
    // caller sends them anyway. Nothing secret leaves this device.
    return Uri.parse(_baseUrl).replace(queryParameters: params);
  }

  String _extractImage(dynamic images) {
    if (images is! List || images.isEmpty) return '';
    const preferredSizes = ['mega', 'extralarge', 'large', 'medium', 'small'];
    for (final size in preferredSizes) {
      for (final img in images) {
        if (img['size'] == size) {
          final url = img['#text'] as String? ?? '';
          if (url.isNotEmpty && !url.endsWith('2a96cbd8b46e442fc41c2b86b821562f.png')) {
            return url;
          }
        }
      }
    }
    return '';
  }

  /// Normalise Last.fm listener count to a 0–100 popularity score.
  int _toPop(dynamic listeners) {
    final n = int.tryParse(listeners?.toString() ?? '0') ?? 0;
    // 10 million listeners → 100 score, linear below
    return (n / 100000).clamp(0, 100).toInt();
  }

  // Public API

  /// Search for tracks or artists.
  /// Used as the first waterfall step in SearchService.
  Future<List<Song>> search(String query, String type, {int limit = 50}) async {
    try {
      final isArtist = type == 'artist';
      final uri = _buildUri({
        'method': isArtist ? 'artist.search' : 'track.search',
        isArtist ? 'artist' : 'track': query,
        'limit': limit.toString(),
      });

      final response =
          await _get(uri, timeout: const Duration(seconds: 5));
      if (response.statusCode != 200) return [];

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      if (isArtist) {
        final artists =
            body['results']?['artistmatches']?['artist'] as List? ?? [];
        return artists
            .where((a) => (a['name'] as String?)?.isNotEmpty == true)
            .map((a) => Song(
                  id: 'artist_lfm_${Uri.encodeComponent(a['name'])}',
                  title: a['name'] as String,
                  artist: 'Artist',
                  image: _extractImage(a['image']),
                  popularity: _toPop(a['listeners']),
                ))
            .toList();
      } else {
        final tracks =
            body['results']?['trackmatches']?['track'] as List? ?? [];
        return tracks
            .where((t) =>
                (t['name'] as String?)?.isNotEmpty == true &&
                (t['artist'] as String?)?.isNotEmpty == true)
            .map((t) => Song(
                  id: 'track_lfm_${Uri.encodeComponent(t['name'])}_${Uri.encodeComponent(t['artist'])}',
                  title: t['name'] as String,
                  artist: t['artist'] as String,
                  image: _extractImage(t['image']),
                  popularity: _toPop(t['listeners']),
                ))
            .toList();
      }
    } catch (_) {
      return [];
    }
  }

  /// Get artist info by name.
  Future<Song?> getArtistByName(String artistName) async {
    if (artistName.trim().isEmpty) return null;
    try {
      final uri = _buildUri({
        'method': 'artist.getInfo',
        'artist': artistName,
        'autocorrect': '1',
      });
      final response =
          await _get(uri, timeout: const Duration(seconds: 5));
      if (response.statusCode != 200) return null;

      final data =
          (jsonDecode(response.body) as Map)['artist'] as Map<String, dynamic>?;
      if (data == null || data['error'] != null) return null;

      return Song(
        id: 'artist_lfm_${Uri.encodeComponent(data['name'] ?? artistName)}',
        title: data['name'] as String? ?? artistName,
        artist: 'Artist',
        image: _extractImage(data['image']),
        popularity:
            _toPop((data['stats'] as Map?)?['listeners']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Artist biography (plain text) via artist.getInfo. Returns null for
  /// missing bios and Last.fm's "This is not an artist" placeholders.
  Future<String?> getArtistBio(String artistName) async {
    if (artistName.trim().isEmpty) return null;
    try {
      final uri = _buildUri({
        'method': 'artist.getInfo',
        'artist': artistName,
        'autocorrect': '1',
      });
      final response =
          await _get(uri, timeout: const Duration(seconds: 6));
      if (response.statusCode != 200) return null;

      final artist =
          (jsonDecode(response.body) as Map)['artist'] as Map<String, dynamic>?;
      final bioMap = artist?['bio'] as Map?;
      final raw = (bioMap?['content'] ?? bioMap?['summary'] ?? '').toString();
      if (raw.isEmpty) return null;

      var bio = raw
          // "Read more on Last.fm" anchor + license boilerplate tail.
          .split('User-contributed text').first
          .replaceAll(RegExp(r'<a href[^>]*>.*?</a>\.?', dotAll: true), '')
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (bio.length < 60) return null;
      if (bio.toLowerCase().startsWith('this is not an artist')) return null;
      return bio;
    } catch (_) {
      return null;
    }
  }

  /// Get artist's top tracks by name.
  /// Significantly better than Deezer for emerging/niche artists.
  Future<List<Song>> getArtistTopTracks(String artistName,
      {int limit = 50}) async {
    if (artistName.trim().isEmpty) return [];
    try {
      final uri = _buildUri({
        'method': 'artist.getTopTracks',
        'artist': artistName,
        'autocorrect': '1',
        'limit': limit.toString(),
      });
      final response =
          await _get(uri, timeout: const Duration(seconds: 5));
      if (response.statusCode != 200) return [];

      final tracks = ((jsonDecode(response.body) as Map)['toptracks']
              ?['track'] as List?) ??
          [];

      return tracks
          .where((t) => (t['name'] as String?)?.isNotEmpty == true)
          .map((t) => Song(
                id: 'track_lfm_${Uri.encodeComponent(t['name'])}_${Uri.encodeComponent(artistName)}',
                title: t['name'] as String,
                artist: artistName,
                // Track images are deprecated on Last.fm; Deezer will fill
                // these in when images are needed via the UI layer.
                image: '',
                popularity: _toPop(t['listeners']),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Song>> getSimilarTracks(String trackName, String artistName,
    {int limit = 20}) async {
  if (trackName.trim().isEmpty || artistName.trim().isEmpty) return [];
  try {
    final uri = _buildUri({
      'method': 'track.getSimilar',
      'track': trackName,
      'artist': artistName,
      'autocorrect': '1',
      'limit': limit.toString(),
    });

    final response = await _get(uri, timeout: const Duration(seconds: 5));
    if (response.statusCode != 200) return [];

    final rawTracks =
        ((jsonDecode(response.body) as Map)['similartracks']?['track']
                as List?) ??
            [];

    return rawTracks
        .where((t) =>
            (t['name'] as String?)?.isNotEmpty == true &&
            (t['artist'] as Map?)?['name'] != null)
        .map((t) => Song(
              id: 'track_lfm_${Uri.encodeComponent(t['name'])}_${Uri.encodeComponent(t['artist']['name'])}',
              title: t['name'] as String,
              artist: t['artist']['name'] as String,
              image: '',
              popularity: _toPop(t['match']),
            ))
        .toList();
  } catch (_) {
    return [];
  }
}

  /// Get similar artists — Last.fm's similarity engine is genuinely excellent.
  /// This is the primary advantage over Spotify's related artists.
  ///
  /// [artistName] — plain artist name OR a Last.fm ID (artist_lfm_...) OR
  ///               a Deezer ID (artist_1234 — returns [] so Deezer handles it).
  Future<List<Song>> getSimilarArtists(String artistNameOrId,
      {int limit = 12}) async {
    final name = _resolveArtistName(artistNameOrId);
    if (name == null) return []; // Deezer numeric ID — let Deezer handle it

    try {
      final uri = _buildUri({
        'method': 'artist.getSimilar',
        'artist': name,
        'autocorrect': '1',
        'limit': limit.toString(),
      });
      final response =
          await _get(uri, timeout: const Duration(seconds: 5));
      if (response.statusCode != 200) return [];

      final artists =
          ((jsonDecode(response.body) as Map)['similarartists']?['artist']
                  as List?) ??
              [];

      return artists
          .where((a) => (a['name'] as String?)?.isNotEmpty == true)
          .map((a) {
        final match = double.tryParse(a['match']?.toString() ?? '0') ?? 0.0;
        return Song(
          id: 'artist_lfm_${Uri.encodeComponent(a['name'])}',
          title: a['name'] as String,
          artist: 'Artist',
          image: _extractImage(a['image']),
          // match is a 0.0–1.0 similarity score from Last.fm
          popularity: (match * 100).toInt().clamp(0, 100),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Real-time global chart — replaces Spotify's curated top hits.
  Future<List<Song>> getChartTopTracks({int limit = 50}) async {
    try {
      final uri = _buildUri({
        'method': 'chart.getTopTracks',
        'limit': limit.toString(),
      });
      final response =
          await _get(uri, timeout: const Duration(seconds: 5));
      if (response.statusCode != 200) return [];

      final tracks = ((jsonDecode(response.body) as Map)['tracks']?['track']
              as List?) ??
          [];

      return tracks
          .where((t) =>
              (t['name'] as String?)?.isNotEmpty == true &&
              (t['artist'] as Map?)?['name'] != null)
          .map((t) => Song(
                id: 'track_lfm_${Uri.encodeComponent(t['name'])}_${Uri.encodeComponent(t['artist']['name'])}',
                title: t['name'] as String,
                artist: t['artist']['name'] as String,
                image: '',
                popularity: _toPop(t['listeners']),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Genre tags for an ARTIST. Ask this before [getTrackTags].
  ///
  /// Track tags are sparse, artist tags are NOT
  ///
  /// The genre learner caches its answer PER ARTIST, so asking about one track
  /// was the wrong question: plenty of individual tracks carry no tags at all
  /// even when their artist is thoroughly tagged, and an empty answer was then
  /// stored as "this artist has no genres" for good. Caught on device —
  /// `genres learned for "Major Lazer": none known`, for an artist Last.fm has
  /// dancehall, moombahton and electronic on.
  Future<List<String>> getArtistTags(String artistName) =>
      _topTags({
        'method': 'artist.getTopTags',
        'artist': artistName,
        'autocorrect': '1',
      });

  /// Genre tags for one TRACK. The narrower fallback when the artist has none.
  Future<List<String>> getTrackTags(String trackName, String artistName) =>
      _topTags({
        'method': 'track.getTopTags',
        'track': trackName,
        'artist': artistName,
        'autocorrect': '1',
      });

  /// Shared for both: `artist.getTopTags` and `track.getTopTags` return the
  /// identical `toptags.tag[]` shape, so the parsing and the junk list live once.
  Future<List<String>> _topTags(Map<String, String> params) async {
    try {
      final response =
          await _get(_buildUri(params), timeout: const Duration(seconds: 4));
      if (response.statusCode != 200) return [];

      final tags =
          ((jsonDecode(response.body) as Map)['toptags']?['tag'] as List?) ??
              [];

      // Top 5, lowercased. This drops only the tags that are junk for ANY
      // consumer; deciding what counts as a genre is the caller's job — see
      // IntelligenceNotifier.isGenreLikeTag, which also has the artist name to
      // compare against.
      final junk = {'seen live', 'favorites', 'favourite', 'love', 'awesome'};
      return tags
          .take(10)
          .map((t) => (t['name'] as String? ?? '').toLowerCase().trim())
          .where((t) => t.isNotEmpty && !junk.contains(t))
          .take(5)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // Three stubs lived here — getAlbumTracks, getPlaylistTracks and
  // getArtistDiscography, each  with a comment saying Deezer
  // handles it. REMOVED: nothing called any of them, and callers that look like
  // they might (search_page, playlist_page, library_provider) go to SearchService
  // or ExternalCatalogService, which implement them for real. An empty stub named
  // after a working feature is a trap for whoever greps for the name next.

  // Private helpers

  /// Resolves various ID formats to a plain artist name for Last.fm calls.
  ///
  ///   "artist_lfm_The+Weeknd"  → "The Weeknd"   (Last.fm ID)
  ///   "The Weeknd"             → "The Weeknd"   (plain name)
  ///   "artist_12345"           → null            (Deezer numeric ID — skip)
  ///   "spotify:artist:xyz"     → null            (legacy Spotify ID — skip)
  String? _resolveArtistName(String input) {
    if (input.startsWith('artist_lfm_')) {
      return Uri.decodeComponent(input.replaceFirst('artist_lfm_', ''));
    }
    if (input.startsWith('spotify:') || input.startsWith('artist_spotify:')) {
      return null;
    }
    // Deezer numeric ID: "artist_12345" or plain "12345"
    final stripped = input.startsWith('artist_') ? input.split('_').last : input;
    if (int.tryParse(stripped) != null) return null;

    // Plain name (e.g., passed directly from home_provider)
    return input.isNotEmpty ? input : null;
  }
}