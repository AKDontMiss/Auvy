import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';

/// The three bouncing bars marking the row that is currently playing.
///
/// PAINT-ONLY BY DESIGN — do not "simplify" this back into animated widgets.
///
/// The original built three `Container`s inside an `AnimatedBuilder` and animated
/// their **height**. Height is a LAYOUT property, so every animation tick marked
/// the parent dirty for layout, and a `RepaintBoundary` cannot isolate layout —
/// it only stops repaint from propagating. Measured on an S24+ (120Hz), with one
/// track loaded and the app otherwise untouched:
///
///     125 fps sustained · raster thread 49.5% · UI thread 28.5% · ~100% CPU total
///
/// …to move three 3px bars. The app never idled while anything was loaded.
///
/// A `CustomPaint` driven by `repaint:` skips the widget layer entirely: no
/// rebuild, no layout, no new render objects — the painter is called with a
/// fixed-size canvas and draws three rounded rects. The frame still happens
/// (something IS animating) but it costs a tiny dirty rect instead of a relayout
/// of everything above it.
class PlayingEqualizer extends ConsumerStatefulWidget {
  final double size;
  final Color? color;
  final bool playing;

  const PlayingEqualizer({
    super.key,
    this.size = 12,
    this.color,
    this.playing = true,
  });

  @override
  ConsumerState<PlayingEqualizer> createState() => _PlayingEqualizerState();
}

/// A TIMER, NOT AN AnimationController — deliberately.
///
/// An AnimationController drives a Ticker, and a Ticker asks for a frame every
/// single vsync. On a 120Hz phone that is 120 whole-scene frames per second for
/// the entire time a track is loaded, and it measured at ~100% CPU (raster
/// thread alone at 50%) with the app otherwise idle on the home screen.
///
/// Nothing about three 3px bars needs 120 steps a second: at 500ms per half
/// cycle each frame moves a bar by ~0.1px. Stepping every 60ms gives ~16 fps —
/// visually indistinguishable for an indicator like this, and it produces a
/// frame only when the value actually changes, so the whole pipeline sleeps in
/// between.
class _PlayingEqualizerState extends ConsumerState<PlayingEqualizer> {
  static const Duration _step = Duration(milliseconds: 60);
  static const int _stepsPerHalfCycle = 8; // 8 × 60ms ≈ the old 500ms half cycle

  final ValueNotifier<double> _phase = ValueNotifier<double>(0.0);
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    if (widget.playing) _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(_step, (_) {
      _tick++;
      // Ping-pong 0→1→0, matching repeat(reverse: true).
      final int span = _stepsPerHalfCycle * 2;
      final int p = _tick % span;
      _phase.value =
          (p < _stepsPerHalfCycle ? p : span - p) / _stepsPerHalfCycle;
    });
  }

  @override
  void didUpdateWidget(PlayingEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        _start();
      } else {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color themeColor = widget.color ?? ref.watch(themeProvider);
    // Fixed box: 3 bars of 3px with 1px margins each side, and the tallest a bar
    // can ever be. Nothing inside can change these bounds, so nothing above ever
    // relayouts.
    final double maxBarHeight = 4 + widget.size;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(15, maxBarHeight),
        painter: _EqualizerPainter(
          phase: _phase,
          color: themeColor,
          size: widget.size,
          playing: widget.playing,
        ),
      ),
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  final ValueListenable<double> phase;
  final Color color;
  final double size;
  final bool playing;

  _EqualizerPainter({
    required this.phase,
    required this.color,
    required this.size,
    required this.playing,
  }) : super(repaint: phase); // repaint ONLY — no rebuild, no layout

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final paint = Paint()..color = color;
    for (int i = 0; i < 3; i++) {
      // Same shape as before: the middle bar runs opposite to the outer two, and
      // a paused indicator sits at a low, static height.
      final double value = playing
          ? ((i == 1) ? phase.value : (1 - phase.value))
          : 0.2;
      final double barHeight = 4 + (value * size);
      final double left = i * 5.0 + 1.0;
      // Vertically CENTRED, matching the old Row (whose crossAxisAlignment
      // defaulted to center). Growing from the bottom would look more like a
      // VU meter, but that is a visual change and this is a perf fix.
      final double top = (canvasSize.height - barHeight) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, 3, barHeight),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter old) =>
      old.color != color || old.size != size || old.playing != playing;
}
