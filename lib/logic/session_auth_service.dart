import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:auvy/logic/session_cookie_manager.dart';

/// Signed-in YouTube session handling: the cookies that make playback and the
/// user's own library available.
///
/// Cookies are the credential here, so everything in this file is written to
/// avoid two failures: leaking them, and losing them. They are encrypted at rest
/// (see session_cookie_manager for the v2 format and why the IV had to move into
/// the payload), and never logged — a redaction pass runs over anything that
/// reaches the activity log.
///
/// A missing cookie is not the same as a signed-out user. The distinction drives
/// whether the app shows the login page or simply retries, and getting it wrong
/// sends a signed-in user back through onboarding.

class SessionAuthService {
  final SessionCookieManager _cookieManager = SessionCookieManager();

  // Native bridge to Android's CookieManager, which returns ALL cookies for a
  // URL — crucially the HttpOnly ones (SID, __Secure-3PSID, …) that the WebView's
  // `document.cookie` can NOT see. Those are the actual auth cookies; without
  // them the saved session is useless and the user is asked to log in again on
  // every launch. (See the matching handler in MainActivity.kt.)
  static const MethodChannel _cookieChannel =
      MethodChannel('com.auvy.app/cookies');

  /// Pull every cookie for [url] from the platform cookie store as a name→value
  /// map. Parses the native "k=v; k=v" string, splitting on the FIRST '=' only
  /// so base64 values containing '=' survive intact.
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

  /// Re-import the surviving platform WebView session (HttpOnly cookies) into
  /// our encrypted store. Returns true when an authenticated session was found.
  Future<bool> _rehydrateFromPlatformJar(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final platform = await _readPlatformCookies('https://music.youtube.com')
        .timeout(timeout, onTimeout: () => <String, String>{});
    if (!_hasAuthCookie(platform)) return false;

    await _cookieManager.setSessionDataFromWebView(
      rawCookieString: jsonEncode(platform),
      ytCfgJson: '{}',
    );
    return _cookieManager.hasAuthCookies();
  }

  /// Startup session reconciliation. Returns true when the user should be
  /// treated as signed in, WITHOUT ever showing a login UI.
  ///
  /// Resolution order:
  ///  1. Our encrypted cookies already prove a session (fast path).
  ///  2. The Android WebView cookie jar still holds the session even though our
  ///     copy was lost (storage hiccup) → silently re-import it.
  ///  3. The durable "signed in, never signed out" marker is set → treat as
  ///     signed in anyway and retry the re-import shortly in the background.
  ///     A cold-boot WebView that answers slowly, a Keystore that is briefly
  ///     unavailable, a trimmed cookie jar — none of these are the user's
  ///     fault, and none of them should ever cost a re-login. Only an explicit
  ///     sign-out (which clears the marker) brings the login gate back.
  ///
  /// Purely local (no network), so it resolves correctly even offline.
  Future<bool> ensureSession() async {
    try {
      // FIRST, BEFORE ANY RECOVERY. An explicit sign-out outranks every
      // recovery path below.
      //
      // This is what fixes "log out is not logging out". Logout clears our
      // encrypted cookies AND the platform WebView jar, but Android's
      // `CookieManager.removeAllCookies()` completes asynchronously and is not
      // flushed to disk, so moments later `_rehydrateFromPlatformJar()` could
      // still find live `SID` / `__Secure-3PSID` cookies and re-import them —
      // handing the user straight back into the app they had just signed out of.
      // Clearing more aggressively cannot win that race; refusing to rehydrate
      // can. The latch is cleared by the next successful sign-in.
      if (await _cookieManager.hasExplicitlySignedOut()) return false;

      if (await _cookieManager.hasAuthCookies()) return true;

      if (await _rehydrateFromPlatformJar()) return true;

      if (await _cookieManager.hasPersistentSession()) {
        // Session material is momentarily unreadable but the user never signed
        // out. Let them in and quietly rehydrate once the WebView is warm.
        _retryRehydrateSoon();
        return true;
      }
      return false;
    } catch (_) {
      // On any failure, prefer whatever durable state we have over a re-login.
      try {
        if (await _cookieManager.hasPersistentSession()) return true;
        return await _cookieManager.hasAuthCookies();
      } catch (_) {
        return false;
      }
    }
  }

  /// One deferred background attempt to recover the cookie copy after a slow
  /// cold start (the WebView provider can take several seconds to come up).
  void _retryRehydrateSoon() {
    Future.delayed(const Duration(seconds: 10), () async {
      try {
        if (await _cookieManager.hasAuthCookies()) return;
        await _rehydrateFromPlatformJar(timeout: const Duration(seconds: 8));
      } catch (_) {}
    });
  }

  /// Opens the NATIVE Android sign-in screen (a plain WebView that is a 1:1
  /// a plain WebView, see LoginActivity.kt) and, on success,
  /// imports the fresh session cookies (HttpOnly included) from the platform
  /// jar into the encrypted store. Returns true when signed in.
  ///
  /// The previous in-app flutter WebView kept tripping Google's sign-in
  /// checks ("This browser or app may not be secure") — the plugin layers its
  /// own WebChromeClient and extra WebSettings between Google's login JS and
  /// the page. The native screen uses exactly the settings/UA/URL of the apps
  /// where this login demonstrably works.
  /// The account chosen in the NATIVE picker at the last sign-in.
  ///
  /// NOT an identity and never treated as one. The Worker derives identity
  /// from the cookies it verifies itself; this is passed along purely so the
  /// admin roster can show a human name next to accounts that resolve to a
  /// numeric datasyncId (no YouTube channel → no email, no @handle anywhere).
  /// A queue of digits cannot be reviewed.
  Future<String?> lastLoginEmail() async {
    try {
      return await _cookieChannel.invokeMethod<String>('lastLoginEmail');
    } catch (_) {
      return null;
    }
  }

  Future<bool> signInWithNativeWebView() async {
    try {
      // The native LoginActivity opens the SYSTEM device-account chooser
      // itself (AccountManager) and auto-completes the identifier step with
      // the picked address — no Play-Services sign-in on the Dart side (the
      // GoogleSignIn picker resolved instantly-empty on some devices, leaving
      // the flow on the blank email form).
      final ok = await _cookieChannel.invokeMethod<bool>('openLogin') ?? false;
      if (!ok) return false;
      return await _rehydrateFromPlatformJar(
          timeout: const Duration(seconds: 8));
    } catch (_) {
      return false;
    }
  }
}
