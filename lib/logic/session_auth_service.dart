import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:auvy/logic/session_cookie_manager.dart';

/// Signed-in YouTube session handling: the cookies that make playback and the
/// user's own library available.
///
/// Cookies are the credential, so this file guards against two failures: leaking
/// them and losing them. They are encrypted at rest (see session_cookie_manager)
/// and never logged.
///
/// A missing cookie is not the same as a signed-out user. Telling the two apart
/// decides whether the app shows the login page or quietly retries.

class SessionAuthService {
  final SessionCookieManager _cookieManager = SessionCookieManager();

  // Native bridge to the platform cookie store (MainActivity.kt on Android,
  // AuvyCookies.swift on iOS). It returns every cookie for a URL, including the
  // HttpOnly auth cookies (SID, __Secure-3PSID, …) that page JavaScript cannot
  // read. Without those the saved session is useless.
  static const MethodChannel _cookieChannel =
      MethodChannel('com.auvy.app/cookies');

  /// Reads every cookie for [url] from the platform store as a name→value map.
  /// Splits each pair on the first '=' only, so base64 values keep their padding.
  Future<Map<String, String>> _readPlatformCookies(String url) async {
    try {
      final raw = await _cookieChannel
          .invokeMethod<String>('getCookies', {'url': url});
      if (raw == null || raw.isEmpty) return {};
      final map = <String, String>{};
      for (final pair in raw.split(';')) {
        final p = pair.trim();
        final i = p.indexOf('=');
        if (i <= 0) continue;
        map[p.substring(0, i)] = p.substring(i + 1);
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  static bool _hasAuthCookie(Map<String, String> cookies) =>
      cookies.containsKey('SID') ||
      cookies.containsKey('__Secure-3PSID') ||
      cookies.containsKey('__Secure-1PSID');

  /// Copies a session that still exists in the platform cookie store back into
  /// our encrypted store. Returns true when an authenticated session was found.
  Future<bool> _rehydrateFromPlatformJar(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final platform = await _readPlatformCookies('https://music.youtube.com')
        .timeout(timeout, onTimeout: () => <String, String>{});
    if (!_hasAuthCookie(platform)) return false;

    await _cookieManager.setSessionDataFromWebView(
      rawCookieString: jsonEncode(platform),
    );
    return _cookieManager.hasAuthCookies();
  }

  /// Decides at startup whether the user is signed in, without showing any login
  /// UI.
  ///
  /// Checked in order:
  ///  1. Our encrypted cookies prove a session (fast path).
  ///  2. Our copy was lost but the platform cookie store still has the session:
  ///     re-import it silently.
  ///  3. The "signed in, never signed out" marker is set: treat the user as signed
  ///     in and retry the re-import shortly in the background. A slow cold start or
  ///     a briefly unavailable keystore should never cost a re-login; only an
  ///     explicit sign-out brings the login page back.
  ///
  /// Purely local, so it answers correctly offline.
  Future<bool> ensureSession() async {
    try {
      // An explicit sign-out outranks every recovery path below.
      //
      // Clearing the platform cookie store finishes asynchronously, so for a moment
      // after logout the re-import below could still find live auth cookies and sign
      // the user straight back in. Refusing to re-import after a sign-out avoids that
      // race. The flag is cleared by the next successful sign-in.
      if (await _cookieManager.hasExplicitlySignedOut()) return false;

      if (await _cookieManager.hasAuthCookies()) return true;

      if (await _rehydrateFromPlatformJar()) return true;

      if (await _cookieManager.hasPersistentSession()) {
        // The session is briefly unreadable but the user never signed out. Let them
        // in and re-import quietly once the platform side is ready.
        _retryRehydrateSoon();
        return true;
      }
      return false;
    } catch (_) {
      // On any failure, trust the durable state we have rather than ask for a login.
      try {
        if (await _cookieManager.hasPersistentSession()) return true;
        return await _cookieManager.hasAuthCookies();
      } catch (_) {
        return false;
      }
    }
  }

  /// One delayed background attempt to recover our cookie copy after a slow cold
  /// start.
  void _retryRehydrateSoon() {
    Future.delayed(const Duration(seconds: 10), () async {
      try {
        if (await _cookieManager.hasAuthCookies()) return;
        await _rehydrateFromPlatformJar(timeout: const Duration(seconds: 8));
      } catch (_) {}
    });
  }

  /// The account address picked at the last native sign-in.
  ///
  /// This is not an identity and is never used as one: the Worker derives identity
  /// from the cookies it verifies itself. It is sent only so the admin roster can
  /// show a readable name for accounts that otherwise resolve to a bare numeric id.
  Future<String?> lastLoginEmail() async {
    try {
      return await _cookieChannel.invokeMethod<String>('lastLoginEmail');
    } catch (_) {
      return null;
    }
  }

  /// Opens the native sign-in screen (LoginActivity.kt on Android,
  /// AuvyCookies.swift on iOS) and, on success, copies the fresh session
  /// cookies, HttpOnly ones included, into the encrypted store. Returns true
  /// when signed in.
  ///
  /// A native screen is used because the Flutter WebView plugin's extra layers
  /// kept tripping Google's "This browser or app may not be secure" check.
  Future<bool> signInWithNativeWebView() async {
    try {
      // On Android the native screen opens the system account chooser and fills
      // in the picked address itself, so nothing on the Dart side needs Play
      // Services.
      final ok = await _cookieChannel.invokeMethod<bool>('openLogin') ?? false;
      if (!ok) return false;
      return await _rehydrateFromPlatformJar(
          timeout: const Duration(seconds: 8));
    } catch (_) {
      return false;
    }
  }
}
