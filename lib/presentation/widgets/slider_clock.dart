import 'dart:async';

import 'package:flutter/widgets.dart';

/// The time the moving seek bars (comet, pulse, flow, liquid) draw from.
///
/// They used to repeat an AnimationController each, which draws on every vsync
/// (120 a second on these screens) for as long as music plays with the player
/// open, and on Android every frame renders the whole player page. A slow
/// wave or drifting sparks look the same at 30 steps a second, so they share
/// this one timer, which runs only while one of them is moving and the app is
/// in front.
class SliderClock with WidgetsBindingObserver {
  SliderClock._();
  static final SliderClock instance = SliderClock._();

  static const Duration step = Duration(milliseconds: 33);

  /// Milliseconds of motion so far. Only moves while the clock runs, so a bar
  /// resumes where it stopped rather than jumping.
  final ValueNotifier<int> elapsedMs = ValueNotifier<int>(0);

  Timer? _timer;
  int _users = 0;
  bool _observing = false;
  bool _foreground = true;

  @visibleForTesting
  static bool get running => instance._timer != null;

  void acquire() {
    _users++;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      final s = WidgetsBinding.instance.lifecycleState;
      _foreground = s == null || s == AppLifecycleState.resumed;
    }
    _sync();
  }

  void release() {
    if (_users > 0) _users--;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final want = _users > 0 && _foreground;
    if (want && _timer == null) {
      _timer = Timer.periodic(step, (_) {
        elapsedMs.value += step.inMilliseconds;
      });
    } else if (!want && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  /// 0 → 1 once every [periodMs], like `repeat()`.
  double loop(int periodMs) => (elapsedMs.value % periodMs) / periodMs;

  /// 0 → 1 → 0 once every two [periodMs], like `repeat(reverse: true)`.
  double pingPong(int periodMs) {
    final t = (elapsedMs.value % (2 * periodMs)) / periodMs;
    return t <= 1 ? t : 2 - t;
  }
}
