import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';

/// The three bouncing bars marking the row that's currently playing.
///
/// Paint-only by design; don't turn it back into animated widgets. Animating the
/// height of three Containers is a layout change every tick (which a
/// RepaintBoundary can't isolate), and it kept the app at ~125 fps and near 100%
/// CPU with a track loaded. A `CustomPaint` driven by `repaint:` skips rebuild and
/// layout and just draws three rounded rects.
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

/// A Timer, not an AnimationController: a Ticker requests a frame every vsync (120
/// a second on a 120 Hz screen) for as long as a track is loaded. Stepping every
/// 60 ms (~16 fps) looks the same for this indicator and produces frames only when
/// the value changes.
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
      // Vertically centred, as the original Row was.
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
