import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';

/// One side of a swipeable tile: the pill revealed behind the drag.
class SwipeAction {
  final IconData icon;
  final String label;
  final Color color;
  final void Function(Offset globalTapPosition) onTap;

  /// Queue actions fly an artwork ghost down to the mini-player on trigger.
  final bool flyToMiniPlayer;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.flyToMiniPlayer = false,
  });
}

/// The app's single swipe-to-reveal tile: drag right for [leftAction], left
/// for [rightAction]. Medium haptic + solid pill at 80px; releasing past that
/// point COMMITS the action directly (no lock-open-then-tap step). Only one
/// tile app-wide is engaged at a time (activeSwipeIdProvider).
/// A null action disables that side entirely (drag is clamped to 0).
class SwipeActionTile extends ConsumerStatefulWidget {
  final String swipeId;
  final Widget child;

  /// Revealed when dragging RIGHT.
  final SwipeAction? leftAction;

  /// Revealed when dragging LEFT.
  final SwipeAction? rightAction;

  final VoidCallback? onTap;

  /// Press-and-hold action (e.g. open the song options menu). The gesture arena
  /// disambiguates this from a tap and a horizontal swipe automatically.
  final VoidCallback? onLongPress;
  final bool enableTapShrink;

  /// Artwork for the queue ghost flight (used by flyToMiniPlayer actions).
  final String? flyImageUrl;

  const SwipeActionTile({
    super.key,
    required this.swipeId,
    required this.child,
    this.leftAction,
    this.rightAction,
    this.onTap,
    this.onLongPress,
    this.enableTapShrink = false,
    this.flyImageUrl,
  });

  @override
  ConsumerState<SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends ConsumerState<SwipeActionTile>
    with SingleTickerProviderStateMixin {
  // The ValueNotifier drives everything that moves (pills + tile offset) via
  // ValueListenableBuilder — no per-frame setState during a swipe.
  final ValueNotifier<double> _dragExtent = ValueNotifier<double>(0.0);

  Animation<double> _settleAnim = const AlwaysStoppedAnimation(0.0);
  
  // 1. Remove the inline initialization
  late final AnimationController _settle;

  bool _hasTriggeredHaptic = false;
  bool _isDragging = false;
  double _scale = 1.0;

  // 2. Add initState to initialize the controller safely before the widget builds
  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() => _dragExtent.value = _settleAnim.value);
  }

  @override
  void dispose() {
    _settle.dispose();
    _dragExtent.dispose();
    super.dispose();
  }

  // Spring to a rest point (0 or the ±100 lock) instead of jumping there.
  void _settleTo(double target) {
    _settleAnim = Tween<double>(begin: _dragExtent.value, end: target)
        .animate(CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic));
    _settle.forward(from: 0);
  }

  void _releaseIfOwner() {
    if (ref.read(activeSwipeIdProvider) == widget.swipeId) {
      ref.read(activeSwipeIdProvider.notifier).state = null;
    }
  }

  void _close() {
    _hasTriggeredHaptic = false;
    _settleTo(0);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_dragExtent.value == 0) {
      ref.read(activeSwipeIdProvider.notifier).state = widget.swipeId;
    }
    final double min = widget.rightAction == null ? 0.0 : -150.0;
    final double max = widget.leftAction == null ? 0.0 : 150.0;
    _dragExtent.value = (_dragExtent.value + d.delta.dx).clamp(min, max);

    // Haptic guard: vibrate once per threshold crossing.
    if (_dragExtent.value.abs() >= 80 && !_hasTriggeredHaptic) {
      HapticService.medium();
      _hasTriggeredHaptic = true;
    } else if (_dragExtent.value.abs() < 80) {
      _hasTriggeredHaptic = false;
    }
  }

  void _onDragEnd() {
    _isDragging = false;
    final double v = _dragExtent.value;
    // Past the trigger point (pill solid + haptic already fired) a release
    // commits the action outright — swipe IS the gesture, no follow-up tap.
    if (v <= -80 && widget.rightAction != null) {
      _commit(widget.rightAction!, isLeft: false);
    } else if (v >= 80 && widget.leftAction != null) {
      _commit(widget.leftAction!, isLeft: true);
    } else {
      _close();
      _releaseIfOwner();
    }
  }

  // Fire an action from a swipe-release: anchor the callback position (menu
  // placement / fly-ghost origin) to the pill's on-screen center.
  void _commit(SwipeAction action, {required bool isLeft}) {
    final box = context.findRenderObject() as RenderBox?;
    Offset? pos;
    if (box != null && box.attached) {
      pos = box.localToGlobal(
          Offset(isLeft ? 54 : box.size.width - 54, box.size.height / 2));
    }
    action.onTap(pos ?? Offset.zero);
    if (action.flyToMiniPlayer && pos != null) {
      QueueFlyOverlay.fly(
        context,
        from: pos,
        imageUrl: widget.flyImageUrl,
        accent: ref.read(themeProvider),
      );
    }
    _close();
    _releaseIfOwner();
  }

  void _onTap() {
    if (_isDragging) return;
    if (_dragExtent.value.abs() >= 5) {
      // Tap while the drawer is open just closes it.
      _close();
      _releaseIfOwner();
      return;
    }
    widget.onTap?.call();
  }

  void _onPillTap(SwipeAction action, Offset globalPos) {
    action.onTap(globalPos);
    if (action.flyToMiniPlayer) {
      QueueFlyOverlay.fly(
        context,
        from: globalPos,
        imageUrl: widget.flyImageUrl,
        accent: ref.read(themeProvider),
      );
    }
    _close();
    ref.read(activeSwipeIdProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    // One-open-at-a-time: close when any other tile starts a swipe.
    ref.listen(activeSwipeIdProvider, (prev, next) {
      if (next != widget.swipeId && _dragExtent.value != 0) _close();
    });

    return GestureDetector(
      onHorizontalDragStart: (_) {
        _isDragging = true;
        _settle.stop();
      },
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: (_) => _onDragEnd(),
      onTapDown:
          widget.enableTapShrink ? (_) => setState(() => _scale = 0.96) : null,
      onTapUp:
          widget.enableTapShrink ? (_) => setState(() => _scale = 1.0) : null,
      onTapCancel:
          widget.enableTapShrink ? () => setState(() => _scale = 1.0) : null,
      onTap: _onTap,
      // NO onLongPress HERE ANY MORE. See the HoldToOpen below
      //
      // Forwarding it to this GestureDetector gave the user no sign the hold
      // had registered: the tile sat still for half a second and then a sheet
      // appeared. HoldToOpen wraps the content instead and draws the hold as it
      // charges, firing when the ring completes.
      //
      // Placed here rather than at the seven call sites because every one of
      // them passes `onLongPress` through this widget — one edit, and no caller
      // needs to change or even know.
      //
      // The horizontal drag above is unaffected: HoldToOpen listens on raw
      // pointer events without claiming a gesture, and abandons the charge once
      // the finger moves past its slop, which is exactly what starting a swipe
      // looks like.
      child: HoldToOpen(
        onHold: widget.onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
        children: [
          // Action pills behind the tile.
          Positioned.fill(
            child: ValueListenableBuilder<double>(
              valueListenable: _dragExtent,
              builder: (context, extent, _) => Row(
                children: [
                  if (widget.leftAction != null && extent > 0)
                    _buildPill(widget.leftAction!, extent, isLeft: true),
                  const Spacer(),
                  if (widget.rightAction != null && extent < 0)
                    _buildPill(widget.rightAction!, extent, isLeft: false),
                ],
              ),
            ),
          ),
          // The tile itself, sliding with the drag.
          ValueListenableBuilder<double>(
            valueListenable: _dragExtent,
            builder: (context, extent, child) =>
                Transform.translate(offset: Offset(extent, 0), child: child),
            child: widget.enableTapShrink
                ? AnimatedScale(
                    scale: _scale,
                    duration: const Duration(milliseconds: 100),
                    child: widget.child,
                  )
                : widget.child,
          ),
        ],
      ),
    ));
  }

  Widget _buildPill(SwipeAction action, double extent, {required bool isLeft}) {
    final double progress = (extent.abs() / 100).clamp(0.0, 1.0);
    final bool isTriggered = extent.abs() >= 80;
    final Color fg = isTriggered ? Colors.black : Colors.white;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _onPillTap(action, details.globalPosition),
      child: Container(
        // Width minus the outer inset keeps the capsule fully inside the strip
        // the tile has slid away from.
        width: (extent.abs() - 4).clamp(0.0, 140.0),
        margin: EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: isLeft ? 4 : 0,
          right: isLeft ? 0 : 4,
        ),
        decoration: BoxDecoration(
          // Translucent glass at rest; the action color soaks in with the
          // drag and goes solid at trigger.
          color: isTriggered
              ? action.color
              : Color.alphaBlend(
                  action.color.withOpacity(0.15 + 0.25 * progress),
                  Colors.white.withOpacity(0.06),
                ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isTriggered
                ? Colors.transparent
                : Colors.white.withOpacity(0.10),
          ),
          boxShadow: isTriggered
              ? [
                  BoxShadow(
                    color: action.color.withOpacity(0.35),
                    blurRadius: 14,
                    spreadRadius: 1.5,
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              // Content anchored to the outer edge so it doesn't drift while
              // the capsule grows.
              Positioned(
                left: isLeft ? 0 : null,
                right: isLeft ? null : 0,
                top: 0,
                bottom: 0,
                width: 100,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.scale(
                      scale: 0.85 + (0.27 * progress),
                      child: Icon(action.icon, color: fg, size: 22),
                    ),
                    const SizedBox(height: 2),
                    AnimatedOpacity(
                      opacity: extent.abs() > 65 ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 120),
                      child: Text(
                        action.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isTriggered
                              ? Colors.black
                              : Colors.white.withOpacity(0.85),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
