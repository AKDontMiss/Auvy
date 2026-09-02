import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';

/// Bumped once per landed ghost. MiniPlayer listens and plays a dock-style
/// scale pop when it changes.
final miniPlayerBounceProvider = StateProvider<int>((_) => 0);

/// Flies a small artwork ghost from a swipe-action pill down into the
/// mini-player — same shrink-toward-the-bar language as the player dismiss.
class QueueFlyOverlay {
  QueueFlyOverlay._();

  /// Fly from the center of [context]'s own render box — for buttons/tiles
  /// that trigger a queue-add directly. Falls back to the lower-center of the
  /// screen when the source widget can't be measured (e.g. a just-popped
  /// sheet's parent context). Returns false when nothing flew (no mini-player
  /// to land on) so the caller can show a toast instead.
  static bool flyFrom(BuildContext context, {String? imageUrl, Color? accent}) {
    Offset from;
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize && ro.size.height < 200) {
      from = ro.localToGlobal(ro.size.center(Offset.zero));
    } else {
      // Whole-page context or unmeasurable widget: rise from the lower third,
      // where a sheet/menu just was.
      final media = MediaQuery.of(context);
      from = Offset(media.size.width / 2, media.size.height * 0.72);
    }
    return fly(context, from: from, imageUrl: imageUrl, accent: accent);
  }

  static bool fly(BuildContext context,
      {required Offset from, String? imageUrl, Color? accent}) {
    final container = ProviderScope.containerOf(context, listen: false);
    final player = container.read(playerProvider);
    // No mini-player on screen (no song, dismissed, or keyboard covering it)
    // → nothing to fly to; skip silently.
    if (player.currentSong == null || !player.miniPlayerVisible) return false;
    if (MediaQuery.of(context).viewInsets.bottom > 0) return false;

    final overlay = Overlay.of(context, rootOverlay: true);
    // Measure from the root overlay so nested scaffolds can't skew the insets.
    final media = MediaQuery.of(overlay.context);

    // Mirror of main_layout's mini-player geometry: the bar sits at
    // bottom = navBar(70 + bottom inset) + 10, height 64, horizontal margin 12,
    // with its 46px artwork ~9px in, so land on the artwork's center.
    final double navBarHeight = 70.0 + media.padding.bottom;
    final Offset target = Offset(
      12.0 + 8.0 + 24.0,
      media.size.height - (navBarHeight + 10.0) - 32.0,
    );

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _QueueFlyGhost(
        from: from,
        to: target,
        imageUrl: imageUrl,
        accent: accent,
        onDone: () {
          entry.remove();
          HapticService.light();
          container.read(miniPlayerBounceProvider.notifier).state++;
        },
      ),
    );
    overlay.insert(entry);
    return true;
  }
}

class _QueueFlyGhost extends StatefulWidget {
  final Offset from;
  final Offset to;
  final String? imageUrl;
  final Color? accent;
  final VoidCallback onDone;

  const _QueueFlyGhost({
    required this.from,
    required this.to,
    required this.imageUrl,
    required this.accent,
    required this.onDone,
  });

  @override
  State<_QueueFlyGhost> createState() => _QueueFlyGhostState();
}

class _QueueFlyGhostState extends State<_QueueFlyGhost>
    with SingleTickerProviderStateMixin {
  static const double _size = 48.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  )
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
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
      // lays out at 48x48; the transforms below are paint-only (no relayout).
      child: Align(
        alignment: Alignment.topLeft,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final double t = _controller.value;
            final double move = Curves.easeInOutCubic.transform(t);
            final Offset pos = Offset.lerp(widget.from, widget.to, move)! -
                // Slight upward arc: picked up, then dropped into the bar.
                Offset(0, math.sin(math.pi * t) * 36.0);
            final double scale =
                1.0 - 0.55 * Curves.easeOutCubic.transform(t);
            final double opacity =
                t < 0.8 ? 1.0 : ((1.0 - t) / 0.2).clamp(0.0, 1.0);
            return Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: pos - const Offset(_size / 2, _size / 2),
                child: Transform.scale(scale: scale, child: child),
              ),
            );
          },
          child: _buildGhost(),
        ),
      ),
    );
  }

  Widget _buildGhost() {
    final String? url = widget.imageUrl;
    final bool hasArt = url != null && url.isNotEmpty;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Static shadow — composited once, never animated on its own.
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
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.queue_music_rounded,
                color: widget.accent != null ? Colors.black : Colors.white,
                size: 24,
              ),
            ),
    );
  }
}
