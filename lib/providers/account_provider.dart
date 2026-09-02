import 'dart:async' show TimeoutException;
import 'dart:convert';
// SocketException / HandshakeException — telling a "cannot reach the service"
// failure apart from a definite answer. See _isTransientNetworkError.
import 'dart:io' show SocketException, HandshakeException;
import 'dart:math';
import 'dart:ui' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart'; 
import 'package:http/http.dart' as http;
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart'; // <-- ADDED for catalog matching
import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/logic/session_auth_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/database_service.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/data_usage_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:auvy/providers/home_provider.dart';
import 'package:auvy/providers/recent_playlists_provider.dart';
import 'package:auvy/providers/slider_provider.dart';
import 'package:auvy/providers/haptics_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/services/listening_policy.dart';
// A restored alarm has to be re-armed with AlarmManager, not just remembered.
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:auvy/core/backend_config.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/providers/mini_player_style_provider.dart';

/// Raised the moment the Worker returns a verdict about the ACCOUNT —
/// `pending`, `blocked` or `closed`. MainLayout listens and ejects to the
/// sign-in page.
///
/// Why a signal rather than ejecting where it is detected: the verdict can
/// arrive from several places (the startup gate, the cloud-backup activation,
/// the resume re-check) and only one of them is near a Navigator. Blocking a
/// user used to just toast "cloud backup access was removed" and leave them
/// playing music — the decision had no effect on the thing that matters.
///
/// Deliberately NOT raised for `unavailable`, `throttled` or `capacity`.
/// Those say nothing about who the user is; ejecting on them would turn a
/// server hiccup or a rate limit into a forced logout.
final accessRevokedProvider =
    ValueNotifier<({String status, String? identity})?>(null);

void _raiseRevoked(String status, String? identity) {
  if (status == 'pending' || status == 'blocked' || status == 'closed') {
    accessRevokedProvider.value = (status: status, identity: identity);
  }
}

enum AccountType { none, spotify, youtube, discord }

// Holds individual session data for a specific connected service
class AuthSession {
  final String userId;
  final String displayName;
  final String? email;
  final String? avatarUrl;
  final String accessToken;
  
  AuthSession({required this.userId, required this.displayName, this.email, this.avatarUrl, required this.accessToken});
  
  Map<String, dynamic> toMap() => {'userId': userId, 'displayName': displayName, 'email': email, 'avatarUrl': avatarUrl, 'accessToken': accessToken};
  factory AuthSession.fromMap(Map<String, dynamic> map) => AuthSession(userId: map['userId'], displayName: map['displayName'], email: map['email'], avatarUrl: map['avatarUrl'], accessToken: map['accessToken']);
}

// State now holds multiple active sessions simultaneously
class AccountState {
  final AuthSession? youtube;
  final AuthSession? discord;
  final AccountType preferredPrimary;

  AccountState({
    this.youtube, 
    this.discord,
    this.preferredPrimary = AccountType.none, 
  });

  bool get isLoggedIn => youtube != null || discord != null;

  AuthSession? get primary {
    if (preferredPrimary == AccountType.youtube && youtube != null) return youtube;
    if (preferredPrimary == AccountType.discord && discord != null) return discord;
    return youtube ?? discord;
  }

  String? get displayName => primary?.displayName;
  String? get email => primary?.email;
  String? get avatarUrl => primary?.avatarUrl;

  AccountState copyWith({
    AuthSession? youtube, 
    AuthSession? discord, 
    AccountType? preferredPrimary, 
    bool clearMusicSession = false, 
    bool clearPresenceSession = false
  }) {
    return AccountState(
      youtube: clearMusicSession ? null : (youtube ?? this.youtube),
      discord: clearPresenceSession ? null : (discord ?? this.discord),
      preferredPrimary: preferredPrimary ?? this.preferredPrimary,
    );
  }
}

class AccountNotifier extends StateNotifier<AccountState> {
  final Ref _ref;

  //  SECURE: OAuth tokens + email live in encrypted secure storage, not plaintext prefs.
  static const String _accountKey = 'auvy_account_v2';
  // Which account the on-device user data belongs to (the cloud backup key /
  // uid). Written whenever cloud backup activates; compared on every activation
  // so signing in with a DIFFERENT account can never inherit the previous
  // account's history/library/taste. See [_ensureLocalDataBelongsTo].
  static const String _dataOwnerKey = 'auvy_data_owner_v1';
  // Shared app-wide instance with pinned AndroidOptions. See the doc on
  // appSecureStorage (youtube_cookie_manager.dart). A second instance with
  // different options is exactly what triggers the plugin's mismatch-wipe.
  final FlutterSecureStorage _secureStorage = appSecureStorage;

  static String get youtubeClientId => BackendConfig.youtubeClientId;
  static const String youtubeRedirectUri = 'com.auvy.app://callback';

  static const String discordClientId = '1454840399909883988'; 
  static const String discordRedirectUri = 'com.auvy.app://callback';

  AccountNotifier(this._ref) : super(AccountState()) { 
    _loadSavedAccount();
  }

  Future<void> _loadSavedAccount() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedJson;
    try {
      savedJson = await _secureStorage.read(key: _accountKey);
    } catch (e) {
      // Transient Keystore/plugin failure. With resetOnError pinned to false
      // this surfaces as an exception instead of a silent wipe: leave the
      // account unloaded for this launch — the blob is untouched and the next
      // launch reads it normally.
      print("ALERT: Secure-storage read failed — account not loaded this launch: $e");
      return;
    }

    //  MIGRATION: move any legacy plaintext blob into secure storage once.
    if (savedJson == null) {
      final legacy = prefs.getString(_accountKey);
      if (legacy != null) {
        try {
          await _secureStorage.write(key: _accountKey, value: legacy);
          await prefs.remove(_accountKey);
        } catch (e) {
          // Keep the plaintext blob for a retry next launch; still load it.
          print("WARN: Legacy account blob migration deferred: $e");
        }
        savedJson = legacy;
      }
    }

    if (savedJson != null) {
      try {
        final data = await compute(jsonDecode, savedJson);
        
        // Parse preferred primary enum
        AccountType pref = AccountType.none;
        if (data['preferredPrimary'] == 'youtube') pref = AccountType.youtube;
        if (data['preferredPrimary'] == 'discord') pref = AccountType.discord;

        state = AccountState(
          youtube: data['youtube'] != null ? AuthSession.fromMap(data['youtube']) : null,
          discord: data['discord'] != null ? AuthSession.fromMap(data['discord']) : null,
          preferredPrimary: pref, // Load preference
        );
      } catch (e) {
        print("ERROR: Failed to load account: $e");
      }
    }
    if (state.youtube != null) {
      _googleSignIn.signInSilently().catchError((_) => null);
      // Known account → silently enable cloud sync and pull any newer backup.
      enableCloudBackup(interactive: false);
    } else {
      // No saved account, but the user may already have a persisted YouTube
      // WebView session (cookies). Register it so the UI reflects the logged-in
      // user without prompting again. Fire-and-forget — updates state when done.
      registerAccountFromSession();
    }
  }

  /// Sign in to Firebase Auth with the user's Google account to obtain a STABLE
  /// per-account uid (the same uid after a reinstall), then enable cloud sync
  /// keyed by that uid and pull any newer backup. The uid is what makes the
  /// Firestore security rules enforce "a user can only touch their own data".
  ///
  /// On startup we only attempt a SILENT sign-in ([interactive] = false) so the
  /// user isn't shown an account picker unprompted; the explicit login flow and
  /// the account dialog pass [interactive] = true.
  /// The stable Firestore backup document key for a YouTube account. It is a
  /// salted SHA-256 of the account's identity (email / handle / channel), so:
  ///   • it is STABLE across reinstalls (same YouTube account → same key), which
  ///     is what makes restore-after-reinstall work with NO second login, and
  ///   • it is not the raw email (no PII in the doc id) and not trivially
  ///     guessable without the app salt.
  /// The Firebase user is ANONYMOUS (silent, no picker) — it exists only to
  /// satisfy the Firestore "must be signed in" rule; the per-account identity is
  /// this key, not the anonymous uid (which changes on every reinstall).
  static const String _backupSalt = 'auvy_cloud_backup_v1::';

  /// C1 (critical security fix) — the deployed Cloudflare Worker URL. When set,
  /// cloud backup uses the SECURE flow: the Worker verifies the caller OWNS the
  /// YouTube account (via its cookies) before minting a Firebase custom token
  /// (uid = the SAME backup key, so existing backups keep working) + a per-user
  /// encryption key. Leave EMPTY to keep the legacy anonymous flow — nothing
  /// changes until this URL is pasted in. Deploy: server/c1-auth-worker/DEPLOY.md.
  static String get _c1WorkerUrl => BackendConfig.workerBase;

  String? _backupKeyFor(String ytIdentity) {
    final id = ytIdentity.trim().toLowerCase();
    if (id.isEmpty) return null;
    return sha256.convert(utf8.encode('$_backupSalt$id')).toString();
  }

  /// One announcement per launch. The approval gate is consulted on every start,
  /// and a pending user would otherwise be told the same thing every time.
  bool _cloudDenialAnnounced = false;

  /// Set the first time the Worker answers `approved` for this device.
  static const String _everApprovedKey = 'auvy_access_ever_approved';

  /// WHICH ACCOUNT that approval belongs to — a hash of its SAPISID cookie.
  ///
  /// WITHOUT THIS THE MARKER IS A DEVICE-WIDE SKELETON KEY. It was never
  /// cleared on logout or on an account switch, so one approved sign-in made the
  /// phone permanently "established": every later account inherited both the
  /// offline grace AND the fast path past the launch gate. Observed exactly that
  /// way — the owner account was approved at 09:01:54, and an unapproved account
  /// on the same device then walked straight into the app.
  ///
  /// Hashed, not stored raw: this is a live credential, and the only question
  /// asked of it is "is this the same account", which equality answers.
  static const String _approvedForKey = 'auvy_access_approved_for';

  /// A stable, local fingerprint of the signed-in account. Null when there is no
  /// readable session, which is itself a reason not to honour the marker.
  ///
  /// Deliberately derived from the COOKIE rather than the resolved identity: the
  /// launch gate needs this answer before any network call, and account_menu
  /// cannot always resolve an identity offline.
  static Future<String?> _accountFingerprint() async {
    try {
      final cookies = await SessionCookieManager().loadCookies();
      if (cookies == null || cookies.isEmpty) return null;
      final sapisid = SessionCookieManager.sapisidFrom(cookies);
      if (sapisid == null || sapisid.isEmpty) return null;
      return sha256.convert(utf8.encode(sapisid)).toString().substring(0, 32);
    } catch (_) {
      return null;
    }
  }

  /// When the Worker last actually said `approved`.
  static const String _lastApprovedMsKey = 'auvy_access_last_approved_ms';

  /// How long an established device keeps working with the Worker unreachable.
  ///
  /// The grace window used to be unbounded: approved once, waved through forever
  /// on a failed request. That turns "be kind during an outage" into "stay
  /// offline and keep access permanently", which is a real hole — revocation
  /// only ever reaches a device that talks to the Worker. Two weeks is long
  /// enough to cover an outage, a holiday or a dead SIM, and short enough that
  /// access cannot be kept indefinitely by simply never connecting.
  static const Duration _offlineGrace = Duration(days: 14);

  /// May this device be forgiven a failed approval check right now?
  ///
  /// The difference between forgiving an outage and leaving the door open. When
  /// the Worker can't be reached, an established user must keep their music — but
  /// a device that has never once been approved has no business being waved
  /// through on the strength of a failed request, which is precisely how an
  /// unapproved account got in and then sat there as "Guest".
  ///
  /// Now also bounded in TIME. See [_offlineGrace].
  Future<bool> withinOfflineGrace() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_everApprovedKey) ?? false)) return false;
      // The approval has to belong to THE ACCOUNT THAT IS SIGNED IN NOW — see
      // [_approvedForKey]. A marker with no owner recorded predates this check,
      // so it is not trusted: re-verifying costs one request, while honouring it
      // would keep the device-wide hole open for exactly the installs that have
      // it.
      final owner = prefs.getString(_approvedForKey);
      final now = await _accountFingerprint();
      if (owner == null || now == null || owner != now) return false;
      final last = prefs.getInt(_lastApprovedMsKey);
      // Approved under the older build, which never recorded a timestamp. Stamp
      // it now rather than locking the user out for an upgrade they didn't ask
      // for: they get one full grace window from first launch of this version.
      if (last == null) {
        await prefs.setInt(
            _lastApprovedMsKey, DateTime.now().millisecondsSinceEpoch);
        return true;
      }
      final age = DateTime.now().millisecondsSinceEpoch - last;
      return age >= 0 && age <= _offlineGrace.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Ask the Worker whether this device's YouTube session may use Auvy at all.
  ///
  /// Returns the Worker's `status` — `approved`, `pending`, `blocked`, `closed`,
  /// `throttled`, `capacity` — plus the identity IT resolved from the cookies, and
  /// `unavailable` when the Worker can't be reached or isn't configured.
  ///
  /// WHY THIS EXISTS SEPARATELY FROM [enableCloudBackup].
  ///
  /// enableCloudBackup refuses to call the Worker until the app has worked out who
  /// is signed in locally, and that resolution fails whenever account_menu won't
  /// answer, leaving the app as "Guest". An unapproved user therefore reached a
  /// fully working app and the gate was never consulted, which is the opposite of
  /// the intent. The cookie alone is enough for the Worker to identify the account,
  /// so the gate asks with the cookie and nothing else.
  ///
  /// `unavailable` deliberately does NOT mean "denied". Auvy plays from the user's
  /// own YouTube session with no server in the path, so a Worker outage must not
  /// brick a legitimate user's music — it only means cloud backup stays off.
  /// The account the user picked in the native chooser, remembered across
  /// launches. DISPLAY ONLY. See SessionAuthService.lastLoginEmail.
  static const String _deviceEmailKey = 'auvy_device_email';

  Future<String?> _displayHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fresh = await SessionAuthService().lastLoginEmail();
      if (fresh != null && fresh.contains('@')) {
        await prefs.setString(_deviceEmailKey, fresh);
        return fresh;
      }
      return prefs.getString(_deviceEmailKey);
    } catch (_) {
      return null;
    }
  }

  // One worker call per launch, shared by every caller
  //
  // verifyAccess() AND enableCloudBackup() POST THE IDENTICAL REQUEST — same
  // URL, same `{cookie, hint}` body, and the single response already carries
  // what both need (status, identity, firebaseToken, uid, encKey). Measured on
  // device, THREE POSTs in one launch, each carrying the full 20-cookie header:
  //
  //   09:25:43.086  verifyAccess: 200      (launch gate)
  //   09:25:43.133  worker replied         (enableCloudBackup)
  //   09:25:46.193  verifyAccess: 200      (MainLayout's launch check)
  //
  // The cookie header is the largest payload in the exchange, so that was three
  // times the mobile data needed for one answer that cannot change in three
  // seconds.
  //
  // Keyed on the COOKIE as well as the clock: a new sign-in is a different
  // session and must never be answered from the previous account's cached
  // verdict. Short TTL because this is an access decision — long enough to
  // collapse one launch's duplicates, far too short to delay a revocation (the
  // periodic re-check is minutes apart and always makes a real request).
  ({int code, Map<String, dynamic> body})? _workerAnswer;
  String? _workerAnswerFor;
  DateTime? _workerAnswerAt;
  Future<({int code, Map<String, dynamic> body})>? _workerInFlight;

  static const Duration _workerAnswerTtl = Duration(seconds: 20);

  /// Cached answer for [cookie], or null when there isn't a usable one.
  ({int code, Map<String, dynamic> body})? _cachedWorkerAnswer(String cookie) {
    final at = _workerAnswerAt;
    final a = _workerAnswer;
    if (a == null || at == null) return null;
    if (_workerAnswerFor != _cookieTag(cookie)) return null;
    if (DateTime.now().difference(at) > _workerAnswerTtl) return null;
    return a;
  }

  /// Short fingerprint of a cookie header — enough to tell sessions apart without
  /// holding a second copy of a live credential around.
  static String _cookieTag(String cookie) =>
      sha256.convert(utf8.encode(cookie)).toString().substring(0, 16);

  void _rememberWorkerAnswer(
      String cookie, int code, Map<String, dynamic> body) {
    _workerAnswer = (code: code, body: body);
    _workerAnswerFor = _cookieTag(cookie);
    _workerAnswerAt = DateTime.now();
  }

  /// Drop any cached verdict. Called when the session changes, so the next ask is
  /// always about the account that is actually signed in.
  void _forgetWorkerAnswer() {
    _workerAnswer = null;
    _workerAnswerFor = null;
    _workerAnswerAt = null;
  }

  Future<({String status, String? identity, String? detail})> verifyAccess() async {
    if (_c1WorkerUrl.isEmpty) {
      return (status: 'unavailable', identity: null, detail: 'not configured');
    }
    try {
      final cookie = await SessionCookieManager().getCookieHeader();
      if (cookie == null || cookie.isEmpty) {
        // Worth distinguishing: "no session to ask about" is a DIFFERENT failure
        // from "the service refused", and lumping both into one silent
        // `unavailable` is what made this take three attempts to pin down.
        return (status: 'unavailable', identity: null, detail: 'no cookies');
      }
      // Reuse this launch's answer when there is one for THIS session. See the
      // note on _workerAnswer. Also joins a call already in flight, so two
      // callers a few milliseconds apart cost one request, not two.
      int code;
      Map<String, dynamic> body;
      final cached = _cachedWorkerAnswer(cookie);
      if (cached != null) {
        code = cached.code;
        body = cached.body;
      } else {
        final inFlight = _workerInFlight;
        if (inFlight != null) {
          final r = await inFlight;
          code = r.code;
          body = r.body;
        } else {
          final future = (() async {
            final resp = await http
                .post(Uri.parse(_c1WorkerUrl),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode(
                        {'cookie': cookie, 'hint': await _displayHint()}))
                .timeout(const Duration(seconds: 15));
            final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
            _rememberWorkerAnswer(cookie, resp.statusCode, parsed);
            return (code: resp.statusCode, body: parsed);
          })();
          _workerInFlight = future;
          try {
            final r = await future;
            code = r.code;
            body = r.body;
          } finally {
            if (identical(_workerInFlight, future)) _workerInFlight = null;
          }
        }
      }
      final status = (body['status'] as String?) ??
          (code == 200 ? 'approved' : 'unavailable');
      final identity = (body['identity'] as String?)?.trim();
      // Remember that this device WAS approved once. That is what lets an
      // outage be forgiving to an established user without also waving through
      // someone who has never been approved at all. See [withinOfflineGrace].
      if (status == 'approved') {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_everApprovedKey, true);
          // Stamp WHOSE approval this is, so it cannot be inherited by the next
          // account to sign in on this device. Cleared to null when the account
          // can't be fingerprinted, which reads as "not trusted" rather than
          // leaving the previous owner's stamp in place.
          final who = await _accountFingerprint();
          if (who == null) {
            await prefs.remove(_approvedForKey);
          } else {
            await prefs.setString(_approvedForKey, who);
          }
          // The clock the grace window runs off. Refreshed on every successful
          // check, so a device in normal use never comes close to expiring.
          await prefs.setInt(
              _lastApprovedMsKey, DateTime.now().millisecondsSinceEpoch);
        } catch (_) {}
      }
      // Any verdict about the ACCOUNT ejects. See accessRevokedProvider.
      _raiseRevoked(status, identity);
      // The `error` text is carried into the log too, because "closed" alone
      // cannot distinguish enrolment being shut from the daily intake being used
      // up — two very different things for whoever has to fix it.
      print('verifyAccess: $code status=$status '
          'identity=${identity == null || identity.isEmpty ? "?" : "known"}'
          '${status == "approved" ? "" : " reason=${body['error'] ?? '?'}"}');
      return (
        status: status,
        identity: (identity == null || identity.isEmpty) ? null : identity,
        // Carried so the gate can SHOW why, rather than a generic "cannot use
        // Auvy" that hides whether the service refused the account or simply
        // couldn't be reached. Release builds don't forward `print` to logcat, so
        // without this the only place the reason existed was a log nobody sees.
        detail: status == 'approved'
            ? null
            : '$code: ${(body['error'] ?? '').toString()}',
      );
    } catch (e) {
      print('verifyAccess failed (treated as unavailable): $e');
      return (
        status: 'unavailable',
        identity: null,
        detail: e.runtimeType.toString(),
      );
    }
  }

  /// Silently activate cloud backup/restore for the signed-in YouTube account —
  /// NO Google account picker, ever (the single WebView YouTube login is the only
  /// sign-in). Uses the C1 Worker's verified custom token + a per-user encryption
  /// key, keyed by the YouTube account.
  /// [interactive] is retained for call-site compatibility but is now a no-op:
  /// nothing here can prompt the user.
  /// QUEUED, NOT COALESCED, and the difference caused real data loss.
  ///
  /// Two of these must never overlap: each performs a RESTORE
  /// (activateAndRestore), overlapping runs both write prefs, and the one that
  /// finishes first clears CloudSyncService's `_restoring` flag while the other is
  /// still restoring — precisely the window in which a push can overwrite the
  /// cloud copy being restored from.
  ///
  /// The first attempt at that guard SHARED the in-flight future with later
  /// callers, and that was wrong, because the result depends on state that
  /// changes between calls. On an app whose data had just been cleared:
  ///
  ///   1. startup finds no saved account and fires registerAccountFromSession(),
  ///      which reaches this method while the YouTube identity is still
  ///      unresolved, so it returns false ("no identity yet — deferring sync");
  ///   2. the user finishes logging in and calls this again, and the shared
  ///      future handed back that stale FALSE;
  ///   3. no restore ever ran, and the user was shown onboarding as if they were
  ///      brand new — with their cloud backup sitting there untouched.
  ///
  /// So callers are QUEUED instead: each waits for the previous attempt to finish
  /// and then makes its OWN, against the state as it stands when it runs. That
  /// keeps the no-overlap property without ever substituting one caller's answer
  /// for another's.
  ///
  /// Each link awaits the PREVIOUS link, never its own future — the
  /// re-entrancy trap that once froze the catalog client.
  Future<bool>? _enableChain;

  Future<bool> enableCloudBackup({bool interactive = false}) {
    // JOIN AN IN-FLIGHT ACTIVATION. DO NOT QUEUE A SECOND ONE BEHIND IT.
    //
    // This used to CHAIN: a concurrent caller awaited the running attempt and
    // then ran the whole thing again. One login therefore hit the Worker sign-in
    // endpoint two or three times — visible in /admin as "3 sign ins" for a
    // single sign-in, and each one is a KV write on a tier that allows about a
    // thousand a day. It also paid the Firebase custom-token sign-in more than
    // once, which is the slowest step in the whole flow.
    //
    // Joining is safe because both calls do IDENTICAL work: the interactive flag
    // is not read anywhere inside _enableCloudBackup on the C1 path — it is a
    // leftover from the old Google-OAuth flow, where it decided whether an
    // account picker could appear. A second caller can therefore only ever want
    // the answer the first one is already fetching.
    //
    // The chain below is kept for SEQUENTIAL calls, which is what it was written
    // for: never awaiting your own future is the re-entrancy rule that matters.
    final inFlight = _enableChain;
    if (inFlight != null) return inFlight;

    final previous = _enableChain;
    // `late` so the completion callback can compare against this very future —
    // it cannot run until after the assignment below, because whenComplete fires
    // asynchronously.
    late Future<bool> next;
    next = _enableAfter(previous, interactive).whenComplete(() {
      // Drop the tail so a settled chain isn't retained forever. Only the CURRENT
      // tail clears it; an earlier link finishing must not orphan a later one.
      if (identical(_enableChain, next)) _enableChain = null;
    });
    _enableChain = next;
    return next;
  }

  Future<bool> _enableAfter(Future<bool>? previous, bool interactive) async {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // A failed attempt is still a finished one; ours proceeds regardless.
      }
    }
    return _enableCloudBackup(interactive: interactive);
  }

  Future<bool> _enableCloudBackup({bool interactive = false}) async {
    // Wait for Firebase, do NOT test it.
    //
    // This runs from the account provider's init, which fires as soon as the
    // widget tree builds — while `main()` is still awaiting
    // `Firebase.initializeApp`. Testing a boolean there is a race, and on a Tab
    // S8 it lost by 277 ms:
    //
    //   22:55:35.157 enableCloudBackup: Firebase NOT available
    //   22:55:35.434 Firebase ready — cloud sync enabled
    //
    // Nothing retried, so that device silently had no cloud backup and no
    // restore for the whole session. Awaiting the ready signal makes the outcome
    // depend on whether Firebase EXISTS rather than on which future won a race.
    //
    // The timeout is what keeps "no Firebase project configured" fast: that
    // future never completes, and 8 s is well past a cold init on a slow device
    // while still bounded.
    if (!CloudSyncService.isAvailable) {
      try {
        await CloudSyncService.ready.timeout(const Duration(seconds: 8));
        print('enableCloudBackup: waited for Firebase — now ready');
      } catch (_) {
        print('enableCloudBackup: Firebase NOT available after 8s — '
            'staying local-only');
        return false;
      }
    }
    try {
      // C1 SECURE FLOW (active only when the Worker URL is configured)
      // Verify account ownership server-side → Firebase custom token (stable uid
      // == the same backup key, so NO data migration) + per-user encryption key.
      // FAIL-CLOSED: never fall back to anonymous (that would reopen the hole).
      if (_c1WorkerUrl.isNotEmpty) {
        final ytIdentity = (state.youtube?.email?.isNotEmpty == true)
            ? state.youtube!.email!
            : (state.youtube?.userId ?? '');
        if (ytIdentity.isEmpty) {
          print('enableCloudBackup[C1]: no YouTube identity yet — deferring');
          return false;
        }
        final cookie = await SessionCookieManager().getCookieHeader();
        if (cookie == null || cookie.isEmpty) {
          print('enableCloudBackup[C1]: no YT cookie yet — deferring');
          return false;
        }
        // RETRIED, AND ON A LONGER LEASH THAN 15s.
        //
        // This one request decides whether the user's library comes back. A
        // single 15s timeout was enough to fail it — a cold Worker plus a cookie
        // payload on mobile data can genuinely take longer, and failing it sent
        // a returning user into onboarding as though their account were gone.
        // One retry costs a few seconds in the rare bad case and saves the
        // account-looks-deleted outcome.
        final body =
            jsonEncode({'cookie': cookie, 'hint': await _displayHint()});
        // Phase timing: the login wait was 13s in total and the split between the
        // Worker call and the library restore was not visible anywhere.
        final tWorker = DateTime.now();
        // REUSE THE LAUNCH VERDICT — verifyAccess() POSTS THE IDENTICAL
        // REQUEST. Same URL, same {cookie, hint} body, and its response already
        // carries firebaseToken/uid/encKey. On a normal launch the answer is
        // therefore already in hand and this costs no network at all. Rebuilt as a
        // Response so every check below is untouched; re-encoding a few hundred
        // bytes is free next to another round trip carrying the whole cookie
        // header. See the note on _workerAnswer for the measured 3-POST launch.
        final reuse = _cachedWorkerAnswer(cookie);
        http.Response? resp =
            reuse == null ? null : http.Response(jsonEncode(reuse.body), reuse.code);
        if (reuse != null) {
          print('cloud: reused the launch verdict — no extra worker request');
        }
        Object? lastError;
        for (var attempt = 1; resp == null && attempt <= 2; attempt++) {
          try {
            resp = await http
                .post(Uri.parse(_c1WorkerUrl),
                    headers: {'Content-Type': 'application/json'},
                    body: body)
                .timeout(Duration(seconds: attempt == 1 ? 25 : 35));
            break;
          } catch (e) {
            lastError = e;
            if (!_isTransientNetworkError(e) || attempt == 2) rethrow;
            print('enableCloudBackup[C1]: attempt $attempt failed '
                '(${e.runtimeType}) — retrying');
          }
        }
        if (resp == null) {
          throw lastError ?? TimeoutException('worker unreachable');
        }
        print('cloud: worker replied in '
            '${DateTime.now().difference(tWorker).inMilliseconds}ms');
        if (resp.statusCode != 200) {
          // Status only. A response body is remote input that can carry echoed
          // request context; release swallows print() anyway, but a log line
          // that cannot leak is better than one that relies on that.
          print('ERROR: enableCloudBackup[C1]: worker ${resp.statusCode}');
          // A DENIAL IS NOT A BUG, and must not look like one.
          //
          // The Worker now gates cloud backup on owner approval, so a legitimate
          // new user is refused on purpose. Failing silently here would present as
          // "backup just doesn't work" — the single most confusing outcome, since
          // playback carries on perfectly. Say which it is, once per launch.
          if (resp.statusCode == 403 || resp.statusCode == 429) {
            String? status;
            try {
              status = (jsonDecode(resp.body) as Map<String, dynamic>)['status']
                  as String?;
            } catch (_) {}
            // BLOCKING MUST DO MORE THAN TOAST. This branch used to just
            // say "cloud backup access was removed" and let the user carry on
            // playing — the owner had revoked them and nothing happened.
            if (status != null) _raiseRevoked(status, null);
            if (!_cloudDenialAnnounced) {
              _cloudDenialAnnounced = true;
              AnimatedToast.message(switch (status) {
                'pending' =>
                  'Cloud backup is waiting to be approved — everything else works',
                'blocked' => 'Cloud backup access was removed for this account',
                'closed' =>
                  'Cloud backup is not taking new accounts right now',
                'throttled' || 'capacity' =>
                  'Cloud backup is rate-limited right now — it will retry later',
                _ => 'Cloud backup unavailable for this account',
              });
            }
          }
          return false;
        }
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = j['firebaseToken'] as String?;
        final uid = j['uid'] as String?;
        final encKey = j['encKey'] as String?;
        if (token == null || token.isEmpty || uid == null || uid.isEmpty) {
          print('ERROR: enableCloudBackup[C1]: bad worker payload');
          return false;
        }
        await fb_auth.FirebaseAuth.instance.signInWithCustomToken(token);
        CloudSyncService.instance.setBackupEncKey(encKey);
        // Never let this account see data left behind by a previous one.
        await _ensureLocalDataBelongsTo(uid);
        // Timed on THIS path, not just the anonymous fallback. The fallback's
        // timer never printed a line, because it only runs when no worker URL is
        // configured, so the slowest phase of the login the user complained about
        // was the one phase with no measurement on it.
        final restoreStarted = DateTime.now();
        final restored = await CloudSyncService.instance.activateAndRestore(uid);
        print('cloud: activateAndRestore took '
            '${DateTime.now().difference(restoreStarted).inMilliseconds}ms');
        print('enableCloudBackup[C1]: SECURE session uid=${uid.substring(0, 12)}… '
            'restored=$restored');
        if (restored) {
          await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
          // Covers before the library, NOT after.
          //
          // Manually-set cover art: the bytes restore into prefs, but this
          // notifier read prefs at construction — before the restore — so
          // without this the files are never rebuilt and every custom cover
          // (playlists included) comes back blank.
          //
          // The ORDER matters as much as the call. A restored playlist's
          // `image` is a file path from the old install, and the rebuild here
          // writes the picture to a fresh path, so the library has to reconcile
          // against overrides that already exist. Reloading the library first
          // meant it reconciled against an empty map, kept the dead path, and
          // the cover stayed missing in the library grid while the home mosaic
          // (which resolves covers differently) showed it correctly.
          await _ref.read(artworkOverrideProvider.notifier).reloadFromStorage();
          await _ref.read(libraryProvider.notifier).reloadFromStorage();
        await _rebuildDerivedCollections();
          await _rebuildDerivedCollections();
          await _applyRestoredSettings();
          // REBUILD THE HOME FEED, or Quick Picks stays wrong until something
          // else happens to refresh it.
          //
          // Quick Picks is generated from the taste profile (trackAffinities,
          // playCounts, trackMetadata) — unlike the other shelves, which come
          // from YouTube and look right regardless. On a fresh install the feed
          // is built BEFORE this restore lands, so it is built from an empty
          // profile, and then CACHED: arbitrary picks that survive relaunches.
          // That is the "everything else is correct but Quick Picks is
          // scrambled after logging in" report.
          //
          // Unawaited on purpose — it fetches over the network and must not hold
          // up entry into the app. refreshHome overwrites the cached feed.
          try {
            _ref.read(homeProvider.notifier).refreshHome();
          } catch (_) {}
        }
        return true;
      }

      // LEGACY FLOW (anonymous session + email-hash key)
      //
      // Reached only when no worker URL is compiled in, AND it cannot succeed.
      // `firestore.rules` grants `/user_backups/{userId}` on `request.auth.uid ==
      // userId`. C1 satisfies that because the Worker mints a custom token for the
      // very uid used as the document id. This flow does not: the id is a hash of
      // the YouTube email while the session is an ANONYMOUS uid, so every read and
      // write below is denied by the server.
      //
      // That is the safe failure — it cannot expose another account's backup,
      // because it cannot reach any document at all, but it is still a dead
      // branch, and it is the only `signInAnonymously` left in the app. Kept for
      // now rather than deleted because a fork running its own Firebase project
      // may write different rules; a build of THIS project always carries the
      // Worker URL (tool/build_release.ps1 passes it, and a build without it is
      // already broken in other ways).
      print('WARN: enableCloudBackup: no Worker URL compiled in — falling back to '
          'the legacy anonymous flow, which the shipped Firestore rules deny. '
          'Cloud backup will not work in this build.');
      // 1. Anonymous Firebase session.
      fb_auth.User? fbUser = fb_auth.FirebaseAuth.instance.currentUser;
      if (fbUser == null) {
        final cred = await fb_auth.FirebaseAuth.instance.signInAnonymously();
        fbUser = cred.user;
        print('enableCloudBackup: anonymous Firebase sign-in → '
            '${fbUser?.uid ?? "null"}');
      } else {
        print('enableCloudBackup: reusing Firebase user ${fbUser.uid} '
            '(anon=${fbUser.isAnonymous})');
      }
      if (fbUser == null) {
        print('enableCloudBackup: anonymous sign-in failed — cannot sync');
        return false;
      }

      // 2. Stable per-account key from the YouTube identity (NOT the anon uid).
      final ytIdentity = (state.youtube?.email?.isNotEmpty == true)
          ? state.youtube!.email!
          : (state.youtube?.userId ?? '');
      final backupKey = _backupKeyFor(ytIdentity);
      if (backupKey == null) {
        print('enableCloudBackup: no YouTube identity yet — deferring sync');
        return false;
      }
      print('enableCloudBackup: key=${backupKey.substring(0, 12)}… '
          '(from YT identity) — activating restore');

      // Never let this account see data left behind by a previous one.
      await _ensureLocalDataBelongsTo(backupKey);
      final tRestore = DateTime.now();
      final restored = await CloudSyncService.instance.activateAndRestore(backupKey);
      print('cloud: activateAndRestore took '
          '${DateTime.now().difference(tRestore).inMilliseconds}ms → $restored');
      if (restored) {
        await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
        await _ref.read(libraryProvider.notifier).reloadFromStorage();
        await _rebuildDerivedCollections();
        await _applyRestoredSettings();
      }
      cloudActivationUnreachable = false;
      return true;
    } catch (e) {
      // DISTINGUISH "NO BACKUP" FROM "COULD NOT REACH THE BACKUP".
      //
      // Both used to return plain false, and the login gate read that single
      // false as "brand-new user" and pushed onboarding. So one slow moment on
      // the Worker call — a 15s timeout was enough — made a returning user with a
      // full cloud backup land in onboarding, looking exactly as though clearing
      // the app's data had deleted their account. It had not: the restore simply
      // never ran.
      //
      // A transient failure is now recorded so the caller can refuse to draw that
      // conclusion. See LoginGatePage._proceed.
      cloudActivationUnreachable = _isTransientNetworkError(e);
      print('ERROR: Cloud backup activation FAILED '
          '(unreachable=$cloudActivationUnreachable): $e');
      return false;
    }
  }

  /// True when the last activation failed because the service could not be
  /// REACHED, rather than because this account has nothing stored.
  ///
  /// The difference decides whether "no local data" means "you are new" or "we
  /// don't know yet", and only the first of those may trigger onboarding.
  bool cloudActivationUnreachable = false;

  /// Is [e] a "try again" failure rather than a definite answer?
  static bool _isTransientNetworkError(Object e) =>
      e is TimeoutException ||
      e is SocketException ||
      e is HandshakeException ||
      e is http.ClientException ||
      // FirebaseAuth surfaces connectivity problems as a network-request-failed
      // code rather than a typed socket error.
      e.toString().contains('network-request-failed');

  /// Prefs holding PERSONAL data (as opposed to device settings). Wiped when the
  /// device changes hands between accounts. Anything matching [_userDataPrefixes]
  /// goes too, which covers the whole `intel_*` taste/history family.
  /// auvy_lib:: IS LISTED EVEN THOUGH THE LOCAL STORE DOES NOT USE IT YET.
  ///
  /// It is the prefix library_sync_split gives every per-playlist part, and
  /// those parts are what a cloud RESTORE writes. A restore that lands and is
  /// then followed by an account switch would otherwise leave one account's
  /// playlists in prefs under keys this wipe does not match — the same
  /// cross-account leak the auvy_library_data_last_good note below describes,
  /// in a key shape that was simply not thought of.
  ///
  /// Listing it now also means the local store can be split per playlist later
  /// without that change quietly reopening the hole.
  static const List<String> _userDataPrefixes = ['intel_', 'auvy_lib::'];
  static const List<String> _userDataKeys = [
    // Library, home-mosaic recents and their play-origin map.
    'auvy_library_data',
    // MUST BE WIPED WITH THE LIBRARY ITSELF. LibraryNotifier keeps a
    // last-known-good copy here and falls back to it when the live blob reads
    // empty (see _kLibraryBackupKey). Leaving it behind on an account switch
    // would hand the incoming account the previous one's playlists — the exact
    // leak this list exists to prevent.
    'auvy_library_data_last_good',
    'recent_playlists_v1',
    'recent_playlist_origins_v1',
    // Playback session snapshot (queue segments + resume point).
    'auvy_user_queue', 'auvy_context_queue', 'auvy_autoplay_queue',
    'auvy_user_queue_end', 'auvy_queue', 'auvy_original_queue',
    'auvy_current_song', 'auvy_position', 'auvy_history',
    'auvy_ctx_id', 'auvy_ctx_type', 'auvy_ctx_title',
    'player_resume_song', 'player_resume_position_ms',
    'player_resume_source', 'player_resume_context_title',
    // Per-user content state.
    'auvy_lyric_offsets', 'auvy_podcast_positions', 'auvy_podcast_taste_genres',
    'auvy_blacklist',
    // Personalised home feed.
    'cached_home_data',
    // "This account has used Auvy before" flags — a genuinely new account must
    // see onboarding. Both are cloud-backed, so a RETURNING account gets them
    // straight back from its own restore.
    'has_onboarded', 'has_seen_tutorial',
    // Restore watermark. MUST be cleared with the data: activateAndRestore only
    // pulls a backup STRICTLY NEWER than this, so leaving the previous account's
    // (newer) timestamp behind would silently skip the new account's restore.
    'cloud_last_backup_ms',
  ];

  /// Erase every trace of the current user's data from this device, leaving
  /// device-level settings (theme, quality, EQ…) alone. Used on logout and when
  /// a different account signs in. [wipeAudio] also removes cached/downloaded
  /// audio — correct on an account CHANGE (otherwise the disk scan re-imports
  /// the previous user's downloads into the new user's library), skipped on a
  /// plain logout so signing back into the SAME account keeps its downloads.
  /// Returns the steps that FAILED, empty on a clean wipe.
  ///
  /// EVERY STEP IS ISOLATED, AND THAT PART IS DELIBERATE — one store being
  /// unavailable must not stop the others from being cleared. What was wrong is
  /// that each failure was also SILENT. If the prefs sweep or the SQLite wipe
  /// threw, the incoming account simply kept the previous account's library,
  /// history and taste, the owner stamp was written as though the wipe had
  /// succeeded, and nothing anywhere recorded it. That is the one failure in this
  /// app that leaks one person's data to another, and it was the only one with no
  /// log line at all. Callers now decide what to do about a partial wipe — see
  /// _criticalWipeFailures.
  Future<List<String>> _wipeLocalUserData({bool wipeAudio = false, bool newAccount = false}) async {
    final failed = <String>[];
    // The Worker's cached answer is about the account being wiped. Keyed on the
    // cookie so it could not be misapplied anyway, but there is no reason to keep
    // a departing account's response body in memory.
    _forgetWorkerAnswer();
    // 1. In-memory playback session (queue/current track) — reset FIRST so its
    //    debounced save can't re-persist after the prefs wipe.
    try { await _ref.read(playerProvider.notifier).clearAllForAccountReset(); } catch (e) { failed.add('playback session ($e)'); }
    // 1b. THE LIBRARY, FOR EXACTLY THE SAME REASON AS THE LINE ABOVE.
    //
    // The player was reset first so its debounced save could not re-persist
    // after the prefs wipe, but the LIBRARY has the same hazard and was not
    // covered. Wiping the audio cache below fires onCacheUpdated →
    // refreshDownloadsFolder → _saveToDisk, which wrote the OUTGOING account's
    // rows back into the just-cleared prefs; the reload read them and the
    // incoming account inherited the previous one's playlists. See
    // LibraryNotifier._accountResetting.
    try { _ref.read(libraryProvider.notifier).beginAccountReset(); } catch (e) { failed.add('library reset guard ($e)'); }

    // 2. Personal prefs.
    try {
      final prefs = await SharedPreferences.getInstance();
      final doomed = prefs
          .getKeys()
          .where((k) =>
              _userDataKeys.contains(k) ||
              _userDataPrefixes.any((p) => k.startsWith(p)))
          .toList();
      for (final k in doomed) {
        await prefs.remove(k);
      }
    } catch (e) {
      failed.add('personal prefs ($e)');
    }

    // 3. The SQLite ledger (play history, playlists, search history, page
    //    caches) — a separate store that prefs cleanup never touches.
    try { await DatabaseService().wipeAllData(); } catch (e) { failed.add('sqlite ledger ($e)'); }

    // 4. On-device audio, only on a real account change (see [wipeAudio]).
    if (wipeAudio) {
      try { await AudioCacheManager().wipeEverything(); } catch (e) { failed.add('on-device audio ($e)'); }
    }

    // 5. Reload every provider from the now-empty stores. Without this the
    //    StateNotifiers keep serving the old account's data from memory (and
    //    would re-persist it on their next save).
    // A DIFFERENT account must not open the app wearing the previous user's
    // colour. Deliberately NOT done on a plain logout: the same account signing
    // back in keeps its accent, and a returning account gets its own back from
    // the cloud restore anyway (app_theme_color is a synced key). See
    // ThemeNotifier.resetToDefault.
    if (newAccount) {
      try { await _ref.read(themeProvider.notifier).resetToDefault(); } catch (e) { failed.add('theme ($e)'); }
    }
    try { await _ref.read(intelligenceProvider.notifier).reloadFromStorage(); } catch (e) { failed.add('taste reload ($e)'); }
    try { await _ref.read(libraryProvider.notifier).reloadFromStorage(); } catch (e) { failed.add('library reload ($e)'); }
    await _rebuildDerivedCollections();
    try { _ref.read(recentPlaylistsProvider.notifier).clear(); } catch (e) { failed.add('recent playlists ($e)'); }
    try { await _ref.read(searchProvider.notifier).loadHistory(); } catch (e) { failed.add('search history ($e)'); }
    try { _ref.read(dataUsageProvider.notifier).reset(); } catch (e) { failed.add('data counter ($e)'); }
    CatalogApiClient.clearCaches();

    if (failed.isEmpty) {
      print('local user data wiped cleanly'
          "${wipeAudio ? ' (including on-device audio)' : ''}");
    } else {
      print('ALERT: THE WIPE WAS INCOMPLETE — ${failed.length} step(s) failed: '
          '${failed.join('; ')}');
    }
    return failed;
  }

  /// The subset of wipe steps whose failure means another account's data is
  /// still on this device and reachable.
  ///
  /// The rest — the accent colour, the data counter — are cosmetic: getting them
  /// wrong shows the wrong colour, not the wrong person's library. The
  /// distinction earns its keep because the response to a critical failure is to
  /// leave the owner stamp alone so the next launch wipes again, and a repeat
  /// wipe deletes downloads. That trade is worth making for a leak and not for a
  /// colour.
  static List<String> _criticalWipeFailures(List<String> failed) => failed
      .where((f) =>
          f.startsWith('personal prefs') ||
          f.startsWith('sqlite ledger') ||
          f.startsWith('on-device audio') ||
          f.startsWith('library reload') ||
          f.startsWith('library reset guard') ||
          f.startsWith('taste reload') ||
          f.startsWith('playback session'))
      .toList();

  /// Guard against one account inheriting another's data. Compares the stored
  /// data-owner against the account about to activate: on a mismatch the device
  /// still holds the PREVIOUS user's history/library/taste, so wipe it before
  /// restoring. Also the safety net for the case logout can't cover (app killed
  /// mid-logout, cookies swapped externally) — without it the leftover
  /// `cloud_last_backup_ms` also made the new account's restore a no-op, and the
  /// next push uploaded the mixed data into the NEW account's cloud backup.
  /// Which SIGNED-IN IDENTITY owns the data on this device.
  ///
  /// Separate from `auvy_data_owner_v1` (the Worker-issued uid) because that one
  /// is only knowable when the Worker APPROVES the account. See the call site
  /// for the leak that created. Like that marker, this is deliberately NOT in
  /// [_userDataKeys]: it is what makes a switch detectable, so wiping it with the
  /// data would blind the next check.
  static const String _dataOwnerIdKey = 'auvy_data_owner_id_v1';

  /// Wipe the previous account's local data when a DIFFERENT account signs in,
  /// regardless of whether that account is approved for anything.
  ///
  /// Keyed on the identity (email/handle), NOT on the SAPISID cookie: Google
  /// rotates SAPISID on a password change, which would read as an account switch
  /// and throw away a user's downloads for changing their own password. The
  /// identity changes when, and only when — the account does.
  ///
  /// Hashed rather than stored plain: this only ever needs to answer "same or
  /// different", and that does not require keeping an email address in prefs.
  Future<void> _ensureLocalDataBelongsToSession(String identity) async {
    try {
      final trimmed = identity.trim().toLowerCase();
      if (trimmed.isEmpty) return; // unknown → never wipe on a guess
      final fp = sha256
          .convert(utf8.encode(trimmed))
          .toString()
          .substring(0, 32);
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_dataOwnerIdKey);
      if (owner != null && owner.isNotEmpty && owner != fp) {
        print('Account switch detected at sign-in — wiping the previous '
            "account's local data before this session sees it.");
        // wipeAudio: a real account change, so the disk scan must not re-import
        // the previous user's downloads into this user's library.
        final failures = _criticalWipeFailures(
            await _wipeLocalUserData(wipeAudio: true, newAccount: true));
        if (failures.isNotEmpty) {
          // Do NOT stamp an owner over data that is still there.
          //
          // Stamping says "this device now belongs to the new account", and it is
          // what stops this check running again. Saying it while the previous
          // account's library is still on disk makes the leak PERMANENT — the
          // mismatch never fires again, so nothing ever cleans it up.
          //
          // Leaving the stamp alone means the next launch sees the mismatch and
          // wipes again. The cost is a repeat wipe, which can delete downloads;
          // that is the right price for not showing one person another person's
          // listening history.
          print('ALERT: owner stamp WITHHELD — the wipe left user data behind '
              '(${failures.join('; ')}). The next launch will see the mismatch '
              'and wipe again rather than leaving it in place.');
          return;
        }
      }
      await prefs.setString(_dataOwnerIdKey, fp);
    } catch (e) {
      // NOT SWALLOWED: THIS KEY IS WHAT STOPS A REPEAT WIPE.
      //
      // The sequence is read-owner → wipe if different → WRITE the new owner. If
      // that write fails and the failure is hidden, the stored owner stays at the
      // previous account, so the NEXT sign-in compares against it and wipes
      // again — including downloads, which `wipeAudio: true` deletes. The wipe is
      // idempotent in principle; deleting audio the user has since re-downloaded
      // is not.
      //
      // A local prefs write realistically only fails on a full disk, so this is
      // rare rather than impossible, and this app has lost a library twice
      // before, both times to a silent write. Saying so is the difference
      // between a diagnosable bug and a mysterious one.
      print('ALERT: could not record the data owner id ($e) — a repeat '
          'account-switch wipe is now possible; check free storage');
    }
  }

  Future<void> _ensureLocalDataBelongsTo(String backupKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_dataOwnerKey);
      if (owner != null && owner.isNotEmpty && owner != backupKey) {
        print('Account switch detected — wiping the previous account\'s '
            'local data before restore.');
        final failures = _criticalWipeFailures(
            await _wipeLocalUserData(wipeAudio: true, newAccount: true));
        if (failures.isNotEmpty) {
          // Do NOT stamp an owner over data that is still there.
          //
          // Stamping says "this device now belongs to the new account", and it is
          // what stops this check running again. Saying it while the previous
          // account's library is still on disk makes the leak PERMANENT — the
          // mismatch never fires again, so nothing ever cleans it up.
          //
          // Leaving the stamp alone means the next launch sees the mismatch and
          // wipes again. The cost is a repeat wipe, which can delete downloads;
          // that is the right price for not showing one person another person's
          // listening history.
          print('ALERT: owner stamp WITHHELD — the wipe left user data behind '
              '(${failures.join('; ')}). The next launch will see the mismatch '
              'and wipe again rather than leaving it in place.');
          return;
        }
      }
      await prefs.setString(_dataOwnerKey, backupKey);
    } catch (e) {
      // Same reasoning as _ensureLocalDataBelongsToSession above: a hidden failure
      // here leaves the stored owner stale, and the next restore wipes again.
      print('ALERT: could not record the data owner key ($e) — a repeat '
          'account-switch wipe is now possible; check free storage');
    }
  }

  /// After a cloud restore, re-read restored SETTINGS into their live providers.
  /// Settings providers read their pref ONCE at startup (before the login-gate
  /// restore runs), so without this a reinstalled user's restored theme /
  /// quality / crossfade / EQ / data-saver / slider / haptics wouldn't apply
  /// until a manual app restart. Best-effort per setting (never throws).
  /// Rebuild the collections that are DERIVED rather than stored.
  ///
  ///"My Top 50" IS NOT IN THE BACKUP AND MUST NOT BE. It is computed from
  /// the play counts (which ARE backed up) by [refreshTop50], and the only thing
  /// that used to call it was a track FINISHING. So a restore brought the counts
  /// back and left the playlist empty until the user happened to finish a song —
  /// reported as "my top 50 should also be backed up, why is there nothing
  /// there". The data was restored; the derivation just never re-ran.
  ///
  /// Ordering requirement: the intelligence provider must already have reloaded,
  /// because that is where the counts come from. Every caller below does that
  /// first.
  Future<void> _rebuildDerivedCollections() async {
    try {
      final intel = _ref.read(intelligenceProvider);
      _ref.read(libraryProvider.notifier).refreshTop50(
          intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
    } catch (_) {}
  }
  Future<void> _applyRestoredSettings() async {
    try {
      await _ref.read(playerProvider.notifier).reloadSettings();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final c = prefs.getInt('app_theme_color');
      if (c != null) _ref.read(themeProvider.notifier).setThemeColor(Color(c));
      HapticService.enabled = prefs.getBool('auvy_haptics_enabled') ?? true;
      // Also re-applies the restored stream-source selection.
      ListeningPolicy.reloadFrom(prefs);
      // reloadFrom only sets the static; the WINDOW flag is normally applied by
      // MainActivity.onCreate, which already ran. Push it now so a restored
      // "block screenshots" doesn't wait for the next cold start.
      await ListeningPolicy.setBlockScreenshots(ListeningPolicy.blockScreenshots);
    } catch (_) {}
    // A restored alarm must be re-armed, NOT just remembered.
    //
    // The schedule lives in Android's AlarmManager, which knows nothing about a
    // Firestore restore, so restoring `auvy_alarm_enabled` alone produced the
    // worst possible state: a settings screen showing "07:30 · Weekdays" with no
    // alarm actually registered anywhere. It would have looked set and never
    // fired. `save()` re-arms natively (and cancels when disabled), and it
    // cancels before re-arming, so this cannot leave a duplicate behind.
    try {
      final prefs = await SharedPreferences.getInstance();
      AlarmService.reloadFrom(prefs);
      await AlarmService.save();
    } catch (_) {}
    // Reads its pref only in its constructor, like the three below.
    try {
      _ref.invalidate(pureBlackProvider);
    } catch (_) {}
    // These read their pref only in their constructor — recreate so the restored
    // value takes effect now (slider style, haptics toggle, data-saver mode).
    try {
      _ref.invalidate(sliderStyleProvider);
    } catch (_) {}
    // Same rule, three providers that were missing from it.
    //
    // All three load their pref in the constructor and never again, so a
    // restored value sat in prefs doing nothing until the next cold start —
    // which reads as "my settings did not come across" on a new device, since
    // these are exactly the visible ones.
    //
    // Invalidating densityProvider also refreshes `densityNow`, the static
    // mirror row builders read (DensityNotifier writes it from _load), so the
    // hand-built rows pick the restored value up in the same frame.
    try {
      _ref.invalidate(densityProvider);
    } catch (_) {}
    try {
      _ref.invalidate(miniPlayerStyleProvider);
    } catch (_) {}
    try {
      _ref.invalidate(dynamicAccentProvider);
    } catch (_) {}
    // Recently-played playlists are restored into prefs but the notifier only
    // reads them at construction, so the Home shelf stayed empty on a new device
    // until the app was restarted.
    try {
      _ref.invalidate(recentPlaylistsProvider);
    } catch (_) {}
    try {
      _ref.invalidate(hapticsProvider);
    } catch (_) {}
    try {
      _ref.invalidate(connectivityProvider);
    } catch (_) {}
    // "My Top 50" is normally rebuilt only from playback (player_queue), so
    // after a cloud restore it would sit stale/empty until the next song plays.
    // Rebuild it now from the just-restored listening data.
    try {
      final intel = _ref.read(intelligenceProvider);
      _ref.read(libraryProvider.notifier).refreshTop50(
          intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
    } catch (_) {}
  }

  /// Populate the YouTube session in the account provider from the persisted
  /// WebView cookies, via the InnerTube `account_menu` endpoint. Called on
  /// startup and right after a WebView login so the account icon shows the
  /// signed-in user (and gives the rest of the app a stable account identity)
  /// without a second OAuth prompt. No-op when not signed in.
  Future<bool> registerAccountFromSession({
    bool force = false,
    String? fallbackIdentity,
  }) async {
    try {
      // THIS IS WHY "LOG OUT" DIDN'T LOG OUT.
      //
      // This runs on startup exactly when no account is saved, which is the state
      // logout leaves behind. It then asks InnerTube who is signed in, using
      // whatever cookies exist, and re-registers the account if that answers.
      //
      // Logout clears the platform WebView cookie jar, but that removal is
      // ASYNCHRONOUS and unflushed (see SessionCookieManager.clearCookies): if any
      // usable cookie is still there on the next launch, this silently signed the
      // user straight back in, and the sign-out latch, which exists for exactly
      // this window, was never consulted here.
      //
      // Only the UNFORCED path is gated. The real login flow calls this with
      // force: true (login_gate_page), so signing in still works, and a
      // successful sign-in retires the latch via _markSessionActive.
      if (!force && await SessionCookieManager().hasExplicitlySignedOut()) {
        print('registerAccountFromSession: user signed out explicitly — '
            'not resurrecting the session');
        return false;
      }

      // Already registered from a cookie session — nothing to do unless forced.
      if (!force &&
          state.youtube != null &&
          state.youtube!.accessToken == _cookieSessionToken) {
        return true;
      }

      final info = await CatalogApiClient().getAccountInfo();
      if (info == null) {
        // "guest" after a successful login
        //
        // getAccountInfo returns null whenever hasAuthCookies() is false or
        // account_menu won't answer. Playback keeps working (public streams need
        // no auth cookie), so the app looked signed OUT while behaving signed in:
        // the side panel said "Guest", there was no Log out row, and — worse —
        // enableCloudBackup then bailed with "no YouTube identity yet", so the
        // approval Worker was never called and the gate never engaged.
        //
        // [fallbackIdentity] is the identity the WORKER resolved from these same
        // cookies, server-side and verified. If we have that, use it: it is the
        // exact string _backupKeyFor hashes, so the backup key is unchanged.
        var fb = fallbackIdentity?.trim() ?? '';
        // No identity supplied by the caller → ASK THE WORKER.
        //
        // Breaks a deadlock that left the app permanently on "Guest": local
        // resolution fails → no identity → enableCloudBackup returns early without
        // ever contacting the Worker → nothing can recover the identity, on this or
        // any future launch. The Worker resolves it from these same cookies
        // server-side, so it is the one component that can still answer. Only the
        // startup path reaches here without a fallback (the login gate passes one),
        // so this costs at most one request per launch, and only while broken.
        if (fb.isEmpty) {
          final access = await verifyAccess();
          fb = access.identity?.trim() ?? '';
          if (fb.isEmpty) {
            print('registerAccountFromSession: no identity locally AND none '
                'from the Worker (${access.status}/${access.detail}) — staying Guest');
            return false;
          }
        }
        print('registerAccountFromSession: account_menu gave nothing — '
            'using the identity the Worker verified instead');
        state = state.copyWith(
          youtube: AuthSession(
            userId: fb,
            displayName: fb.contains('@') ? fb.split('@').first : fb,
            email: fb.contains('@') ? fb : null,
            accessToken: _cookieSessionToken,
          ),
          preferredPrimary: AccountType.youtube,
        );
        await _saveAccount();
        return true;
      }

      final name = (info['name'] ?? '').trim();
      final email = (info['email'] ?? '').trim();
      final handle = (info['handle'] ?? '').trim();
      final avatar = (info['avatarUrl'] ?? '').trim();

      // Stable identity key (also the Firestore document key): a real email when
      // present, else the @handle, else the display name.
      final id = email.isNotEmpty ? email : (handle.isNotEmpty ? handle : name);
      if (id.isEmpty) return false;

      state = state.copyWith(
        youtube: AuthSession(
          userId: id,
          displayName:
              name.isNotEmpty ? name : (handle.isNotEmpty ? handle : 'YouTube User'),
          email: email.isNotEmpty ? email : null,
          avatarUrl: avatar.isNotEmpty ? avatar : null,
          // Marks this as a cookie-derived session (no Google OAuth token). The
          // OAuth-only import features still require loginWithMusicAccount().
          accessToken: _cookieSessionToken,
        ),
        preferredPrimary: AccountType.youtube,
      );
      await _saveAccount();
      print('OK: YouTube session registered: $id');

      // WHOSE DATA IS ON THIS DEVICE IS CHECKED HERE — NOT IN THE CLOUD PATH.
      //
      // `_ensureLocalDataBelongsTo` sits inside enableCloudBackup AFTER the
      // Worker's 200 check, so a REFUSED account returned early and the
      // account-switch wipe never ran. The previous account's library, history
      // and Quick Picks stayed on screen under the new account's session.
      // Observed exactly that way:
      //
      // YouTube session registered: <second account>
      // enableCloudBackup[C1]: worker 403
      //   …no "Account switch detected", no wipe
      //
      // "Is this account approved?" and "whose data is sitting on this phone?"
      // are unrelated questions, and answering the second only when the first
      // says yes is what leaked. This runs on EVERY registration, approved or
      // not, and needs nothing from the network.
      await _ensureLocalDataBelongsToSession(id);
      // Startup auto-registration: silent only (no unprompted account picker).
      // The login gate triggers the interactive sign-in separately.
      //
      // NOT AWAITED — THIS IS WHERE LOGIN SPENT TEN SECONDS.
      //
      // Registering the account needs cookies and a Worker check, both of which
      // are already done by the time we get here. Cloud activation needs neither:
      // it signs in to Firebase with a custom token, and measured on device that
      // step alone took 11.6s (worker 404ms, restore not even reached) — most of it
      // App Check with Play Integrity. Awaiting it made every login wait on
      // Firebase before the app would open.
      //
      // The caller that genuinely needs the result is the login gate, because a
      // returning user's backup carries has_onboarded and decides where they land.
      // It waits there instead, bounded, and only when the flag is not already set
      // locally, so the wait exists exactly where it can change something.
      //
      // Errors are swallowed rather than surfaced: cloud backup is an enhancement,
      // and a failure here must not fail a successful sign-in.
      enableCloudBackup(interactive: false).catchError((Object e) {
        print('background cloud activation failed: ${e.runtimeType}');
        return false;
      });
      return true;
    } catch (e) {
      print('ERROR: registerAccountFromSession failed: $e');
      return false;
    }
  }

  // Sentinel access token for sessions established via WebView cookies (not the
  // Google Sign-In OAuth flow), so we can tell the two apart.
  static const String _cookieSessionToken = 'cookie_session';

  Future<void> _saveAccount() async {
    final data = {
      'youtube': state.youtube?.toMap(),
      'discord': state.discord?.toMap(),
      'preferredPrimary': state.preferredPrimary.name, // Save preference
    };
    //  SECURE: store the OAuth/email blob in encrypted secure storage.
    try {
      await _secureStorage.write(key: _accountKey, value: jsonEncode(data));
    } catch (e) {
      // resetOnError is pinned false, so a transient Keystore failure throws
      // here instead of wiping the store. State stays in memory; the next
      // _saveAccount() call persists it.
      print("ALERT: Secure-storage write failed — account not persisted yet: $e");
    }
  }

  void setPreferredPrimary(AccountType type) {
    if (type == AccountType.youtube && state.youtube == null) return;
    if (type == AccountType.discord && state.discord == null) return;
    
    state = state.copyWith(preferredPrimary: type);
    _saveAccount();
  }

  // ----------------------------------------------------------------
  // String sanitization helpers
  // ----------------------------------------------------------------
  String _cleanArtist(String name) {
    return name
        .replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '') // Removes " - Topic"
        .replaceAll(RegExp(r'vevo$', caseSensitive: false), '')        // Removes "VEVO"
        .replaceAll(RegExp(r'\s*official$', caseSensitive: false), '') // Removes " Official"
        .trim();
  }

  String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'\(.*?(official|video|audio|lyric|visualizer).*?\)', caseSensitive: false), '') 
        .replaceAll(RegExp(r'\[.*?(official|video|audio|lyric|visualizer).*?\]', caseSensitive: false), '')
        .trim();
  }

  // Youtube integration
  // Base sign-in requests ONLY the non-sensitive `email` scope. Cloud backup /
  // Firebase Auth need nothing more, and this is what runs at the mandatory
  // login for EVERY user. The `youtube.readonly` scope is SENSITIVE: an
  // unverified app in "Testing" mode blocks any Google account that isn't an
  // explicit test user from granting it, which is why NEW Google accounts saw
  // "couldn't register" while the owner's test account worked. We now request
  // youtube.readonly INCREMENTALLY, only when the user explicitly imports their
  // YouTube playlists (see [_ensureMusicScope]).
  static const String _youtubeReadonlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);

  /// Request the sensitive YouTube read scope on demand (incremental auth),
  /// only for the optional "import my YouTube playlists" feature. Returns false
  /// if the user declines or the app isn't allowed to grant it.
  Future<bool> _ensureMusicScope() async {
    try {
      // Call requestScopes DIRECTLY. Do NOT gate on canAccessScopes(): that
      // method is UNIMPLEMENTED in this google_sign_in version and throws
      // UnimplementedError, which used to make this always return false — so
      // YouTube import/relink silently failed every time. requestScopes is
      // idempotent (returns true if already granted) and IS implemented.
      return await _googleSignIn.requestScopes([_youtubeReadonlyScope]);
    } catch (e) {
      print('WARN: YouTube scope request failed: $e');
      return false;
    }
  }

  // Ensures YouTube token is fresh before syncing
  Future<String?> _getValidMusicToken() async {
    if (state.youtube == null) return null;
    try {
      final googleUser = _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
      if (googleUser != null) {
        // Import needs the sensitive youtube.readonly scope — request it now
        // (incremental), not at base sign-in, so plain login stays unblocked.
        if (!await _ensureMusicScope()) return null;
        final auth = await googleUser.authentication;
        if (auth.accessToken != null && auth.accessToken != state.youtube!.accessToken) {
          state = state.copyWith(youtube: AuthSession(
            userId: state.youtube!.userId,
            displayName: state.youtube!.displayName,
            email: state.youtube!.email,
            avatarUrl: state.youtube!.avatarUrl,
            accessToken: auth.accessToken!
          ));
          await _saveAccount();
          return auth.accessToken;
        }
      }
    } catch(e) {
      print("ERROR: YT Token Refresh Error: $e");
    }
    return state.youtube!.accessToken;
  }

  Future<bool> loginWithMusicAccount() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn().timeout(const Duration(seconds: 30));
      if (googleUser == null) return false;

      // "Connect YouTube Music" exists to import playlists → needs the sensitive
      // scope. Request it incrementally here (only users who opt into import hit
      // the sensitive-scope grant, not every login).
      if (!await _ensureMusicScope()) return false;

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication.timeout(const Duration(seconds: 10));
      final String? accessToken = googleAuth.accessToken;

      if (accessToken != null) {
        state = state.copyWith(
          youtube: AuthSession(
            userId: googleUser.id,
            displayName: googleUser.displayName ?? 'YouTube User',
            email: googleUser.email,
            avatarUrl: googleUser.photoUrl,
            accessToken: accessToken,
          ),
          preferredPrimary: AccountType.youtube,
        );
        await _saveAccount();
        // Same ownership check as the cookie path, for the same reason.
        //
        // This path can activate a session for a DIFFERENT Google account than
        // the one the cookie session belongs to, and enableCloudBackup below can
        // be refused — in which case its own uid-based check never runs. Every
        // route that makes an account CURRENT has to answer "whose data is on
        // this device" before that account can see anything.
        await _ensureLocalDataBelongsToSession(
            googleUser.email.isNotEmpty ? googleUser.email : googleUser.id);
        // Reuses the Google account just signed in (no second picker).
        await enableCloudBackup(interactive: true);
        return true;
      }
    } catch (e) {
      print("ERROR: YouTube login failed: $e");
    }
    return false;
  }

  void disconnectMusicAccount() {
    _googleSignIn.signOut();
    // Clear the cookie session too, otherwise it gets re-registered on the next
    // launch (registerAccountFromSession reads the persisted cookies).
    SessionCookieManager().clearCookies();
    CatalogApiClient.clearCaches();
    CloudSyncService.instance.deactivate();
    if (CloudSyncService.isAvailable) {
      fb_auth.FirebaseAuth.instance.signOut().catchError((_) {});
    }
    state = state.copyWith(clearMusicSession: true);
    _saveAccount();
  }

  Future<List<Map<String, dynamic>>> fetchAccountPlaylists() async {
    final token = await _getValidMusicToken();
    if (token == null) return [];
    
    final response = await http.get(
      Uri.parse('https://www.googleapis.com/youtube/v3/playlists?part=snippet&mine=true&maxResults=50'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 12),
              onTimeout: () => http.Response('', 408));
    if (response.statusCode != 200) {
      // Status, not body — an InnerTube error response echoes request context
      // (visitorData and friends) that has no business in a log.
      print("ERROR: YouTube Playlists Error: HTTP ${response.statusCode}");
      return [];
    }
    
    final data = jsonDecode(response.body);
    return List<Map<String, dynamic>>.from(data['items'] ?? []);
  }

  Future<List<Song>> fetchAccountPlaylistTracks(String playlistId) async {
    final token = await _getValidMusicToken();
    if (token == null) return [];
    
    final List<Song> songs = [];
    final searchService = _ref.read(searchServiceProvider); // <-- Access to primary catalog
    String? pageToken;
    
    do {
      final uri = Uri.parse(
        'https://www.googleapis.com/youtube/v3/playlistItems'
        '?part=snippet&playlistId=$playlistId&maxResults=50'
        '${pageToken != null ? '&pageToken=$pageToken' : ''}',
      );
      final response = await http.get(uri, headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 12),
              onTimeout: () => http.Response('', 408));
      if (response.statusCode != 200) break;
      final data = jsonDecode(response.body);
      
      final items = data['items'] as List? ?? [];
      
      // Process tracks concurrently for faster matching
      final futures = items.map((item) async {
        final snippet = item['snippet'];
        final videoId = snippet?['resourceId']?['videoId'];
        if (videoId == null) return null;

        final rawTitle = snippet['title'] ?? '';
        final rawArtist = snippet['videoOwnerChannelTitle'] ?? '';
        final rawImage = snippet['thumbnails']?['high']?['url'] ?? '';

        final cleanTitle = _cleanTitle(rawTitle);
        final cleanArtist = _cleanArtist(rawArtist);

        // 1. Try to find the real standard track in the main catalog
        try {
          // E.g. searches "Get Lucky Daft Punk" instead of "Get Lucky (Official Video) Daft Punk - Topic"
          final results = await searchService.search('$cleanTitle $cleanArtist', 'track');
          if (results.isNotEmpty) {
            return results.first; // Success! Real track with album ID, explicit tags, correct image, etc.
          }
        } catch (_) {}

        // 2. Fallback to cleaned YouTube metadata if no match is found
        return Song(
          id: videoId, 
          title: cleanTitle,
          artist: cleanArtist,
          image: rawImage,
        );
      });

      final resolvedBatch = await Future.wait(futures);
      songs.addAll(resolvedBatch.whereType<Song>());
      
      pageToken = data['nextPageToken'];
    } while (pageToken != null);
    
    return songs;
  }

  Future<void> _importAccountRegularPlaylists() async {
    final playlists = await fetchAccountPlaylists();
    final library = _ref.read(libraryProvider.notifier);

    for (final playlist in playlists) {
      final id = playlist['id'] as String? ?? '';
      final name = playlist['snippet']?['title'] as String? ?? 'Untitled';
      final image = playlist['snippet']?['thumbnails']?['high']?['url'] as String? ?? '';

      final tracks = await fetchAccountPlaylistTracks(id);
      if (tracks.isEmpty) continue;

      final playlistSong = Song(id: 'imported_$id', title: name, artist: '', image: image);
      library.savePlaylistFromSearch(playlistSong, tracks);
    }
  }

  Future<void> importLikedSongsFromAccount() async {
    final tracks = await fetchAccountPlaylistTracks('LL');
    if (tracks.isEmpty) return;

    final library = _ref.read(libraryProvider.notifier);
    final item = Song(id: 'imported_youtube_liked', title: 'YouTube Liked Videos', artist: '', image: 'https://www.youtube.com/img/desktop/yt_1200.png');
    library.savePlaylistFromSearch(item, tracks);
  }

  Future<void> importAccountSubscriptions() async {
    final token = await _getValidMusicToken();
    if (token == null) return;
    final List<Song> channels = [];
    String? pageToken;

    do {
      final uri = Uri.parse(
        'https://www.googleapis.com/youtube/v3/subscriptions?part=snippet&mine=true&maxResults=50${pageToken != null ? '&pageToken=$pageToken' : ''}',
      );
      final response = await http.get(uri, headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 12),
              onTimeout: () => http.Response('', 408));
      if (response.statusCode != 200) break;
      final data = jsonDecode(response.body);

      for (final item in data['items'] ?? []) {
        final snippet = item['snippet'];
        final rawTitle = snippet?['title'] ?? '';
        channels.add(Song(
          id: snippet?['resourceId']?['channelId'] ?? '',
          title: _cleanArtist(rawTitle), // Clean the channel name!
          artist: 'Artist',
          image: snippet?['thumbnails']?['high']?['url'] ?? '',
        ));
      }
      pageToken = data['nextPageToken'];
    } while (pageToken != null);

    final library = _ref.read(libraryProvider.notifier);
    for (final channel in channels) {
      if (channel.id.isNotEmpty && channel.title.isNotEmpty) {
        library.toggleArtistSubscription(channel.title, channel.image, channel.id);
      }
    }
  }

  /// Import the signed-in user's YT MUSIC library via the WebView COOKIE
  /// session (InnerTube authed browse) — the path that actually works for the
  /// app's normal login. Returns the number of collections imported, or -1
  /// when there is no cookie session (caller falls back to OAuth).
  Future<int> _importViaCatalogApi() async {
    if (!await SessionCookieManager().hasAuthCookies()) return -1;
    final client = CatalogApiClient();
    final search = _ref.read(searchServiceProvider);
    final library = _ref.read(libraryProvider.notifier);
    int imported = 0;

    // The account is the source of truth, so the page caps have to fit a real
    // LIBRARY — AND SAY SO WHEN THEY DO NOT.
    //
    // Another player's BACKUP FILE cannot stand in for this. Verified against a
    // real Metrolist backup: its `playlist` rows carried no local track mappings
    // at all, because that app keeps playlists on YouTube and stores only a
    // reference to them. The file held 14 liked songs against a library of
    // thousands. Whatever the file format, the playlists live in the account, and
    // this is the only path that reaches them.
    //
    // The old caps were 10 pages of Liked Music (~1000 tracks), 3 pages of the
    // playlist LISTING and 10 pages per playlist, with nothing reported when a
    // cap was reached, so a large library imported partially and looked
    // complete. Raised, and every list that comes back exactly at its ceiling is
    // logged as suspected-truncated rather than assumed whole.
    const likedPages = 40; // ~4000 liked tracks
    const listingPages = 12; // ~1200 playlists/albums in the library listing
    const perPlaylistPages = 30; // ~3000 tracks in one playlist

    // 1. Liked Music — YT Music's auto-playlist 'LM'.
    try {
      final liked = await search.getPlaylistTracks('LM',
          maxPages: likedPages, authenticated: true);
      if (liked.isNotEmpty) {
        library.savePlaylistFromSearch(
          Song(id: 'imported_youtube_liked', title: 'Liked Music', artist: 'YouTube Music', image: liked.first.image),
          liked,
        );
        imported++;
        print('YT Music: Liked Music — ${liked.length} track(s)');
      }
    } catch (e) {
      print('WARN: Liked Music import failed: $e');
    }

    // 2. Every playlist in the user's library (own + saved).
    try {
      final resp = await client.getBrowse('FEmusic_liked_playlists',
          maxPages: listingPages, authenticated: true);
      final items = (resp['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => '${m['type']}' == 'playlist')
          .toList();
      print('YT Music library: ${items.length} playlist(s) found');
      for (final m in items) {
        var id = '${m['id'] ?? ''}';
        if (id.startsWith('VL')) id = id.substring(2);
        final name = '${m['title'] ?? ''}'.trim();
        // 'LM' already imported above; 'SE' is the podcast "Episodes for Later".
        if (id.isEmpty || name.isEmpty || id == 'LM' || id == 'SE') continue;
        try {
          final tracks = await search.getPlaylistTracks(id,
              maxPages: perPlaylistPages, authenticated: true);
          if (tracks.isEmpty) continue;
          final thumb = '${m['thumbnail'] ?? ''}';
          final cover = thumb.isNotEmpty ? thumb : tracks.first.image;
          // A name collision must NOT silently drop a playlist.
          //
          // savePlaylistFromSearch REFUSES a title that already exists and
          // returns false, and nothing checked it, so a second playlist with the
          // same name vanished while the log still reported its track count.
          // Observed on a real account: two playlists both called "Jus Vibe" (75
          // and 76 tracks) — the 76 was read, counted, and thrown away.
          //
          // Numbered instead, so both survive and the user can tell them apart.
          var saved = library.savePlaylistFromSearch(
              Song(
                  id: 'imported_$id',
                  title: name,
                  artist: 'YouTube Music',
                  image: cover),
              tracks);
          var attempt = 2;
          var finalName = name;
          while (!saved && attempt <= 20) {
            finalName = '$name ($attempt)';
            saved = library.savePlaylistFromSearch(
                Song(
                    id: 'imported_${id}_$attempt',
                    title: finalName,
                    artist: 'YouTube Music',
                    image: cover),
                tracks);
            attempt++;
          }
          if (!saved) {
            print('WARN: YT Music: "$name" could not be added (name taken)');
            continue;
          }
          imported++;
          print('YT Music: "$finalName" — ${tracks.length} track(s)');
        } catch (e) {
          print('WARN: Import of "$name" failed: $e');
        }
      }
    } catch (e) {
      print('ERROR: Library playlist listing failed: $e');
    }

    // 3. Saved ALBUMS. Previously imported only on the OAuth path, which needs a
    // scope Google refuses for an unverified app, so for every normal cookie
    // login they were silently skipped and the library came back playlists-only.
    try {
      final resp = await client.getBrowse('FEmusic_liked_albums',
          maxPages: listingPages, authenticated: true);
      final albums = (resp['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => '${m['type']}' == 'album')
          .toList();
      print('YT Music: ${albums.length} saved album(s)');
      for (final m in albums) {
        final title = '${m['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        // The subtitle is YT Music's own "Album • Artist • Year" line; the first
        // segment after the type is the artist, and a liked album without one
        // opens EMPTY later (see toggleAlbumLike).
        final subtitle = '${m['subtitle'] ?? ''}';
        final parts = subtitle.split('•').map((s) => s.trim()).toList();
        final artist = parts.length > 1 ? parts[1] : '';
        library.toggleAlbumLike(
          Album(
            id: '${m['id'] ?? ''}',
            title: title,
            image: '${m['thumbnail'] ?? ''}',
            releaseDate: '',
            recordType: 'album',
            subtitle: subtitle,
            artist: artist,
          ),
          artist,
        );
        imported++;
      }
    } catch (e) {
      print('WARN: Saved albums import failed: $e');
    }

    // 4. Followed ARTISTS, same story as albums.
    try {
      final resp = await client.getBrowse('FEmusic_library_corpus_artists',
          maxPages: listingPages, authenticated: true);
      final artists = (resp['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => '${m['type']}' == 'artist')
          .toList();
      print('YT Music: ${artists.length} followed artist(s)');
      for (final m in artists) {
        final name = '${m['title'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        library.toggleArtistSubscription(
            name, '${m['thumbnail'] ?? ''}', '${m['id'] ?? ''}');
        imported++;
      }
    } catch (e) {
      print('WARN: Followed artists import failed: $e');
    }
    return imported;
  }

  /// Sync the user's YT Music library into Auvy. Cookie-session (InnerTube)
  /// first — the OAuth/Data-API path below needs the sensitive
  /// youtube.readonly scope, which Google refuses for non-test users while
  /// the app is unverified, so for normal WebView logins it silently imported
  /// NOTHING (the "syncing from YouTube Music doesn't work" bug). Returns how
  /// many collections were imported.
  Future<int> importAllAccountPlaylists() async {
    try {
      final viaCookies = await _importViaCatalogApi();
      if (viaCookies >= 0) return viaCookies;

      // No cookie session → legacy OAuth import (test users only).
      await Future.wait([
        _importAccountRegularPlaylists(),
        importLikedSongsFromAccount(),
        importAccountSubscriptions(),
      ]);
      return 1;
    } catch (e) {
      print("ERROR: Error importing YouTube: $e");
      return 0;
    }
  }

  // ----------------------------------------------------------------
  // Discord integration
  // ----------------------------------------------------------------
  Future<bool> linkPresenceAccount() async {
    try {
      final verifier = _generateCodeVerifier();   
      final challenge = _generateCodeChallenge(verifier);

      final url = Uri.https('discord.com', '/api/oauth2/authorize', {
        'client_id': discordClientId,
        'redirect_uri': discordRedirectUri,
        'response_type': 'code',            
        'scope': 'identify email',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });

      final result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: 'com.auvy.app',
      ).timeout(const Duration(seconds: 30));

      final code = Uri.parse(result).queryParameters['code'];
      if (code == null) return false;

      final tokenResponse = await http.post(
        Uri.parse('https://discord.com/api/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': discordRedirectUri,
          'client_id': discordClientId,
          'code_verifier': verifier,
        },
      ).timeout(const Duration(seconds: 10));

      if (tokenResponse.statusCode != 200) return false;

      final tokenData = jsonDecode(tokenResponse.body);
      final token = tokenData['access_token'] as String?;
      if (token == null) return false;

      final profileResponse = await http.get(
        Uri.parse('https://discord.com/api/users/@me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5));

      if (profileResponse.statusCode == 200) {
        final profile = await compute(jsonDecode, profileResponse.body);
        final avatarId = profile['avatar'];
        final userId = profile['id'];

        state = state.copyWith(
          discord: AuthSession(
            userId: userId,
            displayName: profile['global_name'] ?? profile['username'],
            email: profile['email'],
            avatarUrl: avatarId != null ? 'https://cdn.discordapp.com/avatars/$userId/$avatarId.png' : null,
            accessToken: token,
          ),
          preferredPrimary: AccountType.discord, 
        );
        await _saveAccount();
        return true;
      }
    } catch (e) {
      print("ERROR: Discord login failed: $e");
    }
    return false;
  }

  void unlinkPresenceAccount() {
    state = state.copyWith(clearPresenceSession: true);
    _saveAccount();
  }

  // ----------------------------------------------------------------
  // PKCE HELPERS
  // ----------------------------------------------------------------
  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  Future<void> logout() async {
    // FLUSH FIRST: pushes are debounced, so anything played in the last seconds
    // is still local-only. Back it up while the session is alive — the wipe
    // below is otherwise data loss for this account.
    if (CloudSyncService.instance.isActive) {
      // The one failure here that must NOT be silent.
      //
      // The comment above is not decoration: if this push does not land, the
      // wipe below destroys data that existed nowhere else. Swallowing the
      // exception meant that happened with no trace at all — the logout looked
      // completely normal, and the loss surfaced later as "my recent plays are
      // gone" with nothing in any transcript to explain it.
      //
      // The logout still proceeds. Someone asking to sign out is entitled to,
      // and refusing would trap them in an account they are trying to leave —
      // but the record now says what was at stake.
      try {
        await CloudSyncService.instance.pushNow();
      } catch (e) {
        print('ALERT: LOGOUT: the final backup FAILED ($e). The wipe below will '
            'destroy anything played since the last successful push, and it '
            'exists nowhere else. Proceeding, because a sign-out must not be '
            'refusable.');
      }
    }
    state = AccountState(); // Clears all sessions
    // Leave NO user data behind. Logout used to clear only the session, so the
    // next account to sign in inherited this one's history, library, mosaic
    // recents and taste profile (and, because `cloud_last_backup_ms` survived
    // too, its own restore was skipped as "not newer"). Stops playback as part
    // of the wipe, so no orphaned audio plays under the login gate — there is
    // NO guest mode; logout returns to the sign-in screen.
    // Downloads are KEPT: signing back into the same account restores the
    // library that references them. A switch to a DIFFERENT account wipes them
    // via [_ensureLocalDataBelongsTo].
    // Logout stamps no owner, so there is nothing to withhold, but the result
    // is still worth saying: signing back in would otherwise restore ON TOP of
    // whatever the failed step left behind.
    final logoutFailures = _criticalWipeFailures(await _wipeLocalUserData());
    if (logoutFailures.isNotEmpty) {
      print('ALERT: logout left user data on this device: '
          '${logoutFailures.join('; ')}');
    }
    // AWAITED. It was fire-and-forget, so logout could return, and the app
    // re-route to the splash and re-check the session — while Google was still
    // signing out.
    try { await _googleSignIn.signOut(); } catch (_) {}
    // End the YouTube cookie session so the login gate re-appears and the
    // session isn't silently re-registered on next launch.
    await SessionCookieManager().clearCookies();
    CatalogApiClient.clearCaches();
    CloudSyncService.instance.deactivate();
    if (CloudSyncService.isAvailable) {
      await fb_auth.FirebaseAuth.instance.signOut().catchError((_) {});
    }
    try {
      await _secureStorage.delete(key: _accountKey);
    } catch (e) {
      // Don't let a storage hiccup abort the rest of logout (prefs cleanup
      // below must still run). The stale blob is overwritten on next sign-in.
      print("WARN: Secure-storage delete failed during logout: $e");
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accountKey); // Clear any leftover legacy plaintext
    await prefs.remove('auvy_account');
  }

  /// True when cloud backup is live for the signed-in account (Firebase ready +
  /// a uid resolved). Drives the "cloud connected" hint in the account dialog.
  bool get isCloudActive => CloudSyncService.instance.isActive;

  /// Manually back up now so the user can confirm sync works. Ensures the
  /// account is signed in to Firebase (one account-picker tap if needed), then
  /// pushes immediately. Returns true only when the push actually SUCCEEDED
  /// (an attempted-but-failed push reports false; see
  /// [CloudSyncService.lastPushError] for the reason).
  Future<bool> backupNow() async {
    if (!CloudSyncService.isAvailable) return false;
    await enableCloudBackup(interactive: true);
    final attempted = await CloudSyncService.instance.pushNow();
    return attempted && CloudSyncService.lastPushError == null;
  }

  /// DELETE ACCOUNT — removes the user's Auvy data from OUR backend (the
  /// Firestore backup) and from the device, then resets the app to a
  /// brand-new-user state. This does NOT touch the user's Google/YouTube
  /// account — only Auvy's copy of their data. After this, logging in again
  /// with the same account starts fresh (onboarding + tutorial re-run).
  ///
  /// The caller is responsible for navigating to a fresh start (SplashScreen)
  /// afterwards.
  Future<bool> deleteAuvyAccount() async {
    // 1. Delete this account's cloud backup.
    //
    // The key is computed here, NOT left to the sync service to guess.
    //
    // The backup is keyed by a hash of the YouTube identity, and that hash is
    // the SAME after deleting and re-creating the account, so if the cloud copy
    // survives, the next sign-in restores everything the user just asked to have
    // erased. That is exactly what happened: the service could only fall back to
    // the anonymous Firebase uid, which never keys a backup, so it deleted a
    // document that had never existed and reported success.
    //
    // Deleted FIRST and its result carried to the end: if the cloud erase fails
    // there is no point pretending the account is gone, and the user has to be
    // told rather than discovering it on their next login.
    final ytIdentity = (state.youtube?.email?.isNotEmpty == true)
        ? state.youtube!.email!
        : (state.youtube?.userId ?? '');
    final identityKey = _backupKeyFor(ytIdentity);
    var cloudErased = false;
    try {
      cloudErased = await CloudSyncService.instance
          .deleteBackup(identityKey: identityKey);
    } catch (e) {
      print('ERROR: delete account: cloud erase threw ($e)');
    }
    CloudSyncService.instance.deactivate();

    // 2. Sign out everywhere + end the YouTube cookie session. The Firebase
    //    Auth USER is deleted too (best-effort — may require a recent login),
    //    and the Google grant is revoked with disconnect(), so signing in again
    //    with the same account is a genuine from-scratch registration.
    if (CloudSyncService.isAvailable) {
      try { await fb_auth.FirebaseAuth.instance.currentUser?.delete(); } catch (_) {}
    }
    try { await _googleSignIn.disconnect(); } catch (_) {}
    try { await _googleSignIn.signOut(); } catch (_) {}
    // A cookie that survives is a session that survives — the account this is
    // deleting could still be used. Worth a line even though nothing here can
    // retry it.
    try {
      await SessionCookieManager().clearCookies();
    } catch (e) {
      print('ALERT: DELETE ACCOUNT: could not clear the session cookies ($e) — the '
          'signed-out session may still be usable on this device');
    }
    CatalogApiClient.clearCaches();
    if (CloudSyncService.isAvailable) {
      try { await fb_auth.FirebaseAuth.instance.signOut(); } catch (_) {}
    }

    // 3. Wipe on-device audio (auto-cache + downloads + physical files).
    //
    // A SILENT FAILURE HERE IS AN ISOLATION LEAK, NOT AN INCONVENIENCE. The
    // next account to sign in on this device would find the previous one's
    // downloaded audio in its library — the same class of bug as the
    // account-switch wipe that once lived inside the cloud path.
    try {
      await AudioCacheManager().wipeEverything();
    } catch (e) {
      print('ALERT: DELETE ACCOUNT: on-device audio was NOT wiped ($e) — the next '
          'account on this device may inherit these files');
    }

    // 4. Reset in-memory playback state BEFORE clearing prefs so its debounced
    //    save can't re-persist stale data.
    try {
      await _ref.read(playerProvider.notifier).clearAllForAccountReset();
    } catch (e) {
      // The ordering note above says why this runs before the prefs clear: if
      // it fails, a debounced save can still re-persist the outgoing account's
      // state AFTER the wipe, undoing it.
      print('ALERT: DELETE ACCOUNT: playback state was NOT reset ($e) — a debounced '
          'save may re-persist the previous account over the wipe');
    }

    // 5. Clear every local store → true new-user state (incl. onboarding/tutorial
    //    flags, library, intelligence, settings, cache index). The SQLite ledger
    //    (play history, playlists, search history, page caches) is a separate
    //    store from prefs and must be wiped explicitly.
    try { await DatabaseService().wipeAllData(); } catch (_) {}
    try {
      await _secureStorage.deleteAll();
    } catch (_) {
      try { await _secureStorage.delete(key: _accountKey); } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // 6. Reload the data providers from the now-empty stores so nothing held in
    //    memory (feed, search history, stats) can leak the old identity or get
    //    re-persisted by a later debounced save.
    try { await _ref.read(intelligenceProvider.notifier).reloadFromStorage(); } catch (_) {}
    try { await _ref.read(libraryProvider.notifier).reloadFromStorage(); } catch (_) {}
    await _rebuildDerivedCollections();
    // Home mosaic recents live in an in-memory StateNotifier — prefs.clear()
    // doesn't touch them, so wipe explicitly or the deleted user's recently-played
    // albums/playlists linger in the mosaic.
    try { _ref.read(recentPlaylistsProvider.notifier).clear(); } catch (_) {}
    try { await _ref.read(searchProvider.notifier).loadHistory(); } catch (_) {}
    try { _ref.read(dataUsageProvider.notifier).reset(); } catch (_) {}
    try { _ref.read(themeProvider.notifier).setThemeColor(const Color(0xFF53B1E1)); } catch (_) {}
    // Rebuild the home feed from the (now empty) taste profile. Unawaited: it
    // fetches over the network and must not block the reset.
    try { _ref.read(homeProvider.notifier).refreshHome(); } catch (_) {}

    // 7. Clear account sessions in memory.
    state = AccountState();
    print(cloudErased
        ? 'Auvy account data deleted (cloud + device) — new-user state.'
        : 'WARN: Auvy account data deleted ON THIS DEVICE ONLY — the cloud copy '
            'could NOT be erased, so signing in again will restore it.');
    return cloudErased;
  }
}

final accountProvider = StateNotifierProvider<AccountNotifier, AccountState>((ref) {
  return AccountNotifier(ref);
});