import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Detects and attributes MAIN-ISOLATE STALLS — the "UI froze for a second and
/// then came back" report.
///
/// WHY THE OBVIOUS TOOLS CANNOT SEE THIS. `dumpsys gfxinfo` measured this app
/// at 600 frames, 6.8% janky, 99th percentile 20ms and a worst frame of 57ms —
/// i.e. every frame that RENDERED was fast. That is not a contradiction, it is the
/// signature: when the Dart isolate blocks, Flutter submits no frame at all, so
/// there is no slow frame to record. The stall is invisible to frame stats
/// precisely because nothing was drawn. Impeller also emits no "Skipped N frames"
/// warning, so logcat says nothing either.
///
/// A timer that measures ITS OWN lateness does see it. This one is scheduled every
/// [_tick]; if it arrives materially late, the isolate was busy for the
/// difference, because a Dart timer cannot run while synchronous work holds the
/// event loop.
///
/// The lateness alone would only prove a stall happened. To make it actionable,
/// [note] records what expensive operations ran recently, and the report names
/// them, so a stall arrives with its likely cause attached rather than as a
/// number nobody can act on.
///
/// DIAGNOSTIC ONLY, AND IT MUST STAY THAT WAY. [start] is a no-op unless the
/// build passes `--dart-define=AUVY_DEBUG_LOG=true`, the same gate that lets
/// `print` through in release. [note] is a couple of list operations and is safe
/// to leave on call sites permanently; with the watchdog off it returns
/// immediately.
class StallWatchdog {
  StallWatchdog._();

  static const bool _enabled =
      bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false);

  /// How often the heartbeat is scheduled. Short enough to catch a ~200ms hitch,
  /// long enough that the timer itself is not a cost worth measuring.
  static const Duration _tick = Duration(milliseconds: 200);

  /// Lateness past which a tick is worth reporting. Well above normal scheduling
  /// jitter and a frame's worth of work, so ordinary rendering never trips it.
  static const Duration _threshold = Duration(milliseconds: 300);

  static Timer? _timer;
  static Stopwatch? _clock;
  static int _expectedMs = 0;

  /// Whether the PREVIOUS tick ran with the app foregrounded. A resume delivers
  /// the tick that was pending while the process was suspended, so that one tick
  /// carries the whole background gap and would report it as a freeze.
  static bool _lastTickForeground = true;

  /// Recent expensive operations: (elapsed-ms-at-completion, label, cost-ms).
  /// Bounded — this is a rolling window, not a log.
  static final List<(int, String, int)> _recent = [];
  static const int _recentCap = 24;

  /// Worst stall seen, so a session summary can be asked for at any time.
  static int worstStallMs = 0;
  static int stallCount = 0;

  static void start() {
    if (!_enabled || _timer != null) return;
    _clock = Stopwatch()..start();
    _expectedMs = _tick.inMilliseconds;
    _timer = Timer.periodic(_tick, (_) {
      final now = _clock!.elapsedMilliseconds;
      final late = now - _expectedMs;
      // Re-base on the ACTUAL time, not the expected one. Otherwise a single long
      // stall leaves the schedule permanently behind and every subsequent tick
      // reports the same lateness forever.
      _expectedMs = now + _tick.inMilliseconds;

      // A deferred tick is NOT a stall
      //
      // THE BUG THIS FIXES, and it is a bug in the diagnostic rather than in the
      // app, which makes it worse, because it manufactured work. The first
      // day-long transcript reported 309 stalls, median 371ms, worst 2926ms, and
      // they read as a serious jank problem. Then:
      //
      //   • ZERO of the 309 named any instrumented work. Not one. `note()` is
      //     called from the expensive paths, so genuine main-isolate blocking
      //     would have collided with something at least occasionally.
      //   • they clustered in the hours music played with the screen off
      //     (56, 59, 79 in three of them) rather than in the hours of active use.
      //
      // Android coalesces and defers timers for a process that is not
      // foregrounded. The isolate was not busy; it was suspended, and this timer
      // measured the suspension and called it lateness. Playback is native and in
      // a foreground service, so none of it was audible or visible.
      //
      // This watchdog answers exactly one question — "the UI froze while I was
      // looking at it", so it only measures while there is a UI being looked at.
      // Both this tick AND the previous one must have been foreground, because
      // the first tick after a resume still carries the whole background gap.
      final state = SchedulerBinding.instance.lifecycleState;
      // null happens before the first lifecycle message arrives — at launch,
      // which IS foreground.
      final foreground = state == null || state == AppLifecycleState.resumed;
      final wasForeground = _lastTickForeground;
      _lastTickForeground = foreground;
      if (!foreground || !wasForeground) return;

      if (late < _threshold.inMilliseconds) return;

      stallCount++;
      if (late > worstStallMs) worstStallMs = late;
      // Only operations that finished DURING the stall window can explain it.
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

  /// Record that [label] took [ms] milliseconds. Cheap; safe to leave in place.
  static void note(String label, int ms) {
    if (!_enabled || ms <= 0) return;
    _recent.add((_clock?.elapsedMilliseconds ?? 0, label, ms));
    if (_recent.length > _recentCap) _recent.removeAt(0);
  }

  /// Time [body], record it, and return its result. Use for the synchronous work
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

/// True when diagnostic logging is on — handy for guarding extra reporting.
bool get auvyDiagnosticsOn =>
    const bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false) ||
    !kReleaseMode;
