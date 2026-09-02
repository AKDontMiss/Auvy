import 'package:flutter/material.dart';

import 'package:auvy/services/haptic_service.dart';

/// A Niagara-style A–Z scrubber pinned to one edge.
///
/// Drag it and the list jumps to that letter's section. Built for browsing ~200 country sections, where scrolling to
/// "Sweden" by flinging is not navigation, it is a chore.
///
/// Fills the track, up to a cap.
///
/// History worth keeping, because both extremes are wrong. The first version
/// used `spaceEvenly` over the whole viewport, so the rail looked different on
/// every page and a letter changed size with the list. Fixing the pitch outright
/// fixed that but left the rail covering about two thirds of the edge, with the
/// letters bunched at the top and dead track below.
///
/// Now the pitch is `avail / letters` with an upper cap: a tall track spreads
/// the letters out instead of wasting the bottom, and the cap stops a short list
/// becoming a few glyphs adrift in a column. Radio (~27 letters) fills
/// completely; podcasts (~18) sit at the cap and very nearly do.
///
/// PAINT-CHEAP ON PURPOSE. It is on screen the whole time the page is, so the
/// letters are one `Text` each in a plain `Column` with no animation, and the
/// bubble exists only while a finger is down. Nothing here schedules a frame at
/// rest. See `PlayingEqualizer` for what happens when a decorative widget ticks
/// every vsync.
class AlphabetRail extends StatefulWidget {
  /// Letters to show, in order. Only letters that actually have a section — a
  /// rail full of dead letters is worse than no rail.
  final List<String> letters;

  /// Called when the finger lands on, or drags onto, a new letter.
  final ValueChanged<String> onLetter;

  /// Full name for the bubble — the section that letter jumps to. Falls back to
  /// the letter itself.
  final String Function(String letter)? labelFor;

  /// Highlighted letter (the section currently at the top of the viewport).
  final String? active;

  final Color accent;

  const AlphabetRail({
    super.key,
    required this.letters,
    required this.onLetter,
    required this.accent,
    this.labelFor,
    this.active,
  });

  @override
  State<AlphabetRail> createState() => _AlphabetRailState();
}

class _AlphabetRailState extends State<AlphabetRail> {
  /// Upper bound only. The pitch is avail/letters, so a taller track spreads
  /// the letters out instead of leaving the bottom empty; the cap stops a short
  /// list (6-8 letters) from becoming absurdly sparse.
  static const double _preferredPitch = 30.0;
  static const double _railWidth = 34.0;

  int _touchedIndex = -1;

  void _handle(double dy, double pitch) {
    if (widget.letters.isEmpty || pitch <= 0) return;
    final int i =
        (dy / pitch).floor().clamp(0, widget.letters.length - 1);
    if (i == _touchedIndex) return; // same letter — no work, no haptic
    setState(() => _touchedIndex = i);
    HapticService.selection();
    widget.onLetter(widget.letters[i]);
  }

  void _release() {
    if (_touchedIndex == -1) return;
    setState(() => _touchedIndex = -1);
  }

  @override
  Widget build(BuildContext context) {
    // Below a handful of sections the rail is noise: the whole list is within a
    // flick, and a scrubber that moves the page by a few pixels reads as broken.
    if (widget.letters.length < 6) return const SizedBox.shrink();
    final bool dragging = _touchedIndex >= 0;

    // SizedBox, not a bare Stack. Every child below is Positioned, so the
    // Stack has NO intrinsic size — dropped into a Positioned that supplies no
    // width it collapsed to zero and the rail vanished entirely.
    return SizedBox(
      width: _railWidth,
      child: LayoutBuilder(
      builder: (context, constraints) {
        final double avail = constraints.maxHeight;
        // Shrink the pitch only when the letters genuinely cannot fit.
        final double pitch =
            (avail / widget.letters.length).clamp(12.0, _preferredPitch);
        final double railHeight = pitch * widget.letters.length;
        final double top = ((avail - railHeight) / 2).clamp(0.0, avail);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: top,
              right: 0,
              width: _railWidth,
              height: railHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (d) => _handle(d.localPosition.dy, pitch),
                onVerticalDragUpdate: (d) => _handle(d.localPosition.dy, pitch),
                onVerticalDragEnd: (_) => _release(),
                onVerticalDragCancel: _release,
                onTapDown: (d) => _handle(d.localPosition.dy, pitch),
                onTapUp: (_) => _release(),
                onTapCancel: _release,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  decoration: BoxDecoration(
                    // A track appears only while scrubbing — at rest the letters
                    // float over the content with nothing boxing them in.
                    color: dragging
                        ? Colors.white.withOpacity(0.07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(_railWidth / 2),
                  ),
                  child: Column(
                    children: [
                      for (int i = 0; i < widget.letters.length; i++)
                        Builder(builder: (_) {
                          final bool touched = i == _touchedIndex;
                          final bool current =
                              !touched && widget.letters[i] == widget.active;
                          return SizedBox(
                            height: pitch,
                            child: Center(
                              // A filled pill marks where you ARE, instead of a
                              // slightly brighter glyph that was easy to lose
                              // against the artwork scrolling behind the rail.
                              // Still no popup — this reads at a glance without
                              // covering the content you are scrubbing toward.
                              child: Container(
                                width: 20,
                                height: 20,
                                alignment: Alignment.center,
                                decoration: (touched || current)
                                    ? BoxDecoration(
                                        color: touched
                                            ? widget.accent
                                            : Colors.white.withOpacity(0.14),
                                        shape: BoxShape.circle,
                                      )
                                    : null,
                                child: Text(
                                  widget.letters[i],
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.0,
                                    fontWeight: (touched || current)
                                        ? FontWeight.w900
                                        : FontWeight.w700,
                                    color: touched
                                        ? Colors.white
                                        : current
                                            ? Colors.white
                                            : Colors.white.withOpacity(0.66),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ),
            // NO BUBBLE. A popup naming the destination was tried and removed:
            // it covers the very content you are scrubbing toward, which is the
            // one thing you want to see. The feedback is already there without
            // it — the list jumps live under your finger, the touched letter
            // lights up in the accent colour, and each new letter ticks a
            // haptic.
          ],
        );
      },
      ),
    );
  }
}
