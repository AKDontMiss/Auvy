import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';

// Marker placed above the foreground UI so a nested DynamicBackground can detect
// that an ancestor already paints the full-screen backdrop and skip painting its
// own — avoids stacking backdrop layers.
class _DynamicBgScope extends InheritedWidget {
  const _DynamicBgScope({required super.child});
  @override
  bool updateShouldNotify(_DynamicBgScope oldWidget) => false;
}

// App-wide backdrop: a deep dark gradient tinted by the theme colour. The
// playing track's blurred artwork lives only on the PlayerPage; painting it here
// too stacked two blurred copies during the player's open/close animation.
class DynamicBackground extends ConsumerWidget {
  final Widget child;
  // Force painting the backdrop even when nested inside another
  // DynamicBackground (used by modal sheets that float above a page and need
  // their own backdrop rather than seeing the page behind them).
  final bool force;

  const DynamicBackground({super.key, required this.child, this.force = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // If an ancestor DynamicBackground already paints the backdrop (e.g. the
    // global one installed in MaterialApp.builder), just pass the child through.
    if (!force &&
        context.getElementForInheritedWidgetOfExactType<_DynamicBgScope>() != null) {
      return child;
    }

    final themeColor = ref.watch(themeProvider);
    // Pure black (AMOLED): a solid #000 fill instead of the accent-tinted
    // gradient, so those pixels are genuinely off. A ColoredBox rather than a
    // gradient with three identical stops — the shader would still run per frame
    // for a result that never changes.
    final pureBlack = ref.watch(pureBlackProvider);

    return Stack(
      children: [
        Positioned.fill(
          child: pureBlack
              ? const ColoredBox(color: Colors.black)
              : DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.8, -0.8),
                radius: 1.5,
                colors: [
                  themeColor.withOpacity(0.15),
                  const Color(0xFF050505), // Ultra dark grey/black
                  Colors.black,
                ],
              ),
            ),
          ),
        ),
        // Foreground UI, wrapped in the scope marker so any nested
        // DynamicBackground in a descendant page becomes a cheap pass-through.
        _DynamicBgScope(child: child),
      ],
    );
  }
}
