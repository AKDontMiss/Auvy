import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/services/cloud_sync_service.dart';

/// Listen Together
///
/// Real-time synchronized listening: one person hosts a session, friends join
/// with a 6-character code, and everyone hears the same moment of the same
/// track — each device streams its own audio; only tiny control messages are
/// exchanged — the Spotify-Jam shape, where no audio ever crosses the wire.
///
/// Transport is Firestore (already shipped for cloud backup), used as a
/// realtime relay: the HOST is the single source of truth and writes the room
/// document on every track change / play-pause / seek plus a 4-second
/// heartbeat while playing; GUESTS follow via snapshot listeners.
///
/// Staying in sync:
///  • a server-clock offset is estimated at join and refreshed periodically
///    (median of up to five serverTimestamp round trips), so both sides can
///    talk in "server time";
///  • the host stamps every write with (positionMs, atServerMs); a guest's
///    live target is positionMs + (serverNow − atServerMs) — network latency
///    and clock skew cancel out;
///  • guests run a drift loop against an INTERPOLATED playhead: within
///    ±[_softDriftMs] is "in sync"; beyond ±[_hardDriftMs] hard-seeks; in
///    between it time-stretches proportionally (pitch preserved, inaudible)
///    until back inside the soft window;
///  • a track change waits on a BUFFER BARRIER — the host holds the new song
///    until every listener reports it staged, so starts are together rather
///    than each device starting when it happens to be ready;
///  • listeners are not read-only: their play/pause/seek/skip is sent upstream
///    as a request on their own member doc and applied by the host, so one
///    source of truth is preserved while control is shared.
///
/// Sessions live under `listen_sessions/{CODE}` with a `members/{uid}`
/// subcollection for presence (25 s heartbeats; a host silent for >90 s ends
/// the session on guests).

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
  ListenTogetherNotifier(this._ref) : super(const ListenTogetherState());

  final Ref _ref;

  // Codes avoid 0/O/1/I so they survive being read out loud.
  static const String _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  static const int _codeLength = 6;

  // Drift thresholds. A raw WebSocket relay can hold 50/750ms; Firestore fan-out
  // latency is higher, so these windows are proportionally wider.
  // TIGHTENED FROM 250 ms. The loop stops correcting inside this window, so
  // it WAS the precision floor: two devices could sit 250 ms apart and both
  // report "in sync". Measured drift settled at 140–230 ms, which is audible
  // as a flam when two devices are in the same room. 90 ms is under the
  // ~100 ms mark where two sources start to smear rather than double, and the
  // correction that holds it there is a ±3% time-stretch nobody can hear.
  /// 90 → 35 ONLY BECAUSE STARTS ARE NOW ALIGNED.
  ///
  /// Under the old "host acts now, guests chase" design this band WAS the sync
  /// error: every play/pause started the devices apart and the loop pulled them
  /// together to within the band and stopped, so the session sat at up to 90 ms
  /// by construction (measured: 70-110 ms steady state). With scheduled
  /// execution both devices start on the same server tick, so what is left is
  /// genuine clock and decode error — small enough that a tighter band corrects
  /// it without hunting.
  static const int _softDriftMs = 35;

  /// How far ahead a scheduled action is placed, in server-clock ms.
  ///
  /// THE WHOLE POINT: EVERY DEVICE ACTS AT THE SAME INSTANT, INCLUDING THE
  /// HOST. Publishing "I paused" and letting listeners catch up cannot beat one
  /// relay hop — the device that acted is always ahead by the latency. Naming a
  /// FUTURE instant and having everyone wait for it converts that latency into
  /// lead time, which is why the residual can drop to clock error.
  ///
  /// Two leads, because the initiator pays for the hops its message must make:
  /// one for the host (host → listeners), two for a listener (listener → host →
  /// listeners). Measured relay round trips this session were ~90-120 ms each
  /// way, so these carry roughly 3x headroom.
  /// One lead for everyone, host included.
  ///
  /// Two leads (one hop for the host, two for a listener) would be cheaper for
  /// the host, and would make pressing play feel DIFFERENT depending on which
  /// device you happened to be holding. Nobody in a session is a lesser
  /// participant, so the delay between press and sound is identical everywhere;
  /// the value covers the worst case, which is a listener whose message has to
  /// reach the host and be relayed on before the instant arrives.
  ///
  /// Relay round trips measured this session were ~90-120 ms each way, so this
  /// carries roughly 2.5x headroom on the two-hop path.
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
  /// Last reported sync zone, so the drift loop logs transitions, not ticks.
  String? _lastDriftZone;

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
  final Set<String> _seenRequestNonces = {};

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


  /// The last mirror received, kept so it can be re-applied.
  ///
  /// playSong REBUILDS THE QUEUE, SO THE MIRROR HAS TO BE REASSERTED.
  /// _applyRoom plays the host's track, and playSong sets a queue of its own.
  /// It is asynchronous, so it can land AFTER the mirror snapshot and wipe it —
  /// and because the mirror is only republished when the host's queue CHANGES,
  /// the guest would then show the wrong queue until the next edit, possibly for
  /// the rest of the session.
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
      await _memberRef()!.set({
        'name': name,
        'isHost': true,
        'joinedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      await _estimateServerClock();
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

      await _memberRef()!.set({
        'name': _displayName,
        'isHost': false,
        'joinedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      await _estimateServerClock();
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
      // The real error, NOT just the friendly one.
      //
      // Every way this can fail produces the same sentence on screen, and the
      // most likely cause by far is a Firestore rules or anonymous-auth problem
      //, which looks identical to a wrong code from the outside. Swallowing the
      // exception meant a two-device test could only ever report "it doesn't
      // work". The user still sees the friendly line; the log says which.
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
    final wasHost = state.role == LtRole.host;
    final code = _code;
    final members = state.members;
    // Chosen before the teardown below, which clears the roster this reads.
    final successorUid = wasHost ? _successorUid() : null;
    final successor = successorUid == null
        ? null
        : members.firstWhere((m) => m.uid == successorUid);
    _teardown();
    state = state.copyWith(clearSession: true, clearNotice: true);
    if (code == null) return;
    try {
      if (wasHost) {
        // Hand over rather than delete, if anyone is still listening.
        //
        // Deleting the room was the "session over" signal, which meant one
        // person leaving ended everybody else's session. Naming a successor
        // keeps it alive; the room is only torn down when the last listener has
        // gone. hostSeenMs is set to an ancient value so that if the successor
        // never arrives, the remaining listeners see an abandoned room at once
        // and one claims it instead of waiting out the staleness window.
        final heir = successor;
        if (heir != null) {
          await _roomRef(code).set({
            'hostId': heir.uid,
            'hostName': heir.name,
            // 1, NOT 0. An ANCIENT stamp, not a missing one.
            //
            // _checkHostAlive skips `hostSeenMs <= 0` on purpose: a room written
            // by a build that predates the field has no stamp at all, and
            // treating that as "abandoned" would hijack a live session. Zeroing
            // it here therefore disabled the very fallback it was meant to arm.
            // An implausibly old value is unambiguous — the field is present, and
            // it is stale by decades, so if the heir never takes over, the
            // remaining listeners see an abandoned room immediately.
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
        await _roomRef(code).collection('members').doc(_uid).delete();
      }
    } catch (_) {
      // Best-effort: presence staleness cleans up after network failures.
    }
  }

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(clearNotice: true);
  }

  @override
  void dispose() {
    print('LT: notifier disposed (role=${state.role}, code=$_code)');
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

  /// Estimate (serverClock − localClock) the way an NTP exchange does, but with
  /// Firestore's serverTimestamp as the reference:
  /// the commit is stamped roughly mid-flight of the acked write, so
  /// offset ≈ stampedTs − midpoint(sendStart, ackReceived). Best of 2 samples
  /// (lowest round-trip wins — same rationale as NTP's best-RTT filter).
  /// Estimate `serverNow − localNow`, the number that lets both sides talk in
  /// one clock.
  ///
  /// This number is the whole of sync accuracy, AND two samples were NOT
  /// ENOUGH. Every guest correction is computed from
  /// `hostPosition + (serverNow − hostStamp)`, so an offset that is 300 ms wrong
  /// makes every device 300 ms wrong — permanently, and invisibly, because the
  /// drift loop then "corrects" toward the wrong target. Best-of-two on a mobile
  /// connection is one bad pair of samples away from exactly that.
  ///
  /// Now: up to five samples, and the MEDIAN of those whose round trip was
  /// within 1.5× of the fastest — the slow ones carry most of the error, and a
  /// median resists a single outlier in a way a min does not. Also re-run
  /// periodically, because the estimate ages: handset clocks are corrected by
  /// NTP mid-session, and a session can last hours.
  Future<void> _estimateServerClock() async {
    final ref = _memberRef();
    if (ref == null) return;
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

      // Hold the start until every listener has the track staged
      //
      // A track change is otherwise a race each device loses differently: the
      // host starts immediately, every guest still has to resolve its own stream
      // (a player POST, a URL probe, buffering — often a second or more), starts
      // late, and gets hard-seeked forward. That is the stumble at every
      // boundary. Metrolist's server does this with BUFFER_READY/BUFFER_WAIT;
      // Spotify's Jam waits the same way.
      //
      // Bounded by [_bufferBarrierMs] so one stuck listener cannot hold the
      // session, and skipped entirely when the host is alone.
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

    // The mirror is driven from exactly one place per event.
    //
    // _pushQueue used to be called here AND at the end of _pushNow, so every
    // host state change walked the queue twice. It is cheap now (ids decide, and
    // it serialises nothing when unchanged) but it is still work done for no
    // reason, and this listener fires on volume, position and buffering too.
    //
    // _pushNow mirrors as its last step, so the call below is only for the case
    // _pushNow will NOT be reached: a queue edit changes neither the track nor
    // play/pause, and ungated it would otherwise wait for the 4-second
    // heartbeat.

    // A track change is NOT a pause, AND publishing it as one is why the
    // Session stalled between songs.
    //
    // Between two tracks the player reports isPlaying=false for a moment while
    // the next stream is resolved and staged. This listener fired on that
    // transient, wrote `isPlaying: false` to the room, and every guest dutifully
    // paused — then waited out its own 3-tick grace (~2.4 s) before resuming,
    // because the host's later `true` arrived as a separate change. The result
    // was a gap at every track boundary that nobody asked for.
    //
    // A loading player has no settled state worth broadcasting. Skipping the
    // push here costs nothing: the 1-second host ticker publishes the moment the
    // new track is actually playing, and a SONG change is still pushed
    // immediately (that is the part guests need early, so they can start
    // resolving the same stream).
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

  // Host migration
  //
  // The host is a ROLE, not a privilege: it serialises edits so two listeners
  // cannot produce two different queues. Nothing about the session belongs to
  // that device, so losing it should not end the session for everyone.
  //
  // Two paths. A graceful leave NAMES a successor and hands over instantly. A
  // crash or a dead network cannot write anything, so listeners notice
  // hostSeenMs going stale and one of them claims the room.

  /// A host is considered gone once its stamp is this old. Comfortably past the
  /// 25-second presence tick, so a slow write or one dropped tick is not a
  /// takeover.
  static const int _hostGoneMs = 70000;

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
    // If *we* are offline, the host is NOT the one who went missing
    //
    // The staleness test asks "have I seen a fresh stamp lately", and losing our
    // OWN network answers no just as loudly as the host dying, so a listener
    // whose Wi-Fi dropped concluded the host was gone and tried to take the
    // session over. Observed during an offline test:
    //
    // LT: host claim FAILED: [cloud_firestore/unavailable]   (x3)
    //
    // Three transactions fired into a dead network, each burning the backoff and
    // radio time, and each certain to fail — a claim is a WRITE, so it needs the
    // very thing we do not have. If it had somehow succeeded it would have been
    // worse than useless: two hosts, one of them unable to reach anybody.
    //
    // A reconnect brings a fresh snapshot with it, and the check runs again then
    // against real evidence.
    if (!_ref.read(connectivityProvider).hasInternet) return;
    final age = _nowServerMs() - seen;
    // A future-dated stamp means the clocks disagree, NOT that the host is
    // IMMORTAL. Both devices estimate the server clock independently (measured
    // this session: -27 ms on one, -460 ms on the other), so a stamp can land
    // slightly ahead of our own "now". Negative ages are simply not stale; what
    // matters is that they never wrap into looking stale either.
    if (age < _hostGoneMs) return;
    // The election is the part with no witness.
    //
    // A device that is not the successor returned here in silence. If the
    // election is ever wrong in the direction where EVERY device defers, the
    // room simply dies and no device anywhere records why — the one shape a
    // transcript could not explain. Host migration has never run on a real
    // device, so this is the line that will say whether it works. Rate-limited
    // by the same backoff as the claim, or it would print twice a second.
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

  /// Become the host, keeping playback exactly where it is.
  ///
  /// THE GUEST MACHINERY MUST GO FIRST. Left running, the room subscription
  /// would apply this device's own pushes back to itself and the drift loop
  /// would chase a target it is now the source of.
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
        _ref.read(playerProvider.notifier).setSpeed(1.0);
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

      // A position is only meaningful on the track it was measured on.
      //
      // The schedule used to carry a bare number, so when the two devices were on
      // DIFFERENT tracks, which is every track transition — each applied the
      // other's position to its own song. Measured on device:
      //
      //   host: pushing "Life Is Good" playing=true at 183093ms (rev 34)
      //   guest: requesting "set_playing" (value=178313)
      //   host: pushing "Life Is Good" playing=false at 581ms   <- 581ms in!
      //   guest: drift -186021ms -> seek
      //
      // Three-minute seeks, in both directions, on every boundary. The song id
      // makes it checkable: same track, pin the playhead; different track, apply
      // the play STATE only and let the room's own track sync do its job.
      //
      // A late schedule is treated the same way. Its position was true at an
      // instant that has passed, and seeking to a stale number is worse than not
      // seeking at all.
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

  /// The play/pause button, in a session. Returns true when the press became a
  /// schedule, so the caller must NOT also toggle the player.
  ///
  /// THE HOST GOES THROUGH HERE TOO. A host that toggled locally and published
  /// afterwards is always ahead of every listener by one hop — the asymmetry this
  /// mechanism exists to remove.
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
    // The stamp is interpolated, for the same reason the guest's reading is.
    // currentPositionProvider is fed ~twice a second, so stamping it raw told
    // every listener "the host is at X" when the host was really at X+Δ, Δ up to
    // 500 ms. That is a SYSTEMATIC error on the source side: the guests then
    // synchronise perfectly to the wrong number. Projecting from the last
    // update removes it.
    final posMs = _livePositionMs(s.speed);
    // A zero read mid-track is a transient, NOT a seek to the start.
    //
    // Observed on the host across four consecutive pushes: 16377ms, 0ms, 0ms,
    // 56167ms — same song throughout. Publishing the zeroes yanked every
    // listener back to the beginning and the drift loop then hauled them
    // forward again. The engine reports 0 briefly while it re-stages a stream,
    // and that is indistinguishable from a real restart EXCEPT that a real one
    // does not happen with the previous position still tens of seconds in.
    //
    // Skipping is safe: the 1-second ticker republishes as soon as the position
    // is real again.
    if (posMs == 0 &&
        _lastPushedPosMs > 2000 &&
        s.currentSong?.id == _lastPushedSongId) {
      return;
    }
    _rev++;
    _lastPushedSongId = s.currentSong?.id;
    _lastPushedPlaying = isPlaying;
    _lastPushedPosMs = posMs;
    _lastPushedAtLocalMs = DateTime.now().millisecondsSinceEpoch;
    // Logged only when the MATERIAL state changes (track or play/pause), not on
    // the 4-second heartbeat — a session would otherwise print a line every four
    // seconds for its whole life. A write that fails is always reported: a host
    // whose pushes are being rejected looks, from the guest side, exactly like a
    // host who stopped listening.
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
    }, SetOptions(merge: true)).catchError((Object e) {
      print('LT host: push FAILED (rev $_rev): $e');
    });
    _pushQueue();
  }

  /// The shared queue
  ///
  /// Mirror the host's queue so every listener sees, and can act on, the same
  /// "what's next". Without it a session synchronised the current track and
  /// nothing else: each device showed its own queue, and a listener adding a song
  /// added it somewhere nobody else would ever hear.
  ///
  /// A SEPARATE DOCUMENT, DELIBERATELY. The room document is rewritten on the
  /// 4-second heartbeat and on every seek; the queue changes rarely. Carrying a
  /// 60-track list in it would multiply the session's mobile data by the
  /// heartbeat rate for nothing. This document is written only when the queue
  /// actually changes — the signature check below is what guarantees that.
  static const int _queueMirrorLimit = 60;

  void _pushQueue() {
    final code = _code;
    if (code == null || state.role != LtRole.host) return;
    final s = _ref.read(playerProvider);
    final curId = s.currentSong?.id;

    // The three buckets travel separately, NOT as one flat slice.
    //
    // The queue sheet builds its section headings and its drag targets from
    // userQueue / contextQueue / autoplayQueue. A flat list forced the listener
    // to reconstruct them wrongly — same tracks, wrong heading, and a drop index
    // that disagreed with the host. It also carried already-played tracks into
    // the listener's "up next", because a window around the current index
    // includes what came before it.
    //
    // Budgeted in bucket order so the tail of AUTOPLAY is what gets dropped on a
    // long queue, never somebody's explicit "play next".
    // Decide before serialising, NOT after.
    //
    // This packed up to 60 Song.toMap() calls and only then compared the
    // signature, and it runs on every host player-state change, so a volume
    // change or a position tick paid for a full serialisation that was thrown
    // away. Ids alone decide whether anything needs sending.
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

  /// A guest's OWN player changed. Turn it into a request immediately.
  ///
  /// WITHOUT THIS, GUEST → HOST TOOK ~1.6 SECONDS AND FELT BROKEN.
  ///
  /// The tick loop can only INFER intent: it notices the guest's state disagrees
  /// with the room, waits two 800 ms ticks to be sure it is not a transient
  /// loading state, and only then asks the host. So a listener pressing pause got
  /// silence on their own device instantly and the host kept playing for another
  /// second and a half — reported, correctly, as "delayed and not smooth".
  ///
  /// A state listener knows at the moment of the tap. The request goes out in the
  /// same frame, and the round trip is then just Firestore's. The tick loop stays
  /// as the safety net for anything this misses (and for enforcement when the
  /// host never answers).
  ///
  /// `_applying` gates it: while the guest is applying the room's own state, the
  /// resulting play/pause change is the ROOM's, not the user's, and echoing it
  /// back as a request would bounce the session.
  void _onGuestPlayerState(PlayerState s) {
    // A seek we issued looks exactly like the user pressing pause.
    //
    // Pinning the playhead means an apply now SEEKS, and a seek drops isPlaying
    // for a moment. This listener read that transient as intent and asked the
    // host to pause; the host obliged and pushed, the guest applied, seeked and
    // asked again. Measured on device: rev 113 to 132 in thirty seconds, the
    // guest ten seconds ahead, positions alternating 12587 / 3648 / 12588.
    //
    // The echo window is armed BEFORE the mutation and the seek settles after
    // it, so it cannot be the only guard: this one starts when the seek was
    // issued and outlives it.
    if (DateTime.now().millisecondsSinceEpoch - _lastLocalSeekAtMs < 1800) return;
    if (state.role != LtRole.guest || _applying) return;
    final data = _room;
    if (data == null) return;

    //`_applying` IS NOT ENOUGH, BECAUSE THE STATE CHANGE ARRIVES LATER.
    //
    // _applyRoom sets `_applying` around its own calls, but `playSong` and
    // `togglePlay` are asynchronous — the resulting player-state notification
    // lands AFTER the flag has been cleared. So the guest saw the change it had
    // just been told to make, read it as the user's intent, and asked the host to
    // undo it. Measured on a real join:
    //
    //   23:10:38.408 LT guest: switched to "Fair Trade" … playing=true
    //   23:10:38.410 LT guest: requesting "toggle" from the host
    //   23:10:38.914 LT guest: paused to match host
    //
    // Two milliseconds. Joining a session paused it, and every correction the
    // guest applied bounced back as a fresh request — the toggle storm in the
    // host's log. A time window is the only thing that can separate "the room
    // told me to" from "the user tapped", because both look identical here.
    if (DateTime.now().millisecondsSinceEpoch < _suppressGuestEchoUntilMs) {
      return;
    }
    final wantPlaying = data['isPlaying'] == true;
    if (s.isLoading) return;
    if (s.isPlaying == wantPlaying) return;
    _playMismatchTicks = 1; // the tick loop's fallback timer starts here
    _sendRequest('set_playing',
        valueMs: _livePositionMs(s.speed), want: s.isPlaying);
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
      // LIVENESS IS REFRESHED ON EVERY SNAPSHOT; PLAYBACK ONLY ON A NEW REV.
      //
      // The rev gate used to sit above this, so a snapshot that did not advance
      // rev was dropped whole, and the host's 25-second presence tick writes
      // `hostSeenMs` WITHOUT bumping rev. So the guest's copy of the room froze
      // at whatever stamp the last playback push happened to carry, went stale on
      // its own, and the migration check read that frozen value as "the host is
      // gone" while the server had a fresh one. The transaction then declined,
      // 500 ms later the tick tried again, and it looped:
      //
      //   LT: host claim declined — the room was not abandoned   (x many)
      //
      // Keeping `_room` current costs nothing (the fields playback reads are
      // unchanged by a presence-only write) and it is what makes the liveness
      // check honest. Applying playback state stays gated on rev.
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

    // The mirrored queue, on its own document. See _pushQueue for why it is
    // not carried on the room doc.
    //
    // A SEPARATE SUBSCRIPTION. Folding the queue parsing into the room
    // listener above replaced its body and stopped _applyRoom from ever being
    // called: the session connected, the roster filled in, and the guest then
    // followed nothing at all.
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
        if (target > _hardDriftMs) {
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
        // Pin the playhead, NOT only the play state.
        //
        // This branch only toggled, so a pause arriving one relay hop late
        // (~300-600 ms) left the guest paused that much FURTHER INTO the
        // track. Both devices then read "paused" while holding different
        // positions, and the next resume started them apart and let the drift
        // loop nudge the difference out audibly, which is precisely what
        // "they are not synced correctly" was.
        //
        // _targetPositionMs is the right number for both cases: for a pause it
        // is the host's stamped position, and for a resume it is that position
        // projected forward to now. Either way the two devices land in phase
        // no matter how late the message arrived — the COMMAND cannot beat the
        // network, but the PLAYHEAD does not have to lose because of it.
        final target = _targetPositionMs();
        final skew = target - _livePositionMs(ps.speed);
        // ORDER MATTERS EITHER WAY. Pausing first and then seeking keeps a
        // pause silent; seeking while still playing would be audible as a
        // jump right before the stop. A resume is the mirror image — land on
        // the right position first, then start.
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
    return pos + max(0, _nowServerMs() - at);
  }

  /// This device's playhead RIGHT NOW, interpolated.
  ///
  /// MEASURING AGAINST A STALE NUMBER IS WHY SYNC WAS "OFF A BIT".
  ///
  /// `currentPositionProvider` is fed by the native engine about twice a second,
  /// so at any moment it can be up to ~500 ms behind the real playhead, and the
  /// drift loop was comparing the host's precisely-projected target against it,
  /// inside a ±250 ms soft window. Half the measurement was noise larger than the
  /// window itself, so the loop could sit "in sync" while genuinely half a second
  /// out, or nudge in the wrong direction.
  ///
  /// Interpolating from the moment the value last CHANGED removes that: the same
  /// projection the host's own position gets, applied to ours, with playback speed
  /// taken into account so an active ±3% nudge does not skew the reading.
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
    _positionListener = () {
      _positionSeenAtLocalMs = DateTime.now().millisecondsSinceEpoch;
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

    // Play/pause: ask the host first, enforce only if ignored
    //
    // This used to just toggle the guest back. So a listener who paused was
    // overruled two seconds later, and the session was one-directional by
    // construction: only the host could change anything.
    //
    // Now a guest deviation is read as INTENT and sent upstream as a request on
    // their own member document (which they already write for presence, so no new
    // permission is involved). The host applies it and pushes — one source of
    // truth is preserved, and everyone converges on the change including the
    // guest who asked for it.
    //
    // Enforcement is kept as the fallback: if no host acts on the request within
    // [_requestGraceMs] — host backgrounded, offline, or on an older build that
    // does not understand requests — the guest is pulled back into line rather
    // than left silently diverged.
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

    // Drift correction — only meaningful while both sides are playing.
    if (!wantPlaying || !ps.isPlaying) {
      _endNudge(notifier);
      return;
    }
    final drift = _targetPositionMs() - _livePositionMs(ps.speed);
    // LOGGED ON TRANSITIONS ONLY. This loop runs every second for the whole
    // session; a line per tick would be a wakeup and log I/O per second and
    // would bury everything else. Reporting only when the sync STATE changes —
    // in-sync ↔ nudging ↔ hard-seek — is what makes a real desync visible while
    // a healthy session stays quiet.
    final zone = drift.abs() <= _softDriftMs
        ? 'sync'
        : (drift.abs() >= _hardDriftMs ? 'seek' : 'nudge');
    if (zone != _lastDriftZone) {
      _lastDriftZone = zone;
      print('LT guest: drift ${drift}ms → $zone');
    }
    if (drift.abs() <= _softDriftMs) {
      _endNudge(notifier); // back in the window — restore natural tempo
    } else if (drift.abs() >= _hardDriftMs) {
      _endNudge(notifier);
      notifier.seek(Duration(milliseconds: max(0, _targetPositionMs())));
    } else {
      // Soft zone: inaudible ±3% time-stretch instead of a jarring seek.
      // Only when the user hasn't chosen a custom speed (and never podcasts —
      // their speed choice is a sticky preference).
      final isPodcast = ps.currentSong?.albumTitle == 'Podcast';
      if (!isPodcast && (ps.speed == 1.0 || _nudging)) {
        _nudging = true;
        // PROPORTIONAL, NOT A FIXED ±3%.
        //
        // A flat rate takes drift/0.03 of playback to close — 6.7 seconds for a
        // 200 ms error, so the session spent most of its time converging rather
        // than converged. And near the soft edge a fixed rate overshoots straight
        // through the window and starts correcting the other way, which is the
        // slow oscillation that reads as "never quite locked".
        //
        // Scaling with the error closes a large drift quickly and eases off as it
        // approaches, so it settles instead of hunting. Capped at 6%: beyond that
        // the pitch-preserved stretch stops being inaudible.
        final magnitude = drift.abs();
        final rate = (magnitude / 4000).clamp(_nudgeRate * 0.5, 0.06);
        notifier.setSpeed(drift > 0 ? 1.0 + rate : 1.0 - rate);
      }
    }
  }

  void _endNudge(PlayerNotifier notifier) {
    if (!_nudging) return;
    _nudging = false;
    notifier.setSpeed(1.0);
  }

  // Presence & members

  void _watchMembers() {
    final code = _code;
    if (code == null) return;
    _membersSub = _roomRef(code)
        .collection('members')
        .snapshots()
        .listen((snap) {
      if (!mounted || !state.active) return;
      final members = snap.docs.map((d) {
        final m = d.data();
        return LtMember(
          uid: d.id,
          name: (m['name'] ?? 'Listener').toString(),
          isHost: m['isHost'] == true,
          lastSeenMs: (m['lastSeenMs'] as num?)?.toInt() ?? 0,
          joinedAtMs: (m['joinedAtMs'] as num?)?.toInt() ?? 0,
        );
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
        // Host vanished without ending the session (app killed, network died):
        // their presence heartbeat stops advancing.
        //
        // This used to subtract one phone's clock from another's, AND that is
        // Why a healthy session died after a song OR two.
        //
        // `lastSeenMs` is written by the HOST as `hostLocal + hostOffset`, and it
        // was compared against the GUEST's `localNow + guestOffset`. Those agree
        // only if both offset estimates are good, and `_estimateServerClock`
        // falls back to 0 whenever its two samples fail, on the assumption that
        // phone clocks are NTP-synced. When one side got a real offset and the
        // other fell back (or the two handsets simply disagree by a minute), the
        // subtraction crossed 90 000 ms immediately and the guest announced "Lost
        // connection to the host" while the host was sitting there playing.
        //
        // Staleness is now measured WITHOUT comparing clocks: remember the last
        // heartbeat VALUE we saw and how long ago we saw it CHANGE, both by our
        // own monotonic-enough local clock. A live host advances the value every
        // 25 s; a dead one never does. Two consecutive stale observations are
        // required so a single slow snapshot cannot end a session.
        LtMember? host;
        for (final m in members) {
          if (m.isHost) {
            host = m;
            break;
          }
        }
        final nowLocal = DateTime.now().millisecondsSinceEpoch;
        if (host == null) {
          // A missing host row is NOT proof the host left.
          //
          // This ended the session on the FIRST snapshot that lacked the row,
          // and Firestore delivers a CACHED snapshot before the server one — so
          // a guest that had just joined saw a roster containing only itself and
          // hung up on a live host. Measured on device, 17 ms after a successful
          // track switch:
          //
          //   01:05:06.084  guest: switched to "I'm Still Standing"
          //   01:05:06.101  guest: host row gone from the roster
          //   01:05:06.102  _endSession "The host left the session."
          //
          // Presence is a HINT; the room document is the truth. So: ignore cached
          // snapshots, require two consecutive server snapshots without the row,
          // and give way entirely if the room still looks alive — a host that is
          // genuinely gone stops stamping hostSeenMs, and migration takes over
          // from there rather than everyone being disconnected.
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
          // Our own outage is NOT the host going quiet
          //
          // A frozen heartbeat is what a dead host looks like, and it is also
          // exactly what OUR OWN dropped Wi-Fi looks like, because both mean "no
          // fresh snapshot arrived". So a listener whose network blipped hung up
          // on a session that was still running. Observed on device, with the
          // phone's own Wi-Fi cut at 18:47:34:
          //
          //   18:48:40  host stamp is 70485ms old — claiming the session
          //   18:48:48  host claim FAILED [unavailable]        (x3)
          //   18:49:02  _endSession "Lost connection to the host."
          //
          // The host was fine and still hosting six minutes later. A session is
          // meant to last until the host ends it or the listener leaves, so a
          // transient local outage must HOLD, not hang up: while we are offline
          // there is no evidence about the host either way, and the moment we
          // reconnect a fresh snapshot settles it properly.
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

  void _startPresence() {
    _presenceTimer = Timer.periodic(const Duration(seconds: 25), (_) {
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
            // A DENIAL HERE IS NOT NOISE — IT IS NEWS.
            //
            // Only guests watch the room document (_roomSub is created in
            // _startGuestEngine), so a host has no way to learn it was
            // replaced. Host migration makes that reachable: a host whose
            // process is frozen past _hostGoneMs — paused, screen off, no
            // foreground service holding it awake — is legitimately claimed by
            // a member, and the rules then refuse every write from the old
            // host because the room's hostId is no longer its uid.
            //
            // Swallowing that left TWO devices believing they were host. The
            // old one kept showing host controls and kept failing silently;
            // nothing followed it. Nobody would have reported it as a
            // permission problem, because it does not look like one.
            //
            // The stamp is the ideal detector: it already runs every 25s, it
            // is the write the rules gate on hostId, and it costs no extra
            // read.
            .catchError((Object e) => _onHostStampRefused(e));
      }
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
    // THE HOST MACHINERY MUST GO FIRST — the mirror image of the warning on
    // _promoteToHost, and for a sharper reason. _startHostEngine puts a HOST
    // listener in _playerUnsub and _startGuestEngine overwrites that field, so
    // going straight there would leak the host listener AND leave _hostTicker
    // running: a 1-second timer pushing writes the room now refuses, once a
    // second, for as long as the app lives.
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


  // Guest → host requests
  //
  // Written on the guest's own member document, deliberately.
  //
  // A guest already writes that document every 25 seconds for presence, so
  // whatever rule permits presence permits this — no new collection, no new
  // permission, and no second listener on the host side either: the host is
  // already subscribed to the members collection for the roster.
  //
  // The nonce is what makes it exactly-once. Firestore replays snapshots (a local
  // write echoes back, a reconnect re-delivers), so an action keyed only by its
  // name would be applied twice — a double toggle is a no-op the user reads as
  // "nothing happened", and a double skip loses a track.
  static const int _requestGraceMs = 2400;

  /// Ask the host to do something. Best-effort: if this fails, the enforcement
  /// fallback still brings this device back into line.
  void _sendRequest(
    String action, {
    int? valueMs,
    int? toIndex,
    Map<String, dynamic>? track,
    bool? want,
    String? trackId,
    String? afterId,
    int? execAtMs,
  }) {
    if (state.role != LtRole.guest || _memberRef() == null) return;
    // The dedupe lives here, NOT at one call site.
    //
    // It was in _onGuestPlayerState only, so the TICK path could fire a request
    // the listener path had just sent. Observed on device, 73 ms apart with an
    // identical position:
    //
    //   23:10:42.621 LT guest: requesting "toggle" … (value=29507)
    //   23:10:42.694 LT guest: requesting "toggle" … (value=29507)
    //
    // The host applied both, so the session toggled twice and ended up back
    // where it started, which reads as "my pause did nothing".
    //
    // WHAT COUNTS AS "THE SAME REQUEST" DEPENDS ON THE ACTION.
    //
    // Keying on the whole payload read tidier and reintroduced the double
    // toggle, because a toggle carries the CURRENT POSITION, so two of them
    // milliseconds apart differ, and both got through. Measured on device:
    //
    //   23:53:55.641  guest: requesting "toggle" … (value=20199)
    //   23:53:55.717  guest: requesting "toggle" … (value=19655)
    //   23:53:56.310  host: applying "toggle" → playing=true
    //   23:53:56.348  host: applying "toggle" → playing=false
    //
    // Both applied, session back exactly where it started: "my pause did
    // nothing".
    //
    // For the transport actions the value is incidental — a position stamp the
    // host uses for accuracy, not the intent, so the ACTION alone identifies
    // the request. For a seek or a queue edit the value IS the intent: removing
    // entry 3 and then entry 5 is two legitimate requests, which is what the old
    // flat 700 ms gate silently dropped.
    const positionIsIncidental = {'set_playing', 'toggle', 'next', 'prev'};
    final sig = positionIsIncidental.contains(action)
        ? '$action|$want'
        : '$action|$valueMs|$toIndex|$trackId|$afterId|${track?['id']}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_outbox.any((e) => e['_sig'] == sig)) return;
    if (sig == _lastSentSig && now - _lastSentAtMs < 700) return;
    _outbox.add({
      '_sig': sig,
      'action': action,
      if (valueMs != null) 'valueMs': valueMs,
      if (toIndex != null) 'toIndex': toIndex,
      if (track != null) 'track': track,
      if (want != null) 'want': want,
      if (trackId != null) 'trackId': trackId,
      if (afterId != null) 'afterId': afterId,
      if (execAtMs != null) 'execAtMs': execAtMs,
    });
    _drainOutbox();
  }

  /// One request per document write, spaced out.
  ///
  /// The member document holds a single `request` slot, and Firestore coalesces
  /// rapid writes to one document into a single snapshot — two queue edits 30 ms
  /// apart could reach the host as only the second, silently losing the first.
  /// Spacing the writes is what guarantees every request is its own snapshot and
  /// so gets its own nonce on the host side.
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

  // Listener control of the shared queue
  //
  // Every joined device can edit the queue — the host is the SERIALISER, not a
  // gatekeeper. It applies whatever any listener asks for and re-mirrors the
  // result, which is what keeps two listeners editing at once from producing two
  // different queues. There is no permission check anywhere in here.
  //
  // Each returns true when the edit was handled as a session edit, so the caller
  // must not also apply it locally: these methods already did the local half.
  //
  // THE LOCAL HALF IS WHY AN EDIT LOOKS INSTANT. Request out (~300 ms) → host
  // applies → mirror back (~300 ms) meant a listener tapped remove and watched
  // the row sit there for over half a second. The mirror that comes back is still
  // authoritative, so a host that refuses an edit silently puts the row back:
  // optimistic locally, convergent globally. It touches the mirrored buckets
  // only, never the native engine — on a guest the engine holds just the host's
  // current track.
  //
  // EDITS NAME A TRACK BY ID, NEVER BY INDEX. The two devices do not share an
  // index space: the mirror is a bounded, current-track-first view, while the
  // host holds its full queue. Sending index 4 meant "whatever is fourth on the
  // host", which was a different song — the other half of the sheet behaving
  // oddly. An id means the same track on both.

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

  /// Put [song] directly after [afterSong], or at the front of the upcoming list
  /// when [afterSong] is null.
  /// Move [song] to where [toSong] currently sits. Naming the DESTINATION
  /// TRACK rather than computing an offset is what makes a downward drag land
  /// correctly: ReorderableListView reports newIndex as if the dragged row were
  /// still in the list, so every "+1 / -1" correction was a guess that was right
  /// in one direction and wrong in the other. The host resolves both ids in its
  /// own queue and calls reorderQueue exactly as it would for its own drag, so
  /// there is one set of semantics instead of two.
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

  /// Not applied locally: this changes what is PLAYING, and the host owns that.
  /// Jumping the mirror would show a track as current while this device still
  /// played the old one.
  bool requestQueueJump(Song song) {
    if (state.role != LtRole.guest) return false;
    _sendRequest('queue_jump', trackId: song.id);
    return true;
  }

  /// A listener asking for fresh autoplay. Refreshing locally regenerated only
  /// this device's suggestions, which the next mirror then overwrote — reported as
  /// refresh working on the host and doing nothing on a listener.
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

  /// The buffer barrier
  ///
  /// A guest tells the host it has the new track staged and can start.
  ///
  /// Without this, a track change is a race every device loses differently.
  /// The host moves to the next song and starts playing at once; each guest then
  /// has to resolve its own stream (a player POST, a URL probe, buffering — often
  /// a second or more) and only then starts, already behind, and the drift loop
  /// hard-seeks it forward. Every boundary sounded like a stumble.
  ///
  /// Metrolist solves the same problem with a BUFFER_READY / BUFFER_WAIT /
  /// BUFFER_COMPLETE handshake against its server, and Spotify's Jam behaves the
  /// same way: nobody starts until everyone can. This is that idea on the relay
  /// we already have — the guest reports readiness on its own member document,
  /// and the host holds the new track paused until every present member has
  /// reported it (or [_bufferBarrierMs] passes, so one stuck device cannot hold
  /// the session hostage).
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
      // Bounded: one entry per guest action for the life of a session, and a
      // session is minutes to hours, not days.
      if (_seenRequestNonces.length > 200) _seenRequestNonces.clear();
      _seenRequestNonces.add(nonce);

      final action = req['action']?.toString() ?? '';
      final notifier = _ref.read(playerProvider.notifier);
      print('LT host: applying guest request "$action"');
      switch (action) {
        // IDEMPOTENT ON PURPOSE — 'toggle' WAS NOT, AND THAT WAS A BUG
        // FACTORY. A replayed or duplicated flip inverts the session; a
        // duplicated "be playing" is a no-op. The guest sends the state it
        // wants, not the transition it made, so nothing can land inverted.
        case 'set_playing':
          final want = req['want'] == true;
          // THE LISTENER NAMED THE INSTANT — HONOUR IT, DO NOT RE-PICK ONE.
          //
          // The listener already scheduled itself for that instant and told the
          // other listeners nothing; choosing a new one here would put the host
          // and the asker on different ticks, which is exactly the misalignment
          // scheduling exists to remove. Relaying it unchanged is what makes
          // everyone land together.
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
        // Listener edits to the shared queue
        // Applied to the host's REAL queue, which the _pushNow below re-mirrors,
        // so the edit reaches the listener who made it exactly the way it reaches
        // everyone else and there is only ever one queue.
        //
        // TRACKS ARE RESOLVED BY ID, NOT BY THE INDEX THE GUEST SAW. The
        // guest's mirror is a bounded, current-track-first view of a queue the
        // host holds in full, so the two index spaces do not line up; an index
        // named a different song here than the listener touched. Resolving by id
        // also fails SAFELY when the queue has moved on: the track is simply not
        // found, rather than the wrong one being removed.
        case 'queue_add':
        case 'queue_next':
          final t = req['track'];
          if (t is! Map) continue;
          final song = Song.fromMap(Map<String, dynamic>.from(t));
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
          final pt = req['track'];
          if (pt is! Map) continue;
          notifier.playSong(Song.fromMap(Map<String, dynamic>.from(pt)),
              source: 'Listen Together');
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
        _ref.read(playerProvider.notifier).setSpeed(1.0);
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
