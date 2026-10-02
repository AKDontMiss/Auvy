import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// The app's one selectable pill: Home's moods, the library filters, the hub
/// filters, What's New, and the option rows in settings and the player menu.
/// Selected is the accent with dark text; unselected a faint fill. One widget,
/// so every pill in the app looks and behaves the same.
class AuvyPill extends ConsumerWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// A small arrow: the pill opens a choice rather than toggling.
  final bool dropdown;

  /// Defaults to the app's theme colour.
  final Color? accent;
  const AuvyPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dropdown = false,
    this.accent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color tint = accent ?? ref.watch(themeProvider);
    final fg = selected ? Colors.black : Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticService.selection();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 36,
          padding: EdgeInsets.only(left: 14, right: dropdown ? 8 : 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? tint : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? tint : const Color(0x14FFFFFF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: selected ? Colors.black : Colors.white60),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 13,
                  )),
              if (dropdown)
                Icon(Icons.arrow_drop_down_rounded, color: selected ? Colors.black : Colors.white70, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
