import 'package:flutter/material.dart';
import 'package:auvy/services/haptic_service.dart';

/// Wraps a child so it scales down slightly and highlights while pressed,
/// with a haptic tap.
class InteractivePressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final Duration duration;
  final Color? highlightColor;
  final BorderRadius? borderRadius;
  final HitTestBehavior behavior;

  const InteractivePressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.96,
    this.duration = const Duration(milliseconds: 90),
    this.highlightColor,
    this.borderRadius,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<InteractivePressable> createState() => _InteractivePressableState();
}

class _InteractivePressableState extends State<InteractivePressable> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails _) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    setState(() => _isPressed = true);
  }

  void _handleTapUp(TapUpDetails _) {
    if (_isPressed) setState(() => _isPressed = false);
  }

  void _handleTapCancel() {
    if (_isPressed) setState(() => _isPressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = widget.borderRadius ?? BorderRadius.circular(12);

    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: widget.onTap != null
          ? () {
              HapticService.light();
              widget.onTap!();
            }
          : null,
      onLongPress: widget.onLongPress != null
          ? () {
              HapticService.medium();
              widget.onLongPress!();
            }
          : null,
      child: AnimatedScale(
        scale: _isPressed ? widget.scaleDown : 1.0,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: effectiveRadius,
            color: _isPressed
                ? (widget.highlightColor ?? Colors.white.withValues(alpha: 0.10))
                : Colors.transparent,
            border: Border.all(
              color: _isPressed
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.transparent,
              width: 0.8,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
