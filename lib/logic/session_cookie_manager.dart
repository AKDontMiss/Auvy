import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:crypto/crypto.dart';

/// The single app-wide secure-storage instance; every caller (here and in
/// account_provider) must use it. The Android options that decide how the plugin
/// encrypts, and whether it migrates or wipes the store on a perceived mismatch,
/// are pinned instead of left to plugin defaults:
///
///  • resetOnError: false. The plugin default lets any transient keystore error
///    delete the key or the whole store. With it off, errors reach us and we
///    degrade gracefully instead of losing secrets.
///  • cipher pair: pinned to what the current plugin writes (RSA-OAEP-wrapped key
///    + AES-GCM data). If the stored algorithm markers ever differ from the
///    configured pair, the plugin re-keys the store; pinning keeps a future
///    default change from triggering that.
///  • migrateOnAlgorithmChange: true, so a mismatch migrates data rather than
///    failing or wiping it.
///
/// Do not set `iOptions.accessibility`; doing so signs the user out.
///
/// The plugin puts `kSecAttrAccessible` into the query for reads as well as
/// writes, and the keychain treats it as a matching attribute. An item stored
/// under the old accessibility then no longer matches, the read returns null,
/// and `_getEncrypter` takes that as an empty key slot and generates a new key.
/// Every stored `v2:` blob becomes unreadable and the user lands back on
/// sign-in. Changing it would need a real migration (read with the old
/// attribute, then re-write). It isn't needed today: the key is read once at
/// startup, in the foreground, and cached in `_encrypter`.
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    resetOnError: false,
    migrateOnAlgorithmChange: true,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);

/// Stores the YouTube sign-in cookies, encrypted, and answers "is there still a
/// session?".
///
/// Sign-in leaves the app holding real Google session cookies, the most
/// sensitive data it has, so they are encrypted with a key kept in the platform
/// keystore (Android Keystore / iOS Keychain) rather than stored as plain text.
///
/// A signed-in session gives access to the user's library and recommendations
/// and fewer refusals when resolving streams. `sapisidFrom` extracts the value
/// used to sign API requests.
///
/// Nothing here is ever logged, not even a length. `_salvageLegacyCipher` reads
/// values written by an older build once, so updating never forces a new
/// sign-in.
class SessionCookieManager {
  static final SessionCookieManager _instance = SessionCookieManager._internal();
  factory SessionCookieManager() => _instance;
  SessionCookieManager._internal();

  static const String _cookieKey = 'yt_cookies_encrypted';
  static const String _lastValidatedKey = 'yt_cookies_last_validated';
  static const String _visitorDataKey = 'yt_visitor_data';
  static const String _poTokenKey = 'yt_po_token';
  static const String _aesKeyStorageName = 'auvy_yt_aes_key'; // Secure storage key name
  // Set once the user completes a YouTube sign-in and cleared only by signing
  // out. Kept in plain prefs on purpose: it holds no secret and must survive
  // secure-storage hiccups, so a failed cookie read never brings back the login
  // page.
  static const String _sessionActiveKey = 'yt_session_active';

  static const _secureStorage = appSecureStorage;

  Map<String, String>? _cachedCookies;
  encrypt.Encrypter? _encrypter;

  /// Returns the device's 32-byte encryption key, creating it on first use.
  Future<encrypt.Encrypter> _getEncrypter() async {
    if (_encrypter != null) return _encrypter!;

    String? base64Key;
    try {
      base64Key = await _secureStorage.read(key: _aesKeyStorageName);
    } catch (e) {
      // Transient keystore or plugin failure. The stored key may still be intact,
      // and writing a new one now would orphan every encrypted blob for good. Fail
      // this launch instead: loadCookies() keeps the blob and serves defaults,
      // saveCookies() skips, and the session marker keeps the login page away. The
      // next launch retries with the untouched key.
      print('ALERT: Secure-storage read failed (${e.runtimeType}: $e) — '
          'NOT re-keying; cookie crypto unavailable this launch');
      rethrow;
    }

    if (base64Key == null) {
      // The key slot is genuinely empty. If an encrypted blob still exists it can
      // never be decrypted again, so say so in the log before creating a new key.
      final prefs = await SharedPreferences.getInstance();
      final orphan = prefs.getString(_cookieKey);
      if (orphan != null && orphan.startsWith('v2:')) {
        print('ALERT: AES key missing from secure storage but an encrypted cookie '
            'blob exists — the old blob is unrecoverable. Generating a fresh '
            'key; session rehydrates from the WebView jar (sticky login kept).');
      }
      // Generate a new random 32-byte key.
      final secureKey = encrypt.Key.fromSecureRandom(32);
      base64Key = secureKey.base64;
      await _secureStorage.write(key: _aesKeyStorageName, value: base64Key);
    }

    final key = encrypt.Key.fromBase64(base64Key);
    _encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    return _encrypter!;
  }

  // Format: "v2:<iv_b64>:<cipher_b64>", a fresh random IV per encryption stored
  // with the ciphertext. The old format used `IV.fromLength(16)`, which is a new
  // random IV per process, so blobs could not be decrypted after a restart and
  // users were asked to sign in again every few days.

  Future<String> _encryptString(String plain) async {
    final encrypter = await _getEncrypter();
    final iv = encrypt.IV.fromSecureRandom(16);
    final cipher = encrypter.encrypt(plain, iv: iv);
    return 'v2:${iv.base64}:${cipher.base64}';
  }

  /// Decrypts a v2 payload. Throws on anything else (callers handle legacy data).
  Future<String> _decryptString(String stored) async {
    if (!stored.startsWith('v2:')) throw const FormatException('not v2');
    final sep = stored.indexOf(':', 3);
    if (sep < 0) throw const FormatException('bad v2 payload');
    final iv = encrypt.IV.fromBase64(stored.substring(3, sep));
    final cipher = encrypt.Encrypted.fromBase64(stored.substring(sep + 1));
    final encrypter = await _getEncrypter();
    return encrypter.decrypt(cipher, iv: iv);
  }

  /// Best-effort recovery of a legacy blob whose random IV was lost. In AES-CBC a
  /// wrong IV only garbles the first 16-byte block, so we drop everything up to
  /// the first intact `","` boundary of the JSON map and re-open the object,
  /// losing at most one cookie.
  Future<Map<String, String>?> _salvageLegacyCipher(String stored) async {
    try {
      final encrypter = await _getEncrypter();
      final cipher = encrypt.Encrypted.fromBase64(stored);
      // Any IV works since only block 0 is affected; allowMalformed absorbs the
      // garbage bytes.
      final raw = encrypter.decrypt(cipher, iv: encrypt.IV.fromSecureRandom(16));
      final cut = raw.indexOf('","');
      if (cut < 0 || cut + 3 >= raw.length) return null;
      final Map<String, dynamic> json = jsonDecode('{"${raw.substring(cut + 3)}');
      final map = Map<String, String>.from(json);
      return map.isEmpty ? null : map;
    } catch (_) {
      return null;
    }
  }

  /// The value used to sign authenticated InnerTube requests (SAPISIDHASH).
  ///
  /// Google issues it under several names, and which ones a sign-in captures
  /// depends on the domain and cookie partitioning. Reading only `SAPISID` left a
  /// session holding just `__Secure-3PAPISID` without an auth header, so the app
  /// showed "Guest" after a successful sign-in. The Worker accepts the same set.
  static String? sapisidFrom(Map<String, String> cookies) =>
      cookies['SAPISID'] ??
      cookies['__Secure-3PAPISID'] ??
      cookies['__Secure-1PAPISID'];

  /// Whether this cookie jar is signed in. Accepts the SAPISID family as well as
  /// the SID family: requests are signed with the SAPISID value, so a jar holding
  /// it is usable even without `SID`.
  static bool _containsAuthCookie(Map<String, String> cookies) =>
      cookies.containsKey('SID') ||
      cookies.containsKey('SSID') ||
      cookies.containsKey('__Secure-3PSID') ||
      cookies.containsKey('__Secure-1PSID') ||
      sapisidFrom(cookies) != null;

  /// True when the user signed in at some point and has not signed out since.
  /// Deliberately independent of whether the cookie blob is readable right now,
  /// so a transient storage failure never sends a signed-in user to the login
  /// page.
  Future<bool> hasPersistentSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_sessionActiveKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markSessionActive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sessionActiveKey, true);
      // A successful sign-in clears the sign-out flag, or every future session would
      // stay locked out.
      await prefs.remove(_signedOutKey);
    } catch (_) {}
  }

  /// Set when the user signs out, cleared only by a successful sign-in.
  ///
  /// `clearCookies()` also empties the platform cookie store, but that finishes
  /// asynchronously. For a moment after logout the store can still return live
  /// auth cookies, and `SessionAuthService.ensureSession()`, whose job is to
  /// recover sessions from that store, would sign the user straight back in.
  ///
  /// The race is inside the platform, so clearing harder cannot fix it. Recording
  /// that the user chose to sign out can: `ensureSession()` checks this first and
  /// refuses to re-import.
  static const String _signedOutKey = 'yt_signed_out';

  Future<bool> hasExplicitlySignedOut() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_signedOutKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Parses cookies from Netscape (tab-separated), `k=v; k=v` header, or JSON text.
  Map<String, String> parseCookies(String rawCookies) {
    final Map<String, String> cookies = {};

    try {
      final json = jsonDecode(rawCookies);
      if (json is List) {
        for (var cookie in json) {
          if (cookie['name'] != null && cookie['value'] != null) {
            cookies[cookie['name']] = cookie['value'];
          }
        }
      } else if (json is Map) {
        cookies.addAll(Map<String, String>.from(json));
      }
    } catch (e) {
      // Netscape format or plain text, line by line.
      final lines = rawCookies.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;

        // Tab-separated (Netscape format).
        if (line.contains('\t')) {
          final parts = line.split('\t');
          if (parts.length >= 7) {
            cookies[parts[5]] = parts[6];
          }
        } else {
          // Semicolon-separated. Split on the first '=' only: values often contain '='
          // (base64 padding in __Secure-1PSIDCC, LOGIN_INFO, …).
          final pairs = line.split(';');
          for (var pair in pairs) {
            final p = pair.trim();
            final i = p.indexOf('=');
            if (i > 0) {
              cookies[p.substring(0, i).trim()] = p.substring(i + 1).trim();
            }
          }
        }
      }
    }

    return cookies;
  }

  Future<void> saveCookies(Map<String, String> cookies) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // v2 format with the random IV stored alongside, so the blob survives restarts
      // (see _encryptString).
      final payload = await _encryptString(jsonEncode(cookies));
      await prefs.setString(_cookieKey, payload);
      await prefs.setInt(_lastValidatedKey, DateTime.now().millisecondsSinceEpoch);
      _cachedCookies = cookies;
      // A signed-in session was saved: remember it so the login page stays away until
      // the user signs out.
      if (_containsAuthCookie(cookies)) await _markSessionActive();
      print("OK: Saved ${cookies.length} YouTube cookies (encrypted)");
    } catch (e) {
      print("ERROR: Failed to save cookies: $e");
    }
  }

  /// Encrypts and stores the SAPISID value (the SAPISIDHASH signing key).
  Future<void> _saveSapisid(SharedPreferences prefs, String sapisid) async {
    try {
      await prefs.setString('yt_sapisid', await _encryptString(sapisid));
    } catch (e) {
      print("ERROR: Failed to save SAPISID: $e");
    }
  }

  /// Reads the stored SAPISID. Only the v2 format is trusted; legacy values could
  /// not be decrypted reliably, so they are dropped and re-saved on the next cookie
  /// import.
  Future<String?> _readSapisid(SharedPreferences prefs) async {
    final stored = prefs.getString('yt_sapisid');
    if (stored == null) return null;
    try {
      return await _decryptString(stored);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>?> loadCookies() async {
    if (_cachedCookies != null) return _cachedCookies;

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_cookieKey);

      if (stored == null) {
        print("No user cookies found - loading defaults");
        _cachedCookies = await _loadDefaultCookiesFromAsset();
        return _cachedCookies;
      }

      // Current v2 format first.
      try {
        final decrypted = await _decryptString(stored);
        final Map<String, dynamic> json = jsonDecode(decrypted);
        _cachedCookies = Map<String, String>.from(json);
      } catch (_) {
        // Legacy 1: plaintext JSON from installs that predate encryption.
        try {
          final Map<String, dynamic> json = jsonDecode(stored);
          _cachedCookies = Map<String, String>.from(json);
          await saveCookies(_cachedCookies!); // migrate → v2
        } catch (_) {
          // Legacy 2: old ciphertext with a lost IV; salvage everything after the first
          // block (see _salvageLegacyCipher).
          final salvaged = await _salvageLegacyCipher(stored);
          if (salvaged != null) {
            print("Recovered ${salvaged.length} cookies from legacy blob");
            await saveCookies(salvaged); // migrate → v2
            _cachedCookies = salvaged;
          } else {
            // Unreadable. Keep the blob rather than delete it, so a transient keystore
            // failure doesn't become a permanent logout. The next successful import
            // overwrites it.
            print("WARN: Cookie blob unreadable this launch — keeping it and using defaults");
            _cachedCookies = await _loadDefaultCookiesFromAsset();
            return _cachedCookies;
          }
        }
      }

      return _cachedCookies;
    } catch (e) {
      print("WARN: Error loading cookies: $e");
      return await _loadDefaultCookiesFromAsset();
    }
  }

  Future<Map<String, String>> _loadDefaultCookiesFromAsset() async {
    return {};
  }

  /// `Authorization` header for an authenticated InnerTube call:
  /// `SAPISIDHASH <ts>_<sha1(ts + " " + value + " " + origin)>`.
  ///
  /// Always the single `SAPISIDHASH` label, whichever *APISID cookie supplied the
  /// value. Per-cookie labels (SAPISID1PHASH / SAPISID3PHASH) were tried and every
  /// account started failing with 403, so do not "correct" this. The tolerant value
  /// lookup ([sapisidFrom]) is still needed, because a session may carry only the
  /// partitioned variant.
  Future<String?> getAuthorizationHeader(String origin) async {
    final cookies = await loadCookies();
    String? value = cookies == null ? null : sapisidFrom(cookies);

    // Nothing usable in the jar: fall back to the separately stored SAPISID.
    if (value == null || value.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      value = await _readSapisid(prefs);
    }
    if (value == null || value.isEmpty) return null;

    final int timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String hash =
        sha1.convert(utf8.encode('$timestamp $value $origin')).toString();
    return 'SAPISIDHASH ${timestamp}_$hash';
  }

  Future<String?> getCookieHeader() async {
    final cookies = await loadCookies();
    if (cookies == null || cookies.isEmpty) return null;

    return cookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  Future<void> clearCookies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cookieKey);
    await prefs.remove(_lastValidatedKey);
    // Visitor data and PO token are no longer stored; remove values older
    // builds left behind.
    await prefs.remove(_visitorDataKey);
    await prefs.remove(_poTokenKey);
    await prefs.remove('yt_sapisid');
    // Explicit sign-out is the only place the "signed in" marker is cleared, which
    // lets the login page appear again.
    await prefs.remove(_sessionActiveKey);
    // Record the sign-out itself; that is what keeps the user out while the
    // platform cookie store finishes emptying. See _signedOutKey.
    await prefs.setBool(_signedOutKey, true);
    _cachedCookies = null;
    // Also clear the platform cookie store, which holds the real HttpOnly auth
    // cookies (SID / __Secure-3PSID). Otherwise logout or account deletion wiped
    // only our copy, and ensureSession() re-imported the surviving session.
    try {
      await WebViewCookieManager().clearCookies();
    } catch (e) {
      print("WARN: WebView cookie jar clear failed: $e");
    }
    print("Cleared YouTube cookies and tokens (incl. WebView jar)");
  }

  Future<bool> hasAuthCookies() async {
    final cookies = await loadCookies();
    if (cookies == null) return false;

    return _containsAuthCookie(cookies);
  }

  Future<void> setSessionDataFromWebView({
    required String rawCookieString,
  }) async {
    try {
      // 1. Parse and save the cookies (encrypted).
      final cookies = parseCookies(rawCookieString);
      if (cookies.isNotEmpty) {
        await saveCookies(cookies);
      }

      final prefs = await SharedPreferences.getInstance();

      // Keep the SAPISIDHASH fallback source in sync with the fresh session.
      final sapisid = sapisidFrom(cookies);
      if (sapisid != null) await _saveSapisid(prefs, sapisid);

      // 2. Drop the cache and reload from storage.
      _cachedCookies = null;
      await loadCookies();
      print("Automated Login: Session Synced Successfully");

    } catch (e) {
      print("ERROR: Session Sync Error: $e");
    }
  }

}
