import 'dart:ui';
import 'package:flutter/material.dart';

// Helper class to display floating animated notifications.
class AnimatedToast {
  // Static method to trigger a toast overlay.
  static void show(BuildContext context, {
    required String text,
    required IconData icon,
    required Color color,
    Offset? startOffset, 
  }) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => _ToastWidget(
        text: text,
        icon: icon,
        color: color,
        startOffset: startOffset ?? const Offset(0, 500),
      ),
    );

    overlay.insert(overlayEntry);

    // Automatically remove the toast after a set duration.
    Future.delayed(const Duration(milliseconds: 3000), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }
}

// Internal widget that handles the toast's visual appearance and animation.
class _ToastWidget extends StatefulWidget {
  final String text;
  final IconData icon;
  final Color color;
  final Offset startOffset;

  const _ToastWidget({
    required this.text,
    required this.icon,
    required this.color,
    required this.startOffset,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _widthAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Animates the expansion of the toast container.
    _widthAnimation = Tween<double>(begin: 40.0, end: 300.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.4, 1.0, curve: Curves.easeOutCubic)),
    );

    // Controls the fading in of text content.
    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.2, 0.8, curve: Curves.easeOut)),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final endOffset = Offset(screenSize.width / 2 - 150, 60);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = CurvedAnimation(parent: _controller, curve: Curves.easeOutQuart).value;
        final currentPos = Offset.lerp(widget.startOffset, endOffset, t)!;

        return Positioned(
          left: currentPos.dx,
          top: currentPos.dy,
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  height: 54,
                  width: _widthAnimation.value,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(widget.icon, color: Colors.black, size: 24),
                      if (_controller.value > 0.5) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Opacity(
                            opacity: _opacityAnimation.value,
                            child: Text(
                              widget.text,
                              style: const TextStyle(
                                color: Colors.black, 
                                fontWeight: FontWeight.bold, 
                                fontSize: 14
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ]
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}