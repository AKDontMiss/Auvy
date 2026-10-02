import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An on-device recorder for Auvy's own diagnostic log, so issues that happen
/// away from a USB cable (on a commute, overnight) can still be diagnosed.
///
/// It taps the print Zone in main.dart, which every `print()` passes through, so
/// nothing changes at call sites and nothing can be forgotten.
///
/// Lines go into a memory buffer that a timer flushes to disk every few seconds;
/// only the flush touches the filesystem, never a write per line.
class ActivityLog {
  ActivityLog._();
  static final ActivityLog instance = ActivityLog._();

  /// Persisted, so the recorder survives a restart with the state the user chose.
  /// OFF by default: a diagnostic that turns itself on is a diagnostic nobody
  /// consented to.
  static const String _kEnabledPref = 'auvy_activity_log_enabled';

  /// How much history to keep, across two files: two 3 MB files, so the latest
  /// ~6 MB of lines is available and never more (days of normal use). Bounded like
  /// the audio cache, image cache and history.
  static const int _maxBytesPerFile = 3 * 1024 * 1024;

  /// Flush cadence. Long enough that a burst of lines is one write; short enough
  /// that a crash loses seconds, not minutes.
  static const Duration _flushEvery = Duration(seconds: 5);

  /// A hard cap on the in-memory buffer, so a runaway loop cannot exhaust memory
  /// between flushes. Dropping the OLDEST is deliberate: when something is
  /// spinning, the newest lines are the ones that explain it.
  static const int _maxBufferedLines = 4000;

  bool _enabled = false;
  bool _started = false;
  final List<String> _buffer = [];
  Timer? _flushTimer;
  File? _current;
  int _droppedLines = 0;

  bool get isEnabled => _enabled;

  /// Reads the saved switch and starts recording if it's on. Called from main()
  /// before the app runs, so the first lines of a launch are captured too.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabledPref) ?? false;
    } catch (_) {
      // A prefs failure must not stop the app booting; recording simply stays off.
      _enabled = false;
    }
    if (_enabled) await _open();
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledPref, on);
    } catch (_) {}
    if (on) {
      await _open();
      add('activity log started');
    } else {
      add('activity log stopped');
      await flush();
      _flushTimer?.cancel();
      _flushTimer = null;
    }
  }

  /// Record one line. Called from the print Zone — must never throw and must
  /// never await.
  void add(String line) {
    if (!_enabled) return;
    if (_buffer.length >= _maxBufferedLines) {
      _buffer.removeAt(0);
      _droppedLines++;
    }
    _buffer.add('${stamp()} ${redact(line)}');
    _flushTimer ??= Timer.periodic(_flushEvery, (_) => flush());
  }

  /// The timestamp is the whole point.
  ///
  /// Ordering alone would not have found today's bugs. "two requests 73 ms
  /// apart", "the guest echoed 2 ms after applying", "executed 1 ms off the
  /// instant" — every one of those was a millisecond comparison. Local time with
  /// milliseconds, so a line here lines up with a line from logcat.
  @visibleForTesting
  static String stamp() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}:'
        '${p(n.second)}.${p(n.millisecond, 3)}';
  }

  /// Redaction is mandatory: this file exists to be shared, and log lines can
  /// carry things that shouldn't leave the device (the backup identity hash names
  /// the account, and an exception can quote whatever it was handling).
  ///
  /// Long hex ids are shortened, not removed, so two accounts can still be told
  /// apart in a timeline. Anything that looks like a token or cookie is removed
  /// entirely.
  static String redact(String line) {
    var s = line;

    // Whole-credential shapes first, before anything shortens part of them;
    // otherwise credentials that aren't `key=value` or plain hex (or are hex plus a
    // signature) slip through.

    // The Worker's app token: `<64 hex uid>.<expiry>.<signature>`. The hex rule
    // below would shorten the uid and leave the SIGNATURE, which is the part
    // that makes it a working bearer credential.
    s = s.replaceAll(
        RegExp(r'\b[0-9a-f]{64}\.\d{9,11}\.[A-Za-z0-9_-]{20,}', caseSensitive: false),
        '[app token redacted]');

    // JWTs — Firebase ID and custom tokens.
    s = s.replaceAll(
        RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
        '[jwt redacted]');

    // A whole Cookie header or cookie list, once it is clearly `name=value`
    // pairs. The key/value rule further down stops at the first space, so it
    // took the first cookie and left every one after it. The lookahead keeps
    // ordinary lines ("Cookies are valid …") untouched.
    s = s.replaceAllMapped(
        RegExp(r'\b(set-cookie|cookies?)(\s*[:=]\s*)(?=[^\s=;]+=).*$',
            caseSensitive: false),
        (m) => '${m[1]}${m[2]}[redacted]');

    // Google's session cookies by NAME, wherever they appear. `__Secure-1PSID`
    // and `__Secure-3PSID` ARE the session; nothing above knew them.
    s = s.replaceAllMapped(
        RegExp(
            r'\b((?:__Secure-[0-9A-Za-z-]+|__Host-[0-9A-Za-z-]+|SID|HSID|SSID|APISID|SAPISID|LSID|SIDCC|LOGIN_INFO)=)[^;\s]+'),
        (m) => '${m[1]}[redacted]');

    // Signed URLs carry the listener's IP address and a signature in the query:
    // googlevideo streams (`sig`, `lsig`, `pot`), and podcast and paid media
    // (`token-hash`, `auth`, `Signature`, `X-Amz-Credential`), whose signature is
    // access to paid content. Matched by what the parameter name says, not by a
    // fixed list, so a host's own spelling is still caught. The URL shape stays.
    s = s.replaceAllMapped(
        RegExp(
            r'([?&](?:ip|[\w.-]*(?:sig|signature|token|hash|key|auth|credential|policy|secret|password|session|pot)[\w.-]*)=)[^&\s]+',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]');

    // Long token-like pieces of a URL's path. Some private podcast feeds put the
    // subscriber's access token in the path rather than the query (and episode
    // URLs are logged as the track id), which the parameter rule above can't see.
    // A piece of 24+ letters, digits, '-' or '_' with both letters and digits is
    // treated as one; ordinary words and short ids (an 11-character video id)
    // stay readable. The host and the rest of the path stay.
    s = s.replaceAllMapped(RegExp('https?://[^\\s"\'<>]+'), (m) {
      final url = m[0]!;
      final cut = url.indexOf('/', url.indexOf('//') + 2);
      if (cut < 0) return url;
      final path = url.substring(cut).replaceAllMapped(
          RegExp(r'[A-Za-z0-9_-]{24,}'),
          (p) => RegExp(r'[0-9]').hasMatch(p[0]!) && RegExp(r'[A-Za-z]').hasMatch(p[0]!)
              ? '[id]'
              : p[0]!);
      return url.substring(0, cut) + path;
    });

    // The app's install folder on iOS is named by a per-install UUID; it links
    // logs from one install together and says nothing useful.
    s = s.replaceAllMapped(
        RegExp(r'(/Containers/(?:Data|Bundle|Shared/AppGroup)/Application/)[0-9A-Fa-f-]{36}'),
        (m) => '${m[1]}<app>');

    // Bare IPv4 addresses: the network, not the device.
    s = s.replaceAllMapped(
        RegExp(r'\b((?:25[0-5]|2[0-4]\d|1?\d?\d)\.(?:25[0-5]|2[0-4]\d|1?\d?\d))\.(?:25[0-5]|2[0-4]\d|1?\d?\d)\.(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'),
        (m) => '${m[1]}.x.x');

    // Backup keys / identity hashes: 40+ hex chars.
    s = s.replaceAllMapped(
        RegExp(r'\b[0-9a-f]{40,}\b', caseSensitive: false),
        (m) => '${m[0]!.substring(0, 8)}…[${m[0]!.length} hex]');

    // The scheme rule runs first: with the key/value rule first,
    // `Authorization: Token abc123def456` had the word "Token" replaced and kept the
    // secret. replaceAllMapped, because Dart's replaceAll doesn't expand `$1`.
    s = s.replaceAllMapped(
        RegExp(r'\b(Bearer|Token)\s+\S+', caseSensitive: false),
        (m) => '${m[1]} [redacted]');

    // Anything self-described as a secret. `\S+` on purpose: a value with spaces
    // is not a credential shape, and consuming to end-of-line would swallow the
    // diagnostic context that makes the line worth keeping.
    s = s.replaceAllMapped(
        RegExp(
            r'((?:token|cookie|secret|password|api[_-]?key|authorization|sapisid)\s*[:=]\s*)(\S+)',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]');

    // Email addresses: the one identifier here that names a person rather than a
    // session. The local part is masked, not dropped, so different accounts still
    // look different. A bare `@handle` is a public channel name and is left alone.
    s = s.replaceAllMapped(
        RegExp(r'\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b'),
        (m) {
          final local = m[1]!;
          final head = local.length <= 2 ? local : local.substring(0, 2);
          return '$head***@${m[2]}';
        });
    return s;
  }

  Future<void> _open() async {
    if (_current != null) return;
    try {
      final dir = await _logDir();
      _current = File('${dir.path}/activity.log');
      if (!await _current!.exists()) {
        await _current!.create(recursive: true);
      }
      _flushTimer ??= Timer.periodic(_flushEvery, (_) => flush());
    } catch (e) {
      // No file, no recording, but the app carries on.
      _current = null;
      if (kDebugMode) print('WARN: activity log could not open its file: $e');
    }
  }

  /// App-private, and therefore not readable by other apps and excluded from
  /// both backup paths (see data_extraction_rules.xml). It leaves this directory
  /// only when the user exports it deliberately.
  static Future<Directory> _logDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/diagnostics');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Write the buffer out. Safe to call at any time; does nothing when idle.
  Future<void> flush() async {
    if (_buffer.isEmpty) {
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    final f = _current;
    if (f == null) return;
    final lines = List<String>.from(_buffer);
    _buffer.clear();
    final dropped = _droppedLines;
    _droppedLines = 0;
    try {
      if (dropped > 0) {
        // Said out loud: a silent gap in a timeline is worse than a short one,
        // because it looks like nothing happened.
        lines.insert(0, '${stamp()} $dropped line(s) dropped — buffer full');
      }
      await f.writeAsString('${lines.join('\n')}\n',
          mode: FileMode.append, flush: false);
      await _rotateIfNeeded(f);
    } catch (_) {
      // A failed flush loses those lines rather than retrying forever: this runs
      // on a timer, and a queue that grows on every failure is the leak this
      // whole file is careful to avoid.
    }
  }

  /// Keeps the newest file and exactly one previous one, so the log is bounded but
  /// events just before a rotation are still there.
  Future<void> _rotateIfNeeded(File f) async {
    try {
      if (await f.length() < _maxBytesPerFile) return;
      final dir = await _logDir();
      final prev = File('${dir.path}/activity.1.log');
      if (await prev.exists()) await prev.delete();
      await f.rename(prev.path);
      _current = File('${dir.path}/activity.log');
      await _current!.create(recursive: true);
    } catch (_) {
      // Rotation failing is not worth losing the log over; the size cap is the
      // only thing missed and the next flush tries again.
    }
  }

  /// Everything recorded, oldest first, as one transcript. Flushes first so the
  /// last few seconds are included.
  Future<String> transcript() async {
    await flush();
    final out = StringBuffer();
    out.writeln('# Auvy activity log');
    out.writeln('# exported ${DateTime.now().toIso8601String()}');
    out.writeln('# NOTE: identity hashes are shortened and tokens removed — see '
        'ActivityLog.redact');
    out.writeln();
    try {
      final dir = await _logDir();
      for (final name in const ['activity.1.log', 'activity.log']) {
        final f = File('${dir.path}/$name');
        if (!await f.exists()) continue;
        out.writeln('# ── $name ──');
        out.writeln(await f.readAsString());
      }
    } catch (e) {
      out.writeln('# could not read the log files: $e');
    }
    return out.toString();
  }

  /// How much is on disk, for the settings row to show.
  Future<int> sizeOnDisk() async {
    var total = 0;
    try {
      final dir = await _logDir();
      for (final e in dir.listSync()) {
        if (e is File && e.path.endsWith('.log')) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Delete everything recorded so far.
  Future<void> clear() async {
    _buffer.clear();
    _droppedLines = 0;
    try {
      final dir = await _logDir();
      for (final e in dir.listSync()) {
        if (e is File && e.path.endsWith('.log')) await e.delete();
      }
    } catch (_) {}
    _current = null;
    if (_enabled) await _open();
  }

  /// The bytes to hand to the exporter.
  Future<List<int>> exportBytes() async =>
      utf8.encode(await transcript());

  /// A stable, sortable filename — an ISO stamp, so a name sort is a time sort.
  String exportFilename() {
    final iso = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return 'auvy-activity-$iso.log';
  }
}
