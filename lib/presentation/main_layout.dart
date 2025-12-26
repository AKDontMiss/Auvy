import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_provider.dart'; 
import 'package:auvy/presentation/pages/home_page.dart';
import 'package:auvy/presentation/pages/library_page.dart';
import 'package:auvy/presentation/pages/search_page.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/metrolist_nav_bar.dart';
import 'package:auvy/presentation/widgets/mini_player.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

// Main container widget that handles navigation and the persistent player UI.
class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  int _selectedIndex = 0;
  DateTime? _lastBackPressTime; 

  // List of main pages accessible via the navigation bar.
  final List<Widget> _pages = [
    const HomePage(),
    const SearchPage(),
    const LibraryPage(),
  ];

  // Updates the active page index.
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(playerProvider);
    final hasSong = playerState.currentSong != null;

    return PopScope(
      canPop: false, 
      onPopInvoked: (didPop) {
        if (didPop) return;

        // Prevent app exit if the keyboard is active.
        if (MediaQuery.of(context).viewInsets.bottom > 0) {
          return;
        }

        // Close any active UI overlays before navigating back.
        if (ref.read(activeOverlayIdProvider) != null) {
          ref.read(activeOverlayIdProvider.notifier).state = null;
          return;
        }

        // Return to the home page if on a different tab.
        if (_selectedIndex != 0) {
          setState(() => _selectedIndex = 0);
          return;
        }

        // Require two back presses within two seconds to exit the app.
        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          AnimatedToast.show(
            context, 
            text: "Press back again to exit", 
            icon: Icons.exit_to_app, 
            color: Colors.white24
          );
        } else {
          SystemNavigator.pop(); 
        }
      },
      child: DynamicBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent, 
          resizeToAvoidBottomInset: false, 
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: _pages,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Display the mini player if a song is currently loaded.
                      if (hasSong) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8), 
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)],
                            ),
                            child: const MiniPlayer(),
                          ),
                        ),
                      ],
                      // Navigation bar positioned at the bottom.
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212).withOpacity(0.95), 
                          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.1))),
                        ),
                        child: MetrolistNavBar(
                          currentIndex: _selectedIndex,
                          onTap: _onItemTapped,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}