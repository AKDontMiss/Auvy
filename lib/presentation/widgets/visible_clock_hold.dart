import 'package:flutter/widgets.dart';

/// Holds a shared clock while the widget wants it and can be seen.
///
/// A page covered by another (the player over Home, an album over the player)
/// stays alive, and a clock its widgets held kept stepping: on Android every
/// step renders the whole screen, for something nobody can see: Home's
/// now-playing bars under the player page added about 17 frames a second.
/// Flutter turns [TickerMode] off for covered pages, which is
/// how it pauses their animations; this follows the same signal.
mixin VisibleClockHold<T extends StatefulWidget> on State<T> {
  bool _wanted = false;
  bool _holding = false;
  bool _ready = false;

  /// Take one hold on the clock.
  void acquireClock();

  /// Give back the hold [acquireClock] took.
  void releaseClock();

  /// Whether this widget would run the clock if it were visible. Call from
  /// initState and whenever that changes (didUpdateWidget, say).
  void wantClock(bool wanted) {
    _wanted = wanted;
    // TickerMode can't be read in initState; didChangeDependencies follows it.
    if (_ready) _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ready = true;
    _sync();
  }

  void _sync() {
    final want = _wanted && TickerMode.valuesOf(context).enabled;
    if (want == _holding) return;
    _holding = want;
    want ? acquireClock() : releaseClock();
  }

  @override
  void dispose() {
    if (_holding) {
      _holding = false;
      releaseClock();
    }
    super.dispose();
  }
}
