import 'dart:math';
import 'package:flutter/material.dart';

// The "liquid" style lives in squiggly_wavy_slider.dart (AuvyFluidSlider), shared
// by the player page and the settings preview.

// ==========================================
// WAVEFORM SLIDER (SoundCloud / Pro Audio Style)
// ==========================================
class WaveformSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const WaveformSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      onTapDown: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      child: SizedBox(height: 44, width: double.infinity, child: CustomPaint(painter: _WaveformPainter(progress: progress, themeColor: themeColor))),
    );
  }
}
class _WaveformPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _WaveformPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2, currentX = size.width * progress;
    final random = Random(42); // Fixed seed ensures the waveform doesn't jitter
    const barWidth = 3.0, barSpacing = 2.0; double startX = 0.0;
    
    while (startX < size.width) {
      final isActive = startX <= currentX;
      // Generate realistic looking audio peaks
      final maxPeak = (sin(startX * 0.05) * 10).abs() + random.nextDouble() * 15 + 4;
      final paint = Paint()
        ..color = isActive ? themeColor : Colors.white.withOpacity(0.15)
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      
      canvas.drawLine(Offset(startX, centerY - maxPeak / 2), Offset(startX, centerY + maxPeak / 2), paint);
      startX += barWidth + barSpacing;
    }
  }
  @override bool shouldRepaint(covariant _WaveformPainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// MATERIAL SLIDER (Material 3: rounded track + capsule handle)
// ==========================================
class MaterialThumbSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const MaterialThumbSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      onTapDown: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      child: SizedBox(height: 44, width: double.infinity, child: CustomPaint(painter: _MaterialThumbPainter(progress: progress, themeColor: themeColor))),
    );
  }
}
class _MaterialThumbPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _MaterialThumbPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2, currentX = size.width * progress;
    const trackH = 6.0, gap = 6.0, handleW = 4.0, handleH = 20.0;
    // Active fill (stops short of the handle — the M3 "gap").
    final activeEnd = (currentX - gap).clamp(0.0, size.width);
    if (activeEnd > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, centerY - trackH / 2, activeEnd, trackH), const Radius.circular(3)), Paint()..color = themeColor);
    }
    // Inactive remainder (also gapped from the handle).
    final inactiveStart = (currentX + gap).clamp(0.0, size.width);
    if (inactiveStart < size.width) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(inactiveStart, centerY - trackH / 2, size.width - inactiveStart, trackH), const Radius.circular(3)), Paint()..color = Colors.white.withOpacity(0.18));
    }
    // Vertical capsule handle.
    final hx = currentX.clamp(handleW / 2, size.width - handleW / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, centerY), width: handleW, height: handleH), const Radius.circular(2)), Paint()..color = Colors.white);
  }
  @override bool shouldRepaint(covariant _MaterialThumbPainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// GRADIENT SLIDER (glossy theme-color fill with a soft under-glow)
// ==========================================
class GradientSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const GradientSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      onTapDown: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      child: SizedBox(height: 44, width: double.infinity, child: CustomPaint(painter: _GradientPainter(progress: progress, themeColor: themeColor))),
    );
  }
}
class _GradientPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _GradientPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2, currentX = size.width * progress;
    const trackH = 6.0;
    final radius = const Radius.circular(3);
    // Background rail.
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, centerY - trackH / 2, size.width, trackH), radius), Paint()..color = Colors.white.withOpacity(0.10));
    if (currentX > 1) {
      // Soft bloom beneath the fill for depth.
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, centerY - trackH / 2, currentX, trackH), radius),
          Paint()..color = themeColor.withOpacity(0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      // Glossy gradient fill (deeper on the left → full on the right).
      final fillRect = Rect.fromLTWH(0, centerY - trackH / 2, currentX, trackH);
      canvas.drawRRect(RRect.fromRectAndRadius(fillRect, radius), Paint()
        ..shader = LinearGradient(colors: [themeColor.withOpacity(0.5), themeColor]).createShader(fillRect));
    }
    // Head: theme halo + white core.
    canvas.drawCircle(Offset(currentX, centerY), 6, Paint()..color = themeColor.withOpacity(0.35));
    canvas.drawCircle(Offset(currentX, centerY), 3.5, Paint()..color = Colors.white);
  }
  @override bool shouldRepaint(covariant _GradientPainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// TIMELINE SLIDER (ruler of ticks — every 5th taller — with a playhead)
// ==========================================
class TimelineSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const TimelineSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      onTapDown: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      child: SizedBox(height: 44, width: double.infinity, child: CustomPaint(painter: _TimelinePainter(progress: progress, themeColor: themeColor))),
    );
  }
}
class _TimelinePainter extends CustomPainter {
  final double progress; final Color themeColor;
  _TimelinePainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2, currentX = size.width * progress;
    const tickW = 1.5, spacing = 6.0, period = tickW + spacing;

    // A hairline baseline through the ticks. Without it the ruler read as loose
    // floating marks; the line is what makes it a TIMELINE rather than a bar
    // chart, and it gives the passed/remaining split something to sit on.
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()..color = Colors.white.withOpacity(0.10)..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(0, centerY),
      Offset(currentX, centerY),
      Paint()..color = themeColor.withOpacity(0.55)..strokeWidth = 1,
    );

    double x = 0; int i = 0;
    while (x < size.width) {
      final major = i % 5 == 0;
      final h = major ? 13.0 : 6.5;
      final active = x <= currentX;
      // Ticks fade toward the far side of the playhead instead of switching colour at
      // one pixel, which would look like a rendering seam.
      final dist = ((x - currentX).abs() / 46.0).clamp(0.0, 1.0);
      final near = 1.0 - dist;
      final Color c = active
          ? Color.lerp(themeColor.withOpacity(0.45), themeColor, near)!
          : Color.lerp(Colors.white.withOpacity(major ? 0.20 : 0.10),
              Colors.white.withOpacity(major ? 0.42 : 0.24), near)!;
      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        Paint()..color = c..strokeWidth = tickW..strokeCap = StrokeCap.round,
      );
      x += period; i++;
    }

    // Playhead: a themed glow, a white stem, and a cap top and bottom — reads as
    // an instrument marker rather than the plain 2.5px rectangle it was.
    final px = currentX.clamp(2.0, size.width - 2.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, centerY), width: 7, height: 24),
          const Radius.circular(4)),
      Paint()
        ..color = themeColor.withOpacity(0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, centerY), width: 2.5, height: 20),
          const Radius.circular(1.25)),
      Paint()..color = Colors.white,
    );
    for (final dy in [-11.0, 11.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(px, centerY + dy), width: 7, height: 2.5),
            const Radius.circular(1.25)),
        Paint()..color = Colors.white,
      );
    }
  }
  @override bool shouldRepaint(covariant _TimelinePainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// SEGMENTED SLIDER (Digital Equalizer Style)
// ==========================================
class SegmentedSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const SegmentedSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      onTapDown: (details) => onChanged((details.localPosition.dx / (context.findRenderObject() as RenderBox).size.width).clamp(0.0, 1.0)),
      child: SizedBox(height: 44, width: double.infinity, child: CustomPaint(painter: _SegmentedPainter(progress: progress, themeColor: themeColor))),
    );
  }
}
class _SegmentedPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _SegmentedPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2, currentX = size.width * progress;
    const blockWidth = 6.0, blockSpacing = 3.0, trackHeight = 8.0; double startX = 0.0;
    
    while (startX < size.width) {
      final isActive = (startX + blockWidth / 2) <= currentX;
      final paint = Paint()..color = isActive ? themeColor : Colors.white.withOpacity(0.1);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(startX, centerY - trackHeight / 2, blockWidth, trackHeight), const Radius.circular(1.5)), paint);
      startX += blockWidth + blockSpacing;
    }
  }
  @override bool shouldRepaint(covariant _SegmentedPainter old) => old.progress != progress || old.themeColor != themeColor;
}
// Each of these styles expresses position in a structurally different way:
//   • minimal — with almost nothing at all
//   • comet   — as motion, with a trail behind the head
//   • elastic — as tension: the untravelled track sags
//   • pulse   — as a heartbeat tied to playback

/// Shared hit-testing for the painter-based sliders below. Every one of them had
/// the identical two-line drag/tap handler copy-pasted; the seek maths is the
/// same for all, only the painting differs.
class _SeekArea extends StatelessWidget {
  final double height;
  final ValueChanged<double> onChanged;
  final CustomPainter painter;
  const _SeekArea(
      {required this.height, required this.onChanged, required this.painter});

  double _frac(BuildContext context, Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    final w = box?.size.width ?? 1;
    return (local.dx / (w == 0 ? 1 : w)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onChanged(_frac(context, d.localPosition)),
      onTapDown: (d) => onChanged(_frac(context, d.localPosition)),
      child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: painter)),
    );
  }
}

// ==========================================
// MINIMAL SLIDER: a hairline and a single precise tick.
//
// The quietest option, and deliberately not animated, for people who want the
// player to be the album cover and nothing else.
// ==========================================
class MinimalSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const MinimalSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) => _SeekArea(
      height: 44,
      onChanged: onChanged,
      painter: _MinimalPainter(progress: progress, themeColor: themeColor));
}
class _MinimalPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _MinimalPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    final cy = size.height / 2, cx = size.width * progress;
    // 1.5px track — thin enough to read as a rule, thick enough to stay crisp
    // after the device pixel ratio rounds it.
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy),
        Paint()..color = Colors.white.withOpacity(0.14)..strokeWidth = 1.5..strokeCap = StrokeCap.round);
    canvas.drawLine(Offset(0, cy), Offset(cx, cy),
        Paint()..color = Colors.white.withOpacity(0.85)..strokeWidth = 1.5..strokeCap = StrokeCap.round);
    // The one accent: a short themed tick standing on the line. No fill, no
    // glow, no circle — the position is stated once.
    final tx = cx.clamp(1.0, size.width - 1.0);
    canvas.drawLine(Offset(tx, cy - 6), Offset(tx, cy + 6),
        Paint()..color = themeColor..strokeWidth = 2..strokeCap = StrokeCap.round);
  }
  @override bool shouldRepaint(covariant _MinimalPainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// COMET SLIDER: a glowing head dragging a fading trail.
//
// Position as motion: the trail is brightest at the head and falls off behind it,
// so the eye reads direction as well as amount. Sparks drift in the wake while
// playing and settle when paused.
// ==========================================
class CometSlider extends StatefulWidget {
  final double progress; final Color themeColor; final bool isPlaying; final ValueChanged<double> onChanged;
  const CometSlider({super.key, required this.progress, required this.themeColor, this.isPlaying = true, required this.onChanged});
  @override State<CometSlider> createState() => _CometSliderState();
}
class _CometSliderState extends State<CometSlider> with SingleTickerProviderStateMixin {
  // Ticks only while playing. The paused frame freezes the phase anyway, so a
  // running controller there rebuilt the slider every vsync (120 Hz on
  // ProMotion) to draw the same picture.
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600));
  @override void initState() { super.initState(); _sync(); }
  @override void didUpdateWidget(covariant CometSlider old) {
    super.didUpdateWidget(old);
    if (old.isPlaying != widget.isPlaying) _sync();
  }
  void _sync() {
    if (widget.isPlaying) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => _SeekArea(
          height: 44,
          onChanged: widget.onChanged,
          painter: _CometPainter(
              progress: widget.progress,
              themeColor: widget.themeColor,
              // Freezing the phase while paused stops the sparks mid-drift
              // instead of leaving them swimming behind a stopped playhead.
              phase: widget.isPlaying ? _c.value : 0.0,
              isPlaying: widget.isPlaying),
        ),
      );
}
class _CometPainter extends CustomPainter {
  final double progress; final Color themeColor; final double phase; final bool isPlaying;
  _CometPainter({required this.progress, required this.themeColor, required this.phase, required this.isPlaying});
  @override void paint(Canvas canvas, Size size) {
    final cy = size.height / 2, cx = size.width * progress;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - 1.5, size.width, 3), const Radius.circular(1.5)),
        Paint()..color = Colors.white.withOpacity(0.10));

    if (cx > 0.5) {
      // The trail. A shader from transparent to the theme colour, so brightness
      // encodes recency — the gradient IS the direction cue.
      final rect = Rect.fromLTWH(0, cy - 1.75, cx, 3.5);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.75)),
        Paint()
          ..shader = LinearGradient(
            colors: [
              themeColor.withOpacity(0.0),
              themeColor.withOpacity(0.35),
              themeColor,
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(rect),
      );
      // Sparks in the wake: dots trailing the head, fading with distance, each with a
      // soft bloom so it reads as light. They fade out by the end of the trail.
      if (isPlaying) {
        for (int i = 0; i < 6; i++) {
          final t = ((phase + i / 6) % 1.0);
          final d = 7 + t * 40;              // how far behind the head
          final sx = cx - d;
          if (sx < 1) continue;
          final life = 1.0 - t;              // 1 at the head, 0 at the tail
          final sy = cy + sin((t + i) * pi * 2) * 3.6;
          final r = 2.6 * life + 0.6;
          canvas.drawCircle(
              Offset(sx, sy),
              r * 2.2,
              Paint()
                ..color = themeColor.withOpacity(0.34 * life)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
          canvas.drawCircle(
              Offset(sx, sy), r,
              Paint()..color = themeColor.withOpacity(0.30 + 0.62 * life));
        }
      }
    }

    // Head: outer bloom, then a solid white core so it stays legible on any art.
    // The bloom is wider and stronger than it was, to match the brighter wake.
    final hx = cx.clamp(3.0, size.width - 3.0);
    canvas.drawCircle(Offset(hx, cy), 12,
        Paint()..color = themeColor.withOpacity(0.42)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawCircle(Offset(hx, cy), 5.5, Paint()..color = themeColor);
    canvas.drawCircle(Offset(hx, cy), 2.6, Paint()..color = Colors.white);
  }
  @override bool shouldRepaint(covariant _CometPainter old) =>
      old.progress != progress || old.themeColor != themeColor || old.phase != phase || old.isPlaying != isPlaying;
}

// ==========================================
// ELASTIC SLIDER: the untravelled track hangs slack; playing pulls it taut.
//
// Position as tension: the remaining track sags and the sag shrinks as the thumb
// advances, so how much is left is visible from the line's shape.
// ==========================================
class ElasticSlider extends StatelessWidget {
  final double progress; final Color themeColor; final ValueChanged<double> onChanged;
  const ElasticSlider({super.key, required this.progress, required this.themeColor, required this.onChanged});
  @override Widget build(BuildContext context) => _SeekArea(
      height: 44,
      onChanged: onChanged,
      painter: _ElasticPainter(progress: progress, themeColor: themeColor));
}
class _ElasticPainter extends CustomPainter {
  final double progress; final Color themeColor;
  _ElasticPainter({required this.progress, required this.themeColor});
  @override void paint(Canvas canvas, Size size) {
    // Sits ABOVE centre so the sag has room to hang without leaving the row —
    // the slack is the whole point, and a centred rope could only droop half as
    // far before clipping.
    final cy = size.height / 2 - 5, cx = (size.width * progress).clamp(0.0, size.width);
    final remaining = size.width - cx;
    // Sag scales with the remaining span, deep enough to read clearly as a slack
    // rope rather than a slightly bent line.
    final double slack = (remaining / size.width);
    final double sag = 15.0 * slack * slack;

    // Anchor posts at both ends: this is a rope strung between two points, and
    // the posts are what make the sag legible as WEIGHT rather than a stray
    // curve. Nothing else in the list has fixed endpoints.
    for (final ax in [1.5, size.width - 1.5]) {
      canvas.drawLine(Offset(ax, cy - 6), Offset(ax, cy + 6),
          Paint()..color = Colors.white.withOpacity(0.22)..strokeWidth = 2..strokeCap = StrokeCap.round);
    }

    // Slack remainder: a quadratic hanging from the grip to the far post.
    if (remaining > 1) {
      final p = Path()
        ..moveTo(cx, cy)
        ..quadraticBezierTo(cx + remaining / 2, cy + sag * 2, size.width, cy);
      canvas.drawPath(
          p,
          Paint()
            ..color = Colors.white.withOpacity(0.20)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke);
    }

    // Travelled portion: taut and thick, with a hairline highlight along the top
    // edge — the visual language of something under load.
    canvas.drawLine(Offset(0, cy), Offset(cx, cy),
        Paint()..color = themeColor..strokeWidth = 4.5..strokeCap = StrokeCap.round);
    if (cx > 2) {
      canvas.drawLine(Offset(1, cy - 1.4), Offset(cx - 1, cy - 1.4),
          Paint()..color = Colors.white.withOpacity(0.28)..strokeWidth = 1);
    }

    // The GRIP: a diamond, deliberately not a circle
    // Elastic and Pulse both ended up with a white disc and a themed core, which
    // is what made them feel like the same slider. A clamp shape says "this is
    // holding the rope"; a disc says "this is a position marker".
    final gx = cx.clamp(7.0, size.width - 7.0);
    final d = Path()
      ..moveTo(gx, cy - 7)
      ..lineTo(gx + 5.5, cy)
      ..lineTo(gx, cy + 7)
      ..lineTo(gx - 5.5, cy)
      ..close();
    canvas.drawPath(d, Paint()..color = Colors.white);
    canvas.drawPath(
        d,
        Paint()
          ..color = themeColor
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);
  }
  @override bool shouldRepaint(covariant _ElasticPainter old) => old.progress != progress || old.themeColor != themeColor;
}

// ==========================================
// PULSE SLIDER: a thin track with a thumb that breathes.
//
// The halo expands and contracts while playing and stops when paused, so the
// slider itself shows whether audio is running.
// ==========================================
class PulseSlider extends StatefulWidget {
  final double progress; final Color themeColor; final bool isPlaying; final ValueChanged<double> onChanged;
  const PulseSlider({super.key, required this.progress, required this.themeColor, this.isPlaying = true, required this.onChanged});
  @override State<PulseSlider> createState() => _PulseSliderState();
}
class _PulseSliderState extends State<PulseSlider> with SingleTickerProviderStateMixin {
  // Ticks only while playing. The paused frame freezes the phase anyway, so a
  // running controller there rebuilt the slider every vsync (120 Hz on
  // ProMotion) to draw the same picture.
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));
  @override void initState() { super.initState(); _sync(); }
  @override void didUpdateWidget(covariant PulseSlider old) {
    super.didUpdateWidget(old);
    if (old.isPlaying != widget.isPlaying) _sync();
  }
  void _sync() {
    if (widget.isPlaying) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => _SeekArea(
          height: 44,
          onChanged: widget.onChanged,
          painter: _PulsePainter(
              progress: widget.progress,
              themeColor: widget.themeColor,
              // Settles to mid-breath when paused rather than freezing wherever
              // the cycle happened to be, so the paused state looks intentional.
              beat: widget.isPlaying
                  ? Curves.easeInOut.transform(_c.value)
                  : 0.35),
        ),
      );
}
class _PulsePainter extends CustomPainter {
  final double progress; final Color themeColor; final double beat;
  _PulsePainter({required this.progress, required this.themeColor, required this.beat});
  @override void paint(Canvas canvas, Size size) {
    final cy = size.height / 2, cx = size.width * progress;
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy),
        Paint()..color = Colors.white.withOpacity(0.12)..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    canvas.drawLine(Offset(0, cy), Offset(cx, cy),
        Paint()..color = themeColor..strokeWidth = 2.5..strokeCap = StrokeCap.round);

    final tx = cx.clamp(9.0, size.width - 9.0);
    // Breathing halo: radius and opacity move together so it reads as one expanding
    // ring. Two rings half a cycle apart, so one is almost always mid-expansion and
    // the movement is visible against busy artwork.
    final beat2 = (beat + 0.5) % 1.0;
    canvas.drawCircle(Offset(tx, cy), 8.0 + beat * 11.0,
        Paint()..color = themeColor.withOpacity(0.42 * (1.0 - beat)));
    canvas.drawCircle(Offset(tx, cy), 8.0 + beat2 * 11.0,
        Paint()..color = themeColor.withOpacity(0.22 * (1.0 - beat2)));
    // The core breathes a little too, so the thumb itself looks alive rather
    // than static inside a moving ring.
    canvas.drawCircle(Offset(tx, cy), 6.5 + (1.0 - beat) * 1.2,
        Paint()..color = Colors.white);
    canvas.drawCircle(Offset(tx, cy), 3.0, Paint()..color = themeColor);
  }
  @override bool shouldRepaint(covariant _PulsePainter old) =>
      old.progress != progress || old.themeColor != themeColor || old.beat != beat;
}

// ==========================================
// FLOW SLIDER: light travels along the part you've already heard.
//
// A straight rail with a soft highlight sweeping along the played span:
//   1. It only moves while audio is playing; paused, the bar goes still, showing
//      the transport state.
//   2. The sweep is confined to the played portion, so its length is a second
//      reading of progress.
//
// One controller. The crest is drawn as a halo, a gradient band and a small hot
// core so it's visible inside a 4 px bar.
// ==========================================
class FlowSlider extends StatefulWidget {
  final double progress; final Color themeColor; final bool isPlaying; final ValueChanged<double> onChanged;
  const FlowSlider({super.key, required this.progress, required this.themeColor, this.isPlaying = true, required this.onChanged});
  @override State<FlowSlider> createState() => _FlowSliderState();
}
class _FlowSliderState extends State<FlowSlider> with SingleTickerProviderStateMixin {
  // Ticks only while playing. The paused frame freezes the phase anyway, so a
  // running controller there rebuilt the slider every vsync (120 Hz on
  // ProMotion) to draw the same picture.
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1700));
  @override void initState() { super.initState(); _sync(); }
  @override void didUpdateWidget(covariant FlowSlider old) {
    super.didUpdateWidget(old);
    if (old.isPlaying != widget.isPlaying) _sync();
  }
  void _sync() {
    if (widget.isPlaying) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => _SeekArea(
          height: 44,
          onChanged: widget.onChanged,
          painter: _FlowPainter(
              progress: widget.progress,
              themeColor: widget.themeColor,
              // Frozen while paused. See the note above; the stillness is the
              // signal, so it must not drift on at half speed.
              phase: widget.isPlaying ? _c.value : -1.0,
              isPlaying: widget.isPlaying),
        ),
      );
}
class _FlowPainter extends CustomPainter {
  final double progress; final Color themeColor; final double phase; final bool isPlaying;
  _FlowPainter({required this.progress, required this.themeColor, required this.phase, required this.isPlaying});

  @override void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final cx = (size.width * progress).clamp(0.0, size.width);

    // The whole track, dim.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - 1.5, size.width, 3), const Radius.circular(1.5)),
      Paint()..color = Colors.white.withOpacity(0.12),
    );

    if (cx > 1) {
      final played = Rect.fromLTWH(0, cy - 2.5, cx, 5);
      final rr = RRect.fromRectAndRadius(played, const Radius.circular(2.5));
      canvas.drawRRect(rr, Paint()..color = themeColor);

      // The travelling highlight is clipped horizontally to the played span (light must
      // never appear past the playhead), but the clip is taller than the bar so the bloom
      // can spill above and below and be visible.
      if (isPlaying && cx > 12) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, cx, size.height));

        final band = (cx * 0.26).clamp(22.0, 110.0);
        final head = -band + phase * (cx + band * 2);
        final centre = head + band / 2;

        // 1. Wide accent halo, blurred well outside the bar. This is the part
        //    you actually notice travelling.
        canvas.drawCircle(
          Offset(centre, cy),
          band * 0.42,
          Paint()
            ..color = themeColor.withOpacity(0.26)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
        );

        // 2. The band itself, near-white at the crest instead of 0.55.
        final glow = Rect.fromLTWH(head, cy - 2.5, band, 5);
        canvas.drawRect(
          glow,
          Paint()
            ..shader = LinearGradient(
              colors: [
                themeColor.withOpacity(0.0),
                Colors.white.withOpacity(0.16),
                Colors.white.withOpacity(0.52),
                Colors.white.withOpacity(0.16),
                themeColor.withOpacity(0.0),
              ],
              stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
            ).createShader(glow),
        );

        // 3. A small hot core riding the crest, blurred just enough to bloom
        //    rather than look like a dot.
        canvas.drawCircle(
          Offset(centre, cy),
          3.4,
          Paint()
            ..color = Colors.white.withOpacity(0.42)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );

        canvas.restore();
      }
    }

    // Thumb: a soft bloom under a solid core, so it holds up over bright artwork.
    final tx = cx.clamp(6.0, size.width - 6.0);
    canvas.drawCircle(Offset(tx, cy), 10,
        Paint()..color = themeColor.withOpacity(0.28)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(Offset(tx, cy), 6, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(tx, cy), 2.8, Paint()..color = themeColor);
  }

  @override bool shouldRepaint(covariant _FlowPainter old) =>
      old.progress != progress || old.themeColor != themeColor ||
      old.phase != phase || old.isPlaying != isPlaying;
}
