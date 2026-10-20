import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/logic/playback_handoff.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/device_info_service.dart';
import 'package:auvy/services/listening_policy.dart';

/// One of your other phones, as it last described itself.
class AuvyLiveDevice {
  final String id;
  final String name;
  final String platform;
  final bool playing;
  final String title;
  final String artist;
  final String image;
  final int positionMs;
  final int durationMs;

  /// When [positionMs] was true (its clock), so progress can be extrapolated.
  final int atMs;
  final int updatedMs;

  /// Enough to pick the song up here: a PlaybackHandoff as JSON.
  final Map<String, dynamic>? handoff;

  /// In a private session there: playing, but not saying what.
  final bool private;

  /// It answered while this phone's device list was open, so Auvy is running
  /// there and takes commands. A phone that didn't is shown as last seen.
  final bool here;

  /// The install it came from (see DevicePresenceService.installKey). Empty
  /// for an entry an older build wrote.
  final String install;

  const AuvyLiveDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.playing,
    required this.title,
    required this.artist,
    required this.image,
    required this.positionMs,
    required this.durationMs,
    required this.atMs,
    required this.updatedMs,
    this.handoff,
    this.private = false,
    this.here = false,
    this.install = '',
  });

  bool get hasSong => title.isNotEmpty;

  AuvyLiveDevice withHere(bool value) => AuvyLiveDevice(
      id: id, name: name, platform: platform, playing: playing, title: title, artist: artist,
      image: image, positionMs: positionMs, durationMs: durationMs, atMs: atMs,
      updatedMs: updatedMs, handoff: handoff, private: private, here: value,
      install: install);

  /// Playing right now: it said so, and the song it said so about hasn't run
  /// out (a phone that was killed can't say it stopped).
  bool playingAt(int nowMs) {
    if (!playing) return false;
    if (durationMs <= 0) return nowMs - updatedMs < const Duration(minutes: 15).inMilliseconds;
    return nowMs < atMs + (durationMs - positionMs) + 30000;
  }

  /// From a device document. Everything but the timestamps is sealed with the
  /// account's key (see DevicePresenceService); a document that doesn't open is
  /// skipped, never shown half-read.
  static AuvyLiveDevice? fromDoc(String id, Map<String, dynamic>? doc) {
    if (doc == null) return null;
    final opened = CloudSyncService.instance.openSmall(DevicePresenceService.presenceSlot, doc['sealed']);
    if (opened == null) return null;
    Map<String, dynamic> d;
    try {
      final j = jsonDecode(opened);
      if (j is! Map) return null;
      d = Map<String, dynamic>.from(j);
    } catch (_) {
      return null;
    }
    int i(Object? v) => v is num ? v.toInt() : 0;
    String t(Object? v, int max) {
      final s = (v ?? '').toString();
      return s.length > max ? s.substring(0, max) : s;
    }
    final h = d['handoff'];
    return AuvyLiveDevice(
      id: id,
      name: t(d['name'], 64),
      platform: t(d['platform'], 16),
      playing: d['playing'] == true,
      title: t(d['title'], 200),
      artist: t(d['artist'], 200),
      image: t(d['image'], 1024),
      positionMs: i(d['positionMs']),
      durationMs: i(d['durationMs']),
      atMs: i(d['atMs']),
      updatedMs: i(doc['updatedMs']),
      handoff: h is Map ? Map<String, dynamic>.from(h) : null,
      private: d['private'] == true,
      install: t(d['install'], 64),
    );
  }
}

/// What this phone is playing, as the player last broadcast it.
@immutable
class AuvyPresenceState {
  final bool hasSong;
  final bool playing;
  final bool private;
  final String songId;
  final String title;
  final String artist;
  final String image;
  final int positionMs;
  final int durationMs;

  /// When [positionMs] was read (this phone's clock).
  final int atMs;

  const AuvyPresenceState({
    required this.hasSong,
    required this.playing,
    required this.private,
    required this.songId,
    required this.title,
    required this.artist,
    required this.image,
    required this.positionMs,
    required this.durationMs,
    required this.atMs,
  });

  /// While playing, the moment the song "started" holds still (only a seek moves
  /// it); while paused, the position does.
  int get anchorMs => playing ? atMs - positionMs : positionMs;
}

/// Your phones, live, and control across them (Spotify Connect style).
///
/// Built so that it costs next to nothing when nobody is looking, because the
/// free Firestore quota is shared by every user of the app:
///
/// * Each running phone listens to ONE small shared document,
///   `user_backups/<account>/live/control`. It changes only when someone opens
///   the output sheet (and once a minute while it stays open) or sends a
///   command, so it costs one read per phone per such change.
/// * A phone writes its own document, `user_backups/<account>/devices/<id>`,
///   only while another phone has the output sheet open: once when the sheet
///   opens, then on a real change (a new song, play, pause, a seek), at most
///   every 3 s. Nothing is written while nobody looks, however much is played.
/// * The phone with the sheet open listens to the devices collection only while
///   it is open.
///
/// Everything but timestamps is sealed with the backup's key; see the
/// guards on [_maybeRunCommand]. Reads and writes are counted and logged per
/// viewing (`connect: …`). Inside the account's private area, so the backup's
/// security rule covers it. A phone acts on commands only while Auvy runs
/// there (in front, or playing in the background).
class DevicePresenceService {
  DevicePresenceService._();
  static final DevicePresenceService instance = DevicePresenceService._();

  /// The GCM slot the device payloads are bound to (and, per target device,
  /// commands): a sealed value only opens in the slot it was sealed for.
  static const String presenceSlot = 'presence:v1';
  static String commandSlot(String deviceId) => 'command:v1:$deviceId';

  /// The only commands another phone may send. Anything else is dropped.
  static const Set<String> allowedCommands = {'play', 'pause', 'next', 'previous', 'takeOver'};

  /// The other phones on this account, newest first, at most [maxListed].
  /// Filled only while the device list is open ([startWatching]).
  final ValueNotifier<List<AuvyLiveDevice>> others = ValueNotifier(const []);
  static const int maxListed = 10;

  /// Runs a command another phone sent (AuvyAudioHandler wires it to AppCommands).
  Future<void> Function(String name, Map<String, dynamic> args)? onCommand;

  /// How long one "someone is looking" lasts, and how often an open sheet
  /// renews it. A sheet closed without saying so stops costing within this.
  static const Duration watchWindow = Duration(seconds: 90);
  static const Duration watchRenewEvery = Duration(seconds: 60);

  /// At most one write per phone this often while watched (a burst of skips or
  /// seeks is one write).
  static const int minWriteGapMs = 3000;

  /// Whether [now] differs from what was last published enough for another
  /// phone to show it differently: a new song, play or pause, a private session,
  /// a seek (the anchor moved more than 4 s; the player folds its position in
  /// about once a second, so smaller moves are only that), or a length that
  /// arrived late.
  static bool stateChanged(AuvyPresenceState? published, AuvyPresenceState now) {
    if (published == null) return true;
    if (published.hasSong != now.hasSong ||
        published.playing != now.playing ||
        published.private != now.private ||
        published.songId != now.songId) {
      return true;
    }
    if ((published.durationMs - now.durationMs).abs() > 2000) return true;
    return (published.anchorMs - now.anchorMs).abs() > 4000;
  }

  // ── State ──

  String? _myId;
  AuvyPresenceState? _latest;
  AuvyPresenceState? _published;

  String? _controlPath;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _controlSub;
  bool _controlBaseline = true;
  final Map<String, int> _watchSeen = {};

  /// Until when another phone is looking (this phone's clock: a renewal seen
  /// here opens [watchWindow] from the moment it arrives, so clocks that
  /// disagree between phones don't matter).
  int _watchedUntilMs = 0;
  Timer? _watchEndTimer;
  int _watchedSinceMs = 0;
  int _writesAtWatched = 0;

  Timer? _flushTimer;
  int _lastWriteMs = 0;
  bool _saidNoKey = false;
  final List<String> _handled = [];
  final List<int> _recentCommandMs = [];

  // This phone's own device list.
  bool _watching = false;
  int _watchStartedMs = 0;
  int _lastWatchWriteMs = 0;
  Timer? _watchRenewTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _devicesSub;
  QuerySnapshot<Map<String, dynamic>>? _lastSnap;
  Map<String, int>? _baseline;
  final Set<String> _hereIds = {};

  // Counted for the log, so the cost of the feature is visible.
  int _writes = 0;
  int _reads = 0;
  int _writesAtOpen = 0;
  int _readsAtOpen = 0;

  Timer? _retryTimer;
  int _retries = 0;

  DocumentReference<Map<String, dynamic>>? get _account => CloudSyncService.instance.accountDoc;
  CollectionReference<Map<String, dynamic>>? get _devices => _account?.collection('devices');
  DocumentReference<Map<String, dynamic>>? get _control => _account?.collection('live').doc('control');

  Future<String> _deviceId() async => _myId ??= await CloudSyncService.instance.deviceId();

  /// A random id for this install, kept across sign-outs (unlike the device id,
  /// which a sign-out replaces), so the phone can tell its own older entries
  /// apart from a different phone's. Only ever stored inside the sealed entry.
  static const String installKey = 'auvy_install_id';
  String? _install;

  Future<String> _installId() async {
    final known = _install;
    if (known != null) return known;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(installKey) ?? '';
      if (id.isEmpty) {
        final r = math.Random.secure();
        id = List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
        await prefs.setString(installKey, id);
      }
      return _install = id;
    } catch (_) {
      return '';
    }
  }

  /// Whether an entry is this phone's own, from before its id changed (a
  /// sign-out and sign-in, a reinstall): the same install, or, for an entry an
  /// older build wrote without one, this phone's own name on this platform.
  /// Such entries listed the phone as another device for a week.
  @visibleForTesting
  static bool isOwnOldEntry(AuvyLiveDevice d,
      {required String myInstall, required String myName, required String myPlatform}) {
    if (d.install.isNotEmpty) return myInstall.isNotEmpty && d.install == myInstall;
    return myName.isNotEmpty && d.name == myName && d.platform == myPlatform;
  }

  /// One entry per phone, the newest, from a list sorted newest first.
  ///
  /// A phone whose id changed leaves its old entry behind until it removes it
  /// itself (see isOwnOldEntry), and meanwhile the account's other phones
  /// listed it twice (the same phone, one entry hours old). The
  /// same install is the same phone; an entry an older build wrote has no
  /// install, so it is the same phone as a newer entry with its name and
  /// platform. Two phones of one model with their own installs both stay.
  @visibleForTesting
  static List<AuvyLiveDevice> newestPerPhone(List<AuvyLiveDevice> newestFirst) {
    final out = <AuvyLiveDevice>[];
    for (final d in newestFirst) {
      final dup = out.any((o) => d.install.isNotEmpty
          ? o.install == d.install
          : o.name == d.name && o.platform == d.platform);
      if (!dup) out.add(d);
    }
    return out;
  }

  /// This phone's older entries already being removed, so each is deleted once.
  final Set<String> _dropping = {};

  Future<void> _dropOwnOldEntries(List<String> ids) async {
    final col = _devices;
    if (col == null) return;
    for (final id in ids) {
      if (!_dropping.add(id)) continue;
      try {
        await col.doc(id).delete();
        _writes++;
        print('connect: removed an older entry of this phone from your device list');
      } catch (e) {
        print('connect: could not remove an older entry of this phone ($e)');
      }
    }
  }

  /// When the device list opened, for the sheet's "Checking…".
  int get watchStartedMs => _watchStartedMs;

  // ── Publishing this phone ──

  /// What this phone is doing now. Called with every player broadcast; costs
  /// nothing unless another phone is looking and something it would show has
  /// changed.
  void publish({
    required bool hasSong,
    required bool playing,
    required String songId,
    required String title,
    required String artist,
    required String image,
    required int positionMs,
    required int durationMs,
  }) {
    _latest = AuvyPresenceState(
      hasSong: hasSong,
      playing: playing && hasSong,
      private: ListeningPolicy.privateSession,
      songId: songId,
      title: title,
      artist: artist,
      image: image,
      positionMs: positionMs,
      durationMs: durationMs,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!_ensureControl()) return;
    if (!_isWatched) return;
    if (stateChanged(_published, _latest!)) _scheduleFlush();
  }

  bool get _isWatched => DateTime.now().millisecondsSinceEpoch < _watchedUntilMs;

  void _scheduleFlush({int soonestMs = 1000}) {
    if (_flushTimer?.isActive ?? false) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = math.max(soonestMs, _lastWriteMs + minWriteGapMs - now);
    _flushTimer = Timer(Duration(milliseconds: wait), _flush);
  }

  Future<void> _flush() async {
    final col = _devices;
    final s = _latest;
    if (col == null || s == null || !_isWatched) return;
    try {
      final id = await _deviceId();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Where it has got to by now, not where the last broadcast said.
      final pos = s.playing ? s.positionMs + (now - s.atMs) : s.positionMs;
      final data = <String, Object?>{
        'name': DeviceInfoService.currentDeviceName,
        'platform': Platform.operatingSystem,
        'install': await _installId(),
        'playing': s.playing,
        'private': s.private,
        'title': s.hasSong && !s.private ? s.title : '',
        'artist': s.hasSong && !s.private ? s.artist : '',
        'image': s.hasSong && !s.private && s.image.startsWith('https://') ? s.image : '',
        'positionMs': pos,
        'durationMs': s.durationMs,
        'atMs': now,
      };
      if (!s.private) {
        final handoff = await CloudSyncService.handoffSnapshot?.call();
        if (handoff != null) data['handoff'] = await _trimmedHandoff(handoff);
      }
      var plain = jsonEncode(data);
      // A song with a huge queue entry: the queue goes, the song stays.
      if (plain.length > 48 * 1024) {
        data.remove('handoff');
        plain = jsonEncode(data);
      }
      final sealed = CloudSyncService.instance.sealSmall(presenceSlot, plain);
      if (sealed == null) {
        // No key: nothing readable is ever stored, so nothing goes up.
        if (!_saidNoKey) {
          _saidNoKey = true;
          print('connect: no backup key yet, so this phone is not shown to your others');
        }
        return;
      }
      _published = s;
      _lastWriteMs = now;
      _writes++;
      // No server timestamp: resolving one changes the document again on the
      // server, which every listener would read a second time.
      await col.doc(id).set({
        'sealed': sealed,
        'updatedMs': now,
      });
    } catch (e) {
      print('connect: could not publish this phone ($e)');
    }
    // Something changed again while that was written.
    final latest = _latest;
    if (latest != null && _isWatched && stateChanged(_published, latest)) _scheduleFlush();
  }

  /// Takes this phone off the account's device list, on sign-out, while it is
  /// still signed in (the list belongs to the account). The entry used to stay
  /// for a week, and the phone signing back in, with a new id, got a second
  /// one beside it, so the phone listed itself as another device. Sign-in
  /// publishes a fresh one as usual.
  Future<void> leave() async {
    final col = _devices;
    try {
      if (col != null) {
        final id = await _deviceId();
        await col.doc(id).delete();
        _writes++;
        print('connect: this phone left your device list (signing out)');
      }
    } catch (e) {
      print('connect: could not take this phone off your device list ($e)');
    } finally {
      _stopAll();
    }
  }

  /// The handoff stamped with this phone, with a shorter queue: ten songs is
  /// plenty to carry on with, and keeps each write small.
  Future<Map<String, dynamic>> _trimmedHandoff(Map<String, dynamic> h) async {
    final next = h['next'];
    return {
      ...h,
      'device': await _deviceId(),
      'name': DeviceInfoService.currentDeviceName,
      if (next is List) 'next': next.take(10).toList(),
    };
  }

  // ── The shared control document ──

  /// Listening to the control document (one per account). False while cloud
  /// sync isn't signed in; tried again shortly.
  bool _ensureControl() {
    final control = _control;
    if (control == null) {
      if (_controlSub != null) _stopAll();
      _retryLater();
      return false;
    }
    _retries = 0;
    if (_controlPath == control.path && _controlSub != null) return true;
    _stopAll();
    _controlPath = control.path;
    _controlBaseline = true;
    _controlSub = control.snapshots().listen(_onControl, onError: (Object e) {
      print('connect: lost the control document ($e)');
      _controlSub = null;
    });
    return true;
  }

  Future<void> _onControl(DocumentSnapshot<Map<String, dynamic>> snap) async {
    if (!snap.metadata.isFromCache && !snap.metadata.hasPendingWrites) _reads++;
    final me = await _deviceId();
    final data = snap.data() ?? const <String, dynamic>{};
    final baseline = _controlBaseline;
    _controlBaseline = false;

    // Another phone looking. A renewal opens the window from when it arrives
    // here. The first snapshot (Auvy just started) can only use the stamp
    // itself, so a sheet already open elsewhere still counts.
    final watch = data['watch'];
    if (watch is Map) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final e in watch.entries) {
        final id = e.key.toString();
        final until = e.value is num ? (e.value as num).toInt() : 0;
        final before = _watchSeen[id];
        _watchSeen[id] = until;
        if (id == me) continue;
        if (baseline) {
          if (until > now) _watched(math.min(until, now + watchWindow.inMilliseconds));
        } else if (before == null || until > before) {
          _watched(now + watchWindow.inMilliseconds);
        }
      }
    }

    final cmds = data['cmd'];
    if (cmds is Map) {
      final c = cmds[me];
      if (c is Map) {
        // Already there when Auvy started: sent to a phone that wasn't running,
        // so not for now.
        if (baseline) {
          final id = (c['id'] ?? '').toString();
          if (id.isNotEmpty) _handled.add(id);
        } else {
          await _maybeRunCommand(me, c);
        }
      }
    }
  }

  void _watched(int untilMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final starting = now >= _watchedUntilMs;
    _watchedUntilMs = math.max(_watchedUntilMs, untilMs);
    _watchEndTimer?.cancel();
    _watchEndTimer = Timer(Duration(milliseconds: _watchedUntilMs - now + 50), _watchEnded);
    if (starting) {
      _watchedSinceMs = now;
      _writesAtWatched = _writes;
      // Say where this phone is now, even if nothing changes while looked at.
      _published = null;
      if (_latest != null) _scheduleFlush(soonestMs: 300);
    }
  }

  void _watchEnded() {
    if (_isWatched) return;
    final secs = ((DateTime.now().millisecondsSinceEpoch - _watchedSinceMs) / 1000).round();
    print('connect: shown to your other device for ${secs}s, '
        '${_writes - _writesAtWatched} write(s) (this session $_writes write(s), $_reads read(s))');
  }

  // ── This phone's device list (the output sheet) ──

  /// The output sheet opened: other running phones are asked to say what they
  /// play, and the list follows them until [stopWatching].
  Future<void> startWatching() async {
    final devices = _devices;
    if (devices == null || !_ensureControl()) return;
    if (_watching) return;
    _watching = true;
    // Known before the list is first built, so this phone's older entries are
    // recognised (see isOwnOldEntry).
    await _installId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _baseline = null;
    _writesAtOpen = _writes;
    _readsAtOpen = _reads;
    // Reopened within half a minute: the other phones are still in the last
    // viewing's window, so it carries on (no write) and so do its answers.
    if (now - _lastWatchWriteMs > 30000) {
      _watchStartedMs = now;
      _hereIds.clear();
      await _renewWatch();
      if (!_watching) return;
    }
    // Renewed a minute after the last renewal, whenever that was (a reopened
    // list carries on the last viewing's).
    _watchRenewTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().millisecondsSinceEpoch - _lastWatchWriteMs >= watchRenewEvery.inMilliseconds) {
        _renewWatch();
      }
    });
    _devicesSub = devices.snapshots().listen((snap) async {
      // What the server sent; this phone's own unsent writes cost nothing.
      if (!snap.metadata.isFromCache && !snap.metadata.hasPendingWrites) {
        _reads += snap.docChanges.length;
      }
      _lastSnap = snap;
      await _deviceId();
      final base = _baseline;
      if (base == null) {
        _baseline = {for (final d in snap.docs) d.id: (d.data()['updatedMs'] as num?)?.toInt() ?? 0};
        // A phone can answer before this first snapshot arrives; written since
        // the list opened (give or take two phones' clocks) is an answer too.
        for (final e in _baseline!.entries) {
          if (e.value >= _watchStartedMs - 2000) _hereIds.add(e.key);
        }
      } else {
        for (final d in snap.docs) {
          final updated = (d.data()['updatedMs'] as num?)?.toInt() ?? 0;
          if (updated != (base[d.id] ?? -1)) _hereIds.add(d.id);
        }
      }
      _relist();
    }, onError: (Object e) {
      print('connect: lost the device list ($e)');
    });
  }

  void stopWatching() {
    if (!_watching) return;
    _watching = false;
    _watchRenewTimer?.cancel();
    _watchRenewTimer = null;
    _devicesSub?.cancel();
    _devicesSub = null;
    _lastSnap = null;
    final secs = ((DateTime.now().millisecondsSinceEpoch - _watchStartedMs) / 1000).round();
    print('connect: device list was open ${secs}s, ${_writes - _writesAtOpen} write(s), '
        '${_reads - _readsAtOpen} read(s) (this session $_writes write(s), $_reads read(s))');
  }

  Future<void> _renewWatch() async {
    final control = _control;
    if (control == null) return;
    try {
      final me = await _deviceId();
      _writes++;
      _lastWatchWriteMs = DateTime.now().millisecondsSinceEpoch;
      await control.set({
        'watch': {me: _lastWatchWriteMs + watchWindow.inMilliseconds},
      }, SetOptions(merge: true));
    } catch (e) {
      print('connect: could not ask your other devices ($e)');
    }
  }

  /// The other phones from the last snapshot, those that open with this
  /// account's key and were used this week, newest first.
  void _relist() {
    final snap = _lastSnap;
    final me = _myId;
    if (snap == null || me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = <AuvyLiveDevice>[];
    final ownOld = <String>[];
    final myInstall = _install ?? '';
    for (final doc in snap.docs) {
      if (doc.id == me) continue;
      final d = AuvyLiveDevice.fromDoc(doc.id, doc.data());
      if (d == null) continue;
      // This phone under an older id: removed, not listed (see isOwnOldEntry).
      if (isOwnOldEntry(d,
          myInstall: myInstall,
          myName: DeviceInfoService.currentDeviceName,
          myPlatform: Platform.operatingSystem)) {
        ownOld.add(doc.id);
        continue;
      }
      if (now - d.updatedMs > const Duration(days: 7).inMilliseconds) continue;
      list.add(d.withHere(_hereIds.contains(doc.id)));
    }
    if (ownOld.isNotEmpty) unawaited(_dropOwnOldEntries(ownOld));
    list.sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
    others.value = newestPerPhone(list).take(maxListed).toList();
  }

  void _stopAll() {
    _controlSub?.cancel();
    _controlSub = null;
    _controlPath = null;
    _watchSeen.clear();
    _watchedUntilMs = 0;
    _watchEndTimer?.cancel();
    _flushTimer?.cancel();
    _published = null;
    // Another account has another id here.
    _myId = null;
    if (_watching) stopWatching();
    if (others.value.isNotEmpty) others.value = const [];
  }

  /// Trying the control document again a little later, for a phone idle at
  /// startup before sign-in finished. Twenty tries, then the next broadcast
  /// starts it again.
  void _retryLater() {
    // No Firebase at all (a build without it, or a test): nothing to wait for.
    if (!CloudSyncService.isAvailable || _retryTimer != null || _retries >= 20) return;
    _retries++;
    _retryTimer = Timer(const Duration(seconds: 15), () {
      _retryTimer = null;
      _ensureControl();
    });
  }

  // ── Commands ──

  /// A command another phone left for this one. Guards, in order: run once (by
  /// id); under a minute old (either clock); sealed for THIS phone or dropped; a
  /// known command or dropped; no more than six in ten seconds; a take-over
  /// carries a readable song. Never cleared: the next command replaces it, and
  /// the id and age keep it from running twice.
  Future<void> _maybeRunCommand(String me, Map<dynamic, dynamic> c) async {
    final id = (c['id'] ?? '').toString();
    if (id.isEmpty || id.length > 64 || _handled.contains(id)) return;
    _handled.add(id);
    if (_handled.length > 50) _handled.removeAt(0);
    final now = DateTime.now().millisecondsSinceEpoch;
    final at = (c['atMs'] as num?)?.toInt() ?? 0;
    if ((now - at).abs() > 60000) {
      print('connect: dropped a command older than a minute');
      return;
    }
    final opened = CloudSyncService.instance.openSmall(commandSlot(me), c['sealed']);
    if (opened == null) {
      print('connect: dropped a command that did not open with this account\'s key');
      return;
    }
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(opened) as Map);
    } catch (_) {
      return;
    }
    final name = (body['name'] ?? '').toString();
    if (!allowedCommands.contains(name)) {
      print('connect: dropped an unknown command');
      return;
    }
    _recentCommandMs.removeWhere((t) => now - t > 10000);
    if (_recentCommandMs.length >= 6) {
      print('connect: dropped a command (more than six in ten seconds)');
      return;
    }
    _recentCommandMs.add(now);
    final args = body['args'] is Map ? Map<String, dynamic>.from(body['args'] as Map) : <String, dynamic>{};
    if (name == 'takeOver' && PlaybackHandoff.fromJson(args['handoff']) == null) {
      print('connect: dropped a take-over without a readable song');
      return;
    }
    print('connect: "$name" from ${(body['fromName'] ?? 'another phone').toString()}');
    await onCommand?.call(name, {...args, 'from': 'connect'});
  }

  /// Sends [name] to [deviceId], sealed for that phone alone. False when cloud
  /// sync isn't signed in, there is no key, or the write fails.
  Future<bool> send(String deviceId, String name, [Map<String, dynamic> args = const {}]) async {
    final control = _control;
    if (control == null || !allowedCommands.contains(name)) return false;
    try {
      final me = await _deviceId();
      final now = DateTime.now().millisecondsSinceEpoch;
      final sealed = CloudSyncService.instance.sealSmall(
          commandSlot(deviceId),
          jsonEncode({'name': name, 'args': args, 'fromName': DeviceInfoService.currentDeviceName}));
      if (sealed == null) return false;
      _writes++;
      await control.set({
        'cmd': {
          deviceId: {'id': '$me-$now', 'sealed': sealed, 'atMs': now},
        },
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      print('connect: could not reach that phone ($e)');
      return false;
    }
  }

  // ── Moving playback ──

  /// This phone's playback as a handoff, for moving it to another phone.
  Future<Map<String, dynamic>?> currentHandoff() async {
    if (ListeningPolicy.privateSession) return null;
    final h = await CloudSyncService.handoffSnapshot?.call();
    return h == null ? null : _trimmedHandoff(h);
  }

  /// Moves this phone's playback to [to]: it plays from here on, this phone
  /// pauses. Null when it went, otherwise why not.
  Future<String?> sendPlaybackTo(AuvyLiveDevice to, {required Future<void> Function() pauseHere}) async {
    if (ListeningPolicy.privateSession) return 'Not during a private session';
    final h = await currentHandoff();
    if (h == null) return 'Nothing to send';
    // Carried on from this moment, playing, whatever this phone was doing.
    final at = DateTime.now().millisecondsSinceEpoch;
    final sent = await send(to.id, 'takeOver', {
      'handoff': {...h, 'at': at, 'playing': true},
    });
    if (!sent) return "Couldn't reach ${to.name}";
    await pauseHere();
    return null;
  }

  /// Brings [from]'s playback here: [takeOver] plays it on this phone, then
  /// that phone is asked to pause. Null when it came, otherwise why not.
  Future<String?> bringPlaybackFrom(AuvyLiveDevice from,
      {required Future<bool> Function(Map<String, dynamic> handoff) takeOver}) async {
    final saved = from.handoff;
    if (saved == null || PlaybackHandoff.fromJson(saved) == null) return 'Nothing to bring over';
    final playingThere = from.playingAt(DateTime.now().millisecondsSinceEpoch);
    // Said "playing" but its song ran out long ago: Auvy was closed there
    // mid-song, so it is taken where it stopped, not walked on through hours of
    // queue.
    final h = playingThere ? saved : {...saved, 'playing': false};
    if (!await takeOver(h)) return "Couldn't play it here";
    if (playingThere) await send(from.id, 'pause');
    return null;
  }

  /// Where a handed-over song should start now (it kept moving while it played).
  static int positionNow(Map<String, dynamic> handoff, int nowMs) {
    final h = PlaybackHandoff.fromJson(handoff);
    if (h == null) return 0;
    return handoffTarget(h, nowMs).positionMs;
  }
}
