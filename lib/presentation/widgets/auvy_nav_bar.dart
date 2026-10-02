import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/coach_marks.dart';

/// Bottom navigation for the main layout. Custom-drawn (no M3 NavigationBar):
/// three destinations with small labels, a soft theme-tinted pill behind the
/// active icon, and a selection haptic — light, no blur, no ripples.
class AuvyNavBar extends ConsumerWidget {
  final int currentIndex;
  final Function(int) onTap;

  const AuvyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.search_outlined, Icons.search_rounded, 'Search'),
    (Icons.library_music_outlined, Icons.library_music_rounded, 'Library'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return SizedBox(
      height: 62,
      child: Row(
        children: [
          for (int i = 0; i < _items.length; i++)
            // Anchored so the interactive walkthrough can spotlight each tab
            // where it actually is, instead of drawing a fake nav bar.
            Expanded(
              child: CoachAnchor(
                id: 'nav.$i',
                child: _buildItem(i, themeColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildItem(int index, Color themeColor) {
    final (icon, selectedIcon, label) = _items[index];
    final bool selected = index == currentIndex;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selection();
        onTap(index);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Soft pill that carries the active state.
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: selected ? 56 : 40,
            height: 30,
            decoration: BoxDecoration(
              color: selected ? themeColor.withOpacity(0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              selected ? selectedIcon : icon,
              color: selected ? themeColor : Colors.white60,
              size: 24,
            ),
          ),
          const SizedBox(height: 3),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: TextStyle(
              color: selected ? Colors.white : Colors.white38,
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              letterSpacing: 0.2,
            ),
            child: Text(label),
          ),
        ],
      ),
    );
  }
}
