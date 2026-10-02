import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/widgets.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/core/backend_config.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/services/audio_output_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';

/// Listen Together
///
/// Synchronised listening: one person hosts a session, friends join with a
/// 6-character code, and everyone hears the same moment of the same track. Each
/// device streams its own audio; only small control messages are exchanged.
///
/// Transport is Firestore (already used for cloud backup) as a realtime relay.
/// The host is the single source of truth and writes the room document on every
/// track change, play/pause and seek, plus a heartbeat every 4 s while playing;
/// guests follow via snapshot listeners.
///
/// Staying in sync:
///  • both sides estimate their offset to a shared server clock (from the
///    Worker's /time, falling back to Firestore) and talk in server time;
///  • the host stamps every write with (positionMs, atServerMs); a guest's target
///    is positionMs + (serverNow − atServerMs) × the room speed, so latency and
///    clock skew cancel;
///  • play/pause/seek are scheduled for a future server instant, so every device,
///    host included, acts at the same moment;
///  • guests run a drift loop against an interpolated playhead: inside
///    ±[_softDriftMs] is in sync, beyond ±[_hardDriftMs] it hard-seeks, and in
///    between it time-stretches proportionally (pitch preserved) until back in
///    sync;
///  • a track change waits on a buffer barrier: the host holds the new song until
///    every listener reports it staged;
///  • listeners aren't read-only: their play/pause/seek/skip and queue edits are
///    sent as requests on their own member doc and applied by the host.
///
/// Sessions live under `listen_sessions/{CODE}` with a `members/{uid}`
/// subcollection for presence (25 s heartbeats).

enum LtRole { none, host, guest }

class LtMember {
  final String uid;
  final String name;
  final bool isHost;
  final int lastSeenMs; // server-clock ms
  /// When this member joined. The successor in a host migration is the
  /// longest-present listener, and every device has to reach the SAME answer
  /// without talking to the others. See _successorUid.
  final int joinedAtMs;

  const LtMember({
    required this.uid,
    required this.name,
    required this.isHost,
    required this.lastSeenMs,
    this.joinedAtMs = 0,
  });
}

class ListenTogetherState {
  final LtRole role;
  final String? code;
  final String? hostName;
  final bool busy; // create/join in flight
  final List<LtMember> members;

  /// One-shot message for the UI (session ended, host lost…). Cleared with
  /// [ListenTogetherNotifier.clearNotice] after it has been shown.
  final String? notice;

  const ListenTogetherState({
    this.role = LtRole.none,
    this.code,
    this.hostName,
    this.busy = false,
    this.members = const [],
    this.notice,
  });

  bool get active => role != LtRole.none;

  ListenTogetherState copyWith({
    LtRole? role,
    String? code,
    String? hostName,
    bool? busy,
    List<LtMember>? members,
    String? notice,
    bool clearNotice = false,
    bool clearSession = false,
  }) {
    return ListenTogetherState(
      role: role ?? (clearSession ? LtRole.none : this.role),
      code: clearSession ? null : (code ?? this.code),
      hostName: clearSession ? null : (hostName ?? this.hostName),
      busy: busy ?? this.busy,
      members: clearSession ? const [] : (members ?? this.members),
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

class ListenTogetherNotifier extends StateNotifier<ListenTogetherState> {
  ListenTogetherNotifier(this._ref) : super(const ListenTogetherState()) {
    // Fire-and-forget: a session that is still running should survive the app
    // being closed. See [_restoreSessionIfStillLive].
    _restoreSessionIfStillLive();

    _lifecycleHook = _LtLifecycleHook(onDetached: _onAppDetached);
    WidgetsBinding.instance.addObserver(_lifecycleHook!);
  }

  /// Key holding the room this device is in, so closing the app does not end it.
  static const String _kRememberedCode = 'lt_session_code';

  /// Watches for the app being genuinely CLOSED, so a host can end its session.
  _LtLifecycleHook? _lifecycleHook;

  /// Ends the session when the host's app is actually closed, and only then.
  /// Backgrounded (paused/hidden, music still playing in the foreground service)
  /// is not closed and is ignored; only `detached` (engine being torn down) ends
  /// the room. Best-effort: a hard kill may leave no time to write, and host
  /// migration covers that case.
  void _onAppDetached() {
    final code = _code;
    if (code == null || state.role != LtRole.host) return;
    print('LT host: app is closing — ending session $code');
    // Not awaited: there is no time to wait for a round trip during teardown,
    // and Firestore keeps the write queued locally, so it still lands if the
    // process survives long enough to flush.
    _roomRef(code).set({
      'active': false,
      'endedReason': 'host closed the app',
    }, SetOptions(merge: true)).catchError((Object e) {
      print('LT host: could not mark session ended: $e');
    });
  }

  /// Rejoins the remembered session, but only if it's genuinely still running.
  /// Coming back to the app should put a listener back in a room their friends are
  /// still in. The room must prove it's alive (`active` and a recent host heartbeat,
  /// the same window host migration uses), since `active` stays true on a room
  /// whose host was killed; otherwise the memory is dropped.
  ///
  /// Rejoining uses joinSession (the normal listener path) even for a former host;
  /// if the host seat is vacant, host migration promotes whoever is eligible.
  Future<void> _restoreSessionIfStillLive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_kRememberedCode);
      if (code == null || code.isEmpty) return;

      // Signed out, or Firebase not ready: keep the memory and try next launch
      // rather than discarding a live session over a transient condition.
      if (FirebaseAuth.instance.currentUser == null) return;

      final snap = await _roomRef(code).get();
      final data = snap.data();
      final stillActive = snap.exists && data != null && data['active'] == true;
      final hostSeen = (data?['hostSeenMs'] as num?)?.toInt() ?? 0;
      // A room from an older build carries no stamp; treat it as gone rather
      // than rejoining something that cannot be shown to be alive.
      final hostAlive =
          hostSeen > 0 && DateTime.now().millisecondsSinceEpoch - hostSeen < _hostGoneMs;

      if (!stillActive || !hostAlive) {
        print('LT: remembered session $code is over '
            '(active=$stillActive, host last seen '
            '${hostSeen == 0 ? "never" : "${DateTime.now().millisecondsSinceEpoch - hostSeen}ms ago"}) '
            '— forgetting it');
        await _forgetSession();
        return;
      }

      print('LT: rejoining session $code — it is still running');
      final err = await joinSession(code);
      if (err != null) {
        print('LT: could not rejoin $code ($err) — forgetting it');
        await _forgetSession();
      }
    } catch (e) {
      // Never let a restore attempt break app start.
      print('LT: session restore skipped ($e)');
    }
  }

  /// Remember the room across app restarts. Called on host and on join.
  Future<void> _rememberSession(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kRememberedCode, code);
    } catch (_) {}
  }

  /// Forget the room. ONLY on a deliberate leave, never on teardown.
  ///
  /// teardown runs on dispose too, and dispose runs when the app is closing —
  /// which is precisely the case this memory exists for. Clearing it there
  /// would make the whole thing a no-op.
  Future<void> _forgetSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kRememberedCode);
    } catch (_) {}
  }

  final Ref _ref;

  // Codes avoid 0/O/1/I so they survive being read out loud.
  static const String _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  static const int _codeLength = 6;

  // Drift thresholds. Firestore fan-out has more latency than a direct socket
  // relay, so these windows are wider than such a relay would use.
  /// The in-sync band for the drift loop. Tight because starts are scheduled on the
  /// same server instant, so what's left is small clock and decode error that a
  /// narrow band corrects without hunting.
  static const int _softDriftMs = 35;

  /// Where a correction STOPS, as opposed to where it starts.
  ///
  /// Deliberately well inside [_softDriftMs]: with one threshold, a session
  /// that converges to just under it crosses the line every tick and the
  /// corrector becomes the disturbance. See the note in the drift loop.
  static const int _nudgeExitMs = 15;

  /// How far ahead a scheduled action is placed, in server-clock ms.
  ///
  /// Every device acts at the same instant, host included. Naming a future instant
  /// turns relay latency into lead time. One lead for everyone, so pressing play
  /// feels the same on every device; it covers the worst case, a listener's request
  /// reaching the host and being relayed on (relay round trips are ~90–120 ms each
  /// way, so ~2.5x headroom).
  static const int _syncLeadMs = 600;
  static const int _hardDriftMs = 1500;
  /// Correction strength, scaled to the size of the error. See _nudgeFor.
  static const double _nudgeRate = 0.03;

  FirebaseFirestore get _fs => FirebaseFirestore.instance;
  DocumentReference<Map<String, dynamic>> _roomRef(String code) =>
      _fs.collection('listen_sessions').doc(code);

  String? _uid;
  String? _code;
  int _serverOffsetMs = 0; // serverNow ≈ localNow + offset
  int _rev = 0; // host: last written; guest: last applied

  void Function()? _playerUnsub;
  /// Signature of the last pushed host state, so a push logs only on change.
  String? _lastPushSig;
  /// Last logged sync zone, so the drift loop logs transitions, not ticks.
  String? _lastDriftZone;

  // Rolling drift statistics. A session steadily out of sync never changes zone,
  // so it never logs a transition; the signed mean shows a systematic bias (random
  // jitter averages to zero).
  int _driftSamples = 0;
  int _driftSignedSum = 0;
  int _driftAbsSum = 0;
  int _driftWorst = 0;

  /// This device's audio output latency, in milliseconds.
  ///
  /// The drift loop aligns playheads, but sound leaves the speaker some time after
  /// the decoder (over Bluetooth A2DP typically 150–250 ms). Two phones locked to
  /// the same playhead can still be a quarter-second apart at the ear if one is on
  /// Bluetooth.
  ///
  /// The conversion is symmetric: everyone agrees on the heard position.
  ///
  ///   host publishes:   heard    = playhead - L(host)
  ///   listener targets: playhead = heard    + L(listener)
  ///
  /// Android doesn't report a reliable total A2DP latency, so this is a default per
  /// route (tunable), and 0 for wired or built-in outputs, where latency is already
  /// inside the drift band.
  int _outputLatencyMs = 0;

  /// A2DP's typical end-to-end delay. SBC and AAC, the codecs almost every
  /// phone and speaker negotiate, sit around here; aptX LL is far lower but
  /// cannot be detected from the route alone. A default that is roughly right
  /// beats leaving a quarter-second error in place, and it is adjustable.
  static const int _bluetoothLatencyDefaultMs = 180;

  /// Preference key, so a tuned value survives a restart.
  static const String _kOutputLatency = 'lt_output_latency_ms';

  /// Re-read the route and adopt its latency. Cheap, and called when a session
  /// starts and whenever the output device changes under us.
  Future<void> _refreshOutputLatency() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final override = prefs.getInt(_kOutputLatency);
      final route = await AudioOutputService.currentRoute();
      final isBt = route == 'bluetooth';
      // A stored value is the user's own measurement and outranks the guess —
      // but only while it still applies to a Bluetooth route. Carrying it onto
      // the phone speaker would introduce the very error it was set to remove.
      final next = (override != null && isBt)
          ? override
          : (isBt ? _bluetoothLatencyDefaultMs : 0);
      if (next != _outputLatencyMs) {
        _outputLatencyMs = next;
        print('LT: output latency ${next}ms (route=${route ?? "unknown"}'
            '${override != null && isBt ? ", user-set" : ""}) — '
            'compensating so both ends line up at the EAR, not at the playhead');
      }
    } catch (_) {
      // Unknown route: assume none rather than inventing a correction.
      _outputLatencyMs = 0;
    }
  }

  /// The standing offset between this device and the room, learned as it runs.
  ///
  /// This is the integral term. See the note in the drift loop for what it is
  /// correcting and why a proportional-only loop could never do it.
  double _driftBiasMs = 0;

  /// How fast the bias estimate moves. The freshness gate rejects many samples, so
  /// this is high enough to settle within about ten seconds; the gates make that
  /// safe, since only fresh, small samples reach it.
  static const double _biasLearnRate = 0.12;

  /// Ceiling on the learned bias. Guards against integral windup: a track
  /// change or a stall must not be able to accumulate into a correction that
  /// then throws the playhead somewhere absurd. Well beyond any real offset,
  /// so it only engages when something else has already gone wrong.
  static const double _biasClampMs = 500;

  /// A schedule older than this isn't evidence about this device: the target is
  /// projected from the host's stamp, so an old stamp mostly measures its age. The
  /// host restamps every 4 s while playing (and at once on any change), so this
  /// learns from the fresher three quarters of each interval.
  static const int _biasMaxScheduleAgeMs = 3000;

  /// A sample bigger than this is an EVENT, not an offset.
  ///
  /// A standing offset is small by nature — a large one would already have been
  /// hard-seeked away. Rebuffers, late schedules and host hiccups all land far
  /// above this, and letting them teach is what wound the integrator up.
  static const int _biasMaxSampleMs = 250;

  /// How many ticks the bias estimate actually learned from, versus how many
  /// were rejected as stale or as events. Reported so a suspiciously steady
  /// learned offset can be told apart from one built on almost no data.
  int _biasSamplesUsed = 0;
  int _biasSamplesSkipped = 0;

  /// The drift loop ticks twice a second, so this is a summary about every
  /// 15 seconds — often enough to see a trend, rare enough not to be
  /// the noise it is measuring.
  static const int _driftReportEvery = 30;

  // Host liveness, measured without comparing two phones' clocks
  /// The last heartbeat VALUE seen from the host, and when we saw it CHANGE by
  /// our own clock. Staleness means "this number stopped moving", never "their
  /// number is far from my now". See the note in _watchMembers.
  int _lastHostSeenValue = -1;
  int _lastHostSeenAtLocalMs = 0;
  int _hostStaleStrikes = 0;

  /// When our own position value last moved, so drift is measured against an
  /// interpolated playhead rather than a value up to ~500 ms old. See
  /// [_livePositionMs].
  /// Debounces a guest request against itself. See _onGuestPlayerState.

  /// Guest request nonces already applied. See _applyGuestRequests.
  /// Applied guest-request nonces, newest last (Dart's default Set keeps
  /// insertion order, which is what makes the eviction below FIFO).
  final Set<String> _seenRequestNonces = {};

  /// How long a guest request stays actionable. Past this it is history, and
  /// applying it is worse than dropping it — see _applyGuestRequests.
  static const int _requestMaxAgeMs = 60000;

  /// Remembers [nonce], dropping the oldest entries when the set is full (not a
  /// wholesale clear, which would make every request Firestore still holds look new
  /// again). A replayed nonce is always a recent one.
  void _rememberNonce(String nonce) {
    const cap = 200;
    if (_seenRequestNonces.length >= cap) {
      for (var i = 0; i < cap ~/ 2; i++) {
        if (_seenRequestNonces.isEmpty) break;
        _seenRequestNonces.remove(_seenRequestNonces.first);
      }
    }
    _seenRequestNonces.add(nonce);
  }

  // Buffer barrier state (host)
  /// uid → the song id that member reports it has staged.
  final Map<String, String> _memberReadyFor = {};
  /// The song the barrier is currently about, when the wait began, and whether
  /// the host actually paused for it (so it knows to release).
  String _barrierSongId = '';
  int _barrierStartedAtMs = 0;
  bool _barrierHeld = false;

  /// Until when our OWN player changes are the room's doing, not the user's.
  /// See _onGuestPlayerState.
  int _suppressGuestEchoUntilMs = 0;
  int _positionSeenAtLocalMs = 0;

  /// The track the current position reading was taken on. The player announces a
  /// new song before it resets the position, so for a moment the reading still
  /// belongs to the previous track.
  String? _positionSongId;
  void Function()? _positionListener;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roomSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _membersSub;
  Timer? _hostTicker;
  Timer? _guestTicker;
  Timer? _presenceTimer;

  /// The mirrored queue lives on its own document. See [_pushQueue].
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _queueSub;

  /// Host: signature of the queue as last mirrored, so the heartbeat doesn't
  /// rewrite an unchanged track list every four seconds.
  String? _lastQueueSig;


  /// The last mirror received, kept so it can be re-applied: playSong (called when
  /// following the host's track) sets its own queue and can land after the mirror,
  /// and the mirror is only republished when the host's queue changes.
  List<Song> _mirrorUser = const [];
  List<Song> _mirrorContext = const [];
  List<Song> _mirrorAuto = const [];
  String? _mirrorContextTitle;

  /// A play-state change waiting for its instant. Non-null means DO NOT let the
  /// heartbeat or the drift loop touch play state — they would both read the
  /// not-yet-applied state as a disagreement to correct.
  Timer? _execTimer;
  int _execAtServerMs = 0;

  /// When this device last issued a seek of its own accord (applying the room,
  /// executing a schedule, or a drift correction). See _onGuestPlayerState.
  int _lastLocalSeekAtMs = 0;

  /// Guards the takeover transaction against being fired twice by consecutive
  /// ticks while the first is still in flight.
  bool _claiming = false;

  /// Consecutive SERVER roster snapshots with no host row. See _watchMembers.
  int _hostRowMisses = 0;

  /// Freshest hostSeenMs seen from ANY source — a room snapshot, or the claim
  /// transaction's own read. See _checkHostAlive.
  int _hostSeenObserved = 0;

  /// Rate-limits takeover attempts. See _checkHostAlive.
  int _lastClaimAtMs = 0;
  int _lastStandbyLogMs = 0;
  bool get _hasPendingExec =>
      _execTimer != null && _execAtServerMs > _nowServerMs() - 250;
  bool get _hasMirror =>
      _mirrorUser.isNotEmpty ||
      _mirrorContext.isNotEmpty ||
      _mirrorAuto.isNotEmpty;

  void _reapplyMirror() {
    if (state.role != LtRole.guest || !_hasMirror) return;
    _ref.read(playerProvider.notifier).adoptRemoteQueue(
          userQueue: _mirrorUser,
          contextQueue: _mirrorContext,
          autoplayQueue: _mirrorAuto,
          contextTitle: _mirrorContextTitle,
        );
  }

  /// Guest: requests waiting to be written, one document write at a time.
  /// See [_drainOutbox] for why they cannot all go at once.
  final List<Map<String, dynamic>> _outbox = [];
  Timer? _outboxTimer;
  String? _lastSentSig;
  int _lastSentAtMs = 0;
  // Host-side change detection.
  String? _lastPushedSongId;
  bool? _lastPushedPlaying;
  int _lastPushedPosMs = 0;
  int _lastPushedAtLocalMs = 0;
  int _hostTick = 0;
  int _prevMemberCount = 0;

  // Guest-side apply state.
  Map<String, dynamic>? _room;
  bool _applying = false;
  bool _applyQueued = false;
  bool _nudging = false;
  int _playMismatchTicks = 0;
  int _songMismatchTicks = 0;

  int _nowServerMs() => DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;

  String get _displayName {
    final n = _ref.read(accountProvider).displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Listener';
  }

  // Session lifecycle

  /// Start hosting. Returns an error message, or null on success.
  Future<String?> createSession() async {
    if (state.active) return 'You are already in a session.';
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final authErr = await _ensureAuth();
      if (authErr != null) return authErr;

      // Generate a code that isn't already an active room (3 attempts — a
      // collision in a 31^6 space is already lottery-odds).
      final rand = Random.secure();
      String code = '';
      for (var attempt = 0; attempt < 3; attempt++) {
        code = List.generate(
            _codeLength, (_) => _alphabet[rand.nextInt(_alphabet.length)]).join();
        final existing = await _roomRef(code).get();
        if (!existing.exists || existing.data()?['active'] != true) break;
      }
      _code = code;

      final name = _displayName;
      await _roomRef(code).set({
        'active': true,
        'hostId': _uid,
        'hostName': name,
        'rev': 0,
        'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      // The host doesn't remember its own session: closing the app ends it, so there's
      // nothing to return to. Only listeners persist (see _restoreSessionIfStillLive).
      await _memberRef()!.set({
        'name': name,
        'isHost': true,
        'joinedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      await _estimateServerClock();
      await _refreshOutputLatency();
      await _memberRef()!
          .set({'lastSeenMs': _nowServerMs()}, SetOptions(merge: true));

      state = state.copyWith(role: LtRole.host, code: code, hostName: name);
      _startHostEngine();
      _watchMembers();
      _startPresence();
      _pushNow(); // seed the room with the current track immediately
      print('LT: session $code created (host)');
      return null;
    } catch (e) {
      print('LT: createSession failed: $e');
      _code = null;
      return 'Could not start the session. Check your connection.';
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Join an existing session by code. Returns an error message, or null.
  Future<String?> joinSession(String rawCode) async {
    if (state.active) return 'You are already in a session.';
    final code = rawCode.trim().toUpperCase();
    if (code.length != _codeLength) return 'Codes are 6 characters.';
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final authErr = await _ensureAuth();
      if (authErr != null) return authErr;

      final snap = await _roomRef(code).get();
      final data = snap.data();
      if (!snap.exists || data == null || data['active'] != true) {
        return 'No session found for that code.';
      }
      _code = code;
      _rev = 0;
      // Remembered as soon as the room is confirmed active, so closing the app
      // from here on lands back in this session. See _restoreSessionIfStillLive.
      await _rememberSession(code);

      await _memberRef()!.set({
        'name': _displayName,
        'isHost': false,
        'joinedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      await _estimateServerClock();
      await _refreshOutputLatency();
      await _memberRef()!
          .set({'lastSeenMs': _nowServerMs()}, SetOptions(merge: true));

      state = state.copyWith(
        role: LtRole.guest,
        code: code,
        hostName: (data['hostName'] ?? 'Host').toString(),
      );
      _startGuestEngine();
      _watchMembers();
      _startPresence();
      return null;
    } catch (e) {
      // Log the real error as well as the friendly message; a Firestore rules or
      // anonymous-auth problem looks the same as a wrong code on screen.
      print('LT: joinSession("$code") FAILED: $e');
      _code = null;
      return 'Could not join. Check your connection and the code.';
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Leave (guest) or end (host) the current session.
  Future<void> leaveSession() async {
    print('LT: leaveSession (role=${state.role}, code=$_code)');
    await _forgetSession();
    final wasHost = state.role == LtRole.host;
    final code = _code;
    final members = state.members;
    // Chosen before the teardown below, which clears the roster this reads.
    final successorUid = wasHost ? _successorUid() : null;
    final successor = successorUid == null
        ? null
        : members.where((m) => m.uid == successorUid).firstOrNull;
    _teardown();
    state = state.copyWith(clearSession: true, clearNotice: true);
    if (code == null) return;
    try {
      if (wasHost) {
        // Hand over rather than delete if anyone is still listening, so one person
        // leaving doesn't end everyone's session; the room is only removed when the last
        // listener leaves. hostSeenMs is set to an ancient value so that if the
        // successor never arrives, the others see an abandoned room at once and one
        // claims it.
        final heir = successor;
        if (heir != null) {
          await _roomRef(code).set({
            'hostId': heir.uid,
            'hostName': heir.name,
            // 1, not 0: _checkHostAlive skips `hostSeenMs <= 0` (rooms from builds without
            // the field), so an ancient but present value is what marks the room abandoned.
            'hostSeenMs': 1,
          }, SetOptions(merge: true));
          if (_uid != null) {
            await _roomRef(code).collection('members').doc(_uid).delete();
          }
          print('LT: handed the session to ${heir.name}');
        } else {
          final batch = _fs.batch();
          for (final m in members) {
            batch.delete(_roomRef(code).collection('members').doc(m.uid));
          }
          batch.delete(_roomRef(code));
          await batch.commit();
        }
        if (_uid != null) {
          await _roomRef(code).collection('members').doc(_uid).delete();
        }
      } else {
        if (_uid != null) {
          await _roomRef(code).collection('members').doc(_uid).delete();
          print('LT: guest $_uid removed member presence doc on graceful leave');
        }
      }
    } catch (e) {
      print('LT: leaveSession cleanup error: $e');
    }
  }

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(clearNotice: true);
  }

  @override
  void dispose() {
    print('LT: notifier disposed (role=${state.role}, code=$_code)');
    if (_lifecycleHook != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleHook!);
      _lifecycleHook = null;
    }
    _teardown();
    super.dispose();
  }

  // Auth & clock

  Future<String?> _ensureAuth() async {
    if (!CloudSyncService.isAvailable) {
      return 'Listen Together needs an internet connection.';
    }
    // Every Auvy user is signed in with Google, but FIREBASE sign-in only
    // happens through the cloud-backup flow — cookie-session logins never ran
    // it. Reuse that exact flow here (silent when a GoogleSignIn session
    // exists, one account-picker tap when not) instead of bouncing the user
    // to Settings.
    var user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try {
        await _ref
            .read(accountProvider.notifier)
            .enableCloudBackup(interactive: true);
      } catch (_) {}
      user = FirebaseAuth.instance.currentUser;
    }
    if (user == null) {
      return 'Google sign-in didn\'t complete. Try again.';
    }
    _uid = user.uid;
    return null;
  }

  DocumentReference<Map<String, dynamic>>? _memberRef() {
    final code = _code;
    final uid = _uid;
    if (code == null || uid == null) return null;
    return _roomRef(code).collection('members').doc(uid);
  }

  /// Samples the Worker's clock and adopts the offset (`serverNow − localNow`).
  /// True when it succeeded.
  ///
  /// Cristian's algorithm: each sample gives `offset = serverTime − (t0 + t1) / 2`,
  /// which assumes equal request and response times. Network delay only ever adds,
  /// so the fastest round trip is provably closest to the truth (error within
  /// ±rtt/2), and it's used rather than a median. The bound is logged.
  Future<bool> _estimateServerClockFromWorker() async {
    if (!BackendConfig.isConfigured) return false;
    final uri = Uri.parse('${BackendConfig.workerBase}/time');
    int? bestOffset;
    var bestRtt = 1 << 30;
    var ok = 0;

    // One client for all samples: `http.get()` pays a new DNS lookup and TLS
    // handshake each time (most of a cold call), which would inflate every round
    // trip and the error bound. The first, handshake-laden sample is discarded by
    // taking the minimum.
    final client = http.Client();
    try {
      for (var i = 0; i < 8; i++) {
        try {
          final t0 = DateTime.now().millisecondsSinceEpoch;
          final res = await client
              .get(uri, headers: const {'Cache-Control': 'no-cache'})
              .timeout(const Duration(seconds: 3));
          final t1 = DateTime.now().millisecondsSinceEpoch;
          if (res.statusCode != 200) continue;
          final t = (jsonDecode(res.body) as Map<String, dynamic>)['t'];
          if (t is! num) continue;
          ok++;
          final rtt = t1 - t0;
          if (rtt < bestRtt) {
            bestRtt = rtt;
            bestOffset = t.toInt() - ((t0 + t1) ~/ 2);
          }
          // A round trip already at the floor cannot be improved on
          // meaningfully. Requires 4 samples, not 3: the first is always the
          // handshake, so stopping earlier could exit having seen only one or
          // two real measurements.
          if (ok >= 4 && bestRtt <= 25) break;
        } catch (_) {
          // Individual failures are ordinary on mobile; only all-of-them matters.
        }
      }
    } finally {
      client.close();
    }

    if (bestOffset == null) return false;
    _serverOffsetMs = bestOffset;
    print('LT: shared clock offset ${bestOffset}ms via worker '
        '(best rtt ${bestRtt}ms of $ok samples → accurate to about '
        '±${bestRtt ~/ 2}ms)');
    return true;
  }

  /// Estimates the offset between this device's clock and the shared server
  /// clock. Every guest correction depends on it, so a wrong offset makes every
  /// device wrong by the same amount. Run when creating or joining a session.
  Future<void> _estimateServerClock() async {
    // Prefer the Worker's clock (`GET /time`, answered by the nearest Cloudflare
    // location with 10–30 ms round trips) over inferring the server time from a
    // Firestore commit, which happens in a region after replication and costs writes
    // and reads. This offset biases every drift correction, so accuracy matters.
    // Firestore stays as the fallback so a session works without the Worker.
    if (await _estimateServerClockFromWorker()) return;

    final ref = _memberRef();
    if (ref == null) return;
    print('LT: worker clock unavailable — falling back to Firestore timestamps');
    final samples = <({int rtt, int offset})>[];
    for (var i = 0; i < 5; i++) {
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        await ref.set({'ping': FieldValue.serverTimestamp()}, SetOptions(merge: true));
        final t1 = DateTime.now().millisecondsSinceEpoch;
        final snap = await ref.get(const GetOptions(source: Source.server));
        final ts = snap.data()?['ping'];
        if (ts is Timestamp) {
          samples.add((
            rtt: t1 - t0,
            offset: ts.millisecondsSinceEpoch - ((t0 + t1) ~/ 2),
          ));
        }
        // Three good samples is plenty; stop paying for round trips.
        if (samples.length >= 3 && i >= 2) break;
      } catch (_) {}
    }
    if (samples.isEmpty) {
      // 0 fallback: phone clocks are usually NTP-synced. Note that host liveness
      // no longer depends on this being right. See _watchMembers.
      print('LT: server clock estimate FAILED — assuming offset 0');
      _serverOffsetMs = 0;
      return;
    }
    final fastest = samples.map((s) => s.rtt).reduce(min);
    final good = samples.where((s) => s.rtt <= fastest * 1.5).toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    final median = good[good.length ~/ 2].offset;
    print('LT: server clock offset ${median}ms '
        '(${good.length}/${samples.length} samples, fastest rtt ${fastest}ms)');
    _serverOffsetMs = median;
  }

  // Host engine

  void _startHostEngine() {
    _lastPushedSongId = null;
    _lastPushedPlaying = null;
    _hostTick = 0;
    // The host needs the reading's age (to interpolate what it publishes) and its
    // track (so a song change doesn't publish the previous song's position).
    _watchPosition();
    _playerUnsub = _ref
        .read(playerProvider.notifier)
        .addListener(_onHostPlayerState, fireImmediately: false);
    // One ticker does double duty: every second it looks for a local seek
    // (live position far from where the last push projects it to be) and every
    // 4th tick it heartbeats the position while playing so drifting/late
    // guests re-converge (a 4 s PLAY heartbeat).
    _hostTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.role != LtRole.host) return;
      final s = _ref.read(playerProvider);
      _hostTick++;
      if (s.isPlaying && _lastPushedPlaying == true) {
        final elapsed =
            DateTime.now().millisecondsSinceEpoch - _lastPushedAtLocalMs;
        final expected = _lastPushedPosMs + (elapsed * s.speed).round();
        final actual = currentPositionProvider.value.inMilliseconds;
        if ((actual - expected).abs() > 2000) {
          _pushNow(); // host seeked — propagate within a second
          return;
        }
      }
      final alone = state.members.length <= 1;

      // Hold the start until every listener has the track staged. Otherwise the host
      // starts at once while each guest is still resolving its stream (often a second
      // or more) and then gets hard-seeked forward, a stumble at every track change.
      // (Metrolist's server does this with BUFFER_READY/BUFFER_WAIT.) Bounded by
      // [_bufferBarrierMs] so one stuck listener can't hold the session, and skipped
      // when the host is alone.
      final songId = s.currentSong?.id ?? '';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (songId != _barrierSongId) {
        _barrierSongId = songId;
        _barrierStartedAtMs = nowMs;
        _barrierHeld = false;
      }
      if (!alone && songId.isNotEmpty) {
        final waited = nowMs - _barrierStartedAtMs;
        final everyone = _everyoneReady(songId);
        if (!everyone && waited < _bufferBarrierMs) {
          if (s.isPlaying) {
            _barrierHeld = true;
            print('LT host: holding "${s.currentSong?.title}" — '
                'listeners still staging it (${waited}ms)');
            _ref.read(playerProvider.notifier).togglePlay(haptic: false);
            _pushNow(playingOverride: false);
          }
          return;
        }
        if (_barrierHeld && !s.isPlaying) {
          _barrierHeld = false;
          print(everyone
              ? 'LT host: everyone staged — starting together (${waited}ms)'
              : 'LT host: barrier timed out at ${waited}ms — starting anyway');
          _ref.read(playerProvider.notifier).togglePlay(haptic: false);
          return;
        }
      }

      if (_hostTick % 4 == 0 && s.isPlaying && !alone && !_hasPendingExec) {
        _pushNow();
      }
    });
  }

  void _onHostPlayerState(PlayerState s) {
    if (state.role != LtRole.host) return;

    // The queue mirror is pushed once per event: _pushNow mirrors as its last step,
    // so this call only covers a queue edit that changes neither the track nor
    // play/pause.

    // A track change isn't a pause. Between tracks the player briefly reports
    // isPlaying=false while the next stream loads; publishing that paused every
    // guest. A loading state isn't broadcast; the host ticker's heartbeat publishes
    // once the new track plays, and a song change is still pushed immediately so guests can
    // start resolving the same stream.
    final songChanged = s.currentSong?.id != _lastPushedSongId;
    final settling = s.isLoading && !songChanged;
    final material = songChanged || s.isPlaying != _lastPushedPlaying;
    if (!settling && material) {
      // A pause that arrives WITH a song change is the transition, not intent —
      // publish the new song but keep the previous play state, which the ticker
      // will correct within a second if the host really did stop.
      _pushNow(
          playingOverride:
              songChanged && !s.isPlaying ? _lastPushedPlaying : null);
      return; // _pushNow mirrored the queue already
    }
    if (settling) return;
    _pushQueue();
  }

  // Host migration. The host is a role, not a privilege: it serialises edits so
  // two listeners can't produce two different queues, and losing it shouldn't end
  // the session. A graceful leave names a successor and hands over instantly; after
  // a crash or network loss, listeners notice hostSeenMs going stale and one claims
  // the room.

  /// A host is considered gone once its stamp is this old. Comfortably past the
  /// 25-second presence tick, so a slow write or one dropped tick is not a
  /// takeover.
  static const int _hostGoneMs = 70000;

  /// When a listener stops being shown as present: three missed 25 s heartbeats.
  /// Matches [_hostGoneMs] so the roster and succession agree on who is still here.
  static const int _memberGoneMs = 75000;

  /// Who should take over, computed identically on every device so exactly one
  /// of them claims the room and there is no election to negotiate.
  ///
  /// Longest-present listener wins; uid breaks a tie (two devices can share a
  /// joinedAtMs to the millisecond). Members whose own presence is stale are
  /// skipped — promoting a device that left with the host achieves nothing.
  String? _successorUid() {
    final now = _nowServerMs();
    final candidates = state.members
        .where((m) => !m.isHost && now - m.lastSeenMs < _hostGoneMs)
        .toList()
      ..sort((a, b) {
        final j = a.joinedAtMs.compareTo(b.joinedAtMs);
        return j != 0 ? j : a.uid.compareTo(b.uid);
      });
    return candidates.isEmpty ? null : candidates.first.uid;
  }

  /// Guest side: has the host stopped stamping, and am I the one to take over?
  void _checkHostAlive() {
    if (state.role != LtRole.guest) return;
    if (_room == null) return;
    // The freshest stamp from ANY source — snapshots, and the transaction's own
    // read when a claim is declined. Reading the room copy alone was what made
    // the claim loop possible.
    final seen = _hostSeenObserved;
    // A room written by an older build carries no stamp at all. Treating that as
    // "gone" would hijack a live session, so it is treated as alive and the old
    // liveness watchdog stays in charge of it.
    if (seen <= 0) return;
    // If this device is offline, the host isn't the one who went missing: our own
    // outage also produces stale stamps, and a claim is a write that can't succeed
    // offline anyway. A reconnect brings a fresh snapshot and the check runs again.
    if (!_ref.read(connectivityProvider).hasInternet) return;
    final age = _nowServerMs() - seen;
    // A future-dated stamp means the clocks disagree, NOT that the host is
    // IMMORTAL. Both devices estimate the server clock independently (each can be
    // tens to hundreds of ms off), so a stamp can land slightly ahead of our own
    // "now". Negative ages are simply not stale; what
    // matters is that they never wrap into looking stale either.
    if (age < _hostGoneMs) return;
    // Log when this device defers to another successor (rate-limited like the
    // claim), so a failed election is visible in the log.
    final successor = _successorUid();
    if (successor != _uid) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // Its OWN clock, deliberately. Sharing the claim backoff would mean a
      // device that logged "standing by" and then became the successor had its
      // takeover postponed by up to 8s — a log line delaying a recovery.
      if (nowMs - _lastStandbyLogMs >= 8000) {
        _lastStandbyLogMs = nowMs;
        print('LT: host stamp is ${age}ms old but the successor is '
            '${successor ?? "nobody"} (this device is $_uid) — standing by');
      }
      return;
    }
    // Backoff. Without it a declined claim was retried on every 500 ms tick,
    // which is a transaction per tick against a room that is fine.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastClaimAtMs < 8000) return;
    _lastClaimAtMs = now;
    print('LT guest: host stamp is ${age}ms old — claiming the session');
    _claimHost();
  }

  /// Take the room over, but only if it is still abandoned at the moment of
  /// writing — a transaction, because two listeners whose clocks disagree could
  /// otherwise both decide they are the successor.
  Future<void> _claimHost() async {
    final code = _code;
    final uid = _uid;
    if (code == null || uid == null || _claiming) return;
    _claiming = true;
    try {
      final won = await FirebaseFirestore.instance
          .runTransaction<bool>((tx) async {
        final snap = await tx.get(_roomRef(code));
        final data = snap.data();
        if (data == null || data['active'] != true) return false;
        final seen = (data['hostSeenMs'] as num?)?.toInt() ?? 0;
        // Adopt what the server says, win OR lose.
        //
        // This read is the most authoritative stamp there is, and the caller's
        // own copy is what sent us here. Recording it means a decline actually
        // teaches the liveness check something instead of leaving it to reach
        // the same wrong conclusion on the next tick.
        if (seen > _hostSeenObserved) _hostSeenObserved = seen;
        // Someone got here first, or the host came back between the check and
        // this write.
        if (seen > 0 && _nowServerMs() - seen < _hostGoneMs) return false;
        tx.set(_roomRef(code), {
          'hostId': uid,
          'hostName': _displayName,
          'hostSeenMs': _nowServerMs(),
        }, SetOptions(merge: true));
        return true;
      });
      if (!won) {
        print('LT: host claim declined — the room was not abandoned');
        return;
      }
      _promoteToHost();
    } catch (e) {
      print('LT: host claim FAILED: $e');
    } finally {
      _claiming = false;
    }
  }

  /// Becomes the host, keeping playback where it is. The guest machinery stops
  /// first; otherwise the room subscription would apply this device's own pushes
  /// back to it and the drift loop would chase its own output.
  void _promoteToHost() {
    if (state.role == LtRole.host) return;
    print('LT: PROMOTED to host — continuing the session');
    _roomSub?.cancel();
    _roomSub = null;
    _queueSub?.cancel();
    _queueSub = null;
    _guestTicker?.cancel();
    _guestTicker = null;
    _execTimer?.cancel();
    _execTimer = null;
    _playerUnsub?.call();
    _playerUnsub = null;
    if (_nudging) {
      _nudging = false;
      try {
        _ref.read(playerProvider.notifier).setSpeed(_preNudgeSpeed);
      } catch (_) {}
    }
    _room = null;
    _applying = false;
    _mirrorUser = const [];
    _mirrorContext = const [];
    _mirrorAuto = const [];
    _lastQueueSig = null;
    _lastPushSig = null;
    _outbox.clear();
    _outboxTimer?.cancel();
    _outboxTimer = null;

    state = state.copyWith(role: LtRole.host, hostName: _displayName);
    _memberRef()?.set({'isHost': true}, SetOptions(merge: true))
        .catchError((_) {});
    _startHostEngine();
    _pushNow();
    state = state.copyWith(notice: 'You are hosting this session now.');
  }

  // Scheduled execution
  //
  // A play/pause is published as "at server time T, be <playing> at <position>"
  // and EVERY device — the one that pressed the button included — waits for T.
  // Nobody chases anybody, so the alignment no longer depends on the latency of
  // the message that carried it.

  /// Apply a scheduled state at [execAtServerMs], or immediately if that instant
  /// has already passed.
  ///
  /// [posAtExecMs] is the playhead AT THAT INSTANT, not now — the publisher
  /// projects it forward, so a device applying the schedule never has to guess
  /// how long the message took.
  void _scheduleApply({
    required bool playing,
    required int posAtExecMs,
    required int execAtServerMs,
    String? songId,
  }) {
    _execTimer?.cancel();
    _execAtServerMs = execAtServerMs;
    final waitMs = execAtServerMs - _nowServerMs();

    void apply() {
      _execTimer = null;
      if (!mounted || !state.active) return;
      final notifier = _ref.read(playerProvider.notifier);
      final ps = _ref.read(playerProvider);
      // A guest must not report this back as its own user's doing.
      if (state.role == LtRole.guest) _suppressEcho();

      // A position only means something on the track it was measured on. On the same
      // track, pin the playhead; on a different track (every track change), apply
      // only the play state and let the room's track sync catch up. A late schedule is
      // treated the same way: seeking to a stale position is worse than not seeking.
      final sameTrack = songId == null || songId == ps.currentSong?.id;
      final lateMs = _nowServerMs() - execAtServerMs;
      final pinPlayhead = sameTrack && lateMs < 2000;

      // Ordering as established for the pinned pause/resume: stop before seeking
      // so a pause is silent, seek before starting so a resume lands on the right
      // frame.
      if (!playing && ps.isPlaying) notifier.togglePlay(haptic: false);
      final target = playing
          ? posAtExecMs + max(0, lateMs).toInt()
          : posAtExecMs;
      if (pinPlayhead &&
          (target - _livePositionMs(ps.speed)).abs() > _softDriftMs) {
        _lastLocalSeekAtMs = DateTime.now().millisecondsSinceEpoch;
        notifier.seek(Duration(milliseconds: target));
      }
      if (playing && !ps.isPlaying) notifier.togglePlay(haptic: false);
      // Re-armed AFTER the mutations: the state notifications they cause arrive
      // later than a window opened before them.
      if (state.role == LtRole.guest) _suppressEcho(2500);
      print('LT: executed schedule — playing=$playing '
          '${pinPlayhead ? "at ${target}ms" : "(state only)"} '
          '(${lateMs}ms off the instant)');
      // The host publishes the settled result, so a listener that joined while
      // the schedule was in flight converges on it.
      if (state.role == LtRole.host) _pushNow();
    }

    if (waitMs <= 0) {
      print('LT: schedule arrived ${-waitMs}ms LATE — applying at once');
      apply();
      return;
    }
    print('LT: scheduled playing=$playing at ${posAtExecMs}ms in ${waitMs}ms');
    _execTimer = Timer(Duration(milliseconds: waitMs), apply);
  }

  /// The play/pause button during a session. Returns true when the press became a
  /// schedule, so the caller must not also toggle the player. The host goes through
  /// here too, so it doesn't run one hop ahead of every listener.
  bool scheduleToggle() {
    if (!state.active) return false;
    final ps = _ref.read(playerProvider);
    if (ps.currentSong == null) return false;
    final wantPlaying = !ps.isPlaying;
    final isHost = state.role == LtRole.host;
    const lead = _syncLeadMs;
    final execAt = _nowServerMs() + lead;
    // Where the playhead will be AT the instant: it keeps running until then, so
    // a pause has to account for the lead. A resume starts where it stopped.
    final posAtExec =
        ps.isPlaying ? _livePositionMs(ps.speed) + lead : _livePositionMs(ps.speed);

    _scheduleApply(
        playing: wantPlaying,
        posAtExecMs: posAtExec,
        execAtServerMs: execAt,
        songId: ps.currentSong?.id);

    if (isHost) {
      _publishSchedule(
          playing: wantPlaying, posAtExecMs: posAtExec, execAtServerMs: execAt);
    } else {
      // A listener names the instant itself, which is why its lead covers TWO
      // hops: the host still has to receive it, act on it and relay it to the
      // other listeners before the instant arrives.
      //
      // The track goes with it: a position is only meaningful on the song it was
      // measured on, and the host may already have moved to the next one.
      _sendRequest('set_playing',
          want: wantPlaying,
          valueMs: posAtExec,
          execAtMs: execAt,
          trackId: ps.currentSong?.id);
    }
    return true;
  }

  /// Host: write a schedule to the room. Separate from [_pushNow] because a
  /// heartbeat must never carry one. See the suppression there.
  void _publishSchedule({
    required bool playing,
    required int posAtExecMs,
    required int execAtServerMs,
  }) {
    final code = _code;
    if (code == null || state.role != LtRole.host) return;
    _rev++;
    final s = _ref.read(playerProvider);
    _lastPushedSongId = s.currentSong?.id;
    _lastPushedPlaying = playing;
    _lastPushedPosMs = posAtExecMs;
    _lastPushedAtLocalMs = DateTime.now().millisecondsSinceEpoch;
    print('LT host: publishing schedule playing=$playing at ${posAtExecMs}ms '
        'for +${execAtServerMs - _nowServerMs()}ms (rev $_rev)');
    _roomRef(code).set({
      'active': true,
      'rev': _rev,
      'track': s.currentSong?.toMap(),
      'isPlaying': playing,
      'positionMs': posAtExecMs,
      'atServerMs': execAtServerMs,
      'execAtServerMs': execAtServerMs,
      'songId': s.currentSong?.id,
      'hostSeenMs': _nowServerMs(),
    }, SetOptions(merge: true)).catchError((Object e) {
      print('LT host: schedule publish FAILED: $e');
    });
  }

  void _pushNow({bool? playingOverride}) {
    final code = _code;
    if (code == null || state.role != LtRole.host) return;
    final s = _ref.read(playerProvider);
    // See _onHostPlayerState: the momentary not-playing of a track TRANSITION
    // must not be published as a pause, or every guest stalls between songs.
    final isPlaying = playingOverride ?? s.isPlaying;
    // The published position is interpolated from the last update (the provider
    // updates about twice a second), and expressed on the heard timeline: the host's
    // own output latency is subtracted so listeners align with what the room hears.
    // See _outputLatencyMs.
    //
    // A song change is published before the player has reset its position, so the
    // reading can still be the previous track's end. Published as is, guests would
    // load the new song at its last moments, finish it at once and start their own
    // next song. The new track starts at 0; a track that
    // resumes further in is republished by the ticker's seek check within a second.
    // Interpolated only while actually playing: a paused player sends no updates,
    // and projecting a paused reading forward would publish a position it never
    // reached.
    final readingIsCurrent = _positionSongId == s.currentSong?.id;
    final posMs = readingIsCurrent
        ? (s.isPlaying
                ? _livePositionMs(s.speed)
                : currentPositionProvider.value.inMilliseconds) -
            _outputLatencyMs
        : 0;
    // A zero reading mid-track is a transient (the engine reports 0 while re-staging
    // a stream), not a restart, so it's skipped; the host ticker republishes once the
    // position is real. Checked on the raw reading, before the latency is taken
    // off.
    if (readingIsCurrent &&
        currentPositionProvider.value == Duration.zero &&
        _lastPushedPosMs > 2000 &&
        s.currentSong?.id == _lastPushedSongId) {
      return;
    }
    _rev++;
    _lastPushedSongId = s.currentSong?.id;
    _lastPushedPlaying = isPlaying;
    _lastPushedPosMs = posMs;
    _lastPushedAtLocalMs = DateTime.now().millisecondsSinceEpoch;
    // Logged only when the track or play state changes, not on every heartbeat. A failed
    // write is always logged, since from the guest side it looks like a vanished host.
    final sig = '${s.currentSong?.id}|$isPlaying';
    if (sig != _lastPushSig) {
      _lastPushSig = sig;
      print('LT host: pushing "${s.currentSong?.title ?? 'nothing'}" '
          'playing=$isPlaying at ${posMs}ms (rev $_rev)');
    }
    _roomRef(code).set({
      'active': true,
      'rev': _rev,
      'track': s.currentSong?.toMap(),
      'isPlaying': isPlaying,
      'positionMs': posMs,
      'atServerMs': _nowServerMs(),
      'hostSeenMs': _nowServerMs(),
      // Written with every heartbeat too, so `songId` always reflects the current track
      // (the drift loop compares against it).
      'songId': s.currentSong?.id,
      // Everything that shapes the sound (speed, pitch, loop) is published too, so
      // everyone in the room hears the same thing.
      'speed': s.speed,
      'pitch': s.pitch,
      // A-B loop. Sent as plain millisecond ints (nulls when unset) rather than
      // Durations, which Firestore cannot store.
      'loopActive': s.isLoopActive,
      'loopStartMs': s.loopStart?.inMilliseconds,
      'loopEndMs': s.loopEnd?.inMilliseconds,
    }, SetOptions(merge: true)).catchError((Object e) {
      print('LT host: push FAILED (rev $_rev): $e');
    });
    _pushQueue();
  }

  /// The shared queue: every listener sees, and can act on, the same "what's next".
  /// Stored in a separate document, because the room document is rewritten every
  /// few seconds and the queue changes rarely; it's written only when the queue actually
  /// changes (see the signature check below).
  static const int _queueMirrorLimit = 60;

  void _pushQueue() {
    final code = _code;
    if (code == null || state.role != LtRole.host) return;
    final s = _ref.read(playerProvider);
    final curId = s.currentSong?.id;

    // The three lanes travel separately, since the queue sheet builds its headings
    // and drag targets from userQueue / contextQueue / autoplayQueue. Budgeted in
    // lane order, so a long queue loses the tail of autoplay, never someone's
    // explicit "play next". Ids decide whether anything changed before any song is
    // serialised, since this runs on every host player-state change.
    List<Song> take(List<Song> src, int budget) {
      final out = <Song>[];
      for (final t in src) {
        if (out.length >= budget) break;
        if (t.id == curId) continue; // shown as NOW PLAYING, never as upcoming
        out.add(t);
      }
      return out;
    }

    // Budgeted in bucket order so the tail of AUTOPLAY is what gets dropped on a
    // long queue, never somebody's explicit "play next".
    final userQ = take(s.userQueue, _queueMirrorLimit);
    final ctxQ = take(s.contextQueue, _queueMirrorLimit - userQ.length);
    final autoQ =
        take(s.autoplayQueue, _queueMirrorLimit - userQ.length - ctxQ.length);
    if (userQ.isEmpty && ctxQ.isEmpty && autoQ.isEmpty) return;

    String ids(List<Song> l) => l.map((e) => e.id).join(',');
    final sig = '${ids(userQ)}/${ids(ctxQ)}/${ids(autoQ)}/${s.contextTitle}';
    if (sig == _lastQueueSig) return;
    _lastQueueSig = sig;

    final user = [for (final t in userQ) t.toMap()];
    final ctx = [for (final t in ctxQ) t.toMap()];
    final auto = [for (final t in autoQ) t.toMap()];
    print('LT host: mirroring queue — ${user.length} queued, ${ctx.length} from context, ${auto.length} autoplay');
    _roomRef(code).collection('state').doc('queue').set({
      'user': user,
      'context': ctx,
      'auto': auto,
      'contextTitle': s.contextTitle,
      'total': s.queue.length,
    }).catchError((Object e) {
      print('LT host: queue mirror FAILED: $e');
    });
  }

  // Guest engine

  /// A guest's own player changed: turn it into a request immediately, instead of
  /// waiting for the tick loop to infer it (about 1.6 s later). The tick loop stays
  /// as the safety net and for enforcement when the host never answers. `_applying`
  /// gates this, so a change caused by applying the room's state isn't echoed back
  /// as a request.
  void _onGuestPlayerState(PlayerState s) {
    // The scrub baseline is refreshed on every notification, including the ones
    // ignored below, so a jump the room caused is never measured later as the
    // user's. A reading still from the previous track has no baseline.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final mine = _livePositionMs(s.speed);
    final onThisTrack = _positionSongId == s.currentSong?.id;
    // Where the playhead should be now if nobody touched it: playback moves it
    // between notifications, which can be many seconds apart.
    final expectedOwn = !onThisTrack ||
            _lastOwnPosSongId != s.currentSong?.id ||
            _lastOwnPosMs <= 0
        ? -1
        : _lastOwnPosMs +
            (_lastOwnPosPlaying ? ((nowMs - _lastOwnPosAtMs) * s.speed).round() : 0);
    // No baseline from a loading engine either: it can report 0 for a moment.
    _lastOwnPosMs = onThisTrack && !s.isLoading ? mine : -1;
    _lastOwnPosAtMs = nowMs;
    _lastOwnPosPlaying = s.isPlaying && !s.isStalled;
    _lastOwnPosSongId = s.currentSong?.id;

    // A seek this device issued briefly drops isPlaying, which would look like the
    // user pressing pause and start a request loop. This window starts when the
    // seek is issued and outlasts it.
    if (nowMs - _lastLocalSeekAtMs < 1800) return;
    if (state.role != LtRole.guest || _applying) return;
    final data = _room;
    if (data == null) return;

    // `_applying` isn't enough on its own: playSong and togglePlay are async, so the
    // resulting state change arrives after the flag is cleared. A short time window
    // after applying the room's state separates "the room told me to" from "the user
    // tapped".
    if (DateTime.now().millisecondsSinceEpoch < _suppressGuestEchoUntilMs) {
      return;
    }
    if (s.isLoading) return;

    // A listener's other actions are requests too: a scrub becomes a 'seek' request
    // (the host already handles it), and speed, pitch and the A-B loop are sent the
    // same way.
    // Compare against our own previous reading (moved on by the time since), not the
    // room's position: a scrub is an instant multi-second step, while drift
    // accumulates slowly and never steps. Mistaking drift for intent would move
    // everyone to this device's wrong position. A jump only counts within one track
    // (see the baseline above).
    if (expectedOwn > 0 && (mine - expectedOwn).abs() > _seekIntentMs) {
      print('LT guest: requesting seek to ${mine}ms '
          '(jumped ${mine - expectedOwn}ms — read as a deliberate scrub)');
      _seekRequestedAtMs = DateTime.now().millisecondsSinceEpoch;
      _sendRequest('seek', valueMs: mine);
      return; // one intent per notification; the host's push settles the rest
    }

    // Speed, pitch and loop: discrete settings, so any difference from the
    // room's is this listener changing it. The `_nudging` guard is essential —
    // during a drift correction our speed is deliberately off the shared value,
    // and without it every correction would be broadcast as a speed change.
    if (!_nudging) {
      final shared = _sharedSpeed();
      if ((s.speed - shared).abs() > 0.001) {
        print('LT guest: requesting room speed ${s.speed}x');
        _sendRequest('set_speed', value: s.speed);
        return;
      }
    }
    final roomPitch = (data['pitch'] as num?)?.toDouble() ?? 1.0;
    if ((s.pitch - roomPitch).abs() > 0.001) {
      print('LT guest: requesting room pitch ${s.pitch}');
      _sendRequest('set_pitch', value: s.pitch);
      return;
    }
    if (_loopDiffersFromRoom(s, data)) {
      print('LT guest: requesting room A-B loop '
          '${s.loopStart?.inMilliseconds}-${s.loopEnd?.inMilliseconds} '
          'active=${s.isLoopActive}');
      _sendRequest('set_loop',
          valueMs: s.loopStart?.inMilliseconds,
          toIndex: s.loopEnd?.inMilliseconds,
          want: s.isLoopActive);
      return;
    }

    final wantPlaying = data['isPlaying'] == true;
    if (s.isPlaying == wantPlaying) return;
    _playMismatchTicks = 1; // the tick loop's fallback timer starts here
    _sendRequest('set_playing',
        valueMs: _livePositionMs(s.speed), want: s.isPlaying);
  }

  /// Whether this device's A-B loop disagrees with the room's.
  ///
  /// Compared with a tolerance rather than exactly: the points travel as
  /// milliseconds and come back through Duration, and an off-by-one would have
  /// the two devices requesting the loop from each other forever.
  bool _loopDiffersFromRoom(PlayerState s, Map<String, dynamic> data) {
    final roomActive = data['loopActive'] == true;
    if (roomActive != s.isLoopActive) return true;
    if (!roomActive) return false;
    final rs = (data['loopStartMs'] as num?)?.toInt();
    final re = (data['loopEndMs'] as num?)?.toInt();
    final ms = s.loopStart?.inMilliseconds;
    final me = s.loopEnd?.inMilliseconds;
    if (rs == null || re == null || ms == null || me == null) return false;
    return (rs - ms).abs() > 50 || (re - me).abs() > 50;
  }

  /// Ignore our own player changes for a moment. See [_onGuestPlayerState].
  void _suppressEcho([int ms = 1500]) {
    _suppressGuestEchoUntilMs = DateTime.now().millisecondsSinceEpoch + ms;
  }

  void _startGuestEngine() {
    final code = _code;
    if (code == null) return;
    _watchPosition();
    // The guest watches its own player too, so a listener's action reaches the
    // host in one round trip instead of after two inference ticks.
    _playerUnsub = _ref
        .read(playerProvider.notifier)
        .addListener(_onGuestPlayerState, fireImmediately: false);
    _room = null;
    _nudging = false;
    _playMismatchTicks = 0;
    _songMismatchTicks = 0;

    // The room document: what is playing, and whether the session is alive.
    _roomSub = _roomRef(code).snapshots().listen((snap) {
      if (state.role != LtRole.guest) return;
      final data = snap.data();
      if (!snap.exists || data == null || data['active'] != true) {
        _endSession('The host ended the session.');
        return;
      }
      // Liveness is refreshed on every snapshot; playback state only on a new rev. The
      // host's 25 s presence tick updates hostSeenMs without bumping rev, so gating
      // the whole snapshot on rev would freeze the stamp and make a live host look
      // gone.
      _room = data;
      final seenMs = (data['hostSeenMs'] as num?)?.toInt() ?? 0;
      if (seenMs > _hostSeenObserved) _hostSeenObserved = seenMs;

      final rev = data['rev'];
      if (rev is! int || rev <= _rev) return; // stale/duplicate snapshot
      // A graceful handover names us directly — take over now rather than
      // waiting out _hostGoneMs.
      if (data['hostId'] == _uid) {
        _promoteToHost();
        return;
      }
      final newHostName = data['hostName']?.toString();
      if (newHostName != null && newHostName != state.hostName) {
        state = state.copyWith(hostName: newHostName);
      }
      _rev = rev;
      _applyRoom();
    }, onError: (_) {});

    // The mirrored queue, on its own document (see _pushQueue), with its own
    // subscription, separate from the room listener.
    _queueSub = _roomRef(code)
        .collection('state')
        .doc('queue')
        .snapshots()
        .listen((snap) {
      if (state.role != LtRole.guest) return;
      final data = snap.data();
      if (data == null) return;
      List<Song> parse(String key) {
        final raw = data[key];
        if (raw is! List) return const [];
        return <Song>[
          for (final t in raw)
            if (t is Map) Song.fromMap(Map<String, dynamic>.from(t)),
        ];
      }
      _mirrorUser = parse('user');
      _mirrorContext = parse('context');
      _mirrorAuto = parse('auto');
      _mirrorContextTitle = data['contextTitle']?.toString();
      if (!_hasMirror) return;
      _reapplyMirror();
      print('LT guest: queue mirrored — ${_mirrorUser.length} queued, '
          '${_mirrorContext.length} from context, ${_mirrorAuto.length} autoplay');
    }, onError: (Object e) {
      // Named rather than swallowed: a rules rejection here looks exactly like a
      // host who never queued anything.
      print('LT guest: queue mirror subscribe FAILED: $e');
    });

    // Drift + enforcement loop. Runs fast (800 ms) but does nothing when
    // already in sync, so it's just a couple of comparisons per tick.
    _guestTicker =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _guestTick());
  }

  Future<void> _applyRoom() async {
    if (_applying) {
      _applyQueued = true;
      return;
    }
    final data = _room;
    if (data == null || state.role != LtRole.guest) return;
    final track = data['track'];
    if (track is! Map) return; // host has nothing loaded yet

    _applying = true;
    try {
      final song = Song.fromMap(Map<String, dynamic>.from(track));
      final wantPlaying = data['isPlaying'] == true;
      final notifier = _ref.read(playerProvider.notifier);
      final ps = _ref.read(playerProvider);

      if (ps.currentSong?.id != song.id) {
        // Everything this branch does to the player is the ROOM's doing.
        _suppressEcho(2500);
        await notifier.playSong(
          song,
          source: 'Listen Together',
          locationName: '${state.hostName ?? 'Host'}\'s session',
          playImmediately: wantPlaying,
        );
        // Seek once the engine knows the duration (percentage-less Duration
        // seeks are safe, but landing before load would be thrown away).
        for (var i = 0; i < 25; i++) {
          if (!mounted || state.role != LtRole.guest) return;
          if (_ref.read(playerProvider).duration > Duration.zero) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        // Staged: the stream resolved and the engine knows the duration. Telling
        // the host now is what lets a track change START TOGETHER rather than
        // each device starting whenever it happens to be ready and being seeked
        // forward afterwards. See the buffer barrier.
        _reportReady(song.id);
        final target = _targetPositionMs();
        if (target > _hardDriftMs && !_inLastMoments(target)) {
          _lastLocalSeekAtMs = DateTime.now().millisecondsSinceEpoch;
          notifier.seek(Duration(milliseconds: target));
        }
        // The queue playSong just built is this device's, not the session's.
        _reapplyMirror();
        print('LT guest: switched to "${song.title}" '
            '(target ${_targetPositionMs()}ms, playing=$wantPlaying)');
      } else if (wantPlaying != ps.isPlaying && !ps.isLoading) {
        // A future instant means the host published a SCHEDULE: wait for it
        // rather than applying now, or this device acts one hop early and the
        // alignment is lost before the loop even sees it.
        final execAt = (data['execAtServerMs'] as num?)?.toInt() ?? 0;
        if (execAt > _nowServerMs()) {
          _scheduleApply(
            playing: wantPlaying,
            posAtExecMs: (data['positionMs'] as num?)?.toInt() ?? 0,
            songId: (data['track'] is Map)
                ? (data['track'] as Map)['id']?.toString()
                : null,
            execAtServerMs: execAt,
          );
          return;
        }
        _suppressEcho();
        // Pin the playhead as well as the play state, so a pause arriving one relay hop
        // late doesn't leave the guest paused further into the track. _targetPositionMs
        // gives the host's stamped position for a pause and that position projected to
        // now for a resume.
        final target = _targetPositionMs();
        final skew = target - _livePositionMs(ps.speed);
        // Order matters: pause then seek keeps a pause silent; for a resume, seek first,
        // then start.
        if (!wantPlaying) notifier.togglePlay(haptic: false);
        if (skew.abs() > _softDriftMs) {
          _lastLocalSeekAtMs = DateTime.now().millisecondsSinceEpoch;
          notifier.seek(Duration(milliseconds: target));
        }
        if (wantPlaying) notifier.togglePlay(haptic: false);
        // See _scheduleApply: the window has to be re-armed after the seek.
        _suppressEcho(2500);
        print('LT guest: ${wantPlaying ? "resumed" : "paused"} to match '
            'host — pinned to ${target}ms (was ${skew}ms off)');
      }
    } catch (e) {
      // Stream resolution failures are the player pipeline's problem; the
      // enforcement loop will retry on the next mismatch tick. Named, though —
      // "the guest silently plays nothing" and "the guest is out of sync" have
      // the same appearance and very different causes.
      print('LT guest: apply failed: $e');
    } finally {
      _applying = false;
      if (_applyQueued) {
        _applyQueued = false;
        _applyRoom();
      }
    }
  }

  /// Where the host's playhead is RIGHT NOW, in ms: project the stamped position
  /// forward by the
  /// server-clock time elapsed since it was stamped (nothing if paused).
  int _targetPositionMs() {
    final data = _room;
    if (data == null) return 0;
    final pos = (data['positionMs'] as num?)?.toInt() ?? 0;
    if (data['isPlaying'] != true) return pos;
    final at = (data['atServerMs'] as num?)?.toInt() ?? 0;
    if (at <= 0) return pos;
    // At the room's speed: at 1.25x the host moves 1.25 s per second.
    return pos + (max(0, _nowServerMs() - at) * _sharedSpeed()).round();
  }

  /// Within this much of the end, a seek would finish the track at once and start
  /// this device's own next song.
  static const int _trackEndMarginMs = 1500;

  /// Whether [targetMs] is in the last moments of the loaded track. Only a room
  /// written by an older host (which could publish the previous track's position
  /// with a new song) asks for that; the host's next stamp brings the real one.
  bool _inLastMoments(int targetMs) {
    final durMs = _ref.read(playerProvider).duration.inMilliseconds;
    return durMs > 0 && targetMs >= durMs - _trackEndMarginMs;
  }

  /// This device's playhead right now, interpolated from when the provider last
  /// changed (it updates about twice a second, so it can lag by ~500 ms), with
  /// playback speed accounted for so an active nudge doesn't skew the reading.
  int _livePositionMs(double speed) {
    final base = currentPositionProvider.value.inMilliseconds;
    if (_positionSeenAtLocalMs <= 0) return base;
    final since = DateTime.now().millisecondsSinceEpoch - _positionSeenAtLocalMs;
    // Cap the extrapolation: if updates stopped (paused, buffering, backgrounded)
    // projecting forward indefinitely would invent a playhead that never moved.
    final ahead = since.clamp(0, 600);
    return base + (ahead * speed).round();
  }

  /// Watches the position value so [_livePositionMs] knows how old it is.
  void _watchPosition() {
    // A guest promoted to host is already watching.
    if (_positionListener != null) return;
    _positionSongId = _ref.read(playerProvider).currentSong?.id;
    _positionListener = () {
      _positionSeenAtLocalMs = DateTime.now().millisecondsSinceEpoch;
      _positionSongId = _ref.read(playerProvider).currentSong?.id;
    };
    currentPositionProvider.addListener(_positionListener!);
  }

  void _guestTick() {
    // Costs one integer comparison unless the host has actually gone quiet.
    _checkHostAlive();
    // A scheduled action has not happened yet by design; enforcing against it
    // would undo the schedule a fraction of a second before it fires.
    if (_hasPendingExec) return;
    if (state.role != LtRole.guest || _applying) return;
    final data = _room;
    if (data == null) return;
    final track = data['track'];
    final ps = _ref.read(playerProvider);
    final notifier = _ref.read(playerProvider.notifier);

    // Song enforcement — covers the guest's own queue advancing at track end
    // a beat before the host's message lands, and local meddling.
    final roomSongId = track is Map ? track['id']?.toString() : null;
    if (roomSongId != null &&
        roomSongId.isNotEmpty &&
        ps.currentSong?.id != roomSongId &&
        !ps.isLoading) {
      if (++_songMismatchTicks >= 2) {
        _songMismatchTicks = 0;
        _applyRoom();
      }
      return;
    }
    _songMismatchTicks = 0;

    // Play/pause: a guest's deviation is sent upstream as a request on its own
    // member document; the host applies it and pushes, so everyone converges.
    // Enforcement is the fallback: if no host acts within [_requestGraceMs] (host
    // backgrounded, offline or on an older build), the guest is brought back in line.
    final wantPlaying = data['isPlaying'] == true;
    if (wantPlaying != ps.isPlaying && !ps.isLoading) {
      _playMismatchTicks++;
      if (_playMismatchTicks == 2) {
        _sendRequest('set_playing',
            valueMs: _livePositionMs(ps.speed), want: ps.isPlaying);
      } else if (_playMismatchTicks >= 2 + (_requestGraceMs ~/ 800)) {
        _playMismatchTicks = 0;
        print('LT guest: host did not act on the pause/play request — '
            'falling back to following');
        _suppressEcho();
        notifier.togglePlay(haptic: false);
      }
    } else {
      _playMismatchTicks = 0;
    }

    // Shared audio settings, applied before the playing-only early return below, so
    // a listener joining a paused room is already set up when it resumes. Skipped
    // while nudging, when this device's speed is intentionally off the shared value.
    if (!_nudging) {
      final wantSpeed = _sharedSpeed();
      if ((ps.speed - wantSpeed).abs() > 0.001) {
        print('LT guest: matching room speed ${wantSpeed}x (was ${ps.speed}x)');
        notifier.setSpeed(wantSpeed);
      }
    }
    final wantPitch = (data['pitch'] as num?)?.toDouble();
    if (wantPitch != null &&
        wantPitch > 0.05 &&
        wantPitch <= 4.0 &&
        (ps.pitch - wantPitch).abs() > 0.001) {
      print('LT guest: matching room pitch $wantPitch (was ${ps.pitch})');
      notifier.setPitch(wantPitch);
    }

    // Drift correction — only meaningful while both sides are playing.
    if (!wantPlaying || !ps.isPlaying) {
      _endNudge(notifier);
      return;
    }
    // A position only means something on the track it was measured on, so drift
    // correction pauses while the host and this device are on different tracks
    // (every track change, and while a guest loads the next track). Otherwise the
    // loop would seek across track boundaries. The room's track sync converges
    // first; then position comparison resumes.
    //
    // `track` is rewritten with every push, so it's the freshest statement of what the
    // host plays; `songId` is the fallback for rooms from builds that only wrote it
    // on a schedule.
    final hostTrack = data['track'];
    final hostSongId = (hostTrack is Map ? hostTrack['id']?.toString() : null) ??
        data['songId'] as String?;
    final localSongId = ps.currentSong?.id;
    if (hostSongId != null && localSongId != null && hostSongId != localSongId) {
      _endNudge(notifier);
      // The learned offset does not survive a track change. It is an estimate
      // of a steady state, and a boundary is the opposite of that — carrying it
      // across would apply a correction learned on one song to another, which
      // is how an integrator ends up confidently wrong.
      _driftBiasMs = 0;
      if (_lastDriftZone != 'othertrack') {
        _lastDriftZone = 'othertrack';
        print('LT guest: host is on a different track — holding drift '
            'correction until the room agrees (host=$hostSongId, '
            'ours=$localSongId)');
      }
      return;
    }

    // A seek this device requested isn't drift: until the host's answer arrives this
    // device is deliberately elsewhere. The window is short, so an unanswered request
    // still ends with the device pulled back in line.
    if (DateTime.now().millisecondsSinceEpoch - _seekRequestedAtMs <
        _seekGraceMs) {
      _endNudge(notifier);
      return;
    }

    // The room's A-B loop, applied only now that the track is known to match —
    // loop points mean nothing on a different song.
    if (_loopDiffersFromRoom(ps, data)) {
      final on = data['loopActive'] == true;
      final ls = (data['loopStartMs'] as num?)?.toInt();
      final le = (data['loopEndMs'] as num?)?.toInt();
      if (!on) {
        print('LT guest: clearing A-B loop to match the room');
        notifier.clearLoopRegion();
      } else if (ls != null && le != null && le > ls) {
        print('LT guest: matching room A-B loop ${ls}-${le}ms');
        notifier.setLoopRegion(
            Duration(milliseconds: ls), Duration(milliseconds: le));
      }
    }

    // How old the host's stamp is. Declared up here rather than beside the log
    // line that also uses it, because the bias gate below needs it to decide
    // whether this sample is worth learning from.
    final scheduleAgeMs =
        _nowServerMs() - ((data['atServerMs'] as num?)?.toInt() ?? 0);

    // Re-read the route periodically, because headphones come and go mid
    // session. Unawaited and rate-limited inside — a device that switches from
    // Bluetooth to its speaker must stop applying a 180ms correction it no
    // longer needs, or the fix becomes the error.
    if (_driftSamples % 10 == 0) unawaited(_refreshOutputLatency());

    // The room publishes a HEARD position; this device needs a PLAYHEAD target.
    // Adding its own output latency converts between them, so a listener on
    // Bluetooth deliberately runs its playhead ahead of one on a speaker and
    // the two arrive at the ear together. See _outputLatencyMs.
    final rawTarget = _targetPositionMs() + _outputLatencyMs;
    final live = _livePositionMs(ps.speed);

    // The integral term. A proportional controller alone can't remove a constant
    // error, and a steady offset remains (asymmetric network delay, different output
    // latencies). A slow EMA of the signed drift estimates it and shifts the target,
    // so the proportional loop settles at zero. Deliberately slow and clamped (±500
    // ms) to avoid integral windup during a track change or stall.
    //
    // Only trustworthy samples teach it: a stale schedule mostly measures its age,
    // and a large error is an event (rebuffer, late schedule), not a standing
    // offset. Rejected samples are still corrected by the proportional loop; they
    // just don't feed the estimate.
    final rawDrift = rawTarget - live;
    final freshEnough = scheduleAgeMs.abs() < _biasMaxScheduleAgeMs;
    // Measured from the offset already learned: a reading near the current estimate
    // is normal even when that offset is large. Measured on the raw drift, learning
    // would stop once the offset itself neared the limit.
    final plausible = (rawDrift - _driftBiasMs).abs() < _biasMaxSampleMs;
    if (freshEnough && plausible) {
      _driftBiasMs =
          _driftBiasMs * (1 - _biasLearnRate) + rawDrift * _biasLearnRate;
      _driftBiasMs =
          _driftBiasMs.clamp(-_biasClampMs, _biasClampMs).toDouble();
      _biasSamplesUsed++;
    } else {
      // Counted so the summary can say HOW MUCH was rejected. If most samples
      // are being thrown away the learned offset is built on very little, and
      // that is worth knowing rather than inferring from a number that merely
      // looks stable.
      _biasSamplesSkipped++;
    }

    final target = rawTarget - _driftBiasMs.round();
    final drift = target - live;

    // Every input is logged (drift, clock offset, schedule age), so a desync can be
    // attributed. Logged on transitions only (in sync ↔ nudging ↔ hard seek), since
    // this runs twice a second.
    //
    // Hysteresis: start correcting above [_softDriftMs] but don't stop until well
    // inside it ([_nudgeExitMs]). A single threshold made a session near the
    // boundary flip between nudging and in-sync every tick, pushing the tempo off 1.0
    // and back.
    final nudgeFloor = _nudging ? _nudgeExitMs : _softDriftMs;
    final zone = drift.abs() >= _hardDriftMs
        ? 'seek'
        : (drift.abs() > nudgeFloor ? 'nudge' : 'sync');
    if (zone != _lastDriftZone) {
      _lastDriftZone = zone;
      print('LT guest: drift ${drift}ms → $zone '
          '(target ${target}ms, ours ${live}ms, clock offset '
          '${_serverOffsetMs}ms, schedule age ${scheduleAgeMs}ms, '
          'speed ${ps.speed.toStringAsFixed(3)}x)');
    }

    // Rolling bias: the mean of the signed drift over a window. Noise averages out, so
    // what's left is a real bias, and the sign says which way.
    _driftSamples++;
    _driftSignedSum += drift;
    _driftAbsSum += drift.abs();
    if (drift.abs() > _driftWorst) _driftWorst = drift.abs();
    if (_driftSamples >= _driftReportEvery) {
      final meanSigned = _driftSignedSum / _driftSamples;
      final meanAbs = _driftAbsSum / _driftSamples;
      print('LT guest sync over last $_driftSamples ticks: '
          'bias ${meanSigned >= 0 ? '+' : ''}${meanSigned.toStringAsFixed(0)}ms, '
          'mean error ${meanAbs.toStringAsFixed(0)}ms, worst ${_driftWorst}ms '
          '(correcting for a learned offset of '
          '${_driftBiasMs >= 0 ? '+' : ''}${_driftBiasMs.toStringAsFixed(0)}ms, '
          'learned from $_biasSamplesUsed samples and rejected '
          '$_biasSamplesSkipped as stale or one-off — bias should sit near '
          'zero; a growing offset with an unchanged bias means it is winding '
          'up on events rather than measuring a real offset)');
      _biasSamplesUsed = 0;
      _biasSamplesSkipped = 0;
      _driftSamples = 0;
      _driftSignedSum = 0;
      _driftAbsSum = 0;
      _driftWorst = 0;
    }
    // Same decision the zone label above describes — derived from it, rather
    // than re-deriving the thresholds, so the log can never disagree with what
    // was actually done.
    if (zone == 'sync') {
      _endNudge(notifier); // inside the band — restore the shared tempo
    } else if (zone == 'seek') {
      _endNudge(notifier);
      final seekTo = max(0, _targetPositionMs());
      if (!_inLastMoments(seekTo)) {
        // Stamped like the room's other seeks, so _onGuestPlayerState doesn't send
        // this correction back to the host as the listener's own scrub (which would
        // move the host, and with it everyone else).
        _lastLocalSeekAtMs = DateTime.now().millisecondsSinceEpoch;
        notifier.seek(Duration(milliseconds: seekTo));
      }
    } else {
      // Soft zone: inaudible ±3% time-stretch instead of a jarring seek.
      // Only when the user hasn't chosen a speed of their own (and never
      // podcasts — their speed choice is a sticky preference).
      final isPodcast = ps.currentSong?.albumTitle == 'Podcast';

      // "Their own speed" means different from the room's speed, not from 1.0, so drift
      // correction still works when the room listens at 1.25x.
      final shared = _sharedSpeed();
      final atSharedSpeed = (ps.speed - shared).abs() < 0.001;
      if (!isPodcast && (atSharedSpeed || _nudging)) {
        if (!_nudging) {
          _nudging = true;
          // Four other paths end a nudge by clearing _nudging directly, so the
          // last applied step is reset HERE, where every nudge starts, rather
          // than trusting each of them to.
          _appliedNudgeSpeed = 0;
          // Captured BEFORE the first stretch, and only then: after that
          // `ps.speed` is our own nudged value, so re-reading it would ratchet
          // the base upward every tick.
          _preNudgeSpeed = ps.speed;
        }
        // Proportional, capped at 6% (beyond that the pitch-preserved stretch becomes
        // audible), so large errors close quickly and small ones ease in without
        // overshooting. Applied in steps, changing speed only when the step changes:
        // reconfiguring the time-stretch every tick was audible on iPhone.
        final magnitude = drift.abs();
        final rate = magnitude >= 240
            ? 0.06
            : (magnitude >= 120 ? _nudgeRate : _nudgeRate * 0.5);
        // Multiplicative around the room's base speed, not 1.0 ± rate, so a room at 1.25x
        // nudges to ~1.29x rather than jumping to 1.03x.
        final want = _preNudgeSpeed * (drift > 0 ? 1.0 + rate : 1.0 - rate);
        if ((want - _appliedNudgeSpeed).abs() > 0.0005) {
          _appliedNudgeSpeed = want;
          notifier.setSpeed(want);
        }
      }
    }
  }

  /// The tempo everyone in this room is meant to be playing at.
  ///
  /// Falls back to 1.0 for a room published by a build that did not share speed
  /// yet, which is also the right answer for a room that never changed it.
  double _sharedSpeed() {
    final v = (_room?['speed'] as num?)?.toDouble();
    if (v == null || v <= 0.05 || v > 4.0) return 1.0;
    return v;
  }

  /// The speed to return to when a correction ends: the room's shared speed, not
  /// 1.0.
  double _preNudgeSpeed = 1.0;

  /// This device's own playhead at the previous notification, so a deliberate
  /// scrub can be told apart from accumulated drift. See _onGuestPlayerState.
  ///
  /// -1 means "no comparable reading", which is the state after a track change.
  int _lastOwnPosMs = -1;

  /// Which track [_lastOwnPosMs] was measured on. Without this the reading is
  /// compared across a song boundary and a track change looks like a
  /// three-minute scrub — see the note in _onGuestPlayerState.
  String? _lastOwnPosSongId;

  /// When [_lastOwnPosMs] was read, and whether the player was playing then, so the
  /// next reading can be compared with where playback alone would have taken it.
  int _lastOwnPosAtMs = 0;
  bool _lastOwnPosPlaying = false;

  /// When a seek was last asked of the host, so the drift loop can stand down
  /// while the answer is in flight instead of correcting the request away.
  int _seekRequestedAtMs = 0;

  /// A jump this large in one notification is a person dragging the scrubber.
  ///
  /// Comfortably above anything drift produces between two notifications (a few
  /// hundred ms at worst) and below the shortest useful drag.
  static const int _seekIntentMs = 2500;

  /// How long the drift loop defers after a seek request. Long enough for a
  /// round trip through the host and back, short enough that a request the host
  /// never answered does not leave this device diverged.
  static const int _seekGraceMs = 2500;

  void _endNudge(PlayerNotifier notifier) {
    if (!_nudging) return;
    _nudging = false;
    _appliedNudgeSpeed = 0;
    notifier.setSpeed(_preNudgeSpeed);
  }

  /// The speed the current nudge last applied, so an unchanged step is not
  /// re-sent every tick. 0 = no nudge applied yet.
  double _appliedNudgeSpeed = 0;

  // Presence & members

  void _watchMembers() {
    final code = _code;
    if (code == null) return;
    _membersSub = _roomRef(code)
        .collection('members')
        .snapshots()
        .listen((snap) {
      if (!mounted || !state.active) return;
      // A killed app leaves its member document behind (only a graceful leave deletes
      // it), so members whose heartbeat is three beats old are hidden. Documents aren't
      // deleted: members can't be trusted to tidy up after each other, and a
      // backgrounded device reappears on its next beat. `_successorUid` applies its own
      // staleness window, so succession is unaffected.
      final nowMs = _nowServerMs();
      final all = snap.docs.map((d) {
        final m = d.data();
        return LtMember(
          uid: d.id,
          name: (m['name'] ?? 'Listener').toString(),
          isHost: m['isHost'] == true,
          // A member written before lastSeenMs existed, or one whose first beat
          // has not landed yet, falls back to when they joined — otherwise a
          // listener who joined two seconds ago reads as long gone.
          lastSeenMs: (m['lastSeenMs'] as num?)?.toInt() ??
              (m['joinedAtMs'] as num?)?.toInt() ??
              0,
          joinedAtMs: (m['joinedAtMs'] as num?)?.toInt() ?? 0,
        );
      }).toList();
      final members = all.where((m) {
        // This device is always present — it is the one doing the looking, and
        // a clock estimate that is off must never hide the local user.
        if (m.uid == _uid) return true;
        if (m.lastSeenMs <= 0) return true; // unknowable, so assume present
        return nowMs - m.lastSeenMs < _memberGoneMs;
      }).toList()
        ..sort((a, b) {
          if (a.isHost != b.isHost) return a.isHost ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      state = state.copyWith(members: members);
      for (final doc in snap.docs) {
        final ready = doc.data()['readyFor'];
        if (ready is String && ready.isNotEmpty) _memberReadyFor[doc.id] = ready;
      }
      _applyGuestRequests(snap);

      if (state.role == LtRole.host) {
        // Someone new joined → push immediately so they sync in <1 s instead
        // of waiting for the next heartbeat.
        if (members.length > _prevMemberCount && _prevMemberCount > 0) {
          _pushNow();
        }
        _prevMemberCount = members.length;
      } else {
        // The host vanished without ending the session (app killed, network died): its
        // heartbeat stops advancing. Staleness is measured without comparing two phones'
        // clocks: remember the last heartbeat value seen and how long ago (by our local
        // clock) it changed. A live host advances it every 25 s. Two consecutive stale
        // observations are required so one slow snapshot can't end a session.
        LtMember? host;
        for (final m in members) {
          if (m.isHost) {
            host = m;
            break;
          }
        }
        final nowLocal = DateTime.now().millisecondsSinceEpoch;
        if (host == null) {
          // A missing host row isn't proof the host left: Firestore delivers a cached
          // snapshot before the server one. Presence is a hint and the room document is
          // the truth, so cached snapshots are ignored, two consecutive server snapshots
          // without the row are required, and a room that still looks alive wins; host
          // migration handles a host that's really gone.
          if (snap.metadata.isFromCache) return;
          final data = _room;
          final seen = (data?['hostSeenMs'] as num?)?.toInt() ?? 0;
          if (data != null &&
              data['active'] == true &&
              seen > 0 &&
              _nowServerMs() - seen < _hostGoneMs) {
            return; // room is alive; the row is just missing from this snapshot
          }
          if (_prevMemberCount > 0 && ++_hostRowMisses >= 2) {
            print('LT guest: no host row in two server snapshots — taking over');
            // Do NOT end the session: if anyone is still here, one of us should
            // carry it on. _claimHost declines when the room is not abandoned.
            _claimHost();
          }
          _prevMemberCount = members.length;
          return;
        }
        _hostRowMisses = 0;
        if (host.lastSeenMs != _lastHostSeenValue) {
          _lastHostSeenValue = host.lastSeenMs;
          _lastHostSeenAtLocalMs = nowLocal;
          _hostStaleStrikes = 0;
        } else if (_lastHostSeenAtLocalMs > 0 &&
            nowLocal - _lastHostSeenAtLocalMs > 90000) {
          // Our own outage isn't the host going quiet: both look like "no fresh snapshot".
          // While offline there's no evidence either way, so hold rather than hang up; the
          // next snapshot after reconnecting settles it.
          if (!_ref.read(connectivityProvider).hasInternet) {
            // Rebased, so reconnecting does not immediately trip the 90 s test on
            // a gap that was ours.
            _lastHostSeenAtLocalMs = nowLocal;
            _hostStaleStrikes = 0;
            return;
          }
          if (++_hostStaleStrikes >= 2) {
            print('LT guest: host heartbeat frozen for '
                '${nowLocal - _lastHostSeenAtLocalMs}ms — ending');
            _endSession('Lost connection to the host.');
          }
        }
        _prevMemberCount = members.length;
      }
    }, onError: (_) {});
  }

  void _sendPresenceStamp() {
    _memberRef()
        ?.set({'lastSeenMs': _nowServerMs()}, SetOptions(merge: true))
        .catchError((_) {});
    // The host must stamp the room even when nothing is playing.
    //
    // hostSeenMs is what tells listeners the host is alive, and the 4-second
    // heartbeat only runs while playing. Without this a host that paused for a
    // minute looked abandoned and a listener would seize the session.
    final code = _code;
    if (code != null && state.role == LtRole.host) {
      _roomRef(code)
          .set({'hostSeenMs': _nowServerMs()}, SetOptions(merge: true))
          // A refused write here means this device is no longer the host: after host
          // migration the rules reject writes from the old host, and only guests watch the
          // room document. The 25 s stamp is the natural detector, costing no extra read.
          .catchError((Object e) => _onHostStampRefused(e));
    }
  }

  void _startPresence() {
    print('LT: starting presence loop (role=${state.role})');
    _sendPresenceStamp();
    _presenceTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _sendPresenceStamp();
    });
  }

  /// Step down after the room stopped accepting our host writes.
  ///
  /// Only on a permission failure. A network error must NOT demote — being
  /// offline is not evidence that anything changed, and a host that resigned
  /// every time a tunnel dropped would hand the room away for no reason.
  void _onHostStampRefused(Object e) {
    if (state.role != LtRole.host) return;
    final msg = e.toString().toLowerCase();
    if (!msg.contains('permission') && !msg.contains('denied')) {
      print('LT host: stamp failed but not refused ($e) — staying host');
      return;
    }
    print('LT host: the room REFUSED our host stamp — another device has '
        'taken the session over. Stepping down to listener.');
    // Stop the host machinery first (the mirror of _promoteToHost):
    // _startGuestEngine overwrites _playerUnsub, which would leak the host listener
    // and leave _hostTicker pushing refused writes every few seconds.
    _playerUnsub?.call();
    _playerUnsub = null;
    _hostTicker?.cancel();
    _hostTicker = null;
    // Role before the engine, so nothing host-shaped fires in between. The
    // roster subscription is shared by both roles and deliberately kept.
    state = state.copyWith(role: LtRole.guest);
    _memberRef()
        ?.set({'isHost': false}, SetOptions(merge: true))
        .catchError((_) {});
    // Follow the new host instead — this is the subscription a host never had.
    _startGuestEngine();
  }


  // Guest → host requests, written on the guest's own member document (which it
  // already writes for presence), so no new permission or listener is needed; the
  // host already watches the members collection.
  //
  // The nonce makes each request apply exactly once: Firestore replays snapshots
  // (local echoes, reconnects), and a double toggle or double skip would be wrong.
  static const int _requestGraceMs = 2400;

  /// The track a guest request names, from either wire format: current guests send
  /// `trackJson` (a string the rules can bound), older ones a `track` map. The length
  /// check applies even where the rules aren't deployed yet.
  static const int _maxRequestTrackJson = 16384;
  Song? _requestTrack(Map req) {
    try {
      final raw = req['trackJson'];
      if (raw is String) {
        if (raw.length > _maxRequestTrackJson) return null;
        final m = jsonDecode(raw);
        return m is Map ? Song.fromMap(Map<String, dynamic>.from(m)) : null;
      }
      final t = req['track'];
      if (t is Map) return Song.fromMap(Map<String, dynamic>.from(t));
    } catch (e) {
      print('LT host: unreadable track in guest request: $e');
    }
    return null;
  }

  /// Asks the host to do something. Best-effort: if it fails, the enforcement
  /// fallback still brings this device back in line.
  void _sendRequest(
    String action, {
    int? valueMs,
    int? toIndex,
    Map<String, dynamic>? track,
    bool? want,
    String? trackId,
    String? afterId,
    int? execAtMs,
    /// A non-time scalar — speed or pitch. Separate from [valueMs] on purpose:
    /// those are milliseconds and these are multipliers, and one field carrying
    /// both units is how a 1.25 ends up being read as a millisecond.
    double? value,
  }) {
    if (state.role != LtRole.guest || _memberRef() == null) return;
    // Past the cap the rules refuse the write and the host would drop it
    // anyway — say so here instead of failing silently in Firestore.
    if (track != null && jsonEncode(track).length > _maxRequestTrackJson) {
      print('LT guest: "$action" track too large to send — dropped');
      return;
    }
    // Deduplicated here rather than at one call site, since both the listener path
    // and the tick path can send a request. What counts as "the same request"
    // depends on the action: for transport actions (toggle, next, prev) the action
    // alone identifies it (the attached position is incidental); for seeks and queue
    // edits the value is the intent, so different values are different requests.
    const positionIsIncidental = {'set_playing', 'toggle', 'next', 'prev'};
    final sig = positionIsIncidental.contains(action)
        ? '$action|$want'
        : '$action|$valueMs|$toIndex|$trackId|$afterId|${track?['id']}|$value';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_outbox.any((e) => e['_sig'] == sig)) return;
    if (sig == _lastSentSig && now - _lastSentAtMs < 700) return;
    _outbox.add({
      '_sig': sig,
      'action': action,
      if (valueMs != null) 'valueMs': valueMs,
      if (toIndex != null) 'toIndex': toIndex,
      // AS A STRING, not a map. firestore.rules can cap a string's length but
      // not the strings inside a nested map or list, and `track` carries both
      // (a Song map with an artists list) on a document every member
      // downloads. Hosts still accept the legacy `track` map; see
      // [_requestTrack].
      if (track != null) 'trackJson': jsonEncode(track),
      if (want != null) 'want': want,
      if (trackId != null) 'trackId': trackId,
      if (afterId != null) 'afterId': afterId,
      if (execAtMs != null) 'execAtMs': execAtMs,
      if (value != null) 'value': value,
    });
    _drainOutbox();
  }

  /// One request per document write, spaced out: the member document has a single
  /// `request` slot and Firestore coalesces rapid writes into one snapshot, so
  /// spacing guarantees each request (and nonce) reaches the host.
  void _drainOutbox() {
    if (_outboxTimer != null) {
      return; // already draining
    }
    _writeNextRequest();
    if (_outbox.isEmpty) return;
    _outboxTimer = Timer.periodic(const Duration(milliseconds: 260), (t) {
      if (_outbox.isEmpty || state.role != LtRole.guest) {
        t.cancel();
        _outboxTimer = null;
        return;
      }
      _writeNextRequest();
    });
  }

  void _writeNextRequest() {
    final ref = _memberRef();
    if (ref == null || _outbox.isEmpty) return;
    final payload = Map<String, dynamic>.from(_outbox.removeAt(0));
    final sig = payload.remove('_sig')?.toString() ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastSentSig = sig;
    _lastSentAtMs = now;
    // The nonce is what makes it exactly-once. Firestore replays snapshots (a
    // local write echoes back, a reconnect re-delivers), so an action keyed only
    // by its name would be applied twice — a double toggle is a no-op the user
    // reads as "nothing happened", and a double skip loses a track. The action is
    // folded in so two different requests in the same millisecond stay distinct.
    payload['nonce'] = '$now-$sig';
    print('LT guest: requesting "${payload['action']}" from the host '
        '(value=${payload['valueMs']}, to=${payload['toIndex']})');
    ref.set({'request': payload}, SetOptions(merge: true)).catchError((Object e) {
      print('LT guest: request write FAILED: $e');
    });
  }

  // Listener control of the shared queue. The host serialises edits rather than
  // gatekeeping: it applies whatever any listener asks and re-mirrors the result,
  // so two listeners editing at once still produce one queue.
  //
  // Each method returns true when the edit was handled as a session edit, so the
  // caller must not also apply it locally; these already apply the local half
  // optimistically, so edits look instant. The mirror that comes back is
  // authoritative, so a refused edit is undone. Only the mirrored lanes change,
  // never the native player.
  //
  // Edits name tracks by id, never by index: the guest's mirror is a bounded view
  // while the host holds the full queue, so indexes don't line up.

  /// Rebuild the mirrored buckets from an edit and push them into player state.
  void _mirrorEdit({
    List<Song>? user,
    List<Song>? context,
    List<Song>? auto,
  }) {
    _mirrorUser = user ?? _mirrorUser;
    _mirrorContext = context ?? _mirrorContext;
    _mirrorAuto = auto ?? _mirrorAuto;
    _reapplyMirror();
  }

  bool requestQueueAdd(Song song, {bool playNext = false}) {
    if (state.role != LtRole.guest) return false;
    // "Play next" is the front of the user bucket, a plain add is its end — the
    // same two positions addToQueueNext/addToQueue use on the host.
    final user = List<Song>.from(_mirrorUser);
    user.removeWhere((s) => s.id == song.id);
    playNext ? user.insert(0, song) : user.add(song);
    _mirrorEdit(user: user);
    _sendRequest(playNext ? 'queue_next' : 'queue_add', track: song.toMap());
    return true;
  }

  /// [song] rather than an index: see the note above.
  bool requestQueueRemove(Song song) {
    if (state.role != LtRole.guest) return false;
    // Recorded so the sheet offers UNDO to a listener too. Without it the undo
    // affordance only ever appeared for the host, because it is driven by what
    // removeFromQueue stores, and a listener never calls that.
    _ref.read(lastRemovedItemProvider.notifier).state = RemovedQueueItem(
      song: song,
      index: 0,
      timestamp: DateTime.now(),
      userQueue: _mirrorUser,
      contextQueue: _mirrorContext,
      autoplayQueue: _mirrorAuto,
    );
    _mirrorEdit(
      user: _mirrorUser.where((s) => s.id != song.id).toList(),
      context: _mirrorContext.where((s) => s.id != song.id).toList(),
      auto: _mirrorAuto.where((s) => s.id != song.id).toList(),
    );
    _sendRequest('queue_remove', trackId: song.id);
    return true;
  }

  /// Moves [song] to where [toSong] currently sits. Naming the destination track
  /// avoids guessing at ReorderableListView's index offsets; the host resolves both
  /// ids and calls reorderQueue as for its own drag.
  bool requestQueueMove(Song song, Song? toSong) {
    if (state.role != LtRole.guest) return false;
    List<Song> reorder(List<Song> src) {
      final at = src.indexWhere((s) => s.id == song.id);
      if (at < 0) return src; // not in this bucket
      final out = List<Song>.from(src)..removeAt(at);
      final dest = toSong == null
          ? out.length
          : out.indexWhere((s) => s.id == toSong.id);
      out.insert(dest < 0 ? out.length : dest, song);
      return out;
    }
    _mirrorEdit(
      user: reorder(_mirrorUser),
      context: reorder(_mirrorContext),
      auto: reorder(_mirrorAuto),
    );
    _sendRequest('queue_move', trackId: song.id, afterId: toSong?.id);
    return true;
  }

  /// A listener playing a track outright — tapping a played row in the queue
  /// sheet, for instance. It changes what everyone hears, so the host does it.
  bool requestPlayTrack(Song song) {
    if (state.role != LtRole.guest) return false;
    _sendRequest('play_track', track: song.toMap());
    return true;
  }

  /// Not applied locally: this changes what's playing, which the host owns.
  bool requestQueueJump(Song song) {
    if (state.role != LtRole.guest) return false;
    _sendRequest('queue_jump', trackId: song.id);
    return true;
  }

  /// A listener asking for fresh autoplay; the host refreshes and the mirror
  /// brings the result back (a local refresh would be overwritten).
  bool requestQueueRefresh() {
    if (state.role != LtRole.guest) return false;
    _sendRequest('queue_refresh');
    return true;
  }

  /// A listener clearing the shared queue.
  bool requestQueueClear() {
    if (state.role != LtRole.guest) return false;
    _sendRequest('queue_clear');
    return true;
  }

  /// The buffer barrier: a guest tells the host it has the new track staged. The
  /// host holds the new track paused until every present member has reported
  /// (or [_bufferBarrierMs] passes, so one stuck device can't hold the session),
  /// so everyone starts together. Same idea as Metrolist's BUFFER_READY /
  /// BUFFER_WAIT handshake, on the relay we already have.
  static const int _bufferBarrierMs = 4000;

  void _reportReady(String songId) {
    final ref = _memberRef();
    if (ref == null || state.role != LtRole.guest || songId.isEmpty) return;
    ref.set({'readyFor': songId}, SetOptions(merge: true)).catchError((Object e) {
      print('LT guest: ready report FAILED: $e');
    });
  }

  /// Host side: is everyone staged for [songId]?
  bool _everyoneReady(String songId) {
    if (songId.isEmpty) return true;
    final guests = state.members.where((m) => !m.isHost).toList();
    if (guests.isEmpty) return true;
    for (final g in guests) {
      if (_memberReadyFor[g.uid] != songId) return false;
    }
    return true;
  }

  /// A guest's explicit skip. Wired to the transport controls so pressing next as
  /// a listener moves the WHOLE session instead of being corrected back a second
  /// later.
  ///
  /// Returns true when a request was sent, so the caller can skip its own local
  /// action and let the host's push drive every device — including this one.
  bool requestSkip({required bool next}) {
    if (state.role != LtRole.guest) return false;
    _sendRequest(next ? 'next' : 'prev');
    return true;
  }

  /// Host side: apply whatever the guests have asked for.
  void _applyGuestRequests(QuerySnapshot<Map<String, dynamic>> snap) {
    if (state.role != LtRole.host) return;
    for (final doc in snap.docs) {
      if (doc.id == _uid) continue; // our own row
      final req = doc.data()['request'];
      if (req is! Map) continue;
      final nonce = req['nonce']?.toString();
      if (nonce == null || nonce.isEmpty) continue;
      if (_seenRequestNonces.contains(nonce)) continue;

      // A stale request is never applied. The nonce is `'<sentAtMs>-<sig>'` (see
      // _writeNextRequest), so it dates itself. Requests stay on member documents as
      // overwritten fields, and a reconnect re-delivers them, so age is the real test:
      // a request nobody acted on within a minute has been superseded.
      final sentAtMs = int.tryParse(nonce.split('-').first);
      if (sentAtMs != null &&
          DateTime.now().millisecondsSinceEpoch - sentAtMs > _requestMaxAgeMs) {
        // Remembered anyway, so a replay of it does not re-run this arithmetic
        // every snapshot for the rest of the session.
        _rememberNonce(nonce);
        continue;
      }
      _rememberNonce(nonce);

      final action = req['action']?.toString() ?? '';
      final notifier = _ref.read(playerProvider.notifier);
      print('LT host: applying guest request "$action"');
      switch (action) {
        // Idempotent on purpose: the guest sends the state it wants, not a toggle, so a
        // replayed or duplicated request can't invert the session.
        case 'set_playing':
          final want = req['want'] == true;
          // The listener already named the instant; relay it unchanged so the host and the
          // asker act on the same tick.
          final execAt = (req['execAtMs'] as num?)?.toInt();
          final posAt = (req['valueMs'] as num?)?.toInt();
          // The track the listener measured that position on — see
          // _scheduleApply. Absent from an older listener build, which then
          // applies the state without pinning the playhead.
          final reqSongId = req['trackId']?.toString();
          if (execAt != null && posAt != null) {
            _scheduleApply(
                playing: want,
                posAtExecMs: posAt,
                execAtServerMs: execAt,
                songId: reqSongId);
            _publishSchedule(
                playing: want,
                posAtExecMs: posAt,
                execAtServerMs: execAt);
            continue; // _publishSchedule already wrote the room
          }
          // No instant (an older listener build): fall back to acting now.
          if (_ref.read(playerProvider).isPlaying != want) {
            notifier.togglePlay(haptic: false);
          }
          break;
        // Legacy flip, kept for a listener still on an older build.
        case 'toggle':
          notifier.togglePlay(haptic: false);
          break;
        case 'next':
          notifier.playNext();
          break;
        case 'prev':
          notifier.playPrevious();
          break;
        case 'seek':
          final v = (req['valueMs'] as num?)?.toInt();
          if (v != null && v >= 0) notifier.seek(Duration(milliseconds: v));
          break;
        // Everything that shapes the sound is applied here and republished by the push
        // below, so every listener hears it at the same moment. Listeners never change
        // the room directly; they ask.
        case 'set_speed':
          final sp = (req['value'] as num?)?.toDouble();
          // Bounds are the request's, not the UI's: this arrives from another
          // device and a nonsense multiplier would be applied to real audio.
          if (sp != null && sp >= 0.25 && sp <= 4.0) notifier.setSpeed(sp);
          break;
        case 'set_pitch':
          final pt = (req['value'] as num?)?.toDouble();
          if (pt != null && pt >= 0.25 && pt <= 4.0) notifier.setPitch(pt);
          break;
        case 'set_loop':
          // start/end travel as plain millisecond ints; `want` carries whether
          // the loop should be on. A clear arrives as want=false, which must
          // survive even though the two points are then meaningless.
          final on = req['want'] == true;
          final ls = (req['valueMs'] as num?)?.toInt();
          final le = (req['toIndex'] as num?)?.toInt();
          if (!on) {
            notifier.clearLoopRegion();
          } else if (ls != null && le != null && le > ls) {
            notifier.setLoopRegion(Duration(milliseconds: ls), Duration(milliseconds: le));
          }
          break;
        // Listener edits to the shared queue, applied to the host's real queue and
        // re-mirrored by _pushNow below, so there's only ever one queue. Tracks are
        // resolved by id, which also fails safely when the queue has moved on.
        case 'queue_add':
        case 'queue_next':
          final song = _requestTrack(req);
          if (song == null) continue;
          if (action == 'queue_next') {
            notifier.addToQueueNext(song);
          } else {
            notifier.addToQueue(song);
          }
          print('LT host: listener queued "${song.title}"'
              '${action == 'queue_next' ? ' to play next' : ''}');
          break;
        case 'queue_remove':
          final rid = req['trackId']?.toString();
          final ri = rid == null
              ? -1
              : _ref.read(playerProvider).queue.indexWhere((s) => s.id == rid);
          if (ri < 0) {
            print('LT host: queue_remove — no such track ($rid)');
            continue;
          }
          notifier.removeFromQueue(ri);
          break;
        case 'queue_move':
          final mid = req['trackId']?.toString();
          final aid = req['afterId']?.toString();
          final q = _ref.read(playerProvider).queue;
          final from = mid == null ? -1 : q.indexWhere((s) => s.id == mid);
          if (from < 0) {
            print('LT host: queue_move — no such track ($mid)');
            continue;
          }
          // The destination is a TRACK, resolved here, so this is the same call
          // the host would make for its own drag — no index arithmetic to get
          // backwards on a downward move.
          final to = aid == null ? q.length - 1 : q.indexWhere((s) => s.id == aid);
          if (to < 0 || to == from) continue;
          notifier.reorderQueue(from, to);
          break;
        case 'play_track':
          final pt = _requestTrack(req);
          if (pt == null) continue;
          notifier.playSong(pt, source: 'Listen Together');
          break;
        case 'queue_jump':
          final jid = req['trackId']?.toString();
          final ji = jid == null
              ? -1
              : _ref.read(playerProvider).queue.indexWhere((s) => s.id == jid);
          if (ji < 0) {
            print('LT host: queue_jump — no such track ($jid)');
            continue;
          }
          notifier.jumpToQueueIndex(ji);
          break;
        case 'queue_refresh':
          // The host owns autoplay, so a listener refreshing has to come through
          // here — done locally it regenerated only that device's suggestions and
          // the next mirror overwrote them.
          notifier.refreshAutoplay();
          break;
        case 'queue_clear':
          notifier.clearUserQueue();
          break;
        default:
          continue;
      }
      // Push straight away, so the guest that asked sees it happen immediately
      // rather than on the next heartbeat.
      _pushNow();
    }
  }

  void _endSession(String message) {
    print('LT: _endSession "$message" (role=${state.role}, code=$_code)');
    final uid = _uid;
    final code = _code;
    // The session is over, so there is nothing to come back to. Without this
    // the next launch would still try to restore it — harmless, because
    // _restoreSessionIfStillLive checks the room is alive and would drop it,
    // but it costs a pointless read and a confusing log line on every start.
    _forgetSession();
    _teardown();
    state = state.copyWith(clearSession: true, notice: message);
    // Best-effort: remove our presence doc so the roster doesn't show ghosts.
    if (code != null && uid != null) {
      _roomRef(code).collection('members').doc(uid).delete().catchError((_) {});
    }
  }

  void _teardown() {
    final posListener = _positionListener;
    if (posListener != null) {
      currentPositionProvider.removeListener(posListener);
      _positionListener = null;
    }
    _playerUnsub?.call();
    _playerUnsub = null;
    _roomSub?.cancel();
    _roomSub = null;
    _queueSub?.cancel();
    _queueSub = null;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _outbox.clear();
    _lastQueueSig = null;
    _lastSentSig = null;
    _membersSub?.cancel();
    _membersSub = null;
    // Filled by the subscription just cancelled, so it belongs to the session
    // that is ending. It was never cleared anywhere: entries accumulated for
    // every uid ever seen, and — the reason this matters more than the bytes —
    // a stale "ready for song X" from an earlier session could answer for a
    // member who rejoined, since readiness is judged by comparing this to the
    // current song id.
    _memberReadyFor.clear();
    _hostTicker?.cancel();
    _hostTicker = null;
    _execTimer?.cancel();
    _execTimer = null;
    _execAtServerMs = 0;
    _guestTicker?.cancel();
    _guestTicker = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    if (_nudging) {
      _nudging = false;
      try {
        _ref.read(playerProvider.notifier).setSpeed(_preNudgeSpeed);
      } catch (_) {}
    }
    _room = null;
    _applying = false;
    _applyQueued = false;
    _code = null;
    _rev = 0;
    _prevMemberCount = 0;
    _hostRowMisses = 0;
    _hostSeenObserved = 0;
    _lastClaimAtMs = 0;
  }
}

final listenTogetherProvider =
    StateNotifierProvider<ListenTogetherNotifier, ListenTogetherState>(
        (ref) => ListenTogetherNotifier(ref));

/// Tells the notifier when the app is genuinely being closed. A separate observer
/// object (like LibraryLifecycleHook) rather than mixing WidgetsBindingObserver
/// into the notifier. Only `detached` is forwarded; `paused`/`hidden` mean
/// backgrounded, and a host must keep hosting then.
class _LtLifecycleHook extends WidgetsBindingObserver {
  final VoidCallback onDetached;

  _LtLifecycleHook({required this.onDetached});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) onDetached();
  }
}
