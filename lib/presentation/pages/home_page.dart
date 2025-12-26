import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/home_provider.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/logic/search_provider.dart'; 
import 'package:auvy/presentation/pages/history_page.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

// The main landing screen displaying personalized music recommendations and categories.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  // Detects when the user nears the bottom of the list to trigger infinite scrolling.
  void _onScroll() {
    final homeState = ref.read(homeProvider);
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 400) {
      if (!homeState.isFetchingMore) {
        ref.read(homeProvider.notifier).fetchNextSection();
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final homeState = ref.watch(homeProvider);
    final playerNotifier = ref.read(playerProvider.notifier);

    if (homeState.isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Invisible layer to dismiss active overlays when tapping empty space.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => ref.read(activeOverlayIdProvider.notifier).state = null,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          
          CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    child: Row(
                      children: [
                        const Text("Home", style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(icon: const Icon(Icons.history, color: Colors.white), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage()))),
                        IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: () => ref.read(homeProvider.notifier).refreshHome()),
                        const SizedBox(width: 8),
                        const CircleAvatar(backgroundColor: Colors.grey, radius: 16, child: Icon(Icons.person, color: Colors.white, size: 20)),
                      ],
                    ),
                  ),
                ),
              ),

              // Filter chips for switching between different listening moods.
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 16, bottom: 20),
                  child: Row(
                    children: [
                      _MoodChip(label: "All", onTap: () => ref.read(homeProvider.notifier).setMood("All"), isSelected: homeState.currentMood == "All"),
                      const SizedBox(width: 8),
                      _MoodChip(label: "Energize", onTap: () => ref.read(homeProvider.notifier).setMood("Energize"), isSelected: homeState.currentMood == "Energize"),
                      const SizedBox(width: 8),
                      _MoodChip(label: "Relax", onTap: () => ref.read(homeProvider.notifier).setMood("Relax"), isSelected: homeState.currentMood == "Relax"),
                      const SizedBox(width: 8),
                      _MoodChip(label: "Focus", onTap: () => ref.read(homeProvider.notifier).setMood("Focus"), isSelected: homeState.currentMood == "Focus"),
                      const SizedBox(width: 8),
                      _MoodChip(label: "Random", onTap: () => ref.read(homeProvider.notifier).setMood("Random"), isSelected: homeState.currentMood == "Random"),
                    ],
                  ),
                ),
              ),

              _buildSectionHeader("Quick picks", subtitle: DateTime.now().hour < 12 ? "Good morning" : "Good evening"),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 170, 
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    itemCount: homeState.quickPicks.length,
                    itemBuilder: (context, index) => _DoubleTapSongTile(song: homeState.quickPicks[index], onTap: () => playerNotifier.playSong(homeState.quickPicks[index], source: "Home")),
                  ),
                ),
              ),

              if (homeState.keepListening.isNotEmpty) ...[
                _buildSectionHeader("Keep listening"),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 170, 
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: homeState.keepListening.length,
                      itemBuilder: (context, index) => _DoubleTapSongTile(song: homeState.keepListening[index], onTap: () => playerNotifier.playSong(homeState.keepListening[index], source: "Home")),
                    ),
                  ),
                ),
              ],

              // Dynamic list of genre or artist-based content sections.
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final section = homeState.feedSections[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12), 
                          child: Text(section.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)
                        ),
                        SizedBox(
                          height: 170,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: section.songs.length,
                            itemBuilder: (ctx, songIndex) => _DoubleTapSongTile(song: section.songs[songIndex], onTap: () => playerNotifier.playSong(section.songs[songIndex], source: "Home")),
                          ),
                        ),
                      ],
                    );
                  },
                  childCount: homeState.feedSections.length,
                ),
              ),

              if (homeState.isFetchingMore) 
                const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(20.0), child: Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)))),

              if (homeState.hasReachedEnd)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.sentiment_satisfied_alt, color: Colors.white24, size: 32),
                          const SizedBox(height: 12),
                          const Text(
                            "Looks like you've reached the end pal",
                            style: TextStyle(color: Colors.white24, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 160)),
            ],
          ),
        ],
      ),
    );
  }

  // Generates a standard section header with an optional subtitle.
  Widget _buildSectionHeader(String title, {String? subtitle}) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle != null) Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 4),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// A song item that supports single-tap for playback and double-tap for quick actions.
class _DoubleTapSongTile extends ConsumerWidget {
  final Song song;
  final VoidCallback onTap;
  const _DoubleTapSongTile({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeOverlayIdProvider);
    final isOverlayActive = activeId == song.id;

    return Container(
      width: 100,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => isOverlayActive ? ref.read(activeOverlayIdProvider.notifier).state = null : onTap(),
              onDoubleTap: () => ref.read(activeOverlayIdProvider.notifier).state = isOverlayActive ? null : song.id, 
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AuvyImage(path: song.image),
                    // Animated overlay providing queue and playlist options.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: ScaleTransition(scale: Tween<double>(begin: 0.8, end: 1.0).animate(anim), child: child)),
                      child: isOverlayActive
                        ? Column(
                            key: const ValueKey('overlay_on'),
                            children: [
                              Expanded(child: GestureDetector(onTapDown: (d) {
                                final added = ref.read(playerProvider.notifier).toggleQueue(song);
                                AnimatedToast.show(context, text: added ? "Added to Queue" : "Removed from Queue", icon: added ? Icons.queue_music : Icons.remove_circle, color: const Color(0xFF53B1E1), startOffset: d.globalPosition);
                                ref.read(activeOverlayIdProvider.notifier).state = null;
                              }, child: Container(color: const Color(0xFF1DB954).withOpacity(0.9), alignment: Alignment.center, child: const Icon(Icons.queue_music, color: Colors.white, size: 28)))),
                              Expanded(child: GestureDetector(onTap: () {
                                ref.read(activeOverlayIdProvider.notifier).state = null;
                                _showPlaylistSelector(context, ref, song);
                              }, child: Container(color: const Color(0xFF53B1E1).withOpacity(0.9), alignment: Alignment.center, child: const Icon(Icons.playlist_add, color: Colors.black, size: 28)))),
                            ],
                          )
                        : const SizedBox.shrink(key: ValueKey('overlay_off')),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(song.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(song.artist, style: const TextStyle(color: Colors.white70, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  // Opens a selection sheet to add the song to a specific playlist.
  void _showPlaylistSelector(BuildContext context, WidgetRef ref, Song song) { 
    final userPlaylists = ref.read(libraryProvider).allItems.where((item) => item.category == LibraryCategory.playlist && !item.isSystemFolder).toList(); 
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1E1E1E), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) { 
        return Container(padding: const EdgeInsets.symmetric(vertical: 16), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text("Add to Playlist", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), 
              ListTile(leading: const Icon(Icons.add_box, color: Colors.white), title: const Text("Create New Playlist"), onTap: () { Navigator.pop(ctx); _showCreatePlaylistDialog(context, ref, song); }),
              if (userPlaylists.isNotEmpty) Flexible(child: ListView.builder(shrinkWrap: true, itemCount: userPlaylists.length, itemBuilder: (context, index) { 
                      final p = userPlaylists[index]; 
                      return ListTile(leading: SizedBox(width: 40, height: 40, child: AuvyImage(path: p.image)), title: Text(p.title, style: const TextStyle(color: Colors.white)), onTap: () { ref.read(libraryProvider.notifier).addSongToPlaylist(p.title, song); Navigator.pop(ctx); AnimatedToast.show(context, text: "Added to ${p.title}", icon: Icons.check, color: const Color(0xFF53B1E1)); }); 
                    })),
        ])); 
    });
  }

  // Displays a dialog to input a name for a new playlist.
  void _showCreatePlaylistDialog(BuildContext context, WidgetRef ref, Song song) { 
    final controller = TextEditingController(); 
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF2C2C2C), 
      title: const Text("New Playlist", style: TextStyle(color: Colors.white)), 
      content: TextField(controller: controller, style: const TextStyle(color: Colors.white), autofocus: true), 
      actions: [
        TextButton(onPressed: () { 
          FocusManager.instance.primaryFocus?.unfocus(); 
          Navigator.pop(context); 
        }, child: const Text("Cancel")), 
        TextButton(onPressed: () { 
          if (controller.text.isNotEmpty) { 
            FocusManager.instance.primaryFocus?.unfocus(); 
            ref.read(libraryProvider.notifier).addPlaylist(controller.text); 
            ref.read(libraryProvider.notifier).addSongToPlaylist(controller.text, song); 
            Navigator.pop(context); 
            AnimatedToast.show(context, text: "Playlist Created", icon: Icons.check, color: const Color(0xFF53B1E1)); 
          } 
        }, child: const Text("Create", style: TextStyle(color: Color(0xFF53B1E1))))
      ]
    )); 
  }
}

// A clickable button used for filtering content categories on the home screen.
class _MoodChip extends StatelessWidget {
  final String label; final VoidCallback onTap; final bool isSelected;
  const _MoodChip({required this.label, required this.onTap, this.isSelected = false});
  @override Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.white : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(20)), child: Text(label, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontSize: 14, fontWeight: FontWeight.w500))));
}