import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/logic/search_provider.dart'; 
import 'package:auvy/presentation/pages/artist_page.dart'; 
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/presentation/pages/playlist_page.dart'; 
import 'package:auvy/data/artist_model.dart'; 
import 'package:auvy/presentation/widgets/auvy_image.dart';

// The main screen displaying the user's collection of playlists, artists, and albums.
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libState = ref.watch(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent, 
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // Animated header that toggles between the library title and a search bar.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _isSearching ? _buildSearchBar(notifier) : _buildDefaultHeader(notifier),
                ),
              ),
            ),

            // Chips used to filter the library view by content category.
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16, bottom: 16),
                child: Row(
                  children: [
                    _FilterChip(label: "Playlists", isSelected: libState.selectedCategory == LibraryCategory.playlist, onTap: () => notifier.setCategory(libState.selectedCategory == LibraryCategory.playlist ? LibraryCategory.all : LibraryCategory.playlist)),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Artists", isSelected: libState.selectedCategory == LibraryCategory.artist, onTap: () => notifier.setCategory(libState.selectedCategory == LibraryCategory.artist ? LibraryCategory.all : LibraryCategory.artist)),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Albums", isSelected: libState.selectedCategory == LibraryCategory.album, onTap: () => notifier.setCategory(libState.selectedCategory == LibraryCategory.album ? LibraryCategory.all : LibraryCategory.album)),
                  ],
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Recents", style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    IconButton(
                      icon: Icon(libState.isGrid ? Icons.grid_view : Icons.list, color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => notifier.toggleView(),
                    ),
                  ],
                ),
              ),
            ),

            // Displays library items in either a grid or a list based on user preference.
            if (libState.isGrid)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.75, crossAxisSpacing: 16, mainAxisSpacing: 16),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = libState.filteredItems[index];
                      return GestureDetector(onTap: () => _handleItemTap(context, item, ref), child: _LibraryGridItem(item: item));
                    },
                    childCount: libState.filteredItems.length,
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = libState.filteredItems[index];
                    return _SwipeableLibraryTile(
                      item: item,
                      onTap: () => _handleItemTap(context, item, ref),
                      onPin: () => notifier.togglePin(item),
                      onDelete: () => _showDeleteConfirmation(context, item, notifier),
                    );
                  },
                  childCount: libState.filteredItems.length,
                ),
              ),
            
            const SliverToBoxAdapter(child: SizedBox(height: 150)),
          ],
        ),
      ),
    );
  }

  // Header sub-widget containing a search input for filtering library items.
  Widget _buildSearchBar(LibraryNotifier notifier) {
    return Container(
      key: const ValueKey('searchBar'),
      height: 48,
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        onChanged: (val) => notifier.setSearchQuery(val),
        decoration: InputDecoration(
          hintText: "Search library",
          hintStyle: const TextStyle(color: Colors.white38),
          prefixIcon: const Icon(Icons.search, color: Colors.white70),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () {
              setState(() => _isSearching = false);
              _searchController.clear();
              notifier.setSearchQuery('');
            },
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  // Header sub-widget displaying the screen title and quick action buttons.
  Widget _buildDefaultHeader(LibraryNotifier notifier) {
    return Row(
      key: const ValueKey('defaultHeader'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text("Library", style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
        Row(
          children: [
            IconButton(icon: const Icon(Icons.search, color: Colors.white, size: 28), onPressed: () => setState(() => _isSearching = true)),
            IconButton(icon: const Icon(Icons.add, color: Colors.white, size: 28), onPressed: () => _showAddPlaylistDialog(context, notifier)),
            const SizedBox(width: 8),
            const CircleAvatar(backgroundColor: Colors.grey, radius: 16, child: Icon(Icons.person, color: Colors.white, size: 20)),
          ],
        ),
      ],
    );
  }

  // Navigates to the appropriate detail page when a library item is clicked.
  void _handleItemTap(BuildContext context, LibraryItem item, WidgetRef ref) {
    _dismissKeyboard();
    if (item.title == "Your Artists") {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const _FolderPage(title: "Your Artists", type: 'artist')));
    } 
    else if (item.title == "Liked Albums") {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const _FolderPage(title: "Liked Albums", type: 'album')));
    } 
    else if (item.title == "Liked Songs" || item.category == LibraryCategory.playlist || item.title == "My Top 50") {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistPage(playlist: item)));
    }
  }

  // Displays a confirmation dialog before removing a playlist from the library.
  void _showDeleteConfirmation(BuildContext context, LibraryItem item, LibraryNotifier notifier) {
    if (item.isSystemFolder) return; 
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("Delete Playlist?", style: TextStyle(color: Colors.white)),
        content: Text("Delete ${item.title}?", style: const TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(onPressed: () { notifier.deleteItem(item); Navigator.pop(ctx); }, child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  // Displays a dialog to input a name for a new custom playlist.
  void _showAddPlaylistDialog(BuildContext context, LibraryNotifier notifier) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("Create Playlist", style: TextStyle(color: Colors.white)),
        content: TextField(controller: controller, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: "Playlist Name", hintStyle: TextStyle(color: Colors.white54)), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(onPressed: () {
            if (controller.text.isNotEmpty) {
              _dismissKeyboard(); 
              notifier.addPlaylist(controller.text);
              Navigator.pop(context);
            }
          }, child: const Text("Create", style: TextStyle(color: Color(0xFF1DB954)))),
        ],
      ),
    );
  }
}

// A generic sub-page used for viewing lists within "Your Artists" or "Liked Albums" folders.
class _FolderPage extends ConsumerWidget {
  final String title;
  final String type;

  const _FolderPage({required this.title, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libState = ref.watch(libraryProvider);
    List<dynamic> items = [];
    if (type == 'artist') items = libState.subscribedArtists;
    else if (type == 'album') items = libState.likedAlbums;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: items.isEmpty 
        ? const Center(child: Text("Empty", style: TextStyle(color: Colors.grey)))
        : ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              String imageUrl = '';
              String titleText = '';
              String subtitleText = '';
              
              if (item is Song) { imageUrl = item.image; titleText = item.title; subtitleText = "Artist"; } 
              else if (item is Album) { imageUrl = item.image; titleText = item.title; subtitleText = "Album"; }

              return ListTile(
                leading: AuvyImage(path: imageUrl, width: 50, height: 50),
                title: Text(titleText, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(subtitleText, style: const TextStyle(color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                   if(type == 'artist') Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistPage(artist: item as Song)));
                   else Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumPage(album: item as Album, artistName: "Unknown")));
                },
              );
            },
          ),
    );
  }
}

// A swipeable library list tile supporting pinning and deletion actions.
class _SwipeableLibraryTile extends ConsumerStatefulWidget { 
  final LibraryItem item;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onDelete;
  const _SwipeableLibraryTile({required this.item, required this.onTap, required this.onPin, required this.onDelete});
  @override ConsumerState<_SwipeableLibraryTile> createState() => _SwipeableLibraryTileState();
}

class _SwipeableLibraryTileState extends ConsumerState<_SwipeableLibraryTile> {
  double _dragExtent = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen(activeSwipeIdProvider, (prev, next) {
      if (next != widget.item.title && _dragExtent != 0) {
        setState(() => _dragExtent = 0);
      }
    });

    return GestureDetector(
      onHorizontalDragUpdate: (details) { 
        if (_dragExtent == 0) ref.read(activeSwipeIdProvider.notifier).state = widget.item.title;
        setState(() { 
          _dragExtent += details.delta.dx; 
          if (widget.item.isSystemFolder) {
            _dragExtent = _dragExtent.clamp(0.0, 100.0); 
          } else {
            _dragExtent = _dragExtent.clamp(-100.0, 100.0); 
          }
        }); 
      },
      onHorizontalDragEnd: (details) { 
        if (_dragExtent > 50) setState(() => _dragExtent = 80); 
        else if (_dragExtent < -50) setState(() => _dragExtent = -80); 
        else {
          setState(() => _dragExtent = 0); 
          if (ref.read(activeSwipeIdProvider) == widget.item.title) {
            ref.read(activeSwipeIdProvider.notifier).state = null;
          }
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: Row(children: [if (_dragExtent > 0) Expanded(child: Container(color: Colors.blue, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 20), child: IconButton(icon: Icon(widget.item.isPinned ? Icons.push_pin_outlined : Icons.push_pin, color: Colors.white), onPressed: () { widget.onPin(); setState(() => _dragExtent = 0); }))), const Spacer(), if (_dragExtent < -50 && !widget.item.isSystemFolder) Expanded(child: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: IconButton(icon: const Icon(Icons.delete, color: Colors.white), onPressed: () { widget.onDelete(); setState(() => _dragExtent = 0); })))])),
          Transform.translate(offset: Offset(_dragExtent, 0), child: Container(color: Colors.transparent, child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), leading: AuvyImage(path: widget.item.image, width: 56, height: 56), title: Text(widget.item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(widget.item.subtitle, style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis), onTap: widget.onTap))),
        ],
      ),
    );
  }
}

// UI component for filtering the library view by category.
class _FilterChip extends StatelessWidget {
  final String label; final bool isSelected; final VoidCallback onTap;
  const _FilterChip({required this.label, required this.isSelected, required this.onTap});
  @override Widget build(BuildContext context) { return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.white : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(20)), child: Text(label, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))); }
}

// UI component representing a library item in grid view.
class _LibraryGridItem extends StatelessWidget {
  final LibraryItem item;
  const _LibraryGridItem({required this.item});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), color: Colors.white.withOpacity(0.05)), child: AuvyImage(path: item.image, width: double.infinity))), 
        const SizedBox(height: 8), 
        Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis), 
        Text(item.subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)
      ]);
  }
}