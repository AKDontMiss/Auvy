import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/session_cookie_manager.dart' show appSecureStorage;
import 'package:auvy/services/http_pool.dart';

/// Scrobbling to **ListenBrainz** — MusicBrainz's open listening history.
///
/// WHY LISTENBRAINZ AND NOT LAST.FM. Auvy already talks to Last.fm, but only for
/// METADATA (artist bios, similar tracks, charts, tags) — there was never any
/// scrobbling in the app. Adding it would mean the full Last.fm auth dance
/// (api_sig MD5 signing over sorted params, a session token flow) plus an API
/// secret that would have to ship inside the APK, where anyone can extract it.
/// ListenBrainz needs one user token, no signing, no shared secret, and the
/// listening history it builds belongs to the user rather than to a company —
/// which is the same reason Spotube chose it.
///
/// OFF unless a token is entered. No token, no requests, nothing recorded
/// anywhere: this sends what you listen to to a third party, so it can only ever
/// be something the user switched on deliberately.
class ScrobbleService {
  ScrobbleService._();
  static final ScrobbleService instance = ScrobbleService._();

  static const String _endpoint = 'https://api.listenbrainz.org/1/submit-listens';
  static const String _validate = 'https://api.listenbrainz.org/1/validate-token';

  /// Secure storage, not SharedPreferences: this is a credential that can write
  /// to someone's account. Same store the YouTube cookies use.
  static const String _kToken = 'auvy_listenbrainz_token';

  String? _token;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _token = await appSecureStorage.read(key: _kToken);
    } catch (_) {
      _token = null;
    }
  }

  bool get isEnabled => (_token ?? '').isNotEmpty;

  Future<String?> readToken() async {
    await ensureLoaded();
    return _token;
  }

  Future<void> setToken(String? token) async {
    final t = token?.trim();
    _token = (t == null || t.isEmpty) ? null : t;
    _loaded = true;
    try {
      if (_token == null) {
        await appSecureStorage.delete(key: _kToken);
      } else {
        await appSecureStorage.write(key: _kToken, value: _token!);
      }
    } catch (_) {}
  }

  /// Check a token before saving it, so a typo surfaces immediately instead of
  /// silently dropping every listen. Returns the user name on success.
  Future<String?> validate(String token) async {
    if (token.trim().isEmpty) return null;
    try {
      final r = await HttpPool().getClient().get(
        Uri.parse(_validate),
        headers: {'Authorization': 'Token ${token.trim()}'},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['valid'] == true) return (j['user_name'] ?? '').toString();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// A completed listen, submitted once the play has passed Auvy's listen
  /// threshold (see the position handler in player_system).
  ///
  /// `listened_at` is the START of the listen, which is what ListenBrainz
  /// expects — not the moment the threshold was crossed. Passing the crossing
  /// time would file every listen ~30s late and misorder tracks played back to
  /// back.
  Future<void> submitListen(Song song, {DateTime? startedAt}) =>
      _post(song, playingNow: false, startedAt: startedAt);

  /// Optional "playing now" ping. Not persisted by ListenBrainz — it only
  /// populates the user's now-playing panel and expires on its own.
  Future<void> submitPlayingNow(Song song) => _post(song, playingNow: true);

  Future<void> _post(Song song, {required bool playingNow, DateTime? startedAt}) async {
    await ensureLoaded();
    final token = _token;
    if (token == null || token.isEmpty) return;

    // Radio streams and podcasts are not tracks in a music history, and local
    // files often have no usable artist — a listen with an empty artist is
    // rejected by the API anyway, so it is filtered here rather than sent.
    final artist = song.displayArtist.trim();
    final title = song.title.trim();
    if (title.isEmpty || artist.isEmpty) return;
    if (song.id.startsWith('http')) return;

    final meta = <String, dynamic>{
      'artist_name': artist,
      'track_name': title,
      if (song.albumTitle.trim().isNotEmpty &&
          song.albumTitle.trim().toLowerCase() != 'podcast')
        'release_name': song.albumTitle.trim(),
      'additional_info': {
        'media_player': 'Auvy',
        'submission_client': 'Auvy',
        'music_service': 'youtube.com',
        // The video id, so a listen can be traced back to what was played.
        'origin_url': 'https://music.youtube.com/watch?v=${song.id}',
      },
    };

    final payload = <String, dynamic>{'track_metadata': meta};
    if (!playingNow) {
      payload['listened_at'] =
          (startedAt ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    }

    try {
      await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Token $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'listen_type': playingNow ? 'playing_now' : 'single',
              'payload': [payload],
            }),
          )
          .timeout(const Duration(seconds: 10));
      // Deliberately no retry queue and no error surfacing. A dropped scrobble is
      // a cosmetic loss; retrying in the background would mean persisting a queue
      // of everything the user listened to, which is more data at rest than the
      // feature is worth, and failures must never interrupt playback.
    } catch (_) {}
  }
}
