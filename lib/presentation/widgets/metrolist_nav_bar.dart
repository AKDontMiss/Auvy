import 'package:flutter/material.dart';

// Custom navigation bar component that handles tab switching for the main layout.
class MetrolistNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;

  const MetrolistNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        indicatorColor: Colors.white.withOpacity(0.2),
        labelTextStyle: MaterialStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white70),
        ),
        iconTheme: MaterialStateProperty.resolveWith((states) {
          // Changes icon color based on whether the tab is currently selected.
          if (states.contains(MaterialState.selected)) {
            return const IconThemeData(color: Colors.white, size: 24);
          }
          return const IconThemeData(color: Colors.grey, size: 24);
        }),
      ),
      child: NavigationBar(
        height: 75,
        elevation: 0,
        backgroundColor: Colors.transparent,
        selectedIndex: currentIndex,
        onDestinationSelected: onTap,
        destinations: [
          // Home tab destination.
          NavigationDestination(
            icon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.home_outlined)),
            selectedIcon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.home_rounded)),
            label: 'Home',
          ),
          // Search tab destination.
          NavigationDestination(
            icon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.search_outlined)),
            selectedIcon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.search_rounded)),
            label: 'Search',
          ),
          // Library tab destination.
          NavigationDestination(
            icon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.library_music_outlined)),
            selectedIcon: Transform.translate(offset: const Offset(0, 0), child: const Icon(Icons.library_music_rounded)),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}