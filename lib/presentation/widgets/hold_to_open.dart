import 'dart:async';

import 'package:flutter/material.dart';

import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';

/// A press-and-hold target that shows the hold as it charges.
///
/// A bare `onLongPress` gives no feedback: the tile sits still and then a sheet
/// appears, so the gesture can't be discovered and people lift too early. The
/// controller is the clock for both the ring and the action: the sheet opens when
/// the ring completes, so the two can't drift apart.
class HoldToOpen extends StatefulWidget {
  final Widget child;

  /// Fired once the hold completes. Usually a content menu.
  final VoidCallback? onHold;

  /// Pixels of finger movement that abandon the charge.
  ///
  /// These tiles live in scrolling lists, so a press that turns into a scroll
  /// must not arm anything. Flutter's own touch slop, for the same reason it
  /// uses it: below this the finger is holding, above it the finger is dragging.
  static const double _slop = 18;

  /// Corner radius of the charge ring. Match the tile it wraps, or the stroke
  /// cuts across the artwork's corners.
  final BorderRadius borderRadius;

  /// Accent for the ring. Falls back to the theme's primary.
  final Color? color;

  /// How long the hold takes.
  ///
  /// 500ms on purpose — Flutter's own `kLongPressTimeout`. The gesture must feel
  /// the same as every other long-press on the device; this changes what the
  /// user SEES during those 500ms, not how long they wait.
  static const Duration holdDuration = Duration(milliseconds: 500);

  /// Nothing is drawn for the first 150 ms, so an ordinary tap (well under 100 ms of
  /// contact) never flashes the ring. The charge still starts on touch; only the
  /// drawing waits, and a hold still shows 350 ms of sweep.
  static const double revealAfter = 0.3;

  const HoldToOpen({
    super.key,
    required this.child,
    this.onHold,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.color,
  });

  @override
  State<HoldToOpen> createState() => _HoldToOpenState();
}

class _HoldToOpenState extends State<HoldToOpen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _charge = AnimationController(
    vsync: this,
    duration: HoldToOpen.holdDuration,
    // Releasing early rewinds faster than charging. A symmetrical rewind feels
    // like the app is still thinking about it after the finger has gone.
    reverseDuration: const Duration(milliseconds: 140),
  )..addStatusListener(_onStatus);

  bool _fired = false;
  Offset? _downAt;

  /// The charge is bounded by time as well as events: once a swipe recognizer claims
  /// the pointer, this Listener may never see a move, up or cancel. By holdDuration
  /// the press has either fired or been abandoned, so nothing is left drawn. The
  /// event handlers still cancel immediately.
  Timer? _watchdog;

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    // The ring reaching full IS the trigger. See the note on the class.
    HapticService.medium();
    widget.onHold?.call();
    // Straight back to rest: the sheet is already on top, so animating the ring
    // out would only be visible as it slid away.
    _charge.value = 0;
  }

  void _start() {
    if (widget.onHold == null) return;
    _fired = false;
    // Reduce Motion is a real setting in this app, and a ring sweeping around
    // a tile is exactly the kind of movement it exists to stop. The GESTURE must
    // still work identically, so the charge still runs — it simply jumps to the
    // end rather than animating there, and the haptic still marks the moment.
    // Armed on every press, with a margin past the hold so it never races the
    // real completion.
    _watchdog?.cancel();
    _watchdog = Timer(HoldToOpen.holdDuration + const Duration(milliseconds: 220),
        () {
      if (!mounted) return;
      if (_charge.value == 0) return;
      // Reached only when neither an up/cancel nor a completion resolved this.
      _charge.value = 0;
    });
    if (ListeningPolicy.reduceMotion) {
      _charge.value = 0;
      Future.delayed(HoldToOpen.holdDuration, () {
        if (mounted && _charge.value == 0 && !_fired) _onStatus(AnimationStatus.completed);
      });
      return;
    }
    _charge.forward(from: 0);
  }

  void _cancel() {
    _watchdog?.cancel();
    _watchdog = null;
    // A press that began before this tile was rebuilt away keeps delivering its
    // pointer events here (the hit test lasts for the whole gesture), so this can
    // run after dispose; touching the controller then throws.
    if (!mounted || _fired) return;
    _charge.reverse();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _charge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.color ?? Theme.of(context).colorScheme.primary;
    // Listener, not GestureDetector: every wrapped tile is already an InkWell, and a
    // GestureDetector would compete with it for the tap in the gesture arena. Listener
    // only observes raw pointer events, so the tile behaves as before. The slop test
    // is done by hand below.
    return Listener(
      onPointerDown: (e) {
        _downAt = e.position;
        _start();
      },
      onPointerMove: (e) {
        final from = _downAt;
        if (from == null) return;
        final d = e.position - from;
        // Horizontal movement cancels sooner (at half the slop): these tiles are swipe
        // targets, and a swipe starts as a press. Half the slop is still well beyond a
        // finger's natural tremor.
        if (d.dx.abs() > HoldToOpen._slop / 2 ||
            d.distance > HoldToOpen._slop) {
          // Cancel once; later moves of the same press are ignored.
          _downAt = null;
          _cancel();
        }
      },
      onPointerUp: (_) {
        _downAt = null;
        _cancel();
      },
      onPointerCancel: (_) {
        _downAt = null;
        _cancel();
      },
      child: AnimatedBuilder(
        animation: _charge,
        builder: (context, child) {
          final t = _charge.value;
          // Remapped so the ring still completes exactly as the menu opens: the
          // hidden first 150ms is skipped, not compressed, and the visible sweep
          // runs 0→1 across the remainder. See revealAfter.
          final shown = t <= HoldToOpen.revealAfter
              ? 0.0
              : ((t - HoldToOpen.revealAfter) / (1 - HoldToOpen.revealAfter))
                  .clamp(0.0, 1.0);
          return Stack(
            children: [
              // A slight settle under the finger, so the tile reads as being
              // pressed INTO rather than merely outlined. Capped small: this sits
              // in scrolling lists and anything larger turns a scroll that starts
              // on a tile into a visible twitch. Driven by `shown`, so a tap does
              // not nudge the tile either.
              Transform.scale(scale: 1 - (0.015 * shown), child: child),
              if (shown > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ChargePainter(
                        progress: shown,
                        color: accent,
                        radius: widget.borderRadius,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Traces the tile's own outline, clockwise from top-centre.
///
/// The outline rather than a bar or a spinner: it needs to say "this TILE is
/// arming" while sitting on top of artwork it must not obscure, and a shape the
/// tile already has is the one overlay that cannot look bolted on.
class _ChargePainter extends CustomPainter {
  final double progress;
  final Color color;
  final BorderRadius radius;

  _ChargePainter({
    required this.progress,
    required this.color,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect).deflate(1);
    final path = Path()..addRRect(rrect);

    // Rotate the start to top-centre. A path built from an RRect begins at the
    // right edge, and a ring that starts there reads as off-centre.
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final total = metric.length;
    final start = total * 0.875; // top-centre, clockwise

    final drawn = Path();
    final sweep = total * progress.clamp(0.0, 1.0);
    final first = start + sweep > total ? total - start : sweep;
    drawn.addPath(metric.extractPath(start, start + first), Offset.zero);
    if (sweep > first) {
      drawn.addPath(metric.extractPath(0, sweep - first), Offset.zero);
    }

    // A dim full outline underneath, so the ring reads as filling a track rather
    // than a stray line crawling around the artwork.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.14),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color
        // Brightens as it completes, so the last moments read as "about to
        // fire" instead of the stroke simply getting longer.
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, 1.5 + 2.5 * progress),
    );
  }

  @override
  bool shouldRepaint(_ChargePainter old) =>
      old.progress != progress || old.color != color;
}
