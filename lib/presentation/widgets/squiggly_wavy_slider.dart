// lib/presentation/widgets/squiggly_wavy_slider.dart

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The "liquid" seek bar: a squiggly sine wave that flows while playing and
/// flattens when paused. Used by both the player page and the settings
/// live-preview so the two always look identical.
class AuvyFluidSlider extends StatefulWidget {
  final double value; // Bound context between 0.0 and 1.0
  final bool isPlaying;
  final ValueChanged<double> onChanged;
  final Color? activeColor;
  final Color? inactiveColor;

  const AuvyFluidSlider({
    super.key,
    required this.value,
    required this.isPlaying,
    required this.onChanged,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  State<AuvyFluidSlider> createState() => _AuvyFluidSliderState();
}

class _AuvyFluidSliderState extends State<AuvyFluidSlider> with SingleTickerProviderStateMixin {
  late AnimationController _phaseController;

  @override
  void initState() {
    super.initState();
    _phaseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    if (widget.isPlaying) {
      _phaseController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AuvyFluidSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _phaseController.repeat();
      } else {
        _phaseController.stop();
      }
    }
  }

  @override
  void dispose() {
    _phaseController.dispose();
    super.dispose();
  }

  void _handleDragUpdate(Offset localPosition, double maxWidth) {
    double dragPercent = (localPosition.dx / maxWidth).clamp(0.0, 1.0);
    widget.onChanged(dragPercent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activePaintColor = widget.activeColor ?? theme.colorScheme.primary;
    final inactivePaintColor = widget.inactiveColor ?? theme.colorScheme.surfaceContainerHighest;

    return GestureDetector(
      onHorizontalDragStart: (details) => _handleDragUpdate(details.localPosition, context.size!.width),
      onHorizontalDragUpdate: (details) => _handleDragUpdate(details.localPosition, context.size!.width),
      onTapDown: (details) => _handleDragUpdate(details.localPosition, context.size!.width),
      // RepaintBoundary keeps the 60fps wave repaint from dirtying the rest
      // of the page it sits on.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _phaseController,
          builder: (context, child) {
            return CustomPaint(
              size: const Size(double.infinity, 44),
              painter: _FluidSliderPainter(
                progress: widget.value,
                phase: _phaseController.value * 2 * math.pi,
                isPlaying: widget.isPlaying,
                activeColor: activePaintColor,
                inactiveColor: inactivePaintColor,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FluidSliderPainter extends CustomPainter {
  final double progress;
  final double phase;
  final bool isPlaying;
  final Color activeColor;
  final Color inactiveColor;

  _FluidSliderPainter({
    required this.progress,
    required this.phase,
    required this.isPlaying,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final yCenter = size.height / 2;
    final xTrackEnd = size.width;
    final xProgressThumb = size.width * progress;

    // 1. Draw Inactive Background Track Section (Flat line placeholder)
    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(xProgressThumb, yCenter), Offset(xTrackEnd, yCenter), inactivePaint);

    // 2. Draw Active Dynamic Processed Track Section
    final activePaint = Paint()
      ..color = activeColor
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final activePath = Path();
    activePath.moveTo(0, yCenter);

    const frequencyFactor = 0.06; // Width scaling footprint of the wave clusters
    // Amplitude, after two corrections in opposite directions. It was 6.0, cut
    // to 4.0 for reading too tall, and the cut went too far once the envelope
    // below started multiplying TWO ramps together: the peak the number promises
    // is only reached where both ramps are saturated, which early in a track is
    // nowhere. 5.5 with the shorter start ramp lands where 4.0 was meant to.
    const maxAmplitude = 5.5;

    // The wave is anchored to the THUMB, not to x = 0
    //
    // Two things were wrong before, and they had the same root cause: the wave
    // was `sin(x * freq - phase)`, a function of the absolute x position.
    //
    //  1. Its END therefore landed at whatever height the sine happened to be at
    //     the thumb's x — usually not the centre line, so the line DETACHED from
    //     the thumb, meeting it above or below the middle.
    //  2. Because the phase advanced against a fixed origin, that end height
    //     oscillated: the wave appeared to ride UP and down at the tip, most
    //     obviously near the end of a track where the eye has the thumb and the
    //     track end to compare against.
    //
    // Measuring x RELATIVE TO THE THUMB (`x - xProgressThumb`) shifts the whole
    // waveform along -x as playback advances, so the crest pattern travels with
    // the thumb instead of the thumb sliding through a stationary pattern.
    //
    // Phase-locking alone still would not guarantee the line MEETS the thumb, so
    // the amplitude also tapers to exactly zero over the last [tipTaper] px. At
    // x == xProgressThumb the envelope is 0, so the path passes through yCenter —
    // dead centre of the thumb, at every position, always attached.
    //
    const tipTaper = 26.0;

    // BOTH ENDS ARE PINNED. The tip taper alone is NOT enough, and removing
    // the start ramp on the assumption that it was caused a real bug:
    //
    // the taper is measured from the THUMB, so early in a track — say a 20px
    // active span at 0:05 — the pixel at x = 0 is 20px away from the thumb and
    // therefore gets NEAR-FULL amplitude, while the thumb end is pinned at zero.
    // The result is a short wave pivoting about the thumb: the left end swung up
    // and down in place as the phase advanced, which reads as the whole thing
    // pendulum-ing rather than travelling. (The original code had a `rampWidth`
    // for exactly this reason; it was removed in error and is restored here.)
    //
    // Pinning BOTH ends — flat at the track start, flat at the thumb, swelling in
    // between — is what makes the wave look like it is being drawn out of the
    // origin and pulled along by the thumb.
    // 64px was long enough that, on a short active span, this ramp and the tip
    // taper overlapped and their PRODUCT never approached 1 — the wave stayed
    // flat-ish for the first minute of every track. 34px still hides the pivot
    // this exists to prevent while letting the swell arrive quickly.
    const startRamp = 34.0;

    if (isPlaying) {
      for (double x = 0; x <= xProgressThumb; x += 1.0) {
        // Smoothstep on both: a straight ramp leaves a visible kink where the
        // envelope reaches full amplitude.
        final tTip = ((xProgressThumb - x) / tipTaper).clamp(0.0, 1.0);
        final tStart = (x / startRamp).clamp(0.0, 1.0);
        final envelope =
            (tTip * tTip * (3 - 2 * tTip)) * (tStart * tStart * (3 - 2 * tStart));
        activePath.lineTo(
            x,
            yCenter +
                math.sin(((x - xProgressThumb) * frequencyFactor) - phase) *
                    maxAmplitude *
                    envelope);
      }
    } else {
      // Flatline while paused.
      activePath.lineTo(xProgressThumb, yCenter);
    }
    canvas.drawPath(activePath, activePaint);

    // 3. Render Distinct Floating Thumb Indicator Core Component
    final thumbPaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(xProgressThumb, yCenter), 7.5, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant _FluidSliderPainter oldDelegate) {
    return oldDelegate.progress != progress ||
           oldDelegate.phase != phase ||
           oldDelegate.isPlaying != isPlaying ||
           oldDelegate.activeColor != activeColor ||
           oldDelegate.inactiveColor != inactiveColor;
  }
}
