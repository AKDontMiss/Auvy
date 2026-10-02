import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Detects moments when the main isolate freezes ("the UI froze for a second
/// and came back") and reports what was running at the time.
///
/// Frame statistics cannot see these: while the Dart isolate is blocked no frame
/// is submitted at all, so there is no slow frame to record. A timer that
/// measures its own lateness does see it, because a Dart timer cannot fire while
/// synchronous work holds the event loop. This one ticks every [_tick]; if a tick
/// arrives well past its time, the isolate was busy for the difference.
///
/// [note] records recent expensive operations so each report names a likely
/// cause instead of just a number.
///
/// Diagnostic only. [start] does nothing unless the build passes
/// `--dart-define=AUVY_DEBUG_LOG=true`. [note] is a couple of list operations, so
/// it is safe to leave at call sites permanently.
class StallWatchdog {
  StallWatchdog._();

  static const bool _enabled =
      bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false);

  /// How often the heartbeat runs: short enough to catch a ~200ms hitch, long
  /// enough that the timer itself costs nothing measurable.
  static const Duration _tick = Duration(milliseconds: 200);

  /// Lateness worth reporting. Well above normal scheduling jitter, so ordinary
  /// rendering never trips it.
  static const Duration _threshold = Duration(milliseconds: 300);

  static Timer? _timer;
  static Stopwatch? _clock;
  static int _expectedMs = 0;

  /// Whether the previous tick ran in the foreground. The first tick after a
  /// resume carries the whole time the app was suspended and must not be reported
  /// as a freeze.
  static bool _lastTickForeground = true;

  /// Recent expensive operations as (elapsed-ms-at-completion, label, cost-ms).
  /// A bounded rolling window, not a log.
  static final List<(int, String, int)> _recent = [];
  static const int _recentCap = 24;

  /// Worst stall seen so far, for a session summary.
  static int worstStallMs = 0;
  static int stallCount = 0;

  static void start() {
    if (!_enabled || _timer != null) return;
    _clock = Stopwatch()..start();
    _expectedMs = _tick.inMilliseconds;
    _timer = Timer.periodic(_tick, (_) {
      final now = _clock!.elapsedMilliseconds;
      final late = now - _expectedMs;
      // Re-base on the actual time, not the expected one, or a single long stall
      // would leave every later tick reporting the same lateness.
      _expectedMs = now + _tick.inMilliseconds;

      // Only measure while the app is in the foreground.
      //
      // Android defers timers for a backgrounded process, so a late tick during
      // screen-off playback means the isolate was suspended, not busy. Measuring then
      // reported hundreds of "stalls" that never happened. Both this tick and the
      // previous one must be foreground, since the first tick after a resume still
      // carries the background gap.
      final state = SchedulerBinding.instance.lifecycleState;
      // null means no lifecycle message has arrived yet, which only happens at
      // launch, in the foreground.
      final foreground = state == null || state == AppLifecycleState.resumed;
      final wasForeground = _lastTickForeground;
      _lastTickForeground = foreground;
      if (!foreground || !wasForeground) return;

      if (late < _threshold.inMilliseconds) return;

      stallCount++;
      if (late > worstStallMs) worstStallMs = late;
      // Only operations that finished during the stall can explain it.
      final from = now - late - 50; // small margin for work that began just before
      final blamed = _recent.where((r) => r.$1 >= from).toList();
      final detail = blamed.isEmpty
          ? 'no instrumented work — suspect an uninstrumented sync call, a large '
              'jsonEncode/Decode, or a plugin channel reply'
          : blamed.map((r) => '${r.$2} ${r.$3}ms').join(' + ');
      // ignore: avoid_print
      print('STALL ${late}ms (worst ${worstStallMs}ms, #$stallCount) ← $detail');
      _recent.removeWhere((r) => r.$1 < from);
    });
    // ignore: avoid_print
    print('stall watchdog armed (tick ${_tick.inMilliseconds}ms, '
        'report >${_threshold.inMilliseconds}ms)');
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Records that [label] took [ms] milliseconds. Cheap; safe to leave in place.
  static void note(String label, int ms) {
    if (!_enabled || ms <= 0) return;
    _recent.add((_clock?.elapsedMilliseconds ?? 0, label, ms));
    if (_recent.length > _recentCap) _recent.removeAt(0);
  }

  /// Times [body], records it and returns its result. Use it for synchronous work
  /// most likely to block: whole-collection encode/decode, disk writes, big sorts.
  static T time<T>(String label, T Function() body) {
    if (!_enabled) return body();
    final sw = Stopwatch()..start();
    try {
      return body();
    } finally {
      sw.stop();
      note(label, sw.elapsedMilliseconds);
    }
  }

  /// Async variant, for awaited work such as a SharedPreferences write.
  static Future<T> timeAsync<T>(String label, Future<T> Function() body) async {
    if (!_enabled) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      note(label, sw.elapsedMilliseconds);
    }
  }
}

/// True when diagnostic logging is on, for guarding extra reporting.
bool get auvyDiagnosticsOn =>
    const bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false) ||
    !kReleaseMode;
