import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An on-device flight recorder for Auvy's own diagnostics.
///
/// Why it exists
///
/// Every bug worth fixing in this app was diagnosed from its log: the same
/// millisecond timestamps that showed a listener echoing its own pause back to
/// the host, a stall that armed no retry, a category filing audio as metadata.
/// All of that needed a USB cable and a session that happened to be running at
/// the moment the bug did. Most bugs do not have that courtesy — they happen on
/// a commute, in a car, overnight.
///
/// So the phone keeps its own transcript. Same lines, same order, same
/// timestamps, written to disk as they happen and exported on request.
///
/// Where it taps in
///
/// The print Zone in main.dart, which every `print()` in the app already passes
/// through. Nothing at a call site changes and nothing can be forgotten: a line
/// that reaches the log in a debug build reaches this file too.
///
/// What it costs, AND why that is NOT a print per write
///
/// The Zone's own comment is the warning: a print is a synchronous platform
/// write on hot paths and costs real frames, which is why release swallows them.
/// Writing each line to disk would be far worse. So lines land in a memory
/// buffer and are flushed on a timer, and the flush is the only thing that
/// touches the filesystem — typically once every few seconds, never per line.
class ActivityLog {
  ActivityLog._();
  static final ActivityLog instance = ActivityLog._();

  /// Persisted, so the recorder survives a restart with the state the user chose.
  /// OFF by default: a diagnostic that turns itself on is a diagnostic nobody
  /// consented to.
  static const String _kEnabledPref = 'auvy_activity_log_enabled';

  /// How much history to keep, across two files.
  ///
  /// BOUNDED BECAUSE NOTHING ELSE WILL BOUND IT. A log that grows for a week
  /// of listening is a storage leak wearing a useful hat — this app already
  /// caps its audio cache, its image cache and its history ledger for the same
  /// reason. Two 3 MB files means the oldest ~6 MB of lines is always available
  /// and never more: at the observed rate (a busy launch is a few hundred lines)
  /// that is days of ordinary use.
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

  /// Read the persisted switch and start recording if it is on.
  ///
  /// Called from main() before the app runs, so the very first lines of a launch
  /// — the ones that explain a cold-start bug — are captured too.
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

  /// Redaction is NOT optional
  ///
  /// This file exists to be handed to someone else, which makes it the one place
  /// in the app where a logged secret genuinely leaves the device. The log lines
  /// were written for a USB session, not for export, so they carry things that
  /// are fine on a cable and not fine in a file: the backup identity hash names
  /// the account, and an exception string can quote whatever it was handling.
  ///
  /// Long hex identifiers are shortened rather than removed — the prefix is
  /// enough to tell two accounts apart while reading a timeline, which is all a
  /// timeline needs. Anything that looks like a token or cookie is dropped
  /// outright, because nothing in a timeline is worth one.
  @visibleForTesting
  static String redact(String line) {
    var s = line;
    // Backup keys / identity hashes: 40+ hex chars.
    s = s.replaceAllMapped(
        RegExp(r'\b[0-9a-f]{40,}\b', caseSensitive: false),
        (m) => '${m[0]!.substring(0, 8)}…[${m[0]!.length} hex]');

    // The scheme rule runs first, AND the order is the whole fix.
    //
    // With the key/value rule first, `Authorization: Token abc123def456` had its
    // NEXT WORD replaced, and that word was "Token", not the secret:
    //
    //   Authorization: [redacted] abc123def456     ← the secret survived
    //
    // Caught by the test, not by reading it. Handling `Bearer`/`Token <value>`
    // before anything else means the value is gone whatever precedes it; the
    // key/value pass then tidies the remaining `Authorization:` and cannot
    // reach past it.
    s = s.replaceAll(
        RegExp(r'\b(Bearer|Token)\s+\S+', caseSensitive: false), r'$1 [redacted]');

    // Anything self-described as a secret. `\S+` on purpose: a value with spaces
    // is not a credential shape, and consuming to end-of-line would swallow the
    // diagnostic context that makes the line worth keeping.
    s = s.replaceAllMapped(
        RegExp(
            r'((?:token|cookie|secret|password|api[_-]?key|authorization|sapisid)\s*[:=]\s*)(\S+)',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]');
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
    if (_buffer.isEmpty) return;
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

  /// Keep the newest file and exactly one previous, so the log is bounded but a
  /// bug that happened just before a rotation is still there.
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

  /// Everything recorded, oldest first, as one transcript.
  ///
  /// Flushes first so the last few seconds — usually the interesting ones — are
  /// included rather than sitting in memory.
  Future<String> transcript() async {
    await flush();
    final out = StringBuffer();
    out.writeln('# Auvy activity log');
    out.writeln('# exported ${DateTime.now().toIso8601String()}');
    out.writeln('# NOTE: identity hashes are shortened and tokens removed — see '
        'ActivityLog._redact');
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
