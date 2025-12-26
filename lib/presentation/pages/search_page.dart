import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart'; 
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_provider.dart';
import 'package:auvy/logic/search_service.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/presentation/pages/artist_page.dart'; 
import 'package:auvy/presentation/widgets/auvy_image.dart'; 
import 'package:auvy/presentation/widgets/animated_toast.dart'; 

// Screen for searching music, artists, albums, and playlists.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late TextEditingController _searchController;

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: ref.read(searchQueryProvider));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final resultsAsync = ref.watch(searchResultsProvider);
    final activeFilter = ref.watch(searchFilterProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Search input field with a clear button.
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Container(
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: const Color(0xFF53B1E1),
                  decoration: InputDecoration(
                    hintText: "Search for your vibe...",
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                    prefixIcon: const Icon(Icons.search, color: Colors.white),
                    suffixIcon: query.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, color: Colors.white70), onPressed: () { _searchController.clear(); ref.read(searchQueryProvider.notifier).state = ''; }) : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onChanged: (val) => ref.read(searchQueryProvider.notifier).state = val,
                ),
              ),
            ),
            
            // Chips to filter results by category.
            if (query.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16, bottom: 16),
                child: Row(
                  children: [
                    _FilterChip(label: "All", isSelected: activeFilter == SearchFilter.all, onTap: () { _dismissKeyboard(); ref.read(searchFilterProvider.notifier).state = SearchFilter.all; }),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Songs", isSelected: activeFilter == SearchFilter.songs, onTap: () { _dismissKeyboard(); ref.read(searchFilterProvider.notifier).state = SearchFilter.songs; }),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Artists", isSelected: activeFilter == SearchFilter.artists, onTap: () { _dismissKeyboard(); ref.read(searchFilterProvider.notifier).state = SearchFilter.artists; }),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Albums", isSelected: activeFilter == SearchFilter.albums, onTap: () { _dismissKeyboard(); ref.read(searchFilterProvider.notifier).state = SearchFilter.albums; }),
                    const SizedBox(width: 8),
                    _FilterChip(label: "Playlists", isSelected: activeFilter == SearchFilter.playlists, onTap: () { _dismissKeyboard(); ref.read(searchFilterProvider.notifier).state = SearchFilter.playlists; }),
                  ],
                ),
              ),

            // Scrollable list displaying fetched search results.
            Expanded(
              child: resultsAsync.when(
                data: (results) {
                  if (results.isEmpty && query.isNotEmpty) return const Center(child: Text("No results found", style: TextStyle(color: Colors.white54)));
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final s = results[index];
                      if (s.id.startsWith('artist_')) {
                        return ListTile(
                          tileColor: Colors.transparent,
                          leading: ClipOval(child: Image.network(s.image, width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey[800], width: 50))),
                          title: Text(s.title, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            _dismissKeyboard(); 
                            Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistPage(artist: s)));
                          },
                        );
                      } else if (s.id.startsWith('album_') || s.id.startsWith('playlist_')) {
                        final type = s.id.startsWith('album_') ? 'album' : 'playlist';
                        return _SwipeableCollectionTile(
                          item: s, type: type,
                          onTap: () {
                            _dismissKeyboard(); 
                            _showCollectionPreview(context, s, type);
                          },
                          onQueue: (pos) => _handleCollectionQueue(context, ref, s, type, pos),
                          onLibrary: (pos) => _handleCollectionLibrary(context, ref, s, type, pos),
                        );
                      } else {
                        return _SwipeableSearchTile(
                          song: s, onTap: () {
                            _dismissKeyboard(); 
                            ref.read(playerProvider.notifier).playSong(s, source: "Search");
                          },
                          onQueue: (pos) {
                             bool added = ref.read(playerProvider.notifier).toggleQueue(s);
                             AnimatedToast.show(context, text: added ? "Added to Queue" : "Removed from Queue", icon: added ? Icons.queue_music : Icons.remove_circle_outline, color: const Color(0xFF53B1E1), startOffset: pos);
                          },
                          onPlaylist: (pos) => _handleAddToPlaylist(context, ref, s, pos),
                        );
                      }
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
                error: (e, s) => Center(child: Text("Connection Error", style: const TextStyle(color: Colors.red))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Adds all tracks of an album or playlist to the current playback queue.
  void _handleCollectionQueue(BuildContext context, WidgetRef ref, Song item, String type, Offset tapPos) async {
    AnimatedToast.show(context, text: "Fetching tracks...", icon: Icons.downloading, color: Colors.grey, startOffset: tapPos);
    List<Song> tracks = (type == 'album') ? await SearchService().getAlbumTracks(item.id) : await SearchService().getPlaylistTracks(item.id);
    if (tracks.isNotEmpty && context.mounted) {
      ref.read(playerProvider.notifier).addListToQueue(tracks);
      AnimatedToast.show(context, text: "Added ${tracks.length} tracks", icon: Icons.playlist_add_check, color: const Color(0xFF53B1E1), startOffset: tapPos);
    }
  }

  // Toggles the presence of an album or playlist in the user's library.
  void _handleCollectionLibrary(BuildContext context, WidgetRef ref, Song item, String type, Offset tapPos) async {
    if (type == 'album') {
      final album = Album(id: item.id, title: item.title, image: item.image, releaseDate: '2024', recordType: 'album'); 
      bool added = ref.read(libraryProvider.notifier).toggleAlbumLike(album, item.artist);
      AnimatedToast.show(context, text: added ? "Saved Album" : "Removed Album", icon: Icons.favorite, color: const Color(0xFF53B1E1), startOffset: tapPos);
    } else {
      final tracks = await SearchService().getPlaylistTracks(item.id);
      bool added = ref.read(libraryProvider.notifier).savePlaylistFromSearch(item, tracks); 
      if (context.mounted) AnimatedToast.show(context, text: added ? "Saved Playlist" : "Already in Library", icon: Icons.library_add_check, color: const Color(0xFF53B1E1), startOffset: tapPos);
    }
  }

  // Opens a sheet allowing the user to pick a playlist for the selected song.
  void _handleAddToPlaylist(BuildContext context, WidgetRef ref, Song song, Offset tapPos) {
    final userPlaylists = ref.read(libraryProvider).allItems.where((item) => item.category == LibraryCategory.playlist && !item.isSystemFolder).toList();
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1E1E1E), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) { 
        return Container(padding: const EdgeInsets.symmetric(vertical: 16), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text("Add to Playlist", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), 
              ListTile(leading: const Icon(Icons.add_box, color: Colors.white), title: const Text("Create New Playlist"), onTap: () { Navigator.pop(ctx); _showCreatePlaylistDialog(context, ref, song, tapPos); }),
              if (userPlaylists.isNotEmpty) Flexible(child: ListView.builder(shrinkWrap: true, itemCount: userPlaylists.length, itemBuilder: (context, index) { 
                      final p = userPlaylists[index]; 
                      return ListTile(leading: SizedBox(width: 40, height: 40, child: AuvyImage(path: p.image)), title: Text(p.title, style: const TextStyle(color: Colors.white)), onTap: () { ref.read(libraryProvider.notifier).addSongToPlaylist(p.title, song); Navigator.pop(ctx); AnimatedToast.show(context, text: "Added to ${p.title}", icon: Icons.check, color: const Color(0xFF53B1E1), startOffset: tapPos); }); 
                    })),
        ])); 
    });
  }

  // Shows a dialog for creating a new playlist and adding the song to it.
  void _showCreatePlaylistDialog(BuildContext context, WidgetRef ref, Song song, Offset tapPos) {
    final controller = TextEditingController();
    showDialog(context: context, builder: (context) => AlertDialog(backgroundColor: const Color(0xFF2C2C2C), title: const Text("New Playlist", style: TextStyle(color: Colors.white)), content: TextField(controller: controller, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: "Name", hintStyle: TextStyle(color: Colors.white54)), autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")), TextButton(onPressed: () { if (controller.text.isNotEmpty) { ref.read(libraryProvider.notifier).addPlaylist(controller.text); ref.read(libraryProvider.notifier).addSongToPlaylist(controller.text, song); Navigator.pop(context); AnimatedToast.show(context, text: "Playlist Created", icon: Icons.check, color: const Color(0xFF53B1E1), startOffset: tapPos); } }, child: const Text("Create", style: TextStyle(color: Color(0xFF53B1E1))))]));
  }

  // Opens a preview sheet displaying tracks within an album or playlist.
  void _showCollectionPreview(BuildContext context, Song item, String type) {
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1E1E1E), isScrollControlled: true, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => _CollectionPreviewSheet(item: item, type: type));
  }
}

// Widget representing the bottom sheet content for previewing track collections.
class _CollectionPreviewSheet extends StatefulWidget { 
  final Song item; final String type; 
  const _CollectionPreviewSheet({required this.item, required this.type}); 
  @override State<_CollectionPreviewSheet> createState() => _CollectionPreviewSheetState(); 
} 
class _CollectionPreviewSheetState extends State<_CollectionPreviewSheet> { 
  List<Song> _tracks = []; bool _loading = true; 
  @override void initState() { super.initState(); _fetch(); } 
  Future<void> _fetch() async { 
    final fetched = (widget.type == 'album') ? await SearchService().getAlbumTracks(widget.item.id) : await SearchService().getPlaylistTracks(widget.item.id); 
    if (mounted) setState(() { _tracks = fetched; _loading = false; }); 
  } 
  @override Widget build(BuildContext context) { 
    return Container(height: MediaQuery.of(context).size.height * 0.6, padding: const EdgeInsets.all(16), child: Column(children: [Row(children: [ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(widget.item.image, width: 60, height: 60, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey[800]))), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.item.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold), maxLines: 2), const SizedBox(height: 4), GestureDetector(onTap: () async { final results = await SearchService().search(widget.item.artist, 'artist'); if (results.isNotEmpty && context.mounted) { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistPage(artist: results.first))); } }, child: Text(widget.item.artist, style: const TextStyle(color: Color(0xFF53B1E1), fontSize: 14, fontWeight: FontWeight.bold)))])),]), const Divider(color: Colors.white24, height: 32), if (_loading) const Expanded(child: Center(child: CircularProgressIndicator(color: Colors.white))) else Expanded(child: ListView.builder(itemCount: _tracks.length, itemBuilder: (context, index) { final t = _tracks[index]; return Consumer(builder: (context, ref, _) => ListTile(title: Text(t.title, style: const TextStyle(color: Colors.white)), subtitle: Text(t.artist, style: const TextStyle(color: Colors.grey)), onTap: () { ref.read(playerProvider.notifier).playSong(t, newQueue: _tracks, index: index, source: "Search"); Navigator.pop(context); })); })),])); 
  } 
}

// A song list item in the search results supporting left and right swipe actions.
class _SwipeableSearchTile extends ConsumerStatefulWidget { 
  final Song song; final VoidCallback onTap; final Function(Offset) onQueue; final Function(Offset) onPlaylist; 
  const _SwipeableSearchTile({required this.song, required this.onTap, required this.onQueue, required this.onPlaylist}); 
  @override ConsumerState<_SwipeableSearchTile> createState() => _SwipeableSearchTileState(); 
} 
class _SwipeableSearchTileState extends ConsumerState<_SwipeableSearchTile> { 
  double _dragExtent = 0; bool _confirmingQueue = false; bool _confirmingPlaylist = false; 

  @override Widget build(BuildContext context) {
    ref.listen(activeSwipeIdProvider, (prev, next) {
      if (next != widget.song.id && _dragExtent != 0) {
        setState(() {
          _dragExtent = 0;
          _confirmingQueue = false;
          _confirmingPlaylist = false;
        });
      }
    });

    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (_dragExtent == 0) ref.read(activeSwipeIdProvider.notifier).state = widget.song.id;
        setState(() => _dragExtent = (_dragExtent + d.delta.dx).clamp(-150, 150));
      }, 
      onHorizontalDragEnd: (d) => setState(() { 
        if (_dragExtent < -60) { _confirmingQueue = true; _confirmingPlaylist = false; _dragExtent = -100; } 
        else if (_dragExtent > 60) { _confirmingPlaylist = true; _confirmingQueue = false; _dragExtent = 100; } 
        else { 
          _dragExtent = 0; 
          _confirmingQueue = false; 
          _confirmingPlaylist = false; 
          if (ref.read(activeSwipeIdProvider) == widget.song.id) ref.read(activeSwipeIdProvider.notifier).state = null;
        } 
      }), 
      child: Stack(children: [Positioned.fill(child: Row(children: [if (_dragExtent > 0 || _confirmingPlaylist) Expanded(child: Container(color: Colors.black, alignment: Alignment.centerLeft, child: GestureDetector(onTapDown: (d) { widget.onPlaylist(d.globalPosition); setState(() => _dragExtent = 0); }, child: Container(width: 100, color: const Color(0xFF53B1E1), alignment: Alignment.center, child: const Icon(Icons.playlist_add, color: Colors.black))))), const Spacer(), if (_dragExtent < 0 || _confirmingQueue) Expanded(child: Container(color: Colors.black, alignment: Alignment.centerRight, child: GestureDetector(onTapDown: (d) { widget.onQueue(d.globalPosition); setState(() => _dragExtent = 0); }, child: Container(width: 100, color: const Color(0xFF1DB954), alignment: Alignment.center, child: const Icon(Icons.queue_music, color: Colors.white))))),])), Transform.translate(offset: Offset(_dragExtent, 0), child: Container(color: Colors.transparent, child: ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(widget.song.image, width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey[800], width:50))), title: Text(widget.song.title, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(widget.song.artist, style: const TextStyle(color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis), onTap: widget.onTap)))])); 
  }
}

// An album or playlist item in search results that supports swiping for queueing or saving.
class _SwipeableCollectionTile extends ConsumerStatefulWidget { 
  final Song item; final String type; final VoidCallback onTap; final Function(Offset) onQueue; final Function(Offset) onLibrary; 
  const _SwipeableCollectionTile({required this.item, required this.type, required this.onTap, required this.onQueue, required this.onLibrary}); 
  @override ConsumerState<_SwipeableCollectionTile> createState() => _SwipeableCollectionTileState(); 
} 
class _SwipeableCollectionTileState extends ConsumerState<_SwipeableCollectionTile> { 
  double _dragExtent = 0; bool _confirmQueue = false; bool _confirmLibrary = false; 

  @override Widget build(BuildContext context) {
    ref.listen(activeSwipeIdProvider, (prev, next) {
      if (next != widget.item.id && _dragExtent != 0) {
        setState(() {
          _dragExtent = 0;
          _confirmQueue = false;
          _confirmLibrary = false;
        });
      }
    });

    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (_dragExtent == 0) ref.read(activeSwipeIdProvider.notifier).state = widget.item.id;
        setState(() => _dragExtent = (_dragExtent + d.delta.dx).clamp(-150, 150));
      }, 
      onHorizontalDragEnd: (d) => setState(() { 
        if (_dragExtent < -60) { _confirmQueue = true; _confirmLibrary = false; _dragExtent = -100; } 
        else if (_dragExtent > 60) { _confirmLibrary = true; _confirmQueue = false; _dragExtent = 100; } 
        else { 
          _dragExtent = 0; 
          _confirmQueue = false; 
          _confirmLibrary = false; 
          if (ref.read(activeSwipeIdProvider) == widget.item.id) ref.read(activeSwipeIdProvider.notifier).state = null;
        } 
      }), 
      child: Stack(children: [Positioned.fill(child: Row(children: [if (_dragExtent > 0 || _confirmLibrary) Expanded(child: Container(color: Colors.black, alignment: Alignment.centerLeft, child: GestureDetector(onTapDown: (d) { widget.onLibrary(d.globalPosition); setState(() => _dragExtent = 0); }, child: Container(width: 100, color: const Color(0xFF53B1E1), alignment: Alignment.center, child: Icon(widget.type == 'album' ? Icons.favorite : Icons.library_add, color: Colors.black))))), const Spacer(), if (_dragExtent < -60 || _confirmQueue) Expanded(child: Container(color: Colors.black, alignment: Alignment.centerRight, child: GestureDetector(onTapDown: (d) { widget.onQueue(d.globalPosition); setState(() => _dragExtent = 0); }, child: Container(width: 100, color: const Color(0xFF1DB954), alignment: Alignment.center, child: const Icon(Icons.queue_music, color: Colors.white))))),])), Transform.translate(offset: Offset(_dragExtent, 0), child: Container(color: Colors.transparent, child: ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(widget.item.image, width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey[800], width:50))), title: Text(widget.item.title, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text("${widget.type == 'album' ? 'Album' : 'Playlist'} • ${widget.item.artist}", style: const TextStyle(color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.chevron_right, color: Colors.grey), onTap: widget.item.image.isNotEmpty ? widget.onTap : null)))])); 
  }
}

// A clickable category chip for search filtering.
class _FilterChip extends StatelessWidget { final String label; final bool isSelected; final VoidCallback onTap; const _FilterChip({required this.label, required this.isSelected, required this.onTap}); @override Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.white : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(20)), child: Text(label, style: TextStyle(color: isSelected ? Colors.black : Colors.white))));
}