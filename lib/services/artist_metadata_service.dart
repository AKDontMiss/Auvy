// Artist metadata from Last.fm: similar artists, bios, top tracks, charts.
//
// There is no API key in the app. Every request goes to the Worker's /lastfm
// route, which holds the key and allows only read-only methods; if the Worker
// has no key it answers non-200 and every method here returns an empty result
// (see _get).
//
// Deezer covers what Last.fm doesn't: album and playlist tracks, artist
// discography and cover art.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/backend_config.dart';

class ArtistMetadataService {
  /// The Last.fm key is a Worker secret, never in the app. A key compiled into the
  /// binary (even via --dart-define) can be extracted by anyone with the APK, so
  /// there is deliberately no code path that could put one there. Rotating the
  /// key is a Worker secret update, not a new build.
  static String get _baseUrl => '${BackendConfig.workerBase}/lastfm';

  /// One shared client for every instance. This class is created at each call site
  /// (once per artist bio, once per recommendation pass), so a client per instance
  /// opened a new connection pool each time and never closed it.
  ///
  /// It is the pool's client (HttpPool), so this traffic is also counted in the
  /// data usage tracker. A getter rather than a `static final`, for the reason
  /// given on CatalogApiClient._http.
  static http.Client get _sharedClient => HttpPool().getClient();

  final http.Client? _injected;

  /// [client] stays injectable for tests; omitting it uses the pooled client
  /// rather than allocating a per-instance one.
  ArtistMetadataService([http.Client? client]) : _injected = client;

  http.Client get _client => _injected ?? _sharedClient;

  // Helpers

  /// Every Last.fm request goes through here. Callers treat non-200 as "no data",
  /// so a missing key, a rate limit or an undeployed route all degrade to blank
  /// bios and no similar artists; this is the one place that logs the reason. The
  /// method name is safe to print (e.g. `artist.getInfo`); the key is added by the
  /// Worker and never appears on this URL.
  ///
  /// The timeout is applied here, inside the try, so a slow or unreachable Worker
  /// is caught and logged like any other failure.
  Future<http.Response> _get(Uri uri,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final method = uri.queryParameters['method'] ?? 'unknown';
    try {
      final resp = await _client.get(uri).timeout(timeout);
      if (resp.statusCode != 200) {
        _noteFailure(method, 'HTTP ${resp.statusCode}');
      } else if (_failures.containsKey(method)) {
        // Log recovery too, so the log shows the outage ended.
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

  /// Similar artists from Last.fm's similarity data.
  ///
  /// [artistNameOrId] is a plain artist name, a Last.fm id (artist_lfm_...), or a
  /// Deezer id (artist_1234, which returns [] so Deezer handles it).
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

  /// Genre tags for an artist; ask this before [getTrackTags]. Many individual
  /// tracks have no tags even when their artist is well tagged, and the genre
  /// learner caches per artist, so asking about one track could store "no genres"
  /// for a well-tagged artist.
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

  /// Shared by `artist.getTopTags` and `track.getTopTags`, which return the same
  /// `toptags.tag[]` shape.
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


  // Private helpers

  /// Resolves various id formats to a plain artist name for Last.fm calls.
  ///
  ///   "artist_lfm_The+Weeknd"  → "The Weeknd"   (Last.fm id)
  ///   "The Weeknd"             → "The Weeknd"   (plain name)
  ///   "artist_12345"           → null            (Deezer numeric id, skip)
  ///   "spotify:artist:xyz"     → null            (legacy id, skip)
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