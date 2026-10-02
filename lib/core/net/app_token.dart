import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/logic/session_cookie_manager.dart' show appSecureStorage;

/// A short-lived token proving this install passed the approval gate.
///
/// The Worker's proxy routes (Last.fm, lyrics, radio, podcasts, audiobooks)
/// accept it as the `X-Auvy-Token` header, so someone who only knows the Worker's
/// hostname cannot use them. It is issued on an approved sign-in, expires after
/// 7 days and holds no secret (the uid inside is already a salted hash).
///
/// The Worker only enforces it when `REQUIRE_APP_TOKEN` is set, so clients can
/// send it before enforcement is switched on.
class AuvyAppToken {
  const AuvyAppToken._();

  static const String _key = 'auvy_app_token';
  static String? _cached;
  /// Bumped by every [set], so a [load] still reading cannot overwrite a newer
  /// value (including a `set(null)` after a denial).
  static int _generation = 0;

  /// Kept in memory so adding the header never waits on storage.
  static String? get value => _cached;

  /// Loads the token from secure storage (keychain / keystore), moving a copy left
  /// in SharedPreferences by older builds.
  ///
  /// Any failure just means "no token": the next approved sign-in issues a new one.
  static Future<void> load() async {
    final startedAt = _generation;
    String? token;
    try {
      token = await appSecureStorage.read(key: _key);
    } catch (_) {
      token = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_key);
      if (legacy != null) {
        if (token == null && legacy.isNotEmpty) {
          token = legacy;
          await appSecureStorage.write(key: _key, value: legacy);
        }
        await prefs.remove(_key);
      }
    } catch (_) {
      // A failed move leaves the legacy copy in place for the next launch.
    }
    // A set() that raced this load wins: it is the newer verdict.
    if (_generation != startedAt) return;
    _cached = (token != null && token.isNotEmpty) ? token : null;
  }

  static Future<void> set(String? token) async {
    _generation++;
    _cached = (token != null && token.isNotEmpty) ? token : null;
    try {
      if (_cached == null) {
        await appSecureStorage.delete(key: _key);
      } else {
        await appSecureStorage.write(key: _key, value: _cached!);
      }
    } catch (_) {
      // In-memory is enough for this session; the next sign-in reissues it.
    }
    try {
      (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  /// The header to attach, or `{}` when there is nothing to prove yet.
  static Map<String, String> get header =>
      _cached == null ? const {} : {'X-Auvy-Token': _cached!};
}
