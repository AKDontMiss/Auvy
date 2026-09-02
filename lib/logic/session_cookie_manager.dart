import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:crypto/crypto.dart';

/// The ONE app-wide secure-storage instance — every call site (here and in
/// account_provider) MUST use it. Each Android option that decides how the
/// plugin encrypts — and, on a perceived mismatch, MIGRATES or WIPES — the
/// store is pinned explicitly instead of trusting plugin defaults:
///
///  • resetOnError: the v10 Dart-side default is TRUE, which lets ANY
///    transient Keystore/cipher error delete the failing key (or the entire
///    store) as "recovery". Pinned false: errors surface to us and we degrade
///    gracefully instead of losing secrets.
///  • cipher pair: pinned to exactly what v10 writes today (RSA-OAEP-wrapped
///    key + AES-GCM data). Seen live on device: v10 logs "Key mismatch
///    detected … Algorithm changed" whenever its stored algorithm markers
///    differ from the configured pair (it assumes v9-era defaults when the
///    markers are absent) and then re-keys the store. Pinning means a future
///    plugin-default change can never re-trigger that path against our data.
///  • migrateOnAlgorithmChange: today's default, pinned true — if a mismatch
///    does happen anyway, migrate the data rather than fail or wipe.
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    resetOnError: false,
    migrateOnAlgorithmChange: true,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);

/// Stores the YouTube sign-in cookies, encrypted, and answers "is there still
/// a session?".
///
/// Auvy signs in through a WebView, which leaves it holding real Google session
/// cookies. Those are the most sensitive thing in the app, so they are
/// encrypted with a key kept in Android's hardware-backed keystore rather than
/// written as plain text.
///
/// The cookies matter because YouTube serves a signed-in user differently:
/// their library, their recommendations, and fewer refusals when resolving a
/// stream. `sapisidFrom` extracts the one cookie needed to sign API requests.
///
/// Nothing here is ever logged, not even a length. _salvageLegacyCipher exists
/// because an older build stored these with a fixed encryption IV; it reads
/// those old values once so signing in again is not required after an update.
class SessionCookieManager {
  static final SessionCookieManager _instance = SessionCookieManager._internal();
  factory SessionCookieManager() => _instance;
  SessionCookieManager._internal();

  static const String _cookieKey = 'yt_cookies_encrypted';
  static const String _lastValidatedKey = 'yt_cookies_last_validated';
  static const String _visitorDataKey = 'yt_visitor_data';
  static const String _poTokenKey = 'yt_po_token';
  static const String _aesKeyStorageName = 'auvy_yt_aes_key'; // Secure storage key name
  // Sticky "the user completed a YouTube sign-in and never signed out" marker.
  // Lives in PLAIN prefs on purpose: it contains no secret (just routing state)
  // and must survive secure-storage/Keystore hiccups — it is what keeps the
  // login gate from ever re-appearing on a transient cookie-read failure.
  static const String _sessionActiveKey = 'yt_session_active';

  static const _secureStorage = appSecureStorage;

  Map<String, String>? _cachedCookies;
  String? _cachedVisitorData;
  String? _cachedPoToken;
  encrypt.Encrypter? _encrypter;

  ///  SECURE: Retrieves or generates a unique, hardware-backed 32-byte key per device
  Future<encrypt.Encrypter> _getEncrypter() async {
    if (_encrypter != null) return _encrypter!;

    String? base64Key;
    try {
      base64Key = await _secureStorage.read(key: _aesKeyStorageName);
    } catch (e) {
      // Transient Keystore/plugin failure (seen live: flutter_secure_storage
      // v10 "Key mismatch detected ... Algorithm changed"). The stored key may
      // still be intact — writing a fresh key NOW would overwrite it and
      // permanently orphan every v2 blob. Fail this launch instead:
      // loadCookies() keeps the blob and serves defaults, saveCookies() logs
      // and skips, and the sticky yt_session_active flag keeps the login gate
      // closed. Next launch retries with the untouched key.
      print('ALERT: Secure-storage read failed (${e.runtimeType}: $e) — '
          'NOT re-keying; cookie crypto unavailable this launch');
      rethrow;
    }

    if (base64Key == null) {
      // The key slot is genuinely empty. If an encrypted blob still exists it
      // can never be decrypted again (the store was wiped underneath us) —
      // say so loudly instead of silently re-keying past the evidence.
      final prefs = await SharedPreferences.getInstance();
      final orphan = prefs.getString(_cookieKey);
      if (orphan != null && orphan.startsWith('v2:')) {
        print('ALERT: AES key missing from secure storage but an encrypted cookie '
            'blob exists — the old blob is unrecoverable. Generating a fresh '
            'key; session rehydrates from the WebView jar (sticky login kept).');
      }
      // Generate a new cryptographically secure random 32-byte key
      final secureKey = encrypt.Key.fromSecureRandom(32);
      base64Key = secureKey.base64;
      await _secureStorage.write(key: _aesKeyStorageName, value: base64Key);
    }

    final key = encrypt.Key.fromBase64(base64Key);
    _encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    return _encrypter!;
  }

  // Encryption format
  // "v2:<iv_b64>:<cipher_b64>" — a fresh random IV per encryption, stored WITH
  // the ciphertext. The old format used `IV.fromLength(16)`, which in encrypt
  // 5.x is a NEW RANDOM IV PER PROCESS: every relaunch decrypted with a
  // different IV than the one used to encrypt, garbling the blob and (worse)
  // deleting it — the root cause of "asks me to sign in again after a few
  // days". v2 blobs decrypt correctly forever.

  Future<String> _encryptString(String plain) async {
    final encrypter = await _getEncrypter();
    final iv = encrypt.IV.fromSecureRandom(16);
    final cipher = encrypter.encrypt(plain, iv: iv);
    return 'v2:${iv.base64}:${cipher.base64}';
  }

  /// Decrypts a v2 payload. Throws on anything else (legacy handled by callers).
  Future<String> _decryptString(String stored) async {
    if (!stored.startsWith('v2:')) throw const FormatException('not v2');
    final sep = stored.indexOf(':', 3);
    if (sep < 0) throw const FormatException('bad v2 payload');
    final iv = encrypt.IV.fromBase64(stored.substring(3, sep));
    final cipher = encrypt.Encrypted.fromBase64(stored.substring(sep + 1));
    final encrypter = await _getEncrypter();
    return encrypter.decrypt(cipher, iv: iv);
  }

  /// Best-effort recovery of a legacy blob encrypted with a lost random IV.
  /// In AES-CBC a wrong IV only garbles the FIRST 16-byte block; every later
  /// block decrypts fine. The blob is a JSON cookie map, so we drop everything
  /// up to the first intact `","` pair boundary and re-open the object — losing
  /// at most the first cookie but keeping the session alive.
  Future<Map<String, String>?> _salvageLegacyCipher(String stored) async {
    try {
      final encrypter = await _getEncrypter();
      final cipher = encrypt.Encrypted.fromBase64(stored);
      // Any IV works: only block 0 is affected. allowMalformed absorbs the
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
  /// THE PARTITIONED VARIANTS ARE NOT OPTIONAL. Google issues this value under
  /// several names, and which ones a WebView capture yields depends on the domain
  /// and cookie partitioning. Reading only `SAPISID` meant a capture that carried
  /// just `__Secure-3PAPISID` produced NO auth header, so authenticated calls
  /// failed, account_menu returned nothing, and the app showed "Guest" after a
  /// perfectly successful sign-in (and then never contacted the approval Worker,
  /// because that path needs an identity first).
  ///
  /// The C1 Worker already accepted `__Secure-3PAPISID|SAPISID`; the app did not.
  /// That mismatch is exactly why the Worker could identify an account the app
  /// could not.
  static String? sapisidFrom(Map<String, String> cookies) =>
      cookies['SAPISID'] ??
      cookies['__Secure-3PAPISID'] ??
      cookies['__Secure-1PAPISID'];

  /// Is this cookie jar actually signed in?
  ///
  /// Accepts the SAPISID family as well as the SID family. The SAPISID value is
  /// what authenticated requests are SIGNED with, so a jar carrying it is usable
  /// even when no `SID` came across — the previous SID-only test rejected such a
  /// session as anonymous.
  static bool _containsAuthCookie(Map<String, String> cookies) =>
      cookies.containsKey('SID') ||
      cookies.containsKey('SSID') ||
      cookies.containsKey('__Secure-3PSID') ||
      cookies.containsKey('__Secure-1PSID') ||
      sapisidFrom(cookies) != null;

  /// True when the user completed a sign-in at some point and has NOT signed
  /// out since. This is deliberately independent of whether the cookie blob is
  /// currently readable — transient storage failures must never re-gate a
  /// signed-in user.
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
      // A successful sign-in retires the explicit sign-out. Without this the
      // latch below would keep every future session gated out.
      await prefs.remove(_signedOutKey);
    } catch (_) {}
  }

  /// Explicit sign-out latch
  ///
  /// Set when the user signs out, cleared only by a successful sign-in.
  ///
  /// WHY THIS IS NEEDED ON TOP OF CLEARING EVERYTHING. `clearCookies()` wipes our
  /// encrypted copy AND calls `WebViewCookieManager().clearCookies()` — but
  /// Android's underlying `CookieManager.removeAllCookies()` completes
  /// ASYNCHRONOUSLY and does not flush to disk on its own. So immediately after
  /// logout the platform jar can still hand back `SID` / `__Secure-3PSID`, and
  /// `SessionAuthService.ensureSession()` — whose whole job is to recover a
  /// session from that jar — dutifully re-imports them and reports the user as
  /// signed in. The account UI says logged out, the app lets you straight back
  /// in: the reported "log out is not logging out".
  ///
  /// Clearing harder cannot fix this, because the race is inside the platform.
  /// An INTENT flag can: a deliberate sign-out is a fact about what the user
  /// asked for, and no amount of leftover cookie material should be able to
  /// override it. `ensureSession()` checks this first and refuses to rehydrate.
  static const String _signedOutKey = 'yt_signed_out';

  Future<bool> hasExplicitlySignedOut() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_signedOutKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Extract visitor data from cookies or generate
  Future<String?> getVisitorData() async {
    if (_cachedVisitorData != null) return _cachedVisitorData;

    final prefs = await SharedPreferences.getInstance();
    _cachedVisitorData = prefs.getString(_visitorDataKey);

    if (_cachedVisitorData == null) {
      // Try to extract from cookies
      final cookies = await loadCookies();
      _cachedVisitorData = cookies?['VISITOR_INFO1_LIVE'] ??
                          cookies?['VISITOR_PRIVACY_METADATA'];

      // If still null, generate a placeholder
      if (_cachedVisitorData == null) {
        _cachedVisitorData = 'Cgt${_generateRandomString(40)}';
        await prefs.setString(_visitorDataKey, _cachedVisitorData!);
      }
    }

    return _cachedVisitorData;
  }

  /// Get or generate PO Token (needed for some clients)
  Future<String?> getPoToken() async {
    if (_cachedPoToken != null) return _cachedPoToken;

    final prefs = await SharedPreferences.getInstance();
    _cachedPoToken = prefs.getString(_poTokenKey);

    // PO Token is complex to generate - for now return null
    // This will be handled by client selection (prefer clients that don't need it)
    return _cachedPoToken;
  }

  /// Parse cookies from various formats
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
      // Parse Netscape format or plain text
      final lines = rawCookies.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;

        // Try tab-separated (Netscape format)
        if (line.contains('\t')) {
          final parts = line.split('\t');
          if (parts.length >= 7) {
            cookies[parts[5]] = parts[6];
          }
        } else {
          // Try semicolon-separated. Split on the FIRST '=' only — cookie
          // VALUES routinely contain '=' (base64 padding in __Secure-1PSIDCC,
          // LOGIN_INFO, …) and the old length==2 check silently DROPPED
          // exactly those auth-critical cookies from manual imports.
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

  Future<void> forceRefresh() async {
    _cachedCookies = null;
    _cachedVisitorData = null;
    _cachedPoToken = null;
    await loadCookies();
    print("YouTube cookies and tokens refreshed");
  }

  Future<void> setCookiesFromWebView(String rawCookieString, String ytCfgJson) async {
    try {
      final cookies = parseCookies(rawCookieString);
      if (cookies.isEmpty) {
        throw Exception("No valid cookies found to import.");
      }

      await saveCookies(cookies);
      final prefs = await SharedPreferences.getInstance();

      if (ytCfgJson.trim().isNotEmpty) {
        try {
          final cfg = jsonDecode(ytCfgJson);
          final poToken = cfg['PO_TOKEN'] ?? cfg['INNERTUBE_CONTEXT']?['client']?['poToken'];
          if (poToken != null) {
            await prefs.setString(_poTokenKey, poToken);
          }
        } catch (_) {
          print("WARN: Could not parse YouTube config, skipping PO Token.");
        }
      }

      final sapisid = sapisidFrom(cookies);
      if (sapisid != null) {
        await _saveSapisid(prefs, sapisid);
      }

      _cachedCookies = null;
      await loadCookies();
      print("OK: Persistence Fixed: Real Device Session Synced");
    } catch (e) {
      print("ERROR: Auth Sync Error: $e");
      rethrow;
    }
  }

  Future<void> saveCookies(Map<String, String> cookies) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      //  SECURE: v2 format — random IV embedded alongside the ciphertext, so
      //  the blob decrypts across app restarts (see note on _encryptString).
      final payload = await _encryptString(jsonEncode(cookies));
      await prefs.setString(_cookieKey, payload);
      await prefs.setInt(_lastValidatedKey, DateTime.now().millisecondsSinceEpoch);
      _cachedCookies = cookies;
      // A real signed-in session was persisted → remember that durably so the
      // login gate never re-appears until the user explicitly signs out.
      if (_containsAuthCookie(cookies)) await _markSessionActive();
      print("OK: Saved ${cookies.length} YouTube cookies (encrypted)");
    } catch (e) {
      print("ERROR: Failed to save cookies: $e");
    }
  }

  ///  SECURE: Encrypt and store the SAPISID value (used for SAPISIDHASH auth header).
  Future<void> _saveSapisid(SharedPreferences prefs, String sapisid) async {
    try {
      await prefs.setString('yt_sapisid', await _encryptString(sapisid));
    } catch (e) {
      print("ERROR: Failed to save SAPISID: $e");
    }
  }

  ///  SECURE: Read SAPISID. Only the v2 format is trusted: the legacy format
  ///  decrypted with a process-random IV, and its old "plaintext fallback"
  ///  returned base64 ciphertext as if it were the SAPISID — silently building
  ///  invalid SAPISIDHASH headers. Legacy values are dropped; the next cookie
  ///  import re-saves them in v2.
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

      //  SECURE: current v2 format first.
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
          // Legacy 2: old ciphertext whose random IV is lost — salvage all
          // blocks after the first (see _salvageLegacyCipher).
          final salvaged = await _salvageLegacyCipher(stored);
          if (salvaged != null) {
            print("Recovered ${salvaged.length} cookies from legacy blob");
            await saveCookies(salvaged); // migrate → v2
            _cachedCookies = salvaged;
          } else {
            // Unreadable. Do NOT delete the blob (the old behavior) — a
            // transient Keystore failure would turn into a permanent logout.
            // The next successful import simply overwrites it.
            print("WARN: Cookie blob unreadable this launch — keeping it and using defaults");
            _cachedCookies = await _loadDefaultCookiesFromAsset();
            return _cachedCookies;
          }
        }
      }

      _cachedVisitorData = prefs.getString(_visitorDataKey);
      _cachedPoToken = prefs.getString(_poTokenKey);
      return _cachedCookies;
    } catch (e) {
      print("WARN: Error loading cookies: $e");
      return await _loadDefaultCookiesFromAsset();
    }
  }

  String _generateRandomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final random = DateTime.now().millisecondsSinceEpoch;
    return List.generate(length, (i) => chars[(random + i) % chars.length]).join();
  }

  Future<String> getCookieString() async {
    final cookies = await loadCookies();
    return cookies?.entries.map((e) => '${e.key}=${e.value}').join('; ') ?? '';
  }

  Future<Map<String, String>> _loadDefaultCookiesFromAsset() async {
    return {};
  }

  //  UPDATE THIS: Ensure it saves to the key used for initialization
  Future<void> updateCookies(String cookieString) async {
    final cookies = parseCookies(cookieString); // Your existing parser
    if (cookies.isNotEmpty) {
      await saveCookies(cookies); // Your existing encrypted save

      // Extract Visitor Data (the "Real Device" proof)
      final prefs = await SharedPreferences.getInstance();
      final sapisid = sapisidFrom(cookies);
      if (sapisid != null) await _saveSapisid(prefs, sapisid);

      _cachedCookies = cookies;
      print(" Automated YouTube Auth Synced");
    }
  }

  Future<bool> areCookiesValid() async {
    final prefs = await SharedPreferences.getInstance();
    final lastValidated = prefs.getInt(_lastValidatedKey);

    if (lastValidated == null) return false;

    final age = DateTime.now().millisecondsSinceEpoch - lastValidated;
    final daysSinceValidation = age / (1000 * 60 * 60 * 24);

    return daysSinceValidation < 30;
  }

  /// `Authorization` header for an authenticated InnerTube call:
  /// `SAPISIDHASH <ts>_<sha1(ts + " " + value + " " + origin)>`.
  ///
  /// ONE LABEL ONLY — REVERTED 2026-08-05, DO NOT "CORRECT" THIS AGAIN.
  ///
  /// I briefly emitted per-cookie labels (SAPISID1PHASH / SAPISID3PHASH) believing
  /// that hashing `__Secure-3PAPISID` under the plain `SAPISIDHASH` label was a
  /// wrong signature. It is not: the C1 Worker's KV roster showed **14 successful
  /// verifications** under this single-label scheme, and every account — the owner
  /// included — started failing with `account_menu http 403` the moment the
  /// labelled version shipped. `SAPISIDHASH` computed from whichever *APISID value
  /// exists is the recipe YouTube actually accepts.
  ///
  /// The tolerant VALUE lookup ([sapisidFrom]) is still right and still needed: a
  /// capture may carry only the partitioned variant. It is the LABEL that must stay
  /// `SAPISIDHASH`.
  Future<String?> getAuthorizationHeader(String origin) async {
    final cookies = await loadCookies();
    String? value = cookies == null ? null : sapisidFrom(cookies);

    // Nothing usable in the jar → the separately-persisted SAPISID.
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
    await prefs.remove(_visitorDataKey);
    await prefs.remove(_poTokenKey);
    await prefs.remove('yt_sapisid');
    // Explicit sign-out: only here does the durable "signed in" marker fall,
    // so the login gate is allowed to appear again.
    await prefs.remove(_sessionActiveKey);
    // …and the INTENT is recorded, which is what actually holds the gate shut
    // while the platform cookie jar finishes emptying. See _signedOutKey.
    await prefs.setBool(_signedOutKey, true);
    _cachedCookies = null;
    _cachedVisitorData = null;
    _cachedPoToken = null;
    // CRITICAL: also clear the platform WebView cookie jar. The real auth
    // cookies (SID / __Secure-3PSID, HttpOnly) live there, not just in our
    // encrypted copy. Without this, logout / delete-account only wiped our copy
    // while the WebView session survived, and ensureSession()'s platform-cookie
    // fallback then RE-IMPORTED it, silently skipping the login gate. That left
    // the user "logged out" per the account UI but still in the app, so the
    // account dialog showed "Connect YouTube" and tapping it ran the OAuth
    // import flow (which fails on the unverified sensitive scope) — the reported
    // "deleted my account, Connect YouTube doesn't work" bug.
    try {
      await WebViewCookieManager().clearCookies();
    } catch (e) {
      print("WARN: WebView cookie jar clear failed: $e");
    }
    print("Cleared YouTube cookies and tokens (incl. WebView jar)");
  }

  Map<String, String> getEssentialCookies(Map<String, String> allCookies) {
    const essential = [
      'VISITOR_INFO1_LIVE',
      'VISITOR_PRIVACY_METADATA',
      'CONSENT',
      'PREF',
      'SID',
      'HSID',
      'SSID',
      'APISID',
      'SAPISID',
      '__Secure-1PSID',
      '__Secure-3PSID',
      '__Secure-1PAPISID',
      '__Secure-3PAPISID',
      'LOGIN_INFO',
      'YSC',
      'GPS',
    ];

    final Map<String, String> filtered = {};
    for (var key in essential) {
      if (allCookies.containsKey(key)) {
        filtered[key] = allCookies[key]!;
      }
    }

    return filtered;
  }

  Future<bool> hasAuthCookies() async {
    final cookies = await loadCookies();
    if (cookies == null) return false;

    return _containsAuthCookie(cookies);
  }

  Future<void> setSessionDataFromWebView({
    required String rawCookieString,
    required String ytCfgJson // Extracted JSON from window.ytcfg.data_
  }) async {
    try {
      // 1. Parse and Encrypt Cookies (Uses your existing logic)
      final cookies = parseCookies(rawCookieString);
      if (cookies.isNotEmpty) {
        await saveCookies(cookies); // Your existing encrypted save method
      }

      final prefs = await SharedPreferences.getInstance();

      // Keep the SAPISIDHASH fallback source in sync with the fresh session.
      final sapisid = sapisidFrom(cookies);
      if (sapisid != null) await _saveSapisid(prefs, sapisid);

      // 2. Extract & Save PO Token (Critical for Real Device Verification)
      if (ytCfgJson.isNotEmpty) {
        try {
          final data = jsonDecode(ytCfgJson);
          String? poToken;

          // Try multiple paths to find the token
          if (data['botguardData'] != null) {
            poToken = data['botguardData']['programmaticAccessToken'];
          } else if (data['INNERTUBE_CONTEXT'] != null) {
             poToken = data['INNERTUBE_CONTEXT']['client']['poToken'];
          }

          if (poToken != null && poToken.isNotEmpty) {
            await prefs.setString(_poTokenKey, poToken); // Uses your existing constant
            _cachedPoToken = poToken;
          }
        } catch (e) {
          print("WARN: PO Token parse failed: $e");
        }
      }

      // 3. Extract & Save Visitor Data (For Context)
      final visitorData = cookies['VISITOR_INFO1_LIVE'] ??
                          cookies['VISITOR_PRIVACY_METADATA'];
      if (visitorData != null) {
        await prefs.setString(_visitorDataKey, visitorData); // Uses your existing constant
        _cachedVisitorData = visitorData;
      }

      // 4. Force Cache Refresh
      _cachedCookies = null;
      await loadCookies();
      print(" Automated Login: Session Synced Successfully");

    } catch (e) {
      print("ERROR: Session Sync Error: $e");
    }
  }

  Future<bool> validateCookies() async {
    final cookies = await loadCookies();
    if (cookies == null || cookies.isEmpty) {
      print("WARN: No cookies to validate");
      return false;
    }

    try {
      final cookieString = await getCookieHeader();
      if (cookieString == null) return false;

      // Simple validation - try to access YouTube homepage
      final response = await http.get(
        Uri.parse('https://www.youtube.com/'),
        headers: {
          'Cookie': cookieString,
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        // Check if we're logged in (simple heuristic)
        final isLoggedIn = response.body.contains('"LOGGED_IN":true') ||
                          response.body.contains('ytInitialData');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_lastValidatedKey, DateTime.now().millisecondsSinceEpoch);

        if (isLoggedIn) {
          print(" Cookies are valid and authenticated");
        } else {
          print("Cookies are valid but not authenticated");
        }

        return true;
      }

      print("WARN: Cookie validation returned: ${response.statusCode}");
      return false;
    } catch (e) {
      print("WARN: Cookie validation error: $e");
      return false;
    }
  }
}
