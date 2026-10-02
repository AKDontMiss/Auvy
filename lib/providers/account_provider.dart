import 'dart:async' show TimeoutException, Completer;
import 'package:auvy/services/event_log.dart';
import 'package:auvy/core/net/app_token.dart';
import 'dart:convert';
// SocketException / HandshakeException — telling a "cannot reach the service"
// failure apart from a definite answer. See _isTransientNetworkError.
import 'dart:io' show HandshakeException, SocketException;
import 'dart:math';
import 'dart:ui' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/page_cache_service.dart';
import 'package:auvy/services/device_info_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart'; 
import 'package:http/http.dart' as http;
import 'package:auvy/services/http_pool.dart';
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
import 'package:auvy/services/play_tally.dart';
import 'package:auvy/services/set_log.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:auvy/core/backend_config.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/providers/mini_player_style_provider.dart';
import 'package:auvy/providers/podcast_provider.dart';
import 'package:auvy/providers/radio_provider.dart';
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/services/audiobook_service.dart';
import 'package:auvy/services/lyrics_translation_service.dart';

/// Raised when the Worker returns a verdict about the account (`pending`,
/// `blocked` or `closed`); MainLayout listens and returns to the sign-in page. A
/// signal rather than ejecting where it's detected, because the verdict can arrive
/// from several places (startup gate, cloud activation, resume re-check) and only
/// one of them has a Navigator.
///
/// Not raised for `unavailable`, `throttled` or `capacity`: those say nothing
/// about the user, and ejecting on them would turn a server hiccup or rate limit
/// into a forced logout.
final accessRevokedProvider =
    ValueNotifier<({String status, String? identity})?>(null);

/// The last verdict about the account seen by this process; no expiry. Not
/// `_workerAnswer`, which is a 20-second request-dedup cache whose expiry means
/// nothing. "This account is denied" and "never been told" are different facts;
/// only the second deserves the benefit of the doubt.
String? _lastSeenGateStatus;

/// The same fact on disk, since the value above starts each launch as null. The
/// gate and cloud activation both run at startup in no fixed order, and a revoked
/// account must not sync if activation happens to win. Written only for a denial
/// and removed on any other verdict, so it can't lock out a reinstated account.
const String _gateDeniedKey = 'auvy_gate_denied';

/// Completed by the first verdict of the launch, so callers can wait for one.
/// Reading `_lastSeenGateStatus` directly is a race with the gate; waiting on
/// this ensures the cloud path never acts on "no verdict yet" for a revoked
/// account.
Completer<String>? _firstVerdict;

/// The launch's verdict, waiting a bounded time for one to arrive.
///
/// Null on timeout, which keeps the offline meaning intact: we asked and were
/// never told, so the 14-day grace applies rather than a lockout.
Future<String?> _awaitFirstVerdict(Duration timeout) async {
  final known = _lastSeenGateStatus;
  if (known != null) return known;
  final c = _firstVerdict ??= Completer<String>();
  try {
    return await c.future.timeout(timeout);
  } catch (_) {
    return null;
  }
}

void _raiseRevoked(String status, String? identity) {
  _lastSeenGateStatus = status;
  final c = _firstVerdict;
  if (c != null && !c.isCompleted) c.complete(status);
  // Fire-and-forget: this must not delay the verdict reaching the UI, and a
  // failed write only costs the durability, not the in-memory check above.
  () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (status == 'pending' ||
          status == 'blocked' ||
          status == 'closed' ||
          status == 'device_revoked') {
        await prefs.setBool(_gateDeniedKey, true);
      } else if (status == 'approved') {
        await prefs.remove(_gateDeniedKey);
      }
      // Anything else — unavailable, throttled, capacity — is not a statement
      // about the account, so it neither sets nor clears the flag.
    } catch (_) {}
  }();
  if (status == 'pending' ||
      status == 'blocked' ||
      status == 'closed' ||
      status == 'device_revoked') {
    // A refused device has no business holding proof that it was approved.
    // The Worker also refuses the token itself now; this just stops sending it.
    AuvyAppToken.set(null);
    accessRevokedProvider.value = (status: status, identity: identity);
  }
}

enum AccountType { none, spotify, youtube }

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
/// One device this account is signed in on, for the Active devices list.
///
/// The id is a random per-install value, NOT a hardware identifier — see
/// `_deviceInfo`. `model` and `os` exist because a list of opaque ids cannot be
/// acted on, while "Galaxy S10 · Android 12" can.
class AuvyDevice {
  final String id;
  final String model;
  final String os;
  final int lastSeenMs;
  final int firstSeenMs;

  /// Marked so the UI can label it and refuse to offer signing it out from
  /// itself — which would work, but is a confusing thing to hand someone.
  final bool isThisDevice;

  const AuvyDevice({
    required this.id,
    required this.model,
    required this.os,
    required this.lastSeenMs,
    required this.firstSeenMs,
    required this.isThisDevice,
  });

  /// "Active now" / "2 hours ago", readable at a glance.
  String get lastSeenLabel {
    if (lastSeenMs <= 0) return 'Unknown';
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(lastSeenMs));
    if (d.inMinutes < 3) return 'Active now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// Cleanly format device model names, handling Android manufacturer capitalization
  /// and intelligent platform fallbacks rather than raw "Unknown device".
  static String formatDeviceModel(String? rawModel, String? rawOs) {
    var model = (rawModel ?? '').trim();
    final os = (rawOs ?? '').trim();
    if (model.isEmpty ||
        model.toLowerCase() == 'unknown device' ||
        model.toLowerCase() == 'mobile device') {
      if (os.toLowerCase().startsWith('android')) return 'Android device';
      if (os.toLowerCase().startsWith('ios')) return 'Apple device';
      if (os.toLowerCase().startsWith('mac') || os.toLowerCase().startsWith('darwin')) return 'Mac';
      if (os.toLowerCase().startsWith('windows')) return 'Windows PC';
      if (os.toLowerCase().startsWith('linux')) return 'Linux PC';
      return 'Unknown device';
    }
    // Respect Apple branding like "iPhone", "iPad", "iPod" and map raw machine codes
    if (model.startsWith('iPhone') ||
        model.startsWith('iPad') ||
        model.startsWith('iPod')) {
      final mapped = DeviceInfoService.lookupAppleMachine(model);
      return mapped ?? model;
    }
    // Format Samsung SM- model codes if missing manufacturer prefix
    if (model.toUpperCase().startsWith('SM-')) {
      return 'Samsung $model';
    }
    if (model.isNotEmpty &&
        model[0].toLowerCase() == model[0] &&
        model[0].toUpperCase() != model[0]) {
      model = '${model[0].toUpperCase()}${model.substring(1)}';
    }
    return model;
  }
}

class AccountState {
  final AuthSession? youtube;
  final AccountType preferredPrimary;

  AccountState({
    this.youtube, 
    this.preferredPrimary = AccountType.none, 
  });

  bool get isLoggedIn => youtube != null;

  AuthSession? get primary => youtube;

  String? get displayName => primary?.displayName;
  String? get email => primary?.email;
  String? get avatarUrl => primary?.avatarUrl;

  AccountState copyWith({
    AuthSession? youtube, 
    AccountType? preferredPrimary, 
    bool clearMusicSession = false, 
  }) {
    return AccountState(
      youtube: clearMusicSession ? null : (youtube ?? this.youtube),
      preferredPrimary: preferredPrimary ?? this.preferredPrimary,
    );
  }
}

class AccountNotifier extends StateNotifier<AccountState> {
  final Ref _ref;

  //  SECURE: OAuth tokens + email live in encrypted secure storage, not plaintext prefs.
  static const String _accountKey = 'auvy_account_v2';
  // Which account the on-device user data belongs to (the cloud backup key / uid).
  // Written when cloud backup activates and compared on every activation, so a
  // different account signing in never inherits the previous account's history,
  // library or taste. See [_ensureLocalDataBelongsTo].
  static const String _dataOwnerKey = 'auvy_data_owner_v1';

  /// Consecutive account-switch wipes that couldn't complete. A failed wipe withholds
  /// the owner stamp so the next launch tries again, but if something can never be
  /// deleted that would wipe the current user's library on every launch forever, so
  /// the attempts are capped.
  static const String _wipeAttemptsKey = 'auvy_wipe_attempts_v1';

  /// The session that owned the data when [_dataOwnerKey] was stamped. The uid is
  /// derived (sha256 of salt + whatever identity YouTube returns, which can change
  /// from a handle to an email), so it can change for the same account and look like
  /// an account switch. The cookie tag stored here proves the same signed-in session.
  /// It's only used to suppress a wipe, never to authorise one: Google rotates
  /// SAPISID on a password change, so a different tag proves nothing.
  static const String _dataOwnerSessionKey = 'auvy_data_owner_session_v1';

  /// After this many failures, stamp anyway and say so. The leak it stops
  /// guarding against is hypothetical; the data loss it causes is not.
  static const int _maxWipeAttempts = 3;
  // Shared app-wide instance with pinned AndroidOptions. See the doc on
  // appSecureStorage (session_cookie_manager.dart). A second instance with
  // different options is exactly what triggers the plugin's mismatch-wipe.
  final FlutterSecureStorage _secureStorage = appSecureStorage;

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

        // Started unawaited by the constructor, so the notifier may be disposed by now
        // (a rebuild on sign-in or restore); writing state would throw.
        if (!mounted) return;
        state = AccountState(
          youtube: data['youtube'] != null ? AuthSession.fromMap(data['youtube']) : null,
          preferredPrimary: pref, // Load preference
        );
        // A blob written by an older build may still carry a Discord session (the feature
        // was removed); re-saving drops it from secure storage.
        if (data['discord'] != null) {
          await _saveAccount();
        }
      } catch (e) {
        print("ERROR: Failed to load account: $e");
      }
    }
    _forgetRemovedDiscordData(); // fire-and-forget: nothing waits on the cleanup
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

  /// Salt for the cloud backup key. The Firestore backup document key for a YouTube
  /// account is a salted SHA-256 of its identity (email / handle / channel), so it's
  /// stable across reinstalls (restore works with no second login) and it isn't the
  /// raw email. Must match the Worker's BACKUP_SALT.
  static const String _backupSalt = 'auvy_cloud_backup_v1::';

  /// The auth Worker's URL (the backend; not part of the source release). Cloud backup
  /// goes through it: the Worker verifies the caller owns the YouTube account (via
  /// its cookies) before minting a Firebase custom token (uid = the backup key) and
  /// a per-user encryption key. When empty, cloud backup falls back to the legacy
  /// anonymous flow, which the shipped Firestore rules deny.
  static String get _c1WorkerUrl => BackendConfig.workerBase;

  /// An invite code the user just typed, sent with the NEXT gate request.
  ///
  /// Held in memory only, and cleared once spent: a code is single-use, so
  /// persisting it would mean re-sending a code the Worker has already refused
  /// on every launch — noise in the log and nothing gained. If the sign-in
  /// fails the user still has the code and can type it again.
  static String? pendingInviteCode;

  /// Forgets an invite code once the Worker has accepted the account. A redeemed
  /// code can never grant anything twice, but sending it on every launch would cost
  /// an extra lookup forever and keep a typed credential in memory for nothing.
  static void _forgetInviteCode() => pendingInviteCode = null;

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

  /// Which account the approval marker belongs to (a hash of its SAPISID cookie).
  /// Without it, one approved sign-in would make the device permanently
  /// "established" for every later account (offline grace and the fast path past the
  /// launch gate). Hashed, since only equality is ever asked.
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

  /// How long an established device keeps working with the Worker unreachable. Two
  /// weeks covers an outage, a holiday or a dead SIM, while revocation still reaches a
  /// device that never reconnects.
  static const Duration _offlineGrace = Duration(days: 14);

  /// Whether this device may be let through after a failed approval check. Only a
  /// device previously approved for the account signed in now, and only within
  /// [_offlineGrace]; a device never approved gets no benefit of the doubt.
  Future<bool> withinOfflineGrace() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_everApprovedKey) ?? false)) return false;
      // The approval must belong to the account signed in now (see [_approvedForKey]).
      // A marker with no owner recorded predates this check and isn't trusted;
      // re-verifying costs one request.
      final owner = prefs.getString(_approvedForKey);
      final now = await _accountFingerprint();
      if (owner == null || now == null || owner != now) {
        logEvent('gate: offline grace refused — approval belongs to '
            '${owner == null ? "no recorded account" : "a different account"}');
        return false;
      }
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
      final ok = age >= 0 && age <= _offlineGrace.inMilliseconds;
      // Log the offline-grace decision (in days, comparable to the window): it's the
      // only path that opens the app without a verdict.
      logEvent('gate: offline grace ${ok ? "ALLOWED" : "EXPIRED"} — '
          'last approved ${(age / 86400000).toStringAsFixed(1)}d ago '
          '(window ${_offlineGrace.inDays}d)');
      return ok;
    } catch (e) {
      // A failure here must read as "no grace", and must say so: silently
      // returning false is indistinguishable from an expired window.
      logEvent('gate: offline grace check FAILED ($e) — treating as expired');
      return false;
    }
  }

  /// The account the user picked in the native chooser, remembered across launches.
  /// Display only (see SessionAuthService.lastLoginEmail).
  static const String _deviceEmailKey = 'auvy_device_email';

  /// Preference holding this install's device id.
  static const String _deviceIdKey = 'auvy_device_id';

  /// The devices this account is signed in on, newest activity first. Fetched on
  /// demand, not cached, since this list is read when someone wants the current
  /// answer. One Worker POST (limited to 60 per cookie per day); not polled.
  Future<List<AuvyDevice>> fetchDevices({String? revokeDeviceId, bool selfLogout = false}) async {
    final cookie = await SessionCookieManager().getCookieHeader();
    if (cookie == null || cookie.isEmpty) return const [];
    try {
      final dev = await _deviceInfo();
      final isSelf = selfLogout || (revokeDeviceId != null && dev['id'] != null && revokeDeviceId == dev['id']);
      final resp = await http
          .post(Uri.parse(_c1WorkerUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'cookie': cookie,
                'hint': await _displayHint(),
                'device': dev,
                // Revocation rides on this same authenticated request rather
                // than a route of its own — see the note in the Worker: proving
                // account ownership means the cookie → identity → uid
                // resolution INCLUDING the handle anchoring, and duplicating
                // that is how two paths end up disagreeing about who someone is.
                if (revokeDeviceId != null) 'revokeDeviceId': revokeDeviceId,
                if (isSelf) 'selfLogout': true,
              }))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        print('devices: worker replied ${resp.statusCode}');
        return const [];
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final raw = body['devices'];
      if (raw is! List) return const [];
      final me = dev['id'];
      final curModel = DeviceInfoService.currentDeviceName;
      final out = raw
          .whereType<Map>()
          .map((d) {
            final id = (d['id'] ?? '').toString();
            final isMe = me != null && id == me;
            var formattedModel = AuvyDevice.formatDeviceModel(
              d['model']?.toString(),
              d['os']?.toString(),
            );
            // Self-repair: If this device is "isMe", and the server has a generic
            // or unknown device label, use our local resolved marketing model.
            if (isMe &&
                (formattedModel == 'Unknown device' ||
                 formattedModel == 'Apple device' ||
                 formattedModel == 'Android device' ||
                 formattedModel == 'Mobile device')) {
              if (curModel.isNotEmpty && curModel != 'Unknown device' && curModel != 'Auvy Device') {
                formattedModel = curModel;
              }
            } else if (!isMe && (formattedModel == 'Unknown device' || formattedModel == 'Mobile device')) {
              final rawOs = (d['os'] ?? '').toString().toLowerCase();
              if (rawOs.startsWith('ios')) {
                formattedModel = 'Apple device';
              } else if (rawOs.startsWith('android')) {
                formattedModel = 'Android device';
              } else {
                formattedModel = 'Mobile device';
              }
            }
            return AuvyDevice(
              id: id,
              model: formattedModel,
              os: (d['os'] ?? '').toString(),
              lastSeenMs: (d['lastSeenMs'] as num?)?.toInt() ?? 0,
              firstSeenMs: (d['firstSeenMs'] as num?)?.toInt() ?? 0,
              isThisDevice: isMe,
            );
          })
          .toList();
      print('DIAG: fetchDevices retrieved ${out.length} active devices: '
          '${out.map((d) => "${d.model} (${d.isThisDevice ? 'this' : 'other'}, id=${d.id.length >= 6 ? d.id.substring(0, 6) : d.id}…)").join(", ")}');
      return out;
    } catch (e) {
      print('devices: could not fetch ($e)');
      return const [];
    }
  }

  /// Cached so the two identical sign-in requests really are identical.
  Map<String, String>? _deviceInfoMemo;

  /// This device, for the Active devices list. The id is random and per install,
  /// not a hardware identifier (which would identify a person across apps and
  /// survive a reinstall). Model and OS version help the user recognise the device.
  Future<Map<String, String>> _deviceInfo() async {
    final memo = _deviceInfoMemo;
    if (memo != null &&
        memo['model'] != null &&
        memo['model'] != 'Unknown device' &&
        memo['model'] != 'Auvy Device') {
      return memo;
    }
    var id = '';
    var model = 'Unknown device';
    var os = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString(_deviceIdKey) ?? '';
      if (id.isEmpty) {
        final r = Random.secure();
        id = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        await prefs.setString(_deviceIdKey, id);
      }
    } catch (_) {
      // Without a stable id there is nothing useful to register, and a fresh
      // random one each launch would fill the list with phantom devices. Better
      // to send nothing: the Worker simply skips registration.
      return const {};
    }
    // Resolves model and OS across iOS, Android, and desktop via DeviceInfoService.
    try {
      final info = await DeviceInfoService.getDeviceInfo();
      model = info['model'] ?? 'Unknown device';
      os = info['os'] ?? '';
    } catch (_) {
      // Name unavailable — the id still identifies the row.
    }
    final out = {'id': id, 'model': model, 'os': os};
    if (model != 'Unknown device' && model.isNotEmpty) {
      _deviceInfoMemo = out;
    }
    return out;
  }

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

  // One Worker call per launch, shared by every caller. verifyAccess() and
  // enableCloudBackup() send the identical request (same URL, same `{cookie,
  // hint}` body), and one response carries what both need. Sharing it avoids
  // sending the cookie header several times per launch. Keyed on the cookie as well
  // as the clock, so a new sign-in never gets the previous account's verdict. The
  // TTL is short because this is an access decision; the periodic re-check always
  // makes a real request.
  ({int code, Map<String, dynamic> body, bool credentialed})? _workerAnswer;
  String? _workerAnswerFor;
  DateTime? _workerAnswerAt;
  Future<({int code, Map<String, dynamic> body})>? _workerInFlight;

  /// Whether the cached verdict came from a call that mints credentials. The gate
  /// probe (`_probeAccess`) returns only status and identity, never a
  /// `firebaseToken`, so its 200 can't stand in for a full sign-in's 200; otherwise
  /// an approved account could never enable cloud backup.

  static const Duration _workerAnswerTtl = Duration(seconds: 20);

  /// Whether a launch verdict allows reusing an existing Firebase session without
  /// asking the Worker again. A denial blocks it, so revoking an account stops it
  /// syncing. A missing verdict doesn't: that's the offline case, which has its own
  /// 14-day grace.
  @visibleForTesting
  static bool mayReuseSession(String? lastSeenStatus) {
    // The same three-way split the revocation signal uses:
    //
    //   * pending / blocked / closed: a decision about this account. Refuse.
    //   * unavailable / throttled / capacity: a server hiccup or rate limit, which
    //     says nothing about the user.
    //   * null: never told. The offline case, covered by the 14-day grace.
    return !(lastSeenStatus == 'pending' ||
        lastSeenStatus == 'blocked' ||
        lastSeenStatus == 'closed' ||
        lastSeenStatus == 'device_revoked');
  }

  /// Test seam for the verdict this process last saw.
  @visibleForTesting
  static set lastSeenGateStatusForTest(String? s) => _lastSeenGateStatus = s;

  /// Whether a cached verdict can stand in for a real sign-in request. A denial can
  /// (a 403 needs no token); a tokenless success can't (see [_workerAnswer]).
  @visibleForTesting
  static bool reusableForCredentials(
          ({int code, Map<String, dynamic> body, bool credentialed})? a) =>
      a != null && (a.code != 200 || a.credentialed);

  /// Cached answer for [cookie], or null when there isn't a usable one.
  ({int code, Map<String, dynamic> body, bool credentialed})? _cachedWorkerAnswer(
      String cookie) {
    final at = _workerAnswerAt;
    final a = _workerAnswer;
    if (a == null || at == null) return null;
    if (_workerAnswerFor != _cookieTag(cookie)) return null;
    if (DateTime.now().difference(at) > _workerAnswerTtl) return null;
    return a;
  }

  /// An identity reduced to something you can TELL APART but not read.
  ///
  /// `alex@example.com` -> `al***@example.com`; a bare handle keeps its first
  /// two characters. Enough to see that two log lines are different accounts,
  /// which is the only thing the call sites need.
  static String _maskIdentity(String id) {
    final at = id.indexOf('@');
    // A leading "@" is a YouTube HANDLE, not an address — see normIdentity in
    // the Worker for why the two get confused.
    if (at <= 0) {
      return id.length <= 2 ? '***' : '${id.substring(0, 2)}***';
    }
    final local = id.substring(0, at);
    final domain = id.substring(at);
    final head = local.length <= 2 ? local : local.substring(0, 2);
    return '$head***$domain';
  }

  /// Short fingerprint of a session — keyed on the auth cookie (SAPISID/SID)
  /// when readable, so header reordering and harmless cookie churn (YSC/VISITOR)
  /// do not falsely register as a new session. Falls back to hashing the header.
  static String _cookieTag(String cookie) {
    try {
      final map = SessionCookieManager().parseCookies(cookie);
      if (map.isNotEmpty) {
        final auth = SessionCookieManager.sapisidFrom(map) ??
            map['SID'] ??
            map['__Secure-3PSID'];
        if (auth != null && auth.isNotEmpty) {
          return sha256.convert(utf8.encode(auth)).toString().substring(0, 16);
        }
      }
    } catch (_) {}
    return sha256.convert(utf8.encode(cookie)).toString().substring(0, 16);
  }

  void _rememberWorkerAnswer(String cookie, int code, Map<String, dynamic> body,
      {required bool credentialed}) {
    _workerAnswer = (code: code, body: body, credentialed: credentialed);
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

  // Remembered cloud credentials, so a normal launch doesn't mint a new Firebase
  // token. The Firebase SDK keeps its own session and refreshes ID tokens, so a mint
  // is needed about once per install; minting every launch spends the Worker's
  // per-account daily sign-in limit. The two questions are asked separately:
  //
  //   "am I still allowed?"  → the Worker's cheap probe (no token, no counter).
  //   "give me a token"      → only without a live Firebase session or a
  //                            remembered credential.
  //
  // encKey (an HMAC of the uid under a server secret, which encrypts the backup) is
  // kept in the same secure storage as the YouTube cookies, never in
  // SharedPreferences. The record is bound to the session it was minted for; a
  // mismatch is discarded, so another account on this phone can't inherit the key.
  static const String _cloudCredKey = 'auvy_cloud_cred_v1';

  Future<void> _rememberCloudCredential(
      String cookie, String uid, String? encKey) async {
    try {
      await _secureStorage.write(
        key: _cloudCredKey,
        value: jsonEncode({
          'tag': _cookieTag(cookie),
          'uid': uid,
          'encKey': encKey,
          'atMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      // Not fatal: the next launch simply mints again, which is what it did
      // before this existed.
      logEvent('cloud: could not remember the credential ($e) — the next launch '
          'will mint one');
    }
  }

  /// The remembered credential for [cookie], or null when there is none that
  /// belongs to this session.
  Future<({String uid, String? encKey})?> _rememberedCloudCredential(
      String cookie) async {
    try {
      final raw = await _secureStorage.read(key: _cloudCredKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final uid = j['uid'] as String?;
      if (uid == null || uid.isEmpty) return null;
      if (j['tag'] != _cookieTag(cookie)) {
        logEvent('cloud: the remembered credential belongs to another session — '
            'ignoring it and minting a fresh one');
        return null;
      }
      return (uid: uid, encKey: j['encKey'] as String?);
    } catch (e) {
      logEvent('cloud: remembered credential unreadable ($e) — minting');
      return null;
    }
  }

  Future<void> _forgetCloudCredential() async {
    try {
      await _secureStorage.delete(key: _cloudCredKey);
    } catch (_) {}
  }

  /// Cleared for the session the first time the Worker answers a probe the way an
  /// older deployment does (see the firebaseToken check below).
  bool _probeSupported = true;

  /// Asks the Worker only whether this account is still allowed. Returns null
  /// when the probe can't answer and the caller must do a full sign-in (no
  /// anchor yet for this cookie, no record, or the request failed).
  Future<({String status, String? identity, String? detail})?>
      _probeAccess(String cookie) async {
    if (!_probeSupported) return null;
    try {
      final resp = await http
          .post(Uri.parse(_c1WorkerUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'cookie': cookie,
                'probe': true,
                'device': await _deviceInfo(),
              }))
          .timeout(const Duration(seconds: 12));
      Map<String, dynamic> body;
      try {
        body = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
      // A Worker that doesn't know about probes does a full sign-in instead (minting a
      // token). A token in the reply is the tell, so stop probing for the rest of the
      // session.
      if (body.containsKey('firebaseToken')) {
        _probeSupported = false;
        logEvent('gate: this Worker has no status probe (it answered with a '
            'minted token) — not probing again this session; deploy the '
            'Worker to stop spending a sign-in per launch');
        return null;
      }
      final status = body['status'] as String?;
      if (status == null || status == 'needs_signin') {
        logEvent('gate: probe cannot answer (${body['reason'] ?? 'no status'}) — '
            'falling back to a full sign-in');
        return null;
      }
      if (status == 'approved' && body['probe'] != true) {
        // Approved without the probe marker is not an answer this path asked
        // for. Fail to the full flow rather than trusting a shape we do not
        // recognise.
        _probeSupported = false;
        logEvent('gate: unrecognised probe reply — falling back');
        return null;
      }
      // The proxy token (`appToken`) is taken here, because this is the call every
      // launch makes (established installs skip the full flow, and the token expires
      // after 7 days). Absent means an older Worker; the header just isn't sent.
      final appTok = body['appToken'] as String?;
      if (appTok != null && appTok.isNotEmpty) {
        AuvyAppToken.set(appTok);
      }
      logEvent('gate: probe ${resp.statusCode} status=$status '
          '— no token minted, no daily sign-in used'
          '${status == 'approved' ? (appTok == null || appTok.isEmpty ? ' (no app token — older Worker)' : ' (app token refreshed)') : ''}');
      final identity = body['identity'] as String?;
      _raiseRevoked(status, identity);
      return (
        status: status,
        identity: (identity == null || identity.isEmpty) ? null : identity,
        detail: status == 'approved'
            ? null
            : '${resp.statusCode}: ${(body['error'] ?? '').toString()}',
      );
    } catch (e) {
      // A probe failure must never be harsher than the full path would be —
      // it falls back rather than reporting the account unusable.
      logEvent('gate: probe failed ($e) — falling back to a full sign-in');
      return null;
    }
  }

  /// Asks the Worker whether this device's YouTube session may use Auvy. Returns the
  /// Worker's `status` (`approved`, `pending`, `blocked`, `closed`, `throttled`,
  /// `capacity`) plus the identity it resolved from the cookies, or `unavailable`
  /// when the Worker can't be reached or isn't configured. The cookie alone is
  /// enough for the Worker to identify the account, so this doesn't wait for local
  /// identity resolution.
  ///
  /// `unavailable` doesn't mean denied: playback uses the user's own YouTube session
  /// with no server in the path, so a Worker outage only turns cloud backup off.
  ///
  /// [force] skips this launch's cached verdict and asks the Worker; the gate's "have
  /// I been approved yet?" re-check needs a fresh answer.
  Future<({String status, String? identity, String? detail})> verifyAccess(
      {bool force = false}) async {
    if (_c1WorkerUrl.isEmpty) {
      // Record this as the launch's first verdict, even though it isn't about the
      // account, so the cloud path doesn't wait out its full timeout. `unavailable`
      // neither refuses nor clears the saved denial.
      _raiseRevoked('unavailable', null);
      return (status: 'unavailable', identity: null, detail: 'not configured');
    }
    try {
      final cookie = await SessionCookieManager().getCookieHeader();
      if (cookie == null || cookie.isEmpty) {
        // Worth distinguishing: "no session to ask about" is a DIFFERENT failure
        // from "the service refused", and lumping both into one silent
        // `unavailable` is what made this take three attempts to pin down.
        _raiseRevoked('unavailable', null);
        return (status: 'unavailable', identity: null, detail: 'no cookies');
      }
      // Reuse this launch's answer when there is one for THIS session. See the
      // note on _workerAnswer. Also joins a call already in flight, so two
      // callers a few milliseconds apart cost one request, not two.
      int code;
      Map<String, dynamic> body;
      // `force` drops any cached answer as well as ignoring it, so the fresh
      // reply becomes the one every later caller this launch sees.
      if (force) _forgetWorkerAnswer();
      final cached = force ? null : _cachedWorkerAnswer(cookie);
      if (cached != null) {
        code = cached.code;
        body = cached.body;
        // Log whether the answer came from the Worker or from this launch's cache, so
        // request counts can be read from the log.
        logEvent('gate: answered from this launch\'s cached verdict — '
            'no worker request');
      } else if (await _probeAccess(cookie) case final probed?) {
        // The cheap question first: verifyAccess only needs the gate decision, never a
        // token. See _probeAccess.
        _rememberWorkerAnswer(cookie, probed.status == 'approved' ? 200 : 403, {
          'status': probed.status,
          if (probed.identity != null) 'identity': probed.identity,
          // CARRIED, because the next reader of this verdict logs it. The
          // comment on that log line says why it matters: "closed" alone cannot
          // distinguish enrolment being shut from the daily intake being used
          // up. Without this the cached path printed `reason=?` and threw the
          // distinction away — the probe had the text and dropped it.
          if (probed.detail != null) 'error': probed.detail,
        }, credentialed: false);
        return probed;
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
                        {'cookie': cookie, 'hint': await _displayHint(), 'device': await _deviceInfo(),
                         if (pendingInviteCode != null) 'inviteCode': pendingInviteCode}))
                .timeout(const Duration(seconds: 15));
            final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
            _rememberWorkerAnswer(cookie, resp.statusCode, parsed,
                credentialed: true);
            if (resp.statusCode == 200) _forgetInviteCode();
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
      logEvent('verifyAccess: $code status=$status '
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
      // Same reason as the two early returns above: the cloud path is waiting
      // on an answer, and "could not ask" is one.
      _raiseRevoked('unavailable', null);
      return (
        status: 'unavailable',
        identity: null,
        detail: e.runtimeType.toString(),
      );
    }
  }

  /// The activation chain. Two activations must never overlap: each performs a
  /// restore, and when one finishes it clears CloudSyncService's `_restoring` flag
  /// while the other may still be restoring, opening a window for a push to overwrite
  /// the copy being restored from. Sequential callers are queued, each making its own
  /// attempt against current state (sharing a stale result could skip a restore).
  /// Each link awaits the previous one, never its own future.
  Future<bool>? _enableChain;

  /// Silently activates cloud backup/restore for the signed-in YouTube account,
  /// with no Google account picker (the YouTube sign-in is the only login). Uses
  /// the Worker's custom token and a per-account encryption key, keyed by the
  /// YouTube account. [interactive] is kept for call sites but has no effect.
  Future<bool> enableCloudBackup({bool interactive = false}) {
    // Join an activation already in flight rather than queueing a second identical
    // one: both would do the same work, and duplicate sign-ins cost Worker KV writes
    // and a slow Firebase custom-token sign-in. (`interactive` isn't read on this
    // path.) The chain below still serialises sequential calls.
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
    // Wait for Firebase rather than testing it: this can run before main() finishes
    // `Firebase.initializeApp`, and testing a boolean then could disable backup for
    // the whole session. The timeout keeps "no Firebase project configured" fast.
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
        // Retried, with a longer timeout than 15 s: this request decides whether the
        // user's library comes back, and a cold Worker on mobile data can take longer.
        // Failing it would send a returning user to onboarding.
        final body =
            jsonEncode({'cookie': cookie, 'hint': await _displayHint(), 'device': await _deviceInfo(),
                         if (pendingInviteCode != null) 'inviteCode': pendingInviteCode});
        // Phase timing: the login wait was 13s in total and the split between the
        // Worker call and the library restore was not visible anywhere.
        final tWorker = DateTime.now();
        // Reuse the launch verdict: verifyAccess() sends the identical request, so on a
        // normal launch the answer is already in hand and this costs no network. It's
        // rebuilt as a Response so the checks below are unchanged (see _workerAnswer).
        //
        // No mint when Firebase is already signed in. A live FirebaseAuth session renews
        // its own ID tokens, so with a remembered credential for this cookie a normal
        // launch needs no Worker request here. Any doubt falls back to the full flow (no
        // Firebase user, no remembered credential, a credential for a different session,
        // or a uid mismatch), since being permissive could sync against the wrong account.
        //
        // The checks above concern identity; authorisation is separate. So the fast path
        // is blocked by a denial (from this launch's verdict, or the one the last launch
        // saved, in case the startup race is lost), otherwise a revoked account would keep
        // syncing on its live Firebase session. A missing verdict doesn't block (offline,
        // 14-day grace). This waits up to 6 s for the gate's verdict, within the time this
        // path already spends waiting for Firebase.
        final verdict = await _awaitFirstVerdict(const Duration(seconds: 6));
        var refused = !mayReuseSession(verdict);
        // Log the fast-path access decision; a correct refusal is otherwise silent.
        logEvent('cloud: fast-path check — verdict=$verdict refused=$refused');
        if (!refused && verdict == null) {
          try {
            final prefs = await SharedPreferences.getInstance();
            if (prefs.getBool(_gateDeniedKey) ?? false) {
              refused = true;
              logEvent('cloud: the last launch was denied and this one has no '
                  'verdict yet — refusing the remembered-session fast path');
            }
          } catch (_) {}
        }
        if (refused && verdict != null) {
          logEvent('cloud: the gate said "$verdict" — refusing the '
              'remembered-session fast path');
        }

        final fbUser = fb_auth.FirebaseAuth.instance.currentUser;
        final remembered = (fbUser == null || refused)
            ? null
            : await _rememberedCloudCredential(cookie);
        if (!refused &&
            fbUser != null &&
            remembered != null &&
            remembered.uid == fbUser.uid) {
          CloudSyncService.instance.setBackupEncKey(remembered.encKey);
          await _ensureLocalDataBelongsTo(remembered.uid,
              sessionTag: _cookieTag(cookie));
          final t0 = DateTime.now();
          final restoredFast =
              await CloudSyncService.instance.activateAndRestore(remembered.uid);
          logEvent('cloud: reused the existing Firebase session — no token minted, '
              'no daily sign-in used (activateAndRestore took '
              '${DateTime.now().difference(t0).inMilliseconds}ms, '
              'restored=$restoredFast)');
          if (restoredFast) {
            await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
            await _ref.read(artworkOverrideProvider.notifier).reloadFromStorage();
            await _ref.read(libraryProvider.notifier).reloadFromStorage();
            await _rebuildDerivedCollections();
            await _applyRestoredSettings();
          }
          return true;
        }

        // A denial is reusable; a tokenless success isn't (see _workerAnswer).
        final cachedAnswer = _cachedWorkerAnswer(cookie);
        final reuse = reusableForCredentials(cachedAnswer) ? cachedAnswer : null;
        http.Response? resp =
            reuse == null ? null : http.Response(jsonEncode(reuse.body), reuse.code);
        if (reuse != null) {
          logEvent('cloud: reused the launch verdict — no extra worker request');
        } else if (cachedAnswer != null) {
          logEvent('cloud: the cached verdict is approval WITHOUT credentials '
              '(gate probe) — asking the worker for a token');
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
        logEvent('cloud: worker replied in '
            '${DateTime.now().difference(tWorker).inMilliseconds}ms');
        if (resp.statusCode != 200) {
          // Status only. A response body is remote input that can carry echoed
          // request context; release swallows print() anyway, but a log line
          // that cannot leak is better than one that relies on that.
          print('ERROR: enableCloudBackup[C1]: worker ${resp.statusCode}');
          // A denial isn't a bug and mustn't look like one: the Worker gates cloud backup
          // on approval, so a new user is refused on purpose. Say which it is, once per
          // launch.
          if (resp.statusCode == 403 || resp.statusCode == 429) {
            String? status;
            try {
              status = (jsonDecode(resp.body) as Map<String, dynamic>)['status']
                  as String?;
            } catch (_) {}
            // A block also ejects the user (via _raiseRevoked), not just a toast.
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
        // Proves to the Worker's PROXY routes that this caller got past the
        // gate, without sending the session cookie on every lyrics or radio
        // request. Absent from an older Worker, which is fine: the header is
        // simply not sent and those routes answer as they always have.
        final issued = j['appToken'] as String?;
        AuvyAppToken.set(issued);
        // Log whether the Worker issued an app token (length only; the token is never
        // logged). It shows whether enabling REQUIRE_APP_TOKEN would be safe for this
        // install.
        logEvent(issued == null || issued.isEmpty
            ? 'gate: no app token in the reply — older Worker, proxy header '
                'will not be sent (do NOT enable REQUIRE_APP_TOKEN yet)'
            : 'gate: app token issued (${issued.length} chars) — proxy header '
                'will be sent to the Worker only');
        _forgetInviteCode();
        if (token == null || token.isEmpty || uid == null || uid.isEmpty) {
          print('ERROR: enableCloudBackup[C1]: bad worker payload');
          return false;
        }
        await fb_auth.FirebaseAuth.instance.signInWithCustomToken(token);
        CloudSyncService.instance.setBackupEncKey(encKey);
        // Remembered so the NEXT launch does not have to mint one. See
        // _rememberCloudCredential.
        await _rememberCloudCredential(cookie, uid, encKey);
        // Never let this account see data left behind by a previous one.
        await _ensureLocalDataBelongsTo(uid, sessionTag: _cookieTag(cookie));
        // Timed on THIS path, not just the anonymous fallback. The fallback's
        // timer never printed a line, because it only runs when no worker URL is
        // configured, so the slowest phase of the login the user complained about
        // was the one phase with no measurement on it.
        final restoreStarted = DateTime.now();
        final restored = await CloudSyncService.instance.activateAndRestore(uid);
        logEvent('cloud: activateAndRestore took '
            '${DateTime.now().difference(restoreStarted).inMilliseconds}ms');
        print('enableCloudBackup[C1]: SECURE session uid=${uid.substring(0, 12)}… '
            'restored=$restored');
        if (restored) {
          await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
          // Covers before the library. The override notifier read prefs before the restore,
          // so it must reload (rebuilding cover files) first; the library then reconciles
          // playlist images against overrides that exist.
          await _ref.read(artworkOverrideProvider.notifier).reloadFromStorage();
          await _ref.read(libraryProvider.notifier).reloadFromStorage();
          await _rebuildDerivedCollections();
          await _applyRestoredSettings();
          // Rebuild the home feed: Quick Picks comes from the taste profile, and on a fresh
          // install the feed was built (and cached) from an empty profile before this
          // restore landed. Unawaited so it doesn't delay entering the app.
          try {
            _ref.read(homeProvider.notifier).refreshHome();
          } catch (_) {}
        }
        return true;
      }

      // Legacy flow (anonymous session + email-hash key), reached only when no Worker
      // URL is compiled in, and it can't succeed: the Firestore rules require
      // `request.auth.uid == userId`, which only the Worker-minted custom token
      // satisfies. It fails safely (it can't reach any document). Kept for forks that
      // run their own Firebase project with different rules; builds of this project
      // always include the Worker URL.
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
      // The "key" here is an account id (sha256 of salt + identity, used as the
      // Firestore path), not key material. The AES key is a separate value from the
      // Worker (CloudSyncService.setBackupEncKey) and is never logged. 12 hex characters
      // tell accounts apart in a log.
      print('enableCloudBackup: account=${backupKey.substring(0, 12)}… '
          '(hash of YT identity, not the encryption key) — activating restore');

      // Never let this account see data left behind by a previous one.
      await _ensureLocalDataBelongsTo(backupKey);
      final tRestore = DateTime.now();
      final restored = await CloudSyncService.instance.activateAndRestore(backupKey);
      logEvent('cloud: activateAndRestore took '
          '${DateTime.now().difference(tRestore).inMilliseconds}ms → $restored');
      if (restored) {
        await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
        await _ref.read(artworkOverrideProvider.notifier).reloadFromStorage();
        await _ref.read(libraryProvider.notifier).reloadFromStorage();
        await _rebuildDerivedCollections();
        await _applyRestoredSettings();
      }
      cloudActivationUnreachable = false;
      return true;
    } catch (e) {
      // Tell "no backup" apart from "couldn't reach the backup", so a slow Worker call
      // doesn't make the login gate treat a returning user as new. See
      // LoginGatePage._proceed.
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

  /// Prefs holding personal data (as opposed to device settings), wiped when the
  /// device changes hands between accounts, plus anything matching
  /// [_userDataPrefixes] (the whole `intel_*` family). `auvy_lib::` is included
  /// because a cloud restore writes per-playlist parts under it
  /// (library_sync_split).
  static const List<String> _userDataPrefixes = ['intel_', 'auvy_lib::'];
  static const List<String> _userDataKeys = [
    // Library, home-mosaic recents and their play-origin map.
    'auvy_library_data',
    // Must be wiped with the library: LibraryNotifier falls back to this
    // last-known-good copy when the live blob reads empty (see _kLibraryBackupKey).
    'auvy_library_data_last_good',
    'recent_playlists_v1',
    // Keep fresh playlists and Weekly Discovery's week: per account, like the
    // playlists they describe.
    'auvy_keep_fresh_v1',
    // What's New: built from this account's follows.
    'auvy_whats_new_v1',
    // Saved audiobooks and where the listener is in each.
    'auvy_audiobooks_v1',
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
    'auvy_pinned_podcast_shows_v1',
    'auvy_pinned_radio_stations_v1',
    'auvy_recognition_history',
    'auvy_artwork_overrides_v1',
    'auvy_artwork_overrides_v2',
    // Personalised home feed.
    'cached_home_data',
    // "This account has used Auvy before" flags — a genuinely new account must
    // see onboarding. Both are cloud-backed, so a RETURNING account gets them
    // straight back from its own restore.
    'has_onboarded',
    // Restore watermark. MUST be cleared with the data: activateAndRestore only
    // pulls a backup STRICTLY NEWER than this, so leaving the previous account's
    // (newer) timestamp behind would silently skip the new account's restore.
    'cloud_last_backup_ms',
    // The unpushed-work marker. The wipe itself is a pref write that would set it, and
    // activateAndRestore would then refuse to restore and push the emptied local copy
    // over the incoming account's backup. After a wipe there's nothing local worth
    // keeping, so the marker goes too.
    'cloud_pending_since_ms',
    // The cross-device merge ledgers; all personal, and leaving any behind hands them
    // to the next account:
    //
    //   set log     the old account's likes, follows and un-likes; its timestamped
    //               removals would outrank the new account's own decisions.
    //   own tally   the old account's plays, which would be added to the new
    //               account's counts.
    //   baseline    a frozen play-count total belonging to the other account.
    //   shard id    not personal, but shards are per (account, device).
    SetLog.prefsKey,
    PlayTally.prefsKey,
    PlayTally.baselineKey,
    CloudSyncService.shardIdKey,
  ];

  /// Erases the current user's data from this device, leaving device settings
  /// (theme, quality, EQ…) alone. Used on logout and when a different account signs
  /// in. [wipeAudio] also removes cached and downloaded audio (right on an account
  /// change, or the disk scan would re-import the old downloads; skipped on logout
  /// so the same account keeps its downloads). Returns the steps that failed, empty
  /// on a clean wipe.
  ///
  /// Every step is isolated so one unavailable store doesn't stop the others, and
  /// every failure is reported so callers can act on a partial wipe (see
  /// _criticalWipeFailures).
  Future<List<String>> _wipeLocalUserData({bool wipeAudio = false, bool newAccount = false}) async {
    print('DIAG: _wipeLocalUserData started (wipeAudio=$wipeAudio, newAccount=$newAccount)');
    final failed = <String>[];
    // First, before anything can write prefs again: everything below triggers saves
    // (each calling scheduleBackup), and those writes are the wipe's own defaults, not
    // user work. The reset window stops them being treated as unpushed changes.
    CloudSyncService.instance.beginAccountReset();
    // The Worker's cached answer is about the account being wiped. Keyed on the
    // cookie so it could not be misapplied anyway, but there is no reason to keep
    // a departing account's response body in memory.
    _forgetWorkerAnswer();
    // 1. In-memory playback session (queue/current track) — reset FIRST so its
    //    debounced save can't re-persist after the prefs wipe.
    try { await _ref.read(playerProvider.notifier).clearAllForAccountReset(); } catch (e) { failed.add('playback session ($e)'); }
    // 1b. The library needs the same guard: wiping the audio cache below triggers a
    // library save that would write the old account's rows back into the cleared
    // prefs. See LibraryNotifier._accountResetting.
    try { _ref.read(libraryProvider.notifier).beginAccountReset(); } catch (e) { failed.add('library reset guard ($e)'); }

    // 2. Personal prefs.
    try {
      final prefs = await SharedPreferences.getInstance();
      final doomed = prefs
          .getKeys()
          .where((k) =>
              _userDataKeys.contains(k) ||
              _userDataPrefixes.any((p) => k.startsWith(p)))
          .where((k) => newAccount || k != 'has_onboarded')
          .toList();
      for (final k in doomed) {
        await prefs.remove(k);
      }
      print('DIAG: _wipeLocalUserData - wiped ${doomed.length} keys '
          '(newAccount=$newAccount, wipeAudio=$wipeAudio, preservedOnboarding=${!newAccount})');
    } catch (e) {
      failed.add('personal prefs ($e)');
    }

    // 2b. The merge ledgers, in memory as well as on disk: both are singletons that
    // read their pref once per process, so removing the keys isn't enough.
    try { await SetLog.instance.reset(); } catch (e) { failed.add('set log ($e)'); }
    try { await PlayTally.instance.reset(); } catch (e) { failed.add('play tally ($e)'); }
    // The remembered cloud credential is the OUTGOING account's uid and
    // encryption key. It is bound to that account's cookie tag, so it would be
    // rejected rather than misapplied — but a departing account's key has no
    // business staying on the device, and deleting it here means the check
    // never has to be the only thing standing between two accounts.
    try { await _forgetCloudCredential(); } catch (e) { failed.add('cloud credential ($e)'); }
    // The event log names tracks and playlists, so it is this account's too.
    // In memory only, so this is the only place it can be cleared from.
    EventLog.clear();

    // 3. The SQLite ledger (play history, playlists, search history, page
    //    caches) — a separate store that prefs cleanup never touches.
    try { await DatabaseService().wipeAllData(); } catch (e) { failed.add('sqlite ledger ($e)'); }
    // The home feed and page caches must not survive into the next account.
    try { await PageCacheService().clearAllPageCaches(); } catch (e) { failed.add('page caches ($e)'); }

    // 3b. Subsystem state & caches (pinned media, recognition log, artwork overrides, spoken word & translation).
    try { await _ref.read(artworkOverrideProvider.notifier).clearAll(); } catch (e) { failed.add('artwork overrides ($e)'); }
    try { await _ref.read(pinnedPodcastsProvider.notifier).clear(); } catch (e) { failed.add('pinned podcasts ($e)'); }
    try { await _ref.read(pinnedRadioStationsProvider.notifier).clear(); } catch (e) { failed.add('pinned radio ($e)'); }
    try { await RecognitionHistory.clear(); } catch (e) { failed.add('recognition history ($e)'); }
    try { AudiobookService.clearCache(); } catch (e) { failed.add('audiobook cache ($e)'); }
    try { LyricsTranslationService().clearCache(); } catch (e) { failed.add('lyrics translation cache ($e)'); }

    // 4. On-device audio, only on a real account change (see [wipeAudio]). A false
    // success here matters: surviving files would be re-imported into the incoming
    // account's library, so a failed wipe is treated as critical.
    if (wipeAudio) {
      print('DIAG: _wipeLocalUserData: wipeAudio=true, wiping on-device audio');
      try {
        final clean = await AudioCacheManager().wipeEverything();
        if (!clean) {
          failed.add('on-device audio (files survived the wipe — the next '
              'account would import them)');
        }
      } catch (e) {
        failed.add('on-device audio ($e)');
      }
    } else {
      print('DIAG: _wipeLocalUserData: wipeAudio=false, preserving user downloads on disk');
    }

    // 5. Reload every provider from the now-empty stores, or they keep serving (and
    // re-saving) the old account's data from memory.
    // A different account also mustn't inherit the previous user's accent colour. Not
    // done on a plain logout: the same account keeps its accent, and a returning
    // account gets its own back from the cloud restore. See ThemeNotifier.resetToDefault.
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

  /// The wipe steps whose failure leaves another account's data reachable on this
  /// device. The rest (accent colour, data counter) are cosmetic. A critical failure
  /// leaves the owner stamp alone so the next launch wipes again, which is worth a
  /// repeat wipe for a leak, not for a colour.
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

  /// Which signed-in identity owns the data on this device. Separate from
  /// `auvy_data_owner_v1` (the Worker-issued uid), which is only known once the Worker
  /// approves the account. Like that marker, deliberately not in [_userDataKeys]: it's
  /// what makes a switch detectable.
  static const String _dataOwnerIdKey = 'auvy_data_owner_id_v1';

  /// Wipes the previous account's local data when a different account signs in,
  /// whether or not that account is approved for anything.
  ///
  /// Keyed on the identity (email/handle), not the SAPISID cookie, which Google
  /// rotates on a password change. Hashed, since only "same or different" is ever
  /// asked.
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
      if (owner == null || owner.isEmpty) {
        print('DIAG: _ensureLocalDataBelongsToSession: fresh device (no stored owner), stamping ${fp.substring(0, 12)}…');
      } else if (owner == fp) {
        print('DIAG: _ensureLocalDataBelongsToSession: verified owner match (${fp.substring(0, 12)}…)');
      } else {
        // The same session means identity drift, not a switch: the identity is `email ||
        // handle || name`, and YouTube chooses which it returns.
        final stampedSession = prefs.getString(_dataOwnerSessionKey);
        final tag = await _currentSessionTag();
        final persistent = await SessionCookieManager().hasPersistentSession();
        final signedOut = await SessionCookieManager().hasExplicitlySignedOut();
        final isSameSession = (tag != null && stampedSession != null && stampedSession == tag) ||
            (stampedSession == null && persistent && !signedOut);
        print('DIAG: _ensureLocalDataBelongsToSession: storedOwner=${owner.substring(0, owner.length < 12 ? owner.length : 12)}… '
            'incoming=${fp.substring(0, 12)}… tag=$tag stamped=$stampedSession persistent=$persistent signedOut=$signedOut isSameSession=$isSameSession');
        if (isSameSession) {
          print('ALERT: signed-in identity changed for an UNCHANGED session '
              '— re-spelled by YouTube, not a different person. Re-stamping '
              'without a wipe.');
          await prefs.setString(_dataOwnerIdKey, fp);
          if (tag != null) {
            await prefs.setString(_dataOwnerSessionKey, tag);
          }
          await prefs.setInt(_wipeAttemptsKey, 0);
          return;
        }
        // Name both sides, for the same reason as the uid-keyed check: a log
        // that says only "switch detected" cannot tell a real switch from a
        // spurious one, and a spurious one costs a user their library.
        print('Account switch detected at sign-in — stored '
            '${owner.substring(0, owner.length < 12 ? owner.length : 12)}… != '
            '${fp.substring(0, 12)}… — wiping the previous '
            "account's local data before this session sees it.");
        final attempts = (prefs.getInt(_wipeAttemptsKey) ?? 0) + 1;
        await prefs.setInt(_wipeAttemptsKey, attempts);
        // wipeAudio: false — downloads belong to the device/user and must
        // NEVER be wiped automatically. Personal library and history are wiped,
        // but audio files on disk remain safe.
        final failures = _criticalWipeFailures(
            await _wipeLocalUserData(wipeAudio: false, newAccount: true));
        if (failures.isNotEmpty && attempts < _maxWipeAttempts) {
          // Do NOT stamp an owner over data that is still there — while the
          // wipe is still getting somewhere. See the cap below for why that
          // qualifier is load-bearing.
          print('ALERT: owner stamp WITHHELD (attempt $attempts of '
              '$_maxWipeAttempts) — the wipe left user data behind '
              '(${failures.join('; ')}). The next launch will see the mismatch '
              'and wipe again rather than leaving it in place.');
          return;
        }
        if (failures.isNotEmpty) {
          // Same reasoning as the uid-keyed check: an unbounded retry destroys
          // the current user's data on every launch to guard against a next
          // account that may never arrive.
          print('ALERT: wipe FAILED $attempts times and will not be retried — '
              'stamping the owner to stop an endless wipe loop. Residue: '
              '${failures.join('; ')}.');
        }
        await prefs.setInt(_wipeAttemptsKey, 0);
      }
      await prefs.setString(_dataOwnerIdKey, fp);
      final tagNow = await _currentSessionTag();
      if (tagNow != null) {
        await prefs.setString(_dataOwnerSessionKey, tagNow);
      }
    } catch (e) {
      // Not swallowed: this key is what prevents a repeat wipe. If writing the new owner
      // fails silently, the next sign-in compares against the old owner and wipes again,
      // possibly deleting downloads. Rare (a full disk), but worth logging.
      print('ALERT: could not record the data owner id ($e) — a repeat '
          'account-switch wipe is now possible; check free storage');
    }
  }

  /// The current session's cookie tag, or null without a session. Resolved here
  /// rather than passed in, so no caller can forget it.
  Future<String?> _currentSessionTag() async {
    try {
      final cookies = await SessionCookieManager().loadCookies();
      if (cookies != null && cookies.isNotEmpty) {
        final auth = SessionCookieManager.sapisidFrom(cookies) ??
            cookies['SID'] ??
            cookies['__Secure-3PSID'];
        if (auth != null && auth.isNotEmpty) {
          final tag = sha256.convert(utf8.encode(auth)).toString().substring(0, 16);
          print('OK: currentSessionTag (auth) -> $tag');
          return tag;
        }
      }
      final c = await SessionCookieManager().getCookieHeader();
      if (c == null || c.isEmpty) return null;
      final tag = _cookieTag(c);
      print('OK: currentSessionTag (header) -> $tag');
      return tag;
    } catch (_) {
      return null;
    }
  }

  /// Guards against one account inheriting another's data: compares the stored
  /// data owner with the account about to activate and, on a mismatch, wipes
  /// the previous user's history, library and taste before restoring. Also
  /// covers what logout can't (app killed mid-logout, cookies swapped
  /// externally).
  Future<void> _ensureLocalDataBelongsTo(String backupKey,
      {String? sessionTag}) async {
    try {
      sessionTag ??= await _currentSessionTag();
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_dataOwnerKey);
      if (owner == null || owner.isEmpty) {
        print('DIAG: _ensureLocalDataBelongsTo: fresh device (no stored owner), stamping ${backupKey.substring(0, backupKey.length < 12 ? backupKey.length : 12)}… sessionTag=$sessionTag');
      } else if (owner == backupKey) {
        print('DIAG: _ensureLocalDataBelongsTo: verified owner match (${backupKey.substring(0, backupKey.length < 12 ? backupKey.length : 12)}…)');
      } else {
        // Same session? Then it isn't a different person (see [_dataOwnerSessionKey]):
        // the uid can change for a stable account, and wiping would destroy the current
        // user's library.
        final stampedSession = prefs.getString(_dataOwnerSessionKey);
        final persistent = await SessionCookieManager().hasPersistentSession();
        final signedOut = await SessionCookieManager().hasExplicitlySignedOut();
        final isSameSession = (sessionTag != null &&
            stampedSession != null &&
            stampedSession == sessionTag) ||
            (stampedSession == null && persistent && !signedOut);
        print('DIAG: _ensureLocalDataBelongsTo: storedOwner=${owner.substring(0, owner.length < 12 ? owner.length : 12)}… '
            'incoming=${backupKey.substring(0, backupKey.length < 12 ? backupKey.length : 12)}… '
            'sessionTag=$sessionTag stamped=$stampedSession persistent=$persistent signedOut=$signedOut isSameSession=$isSameSession');
        if (isSameSession) {
          print('ALERT: account id changed for an UNCHANGED session '
              '(${owner.substring(0, owner.length < 12 ? owner.length : 12)}… -> '
              '${backupKey.substring(0, backupKey.length < 12 ? backupKey.length : 12)}…) '
              '— identity drift, NOT an account switch. Re-stamping without a '
              'wipe. If this repeats, the Worker is re-resolving the identity '
              'for the same account; see the anchor note in worker.js.');
          await prefs.setString(_dataOwnerKey, backupKey);
          if (sessionTag != null) {
            await prefs.setString(_dataOwnerSessionKey, sessionTag);
          }
          await prefs.setInt(_wipeAttemptsKey, 0);
          return;
        }
        // Log both owners (truncated salted hashes) so a real switch can be told apart
        // from a spurious one.
        print('Account switch detected — stored owner '
            '${owner.substring(0, owner.length < 12 ? owner.length : 12)}… != '
            'incoming ${backupKey.substring(0, backupKey.length < 12 ? backupKey.length : 12)}…'
            ' — wiping the previous account\'s local data before restore.');
        // Count failed attempts: repeating the wipe is right while it makes progress, not
        // forever.
        final attempts = (prefs.getInt(_wipeAttemptsKey) ?? 0) + 1;
        await prefs.setInt(_wipeAttemptsKey, attempts);
        // wipeAudio: false — downloads belong to the device/user and must
        // NEVER be wiped automatically. Personal library and history are wiped,
        // but audio files on disk remain safe.
        final failures = _criticalWipeFailures(
            await _wipeLocalUserData(wipeAudio: false, newAccount: true));
        if (failures.isNotEmpty && attempts < _maxWipeAttempts) {
          // Don't stamp a new owner while the previous account's data is still on disk:
          // that would make the leak permanent, since the mismatch would never fire again.
          // Leaving the stamp means the next launch wipes again, which is the right price
          // while it's making progress (see the attempt cap below).
          print('ALERT: owner stamp WITHHELD (attempt $attempts of '
              '$_maxWipeAttempts) — the wipe left user data behind '
              '(${failures.join('; ')}). The next launch will see the mismatch '
              'and wipe again rather than leaving it in place.');
          return;
        }
        if (failures.isNotEmpty) {
          // The loop has to end: past the cap, re-wiping destroys the current user's library
          // every launch for a next account that may never come. Stamped, and logged loudly,
          // because whatever survived is still on disk.
          print('ALERT: wipe FAILED $attempts times and will not be retried — '
              'stamping the owner to stop an endless wipe loop. Residue: '
              '${failures.join('; ')}. This device may still hold the previous '
              "account's audio; clear the app's storage to be certain.");
        }
        await prefs.setInt(_wipeAttemptsKey, 0);
      }
      await prefs.setString(_dataOwnerKey, backupKey);
      // Recorded WITH the owner, so the next mismatch can tell drift from a
      // switch. Absent (an older install, or a caller with no cookie to hand)
      // simply means the suppression above cannot fire, which is the old
      // behaviour rather than a new risk.
      if (sessionTag != null) {
        await prefs.setString(_dataOwnerSessionKey, sessionTag);
      }
    } catch (e) {
      // Same reasoning as _ensureLocalDataBelongsToSession above: a hidden failure
      // here leaves the stored owner stale, and the next restore wipes again.
      print('ALERT: could not record the data owner key ($e) — a repeat '
          'account-switch wipe is now possible; check free storage');
    }
  }

  /// Rebuilds collections that are derived rather than stored. "My Top 50" is
  /// computed from the backed-up play counts by [refreshTop50], so after a restore it
  /// must be rebuilt. The intelligence provider must have reloaded first; every
  /// caller does that.
  Future<void> _rebuildDerivedCollections() async {
    try {
      final intel = _ref.read(intelligenceProvider);
      _ref.read(libraryProvider.notifier).refreshTop50(
          intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
    } catch (_) {}
  }
  /// After a cloud restore, re-reads restored settings into their live
  /// providers. Settings providers read their pref once at startup (before the
  /// restore), so otherwise restored theme, quality, EQ, data saver and so on
  /// would only apply after a restart. Best-effort per setting; never throws.
  Future<void> _applyRestoredSettings() async {
    print('DIAG: _applyRestoredSettings started');
    try {
      await _ref.read(playerProvider.notifier).reloadSettings();
    } catch (_) {}
    try {
      await _ref.read(themeProvider.notifier).reloadFromStorage();
      await _ref.read(dynamicAccentProvider.notifier).reloadFromStorage();
      await _ref.read(pureBlackProvider.notifier).reloadFromStorage();
      await _ref.read(playerControlsColorProvider.notifier).reloadFromStorage();
      await _ref.read(artworkGlowModeProvider.notifier).reloadFromStorage();
      await _ref.read(playerBackgroundStyleProvider.notifier).reloadFromStorage();
      final prefs = await SharedPreferences.getInstance();
      HapticService.enabled = prefs.getBool('auvy_haptics_enabled') ?? true;
      // Also re-applies the restored stream-source selection.
      ListeningPolicy.reloadFrom(prefs);
      // reloadFrom only sets the static; the WINDOW flag is normally applied by
      // MainActivity.onCreate, which already ran. Push it now so a restored
      // "block screenshots" doesn't wait for the next cold start.
      await ListeningPolicy.setBlockScreenshots(ListeningPolicy.blockScreenshots);
    } catch (e) {
      print('WARN: _applyRestoredSettings theme reload failed: $e');
    }
    // A restored alarm must be re-armed, not just remembered: the schedule lives in
    // Android's AlarmManager, which knows nothing about the restore. `save()` re-arms
    // natively (cancelling first, so there's no duplicate) and cancels when disabled.
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
    // Three more providers that read their pref only in the constructor, so a restored
    // value would sit unused until the next cold start. Invalidating densityProvider
    // also refreshes `densityNow` (written by DensityNotifier._load).
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
    try {
      _ref.invalidate(pinnedPodcastsProvider);
    } catch (_) {}
    try {
      _ref.invalidate(artworkGlowModeProvider);
    } catch (_) {}
    try {
      _ref.invalidate(playerBackgroundStyleProvider);
    } catch (_) {}

    // "My Top 50" is normally rebuilt only from playback (player_queue), so
    // after a cloud restore it would sit stale/empty until the next song plays.
    // Rebuild it now from the just-restored listening data.
    try {
      final intel = _ref.read(intelligenceProvider);
      _ref.read(libraryProvider.notifier).refreshTop50(
          intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
    } catch (_) {}
    print('OK: _applyRestoredSettings finished');
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
      // Respect an explicit sign-out. This runs at startup when no account is saved,
      // which is the state logout leaves; clearing the platform cookie store is
      // asynchronous, so leftover cookies could otherwise sign the user straight back
      // in. Only the unforced path is gated: the real login flow passes force: true, and
      // a successful sign-in clears the flag (_markSessionActive).
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
        // If local account lookup fails (no auth cookies, or account_menu won't answer),
        // use [fallbackIdentity]: the identity the Worker resolved from these same cookies.
        // It's the exact string _backupKeyFor hashes, so the backup key is unchanged.
        // Otherwise the app would show "Guest" and never reach the Worker.
        var fb = fallbackIdentity?.trim() ?? '';
        // No identity supplied: ask the Worker, which resolves it from these cookies.
        // Otherwise the app could stay on "Guest" forever (no identity → no Worker call →
        // no way to recover the identity). Only the startup path gets here without a
        // fallback, so at most one request per launch, only while broken.
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
        print('OK: YouTube session registered (fallback): ${_maskIdentity(fb)}');
        await _ensureLocalDataBelongsToSession(fb);
        enableCloudBackup(interactive: false).catchError((Object e) {
          print('background cloud activation failed: ${e.runtimeType}');
          return false;
        });
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
          // Marks this as a cookie-derived session (no Google OAuth token).
          accessToken: _cookieSessionToken,
        ),
        preferredPrimary: AccountType.youtube,
      );
      await _saveAccount();
      // Masked: the line only needs to show which account registered, and the activity
      // log records print output.
      print('OK: YouTube session registered: ${_maskIdentity(id)}');

      // Check whose data is on this device on every registration, approved or not, with
      // no network needed. The cloud path's check only runs after the Worker approves,
      // so a refused account would otherwise see the previous account's library.
      await _ensureLocalDataBelongsToSession(id);
      // Startup auto-registration: silent only (no unprompted account picker); the login
      // gate triggers interactive sign-in separately.
      //
      // Not awaited: cloud activation signs in to Firebase with a custom token, which
      // can take ten seconds or more (mostly App Check with Play Integrity), and login
      // shouldn't wait for it. The login gate waits where it matters (a returning user's
      // backup decides whether onboarding shows), bounded, and only when the flag isn't
      // already set locally. Errors are swallowed: cloud backup is an enhancement.
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

  // YouTube integration. Base sign-in requests only the non-sensitive `email` scope.
  // `youtube.readonly` is sensitive, and an unverified app in Testing mode can only
  // grant it to listed test users, so it's requested incrementally, only when the
  // user imports their YouTube playlists (see [_ensureMusicScope]).
  static const String _youtubeReadonlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);

  /// Request the sensitive YouTube read scope on demand (incremental auth),
  /// only for the optional "import my YouTube playlists" feature. Returns false
  /// if the user declines or the app isn't allowed to grant it.
  Future<bool> _ensureMusicScope() async {
    try {
      // Call requestScopes directly; canAccessScopes() is unimplemented in this
      // google_sign_in version and throws. requestScopes is idempotent.
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

  Future<List<Map<String, dynamic>>> fetchAccountPlaylists() async {
    final token = await _getValidMusicToken();
    if (token == null) return [];
    
    final response = await HttpPool().getClient().get(
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
      final response = await HttpPool().getClient().get(uri, headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 12),
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
      final response = await HttpPool().getClient().get(uri, headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 12),
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

    // The account is the source of truth for playlists (other apps' backups often only
    // reference them), so the page caps fit a real library, and any list that comes
    // back exactly at its cap is logged as possibly truncated.
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
          // A name collision must not silently drop a playlist: savePlaylistFromSearch
          // refuses an existing title, so duplicates get a number and both survive.
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

    // 3. Saved albums, imported on the cookie path too (the OAuth path needs a scope
    // Google won't grant an unverified app).
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

  /// Syncs the user's YouTube Music library into Auvy. Cookie session (InnerTube)
  /// first; the OAuth/Data API path below needs the sensitive youtube.readonly scope,
  /// which Google refuses for non-test users while the app is unverified. Returns how
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

  /// Deletes what the removed Discord features left on the device, once. A token
  /// nothing reads is still a live credential on disk.
  Future<void> _forgetRemovedDiscordData() async {
    try {
      await _secureStorage.delete(key: 'auvy_discord_rpc_token');
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('auvy_discord_rpc_enabled');
    } catch (_) {}
  }

  Future<void> logout() async {
    // FLUSH FIRST: pushes are debounced, so anything played in the last seconds
    // is still local-only. Back it up while the session is alive — the wipe
    // below is otherwise data loss for this account.
    if (CloudSyncService.instance.isActive) {
      // Log a failed final push: the wipe below would destroy data that existed nowhere
      // else. Logout still proceeds; the user is entitled to sign out.
      try {
        await CloudSyncService.instance.pushNow();
      } catch (e) {
        print('ALERT: LOGOUT: the final backup FAILED ($e). The wipe below will '
            'destroy anything played since the last successful push, and it '
            'exists nowhere else. Proceeding, because a sign-out must not be '
            'refusable.');
      }
    }

    // Deregister/revoke active device session from Worker BEFORE wiping cookies & session.
    // This immediately drops this device from the active device list on other devices.
    try {
      final prefs = await SharedPreferences.getInstance();
      final myDeviceId = prefs.getString(_deviceIdKey);
      if (myDeviceId != null && myDeviceId.isNotEmpty) {
        print('DIAG: AccountNotifier.logout - revoking device (${myDeviceId.length >= 6 ? myDeviceId.substring(0, 6) : myDeviceId}…) from Worker active sessions');
        await fetchDevices(revokeDeviceId: myDeviceId, selfLogout: true)
            .timeout(const Duration(seconds: 10));
        print('DIAG: AccountNotifier.logout - successfully deregistered device (${myDeviceId.length >= 6 ? myDeviceId.substring(0, 6) : myDeviceId}…) from Worker');
      }
    } catch (e) {
      print('DIAG: AccountNotifier.logout - device deregistration timeout/error ($e) — proceeding with local wipe');
    }

    state = AccountState(); // Clears all sessions
    // Leave no user data behind, so the next account doesn't inherit this one's
    // history, library, recents or taste (or have its restore skipped). Stops playback
    // as part of the wipe; there's no guest mode, logout returns to sign-in. Downloads
    // are kept, since signing back into the same account restores the library that
    // references them; a switch to a different account wipes them via
    // [_ensureLocalDataBelongsTo]. A failed step is reported, since signing back in
    // would restore on top of whatever it left behind.
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
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_dataOwnerIdKey);
    await prefs.remove(_dataOwnerKey);
    await prefs.remove(_dataOwnerSessionKey);
    _deviceInfoMemo = null;
    DeviceInfoService.resetForTest();
    await prefs.remove(_accountKey); // Clear any leftover legacy plaintext
    await prefs.remove('auvy_account');
  }

  /// Resets this device's session after another device signed it out. Clears the
  /// device id (so the next sign-in registers a fresh one), the saved account and the
  /// offline-grace markers.
  ///
  /// The data-owner stamps are kept: nothing is wiped here, so they're what lets the
  /// next sign-in notice a different account and clear the previous library.
  Future<void> resetDeviceSession() async {
    _deviceInfoMemo = null;
    DeviceInfoService.resetForTest();
    _forgetWorkerAnswer();
    state = AccountState();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_deviceIdKey);
      await prefs.remove(_accountKey);
      await prefs.remove('auvy_account');
      await prefs.remove(_everApprovedKey);
      await prefs.remove(_approvedForKey);
      await prefs.remove(_lastApprovedMsKey);
    } catch (_) {}
    try {
      await SessionCookieManager().clearCookies();
    } catch (_) {}
    try {
      await _secureStorage.delete(key: _accountKey);
    } catch (_) {}
    AuvyAppToken.set(null);
    CloudSyncService.instance.deactivate();
    if (CloudSyncService.isAvailable) {
      try {
        await fb_auth.FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
  }

  /// True when cloud backup is live for the signed-in account (Firebase ready +
  /// a uid resolved). Drives the "cloud connected" hint in the account dialog.
  bool get isCloudActive => CloudSyncService.instance.isActive;

  /// Manually back up now so the user can confirm sync works. Ensures the
  /// account is signed in to Firebase (one account-picker tap if needed), then
  /// pushes immediately. If another device pushed a newer backup, automatically
  /// restores and converges before pushing. Returns true only when the push
  /// actually SUCCEEDED (an attempted-but-failed push reports false; see
  /// [CloudSyncService.lastPushError] for the reason).
  Future<bool> backupNow() async {
    if (!CloudSyncService.isAvailable) return false;
    await enableCloudBackup(interactive: true);
    if (CloudSyncService.instance.needsRemoteMerge) {
      final restored = await restoreCloudBackup(force: true);
      if (restored) {
        final ok = await CloudSyncService.instance.pushNow();
        return ok && CloudSyncService.lastPushError == null;
      }
    }
    final attempted = await CloudSyncService.instance.pushNow();
    return attempted && CloudSyncService.lastPushError == null;
  }

  /// Manually pulls down the latest cloud backup, merging history/shards and
  /// updating live providers to converge multi-device state.
  Future<bool> restoreCloudBackup({bool force = false}) async {
    if (!CloudSyncService.isAvailable) return false;
    final uid = CloudSyncService.instance.currentUserId;
    if (uid == null) return false;
    final restored =
        await CloudSyncService.instance.activateAndRestore(uid, force: force);
    if (restored) {
      await _ref.read(intelligenceProvider.notifier).reloadFromStorage();
      await _ref.read(artworkOverrideProvider.notifier).reloadFromStorage();
      await _ref.read(libraryProvider.notifier).reloadFromStorage();
      await _rebuildDerivedCollections();
      await _applyRestoredSettings();
      try {
        _ref.read(homeProvider.notifier).refreshHome();
      } catch (_) {}
    }
    return restored;
  }

  /// Delete account: removes the user's Auvy data from our backend (the Firestore
  /// backup) and from the device, then resets the app to a new-user state. It
  /// doesn't touch the Google/YouTube account itself. Signing in again with the same
  /// account starts fresh. The caller navigates to a fresh start (SplashScreen)
  /// afterwards.
  Future<bool> deleteAuvyAccount() async {
    // 1. Delete this account's cloud backup, with the key computed here: the backup is
    // keyed by a hash of the YouTube identity, which is the same after re-creating the
    // account, so a surviving copy would be restored on the next sign-in. Done first,
    // and its result reported at the end, so the user is told if the cloud erase
    // failed.
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

    // 3. Wipe on-device audio (auto-cache, downloads and files). A failure here would
    // leave this account's downloads for the next account to find.
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

    // 6. Reload the data providers from the now-empty stores so nothing in memory
    // (feed, search history, stats) leaks or gets re-saved by a later save.
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