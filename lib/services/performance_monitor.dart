import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';

import 'package:auvy/services/activity_log.dart';

/// Periodic CPU, memory, thread and frame-timing report, for finding battery
/// drains and leaks.
///
/// The activity log records what Auvy did, not what it cost. A profiler only
/// helps while attached, and the interesting cases are long ones (an hour of
/// radio with the screen off, a night of Listen Together). So this samples cheap
/// numbers slowly into the same log, exportable afterwards.
///
/// The monitor must not be the drain:
///   * Off unless diagnostics are enabled, so a normal install doesn't read
///     /proc or register a frame callback.
///   * Samples every 30 seconds. Frame timings are aggregated in memory and
///     printed once per interval, never per frame.
///   * Each reading is a small file read or an existing counter: no native
///     calls, no per-frame allocation.
class PerformanceMonitor {
  PerformanceMonitor._();
  static final PerformanceMonitor instance = PerformanceMonitor._();

  /// A diagnostic build, which forwards everything to the console as well.
  static const bool _debugBuild =
      bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false);

  /// Whether sampling is wanted: in debug builds, or when the user has turned on
  /// the activity log (Settings → diagnostics). That switch is off by default, so
  /// a normal install never samples, and checking it here means no caller can
  /// start sampling on a device whose owner didn't ask.
  static bool get _wanted => _debugBuild || ActivityLog.instance.isEnabled;

  /// Long enough that the sampler is invisible next to playback, short enough
  /// that a leak is obvious within a few minutes of listening.
  static const Duration _interval = Duration(seconds: 30);

  /// Anything past one 60Hz frame is a dropped frame; past two is visible.
  /// Reported separately because they mean different things — a handful of 17ms
  /// frames is a stutter, a 40ms frame is a lurch.
  static const int _jankMs = 17;
  static const int _badJankMs = 33;

  Timer? _timer;
  bool _started = false;

  /// What the app was doing during this sample, appended to the line as is. CPU use
  /// means little without it: "0 frames" says the UI wasn't drawing, not whether
  /// audio was streaming, and those differ by a factor of fifty.
  ///
  /// A pull callback returning a string, so the monitor holds no app state and new
  /// signals can be added where it's registered (see MainLayout, which also clears
  /// it on dispose). Called inside a try/catch so a failing probe can't lose the
  /// sample.
  String Function()? contextProbe;

  // Frame aggregation for the current interval.
  int _frames = 0;
  int _janky = 0;
  int _badJanky = 0;
  int _worstMs = 0;
  int _buildUs = 0;
  int _rasterUs = 0;

  // CPU accounting. /proc/self/stat reports CPU time in clock ticks; the delta
  // against wall time is the only meaningful figure, so the first sample
  // establishes a baseline and reports nothing.
  int? _lastCpuTicks;
  DateTime? _lastSampleAt;

  // Memory baseline, so the log can say "grew by" rather than just a number
  // nobody can calibrate.
  int? _rssAtStart;

  /// Starts or stops sampling to match [_wanted]. Safe to call repeatedly, from
  /// launch and from the settings toggle, so flipping the switch takes effect
  /// without a restart.
  void syncWithDiagnostics() => _wanted ? start() : stop();

  void start() {
    if (!_wanted || _started) return;
    _started = true;
    _rssAtStart = _rssBytes();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _timer = Timer.periodic(_interval, (_) => _report());
    print('perf monitor on — sampling every ${_interval.inSeconds}s '
        '(CPU, RSS, threads, frame timings)');
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    // Drop the CPU baseline. CPU use is (ticks since last sample) / (time since last
    // sample); keeping the baseline across a stop would divide a long switched-off
    // period by one interval. Without a baseline the next sample just sets one.
    _lastCpuTicks = null;
    _lastSampleAt = null;
    // Frame counters too: they would otherwise fold whatever was drawn before
    // the switch into the first interval after it.
    _frames = _janky = _badJanky = _worstMs = 0;
    _buildUs = _rasterUs = 0;
  }

  /// Aggregate only. Deliberately does no work proportional to jank, so a bad
  /// frame is never made worse by being measured.
  void _onFrames(List<FrameTiming> timings) {
    for (final t in timings) {
      final totalUs = t.totalSpan.inMicroseconds;
      final ms = totalUs ~/ 1000;
      _frames++;
      _buildUs += t.buildDuration.inMicroseconds;
      _rasterUs += t.rasterDuration.inMicroseconds;
      if (ms > _worstMs) _worstMs = ms;
      if (ms >= _badJankMs) {
        _badJanky++;
      } else if (ms >= _jankMs) {
        _janky++;
      }
    }
  }

  /// Resident set size in bytes, or null when unavailable.
  ///
  /// ProcessInfo.currentRss is the portable reading and is what Android's own
  /// memory pressure tracks most closely.
  int? _rssBytes() {
    try {
      final rss = ProcessInfo.currentRss;
      return rss > 0 ? rss : null;
    } catch (_) {
      return null;
    }
  }

  /// utime + stime for this process, in clock ticks, from /proc/self/stat.
  ///
  /// Fields 14 and 15 (1-indexed) of that line. The process NAME sits in
  /// parentheses in field 2 and can itself contain spaces, so the parse starts
  /// after the last ')' rather than splitting the whole line — the naive split
  /// is the classic way this reads the wrong numbers.
  int? _cpuTicks() {
    try {
      final line = File('/proc/self/stat').readAsStringSync();
      final close = line.lastIndexOf(')');
      if (close < 0) return null;
      final rest = line.substring(close + 1).trim().split(RegExp(r'\s+'));
      // After the name, field 3 is `state`, so utime is index 11 and stime 12.
      if (rest.length < 13) return null;
      final utime = int.tryParse(rest[11]);
      final stime = int.tryParse(rest[12]);
      if (utime == null || stime == null) return null;
      return utime + stime;
    } catch (_) {
      // Not Android/Linux, or /proc is restricted. CPU is simply omitted.
      return null;
    }
  }

  /// Live thread count from /proc/self/status. A plugin or isolate that is created
  /// per use and never torn down shows up here first.
  int? _threads() {
    try {
      for (final l in File('/proc/self/status').readAsLinesSync()) {
        if (l.startsWith('Threads:')) {
          return int.tryParse(l.split(RegExp(r'\s+'))[1]);
        }
      }
    } catch (_) {/* same as above */}
    return null;
  }

  /// "screen off" and "another app is in front" both produce no frames, and
  /// they are different complaints. The lifecycle state separates them: an app
  /// that is `resumed` with nothing drawing has the screen off in front of it.
  static String _lifecycleName(AppLifecycleState? s) {
    switch (s) {
      case AppLifecycleState.resumed:
        return 'resumed, screen off';
      case AppLifecycleState.inactive:
        return 'inactive';
      case AppLifecycleState.hidden:
        return 'hidden';
      case AppLifecycleState.paused:
        return 'app backgrounded';
      case AppLifecycleState.detached:
        return 'detached';
      case null:
        return 'lifecycle unknown';
    }
  }

  void _report() {
    final now = DateTime.now();
    final parts = <String>[];

    // CPU.
    final ticks = _cpuTicks();
    final lastTicks = _lastCpuTicks;
    final lastAt = _lastSampleAt;
    if (ticks != null && lastTicks != null && lastAt != null) {
      final elapsedMs = now.difference(lastAt).inMilliseconds;
      if (elapsedMs > 0) {
        // Linux USER_HZ is 100 on Android, so a tick is 10ms of CPU time.
        final cpuMs = (ticks - lastTicks) * 10;
        final pct = (cpuMs / elapsedMs) * 100;
        // Of ONE core. Above 100% means genuinely parallel work, which for this
        // app means decode plus UI, and is not by itself a problem.
        parts.add('cpu ${pct.toStringAsFixed(1)}% of a core');
      }
    }
    _lastCpuTicks = ticks;
    _lastSampleAt = now;

    // Memory.
    final rss = _rssBytes();
    if (rss != null) {
      final mb = rss / (1024 * 1024);
      final base = _rssAtStart;
      if (base != null && base > 0) {
        final deltaMb = (rss - base) / (1024 * 1024);
        parts.add('rss ${mb.toStringAsFixed(0)}MB '
            '(${deltaMb >= 0 ? '+' : ''}${deltaMb.toStringAsFixed(0)}MB since start)');
      } else {
        parts.add('rss ${mb.toStringAsFixed(0)}MB');
      }
    }

    // Threads.
    final threads = _threads();
    if (threads != null) parts.add('$threads threads');

    // Frames.
    if (_frames > 0) {
      final avgBuild = (_buildUs / _frames / 1000);
      final avgRaster = (_rasterUs / _frames / 1000);
      parts.add('$_frames frames, $_janky janky, $_badJanky bad, '
          'worst ${_worstMs}ms, avg build ${avgBuild.toStringAsFixed(1)}ms '
          'raster ${avgRaster.toStringAsFixed(1)}ms');
    } else {
      // No frames means the UI was not drawing. It does NOT mean the app was
      // idle, which is why the lifecycle state is named here and the context
      // probe below says what was running — see [contextProbe].
      final lifecycle = SchedulerBinding.instance.lifecycleState;
      parts.add('0 frames (${_lifecycleName(lifecycle)})');
    }
    _frames = _janky = _badJanky = _worstMs = 0;
    _buildUs = _rasterUs = 0;

    // What the app was doing.
    final probe = contextProbe;
    if (probe != null) {
      try {
        final ctx = probe();
        if (ctx.isNotEmpty) parts.add(ctx);
      } catch (_) {
        // A probe that throws costs this sample its context and nothing else.
        parts.add('context unavailable');
      }
    }

    if (parts.isNotEmpty) print('perf: ${parts.join(' · ')}');
  }
}
