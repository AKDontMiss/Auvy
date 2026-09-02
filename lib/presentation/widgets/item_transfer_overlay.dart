import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/haptic_service.dart';

/// Artwork ghosts that show where a list change went.
///
/// [toLibrary] arcs the artwork down into the Library tab — the place the track
/// can now be found. [discard] drops it away.
///
/// RISING STRAIGHT UP WAS THE FIRST ATTEMPT AND IT READ AS A GLITCH, for two
/// reasons worth keeping in mind before changing the motion again:
///
///  • It appeared at FULL OPACITY. A shape that exists abruptly looks like a
///    rendering fault, not like something moving, however smooth the path is.
///    Every ghost here fades in over its first frames.
///  • It went nowhere. Travelling off the top edge told the user nothing about
///    where the track went, and from a swipe, which starts near the right edge —
///    it looked like the artwork was thrown at the top-right corner. Flying to a
///    real destination reads as delivery instead.
///
/// Purely decorative and non-blocking: the list has already changed by the time
/// this runs, and the overlay removes itself.
class ItemTransferOverlay {
  ItemTransferOverlay._();

  /// Sends the artwork to the Library tab, for something just added to the
  /// library (a playlist, liked songs).
  static void toLibrary(BuildContext context,
      {String? imageUrl, Color? accent, Offset? origin}) {
    final overlay = _overlayOf(context);
    if (overlay == null) return;
    final media = MediaQuery.of(overlay.context);

    // Mirror of AuvyNavBar's geometry: three equal-width destinations in a row
    // 62 high, Library last. So its centre sits five-sixths across, half the row
    // height up from the safe-area bottom.
    final target = Offset(
      media.size.width * 5 / 6,
      media.size.height - media.padding.bottom - 31,
    );

    final from = _originIn(context, overlay, origin);
    if (from == null) return;
    _insert(overlay,
        from: from,
        to: target,
        imageUrl: imageUrl,
        accent: accent,
        falling: false);
  }

  /// Drops the artwork away, for something just removed.
  static void discard(BuildContext context,
      {String? imageUrl, Color? accent, Offset? origin}) {
    final overlay = _overlayOf(context);
    if (overlay == null) return;
    final from = _originIn(context, overlay, origin);
    if (from == null) return;
    final media = MediaQuery.of(overlay.context);
    _insert(overlay,
        from: from,
        // Stops short of the edge rather than leaving the screen: the fade
        // finishes the gesture, and a shape clipping through the bottom bezel is
        // the same abruptness as appearing from nowhere.
        to: Offset(from.dx, math.min(from.dy + 190, media.size.height - 40)),
        imageUrl: imageUrl,
        accent: accent,
        falling: true);
  }

  static OverlayState? _overlayOf(BuildContext context) =>
      context.mounted ? Overlay.maybeOf(context, rootOverlay: true) : null;

  /// Where the ghost starts, or NULL when that cannot be established.
  ///
  /// NO FALLBACK TO THE MIDDLE OF THE SCREEN. It used to end there, and that
  /// is what made a removal look wrong: the caller often has only the PAGE
  /// context — a full-height render box, so the ghost launched from the centre
  /// of the screen rather than from the row that was deleted. An animation that
  /// starts somewhere the user was not looking reads as a stray artefact.
  ///
  /// Returning null makes the caller skip the ghost entirely. Showing nothing is
  /// correct when the thing being animated has no known position; the list has
  /// already updated and the undo toast still says what happened.
  static Offset? _originIn(
      BuildContext context, OverlayState overlay, Offset? origin) {
    if (origin != null) return origin;
    final ro = context.findRenderObject();
    // Height-bounded: a tall box is a page, not a row, and its centre is not the
    // source of anything.
    if (ro is RenderBox && ro.attached && ro.hasSize && ro.size.height < 200) {
      return ro.localToGlobal(ro.size.center(Offset.zero));
    }
    return null;
  }

  static void _insert(OverlayState overlay,
      {required Offset from,
      required Offset to,
      required String? imageUrl,
      required Color? accent,
      required bool falling}) {
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TransferGhost(
        from: from,
        to: to,
        falling: falling,
        imageUrl: imageUrl,
        accent: accent,
        onDone: () {
          entry.remove();
          HapticService.light();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _TransferGhost extends StatefulWidget {
  final Offset from;
  final Offset to;
  final bool falling;
  final String? imageUrl;
  final Color? accent;
  final VoidCallback onDone;

  const _TransferGhost({
    required this.from,
    required this.to,
    required this.falling,
    required this.imageUrl,
    required this.accent,
    required this.onDone,
  });

  @override
  State<_TransferGhost> createState() => _TransferGhostState();
}

class _TransferGhostState extends State<_TransferGhost>
    with SingleTickerProviderStateMixin {
  static const double _size = 48.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    // Long enough to read as travel. The first version ran in 520ms with an
    // instant appearance, which is short enough that the eye registers two
    // positions rather than a movement.
    duration: Duration(milliseconds: widget.falling ? 620 : 700),
  )
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    })
    ..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // Align loosens the overlay's tight full-screen constraints so the ghost
      // lays out at its own size; the transforms below are paint-only, so none
      // of this triggers a relayout mid-flight.
      child: Align(
        alignment: Alignment.topLeft,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final double t = _controller.value;

            // Falling accelerates, because gravity does. A delivery decelerates
            // into its destination.
            final double travel = widget.falling
                ? Curves.easeInCubic.transform(t)
                : Curves.easeInOutCubic.transform(t);
            Offset pos = Offset.lerp(widget.from, widget.to, travel)!;

            // A slight lift before the descent, so the flight to the Library tab
            // is an arc rather than a straight diagonal.
            if (!widget.falling) {
              pos -= Offset(0, math.sin(math.pi * t) * 42.0);
            }

            final double scale = widget.falling
                ? 1.0 - 0.35 * travel
                : 1.0 - 0.62 * Curves.easeInCubic.transform(t);

            // Fades IN over the first frames and out at the end, with no jump at
            // either edge — this is the part that made the old version look like
            // a glitch.
            const double inEnd = 0.10;
            final double outStart = widget.falling ? 0.55 : 0.75;
            double opacity;
            if (t < inEnd) {
              opacity = t / inEnd;
            } else if (t > outStart) {
              opacity = 1.0 - (t - outStart) / (1.0 - outStart);
            } else {
              opacity = 1.0;
            }

            return Opacity(
              opacity: Curves.easeOut.transform(opacity.clamp(0.0, 1.0)),
              child: Transform.translate(
                offset: pos - const Offset(_size / 2, _size / 2),
                child: Transform.scale(scale: scale, child: child),
              ),
            );
          },
          child: _ghost(),
        ),
      ),
    );
  }

  Widget _ghost() {
    final url = widget.imageUrl;
    final hasArt = url != null && url.isNotEmpty;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Static shadow — composited once rather than animated per frame.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: hasArt
          ? AuvyImage(path: url, width: _size, height: _size, borderRadius: 12)
          : Container(
              decoration: BoxDecoration(
                color: widget.accent ?? const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                widget.falling
                    ? Icons.delete_outline_rounded
                    : Icons.playlist_add_check_rounded,
                color: widget.accent != null ? Colors.black : Colors.white,
                size: 22,
              ),
            ),
    );
  }
}
