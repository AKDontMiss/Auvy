import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_service.dart'; 
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/presentation/widgets/mini_player.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

// Screen for viewing and managing tracks within a specific playlist or collection.
class PlaylistPage extends ConsumerWidget {
  final LibraryItem playlist;

  const PlaylistPage({super.key, required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.currentSong != null));
    final libState = ref.watch(libraryProvider);
    final libraryNotifier = ref.read(libraryProvider.notifier);
    
    List<Song> tracks = [];
    if (playlist.title == "Liked Songs") {
      tracks = libState.likedSongs;
    } 
    else if (playlist.title == "My Top 50") {
      tracks = ref.read(playerProvider).history.take(50).toList();
    }
    else {
      tracks = libState.playlistSongs[playlist.title] ?? [];
    }

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                // AppBar containing the playlist artwork, title, and subtitle.
                SliverAppBar(
                  backgroundColor: Colors.transparent,
                  pinned: true,
                  elevation: 0,
                  expandedHeight: 300,
                  leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                  flexibleSpace: FlexibleSpaceBar(
                    background: Container(
                      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.purple.withOpacity(0.6), Colors.transparent])),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 60),
                          Container(width: 160, height: 160, decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)]), child: AuvyImage(path: playlist.image, width: 160, height: 160, fit: BoxFit.cover)),
                          const SizedBox(height: 16),
                          Text(playlist.title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                          Text(playlist.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        FloatingActionButton(
                          onPressed: () { if (tracks.isNotEmpty) ref.read(playerProvider.notifier).playSong(tracks.first, newQueue: tracks); },
                          backgroundColor: const Color(0xFF53B1E1),
                          child: const Icon(Icons.play_arrow, color: Colors.black),
                        ),
                    ])),
                ),

                if (tracks.isEmpty)
                  const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32.0), child: Center(child: Text("No songs here yet.", style: TextStyle(color: Colors.grey)))))
                else
                  // List of playlist tracks with reordering and swiping capabilities.
                  SliverReorderableList(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final song = tracks[index];
                      return _SwipeablePlaylistTile(
                        key: ValueKey(song.id),
                        index: index, 
                        song: song,
                        onTap: () => ref.read(playerProvider.notifier).playSong(song, newQueue: tracks, index: index),
                        onDelete: () {
                           if (playlist.title == "Liked Songs") {
                              libraryNotifier.toggleSongLike(song);
                              AnimatedToast.show(context, text: "Removed from Liked Songs", icon: Icons.favorite_border, color: const Color(0xFF53B1E1));
                           } else {
                              libraryNotifier.removeSongFromPlaylist(playlist.title, song.id);
                              AnimatedToast.show(context, text: "Removed from Playlist", icon: Icons.delete_outline, color: const Color(0xFF53B1E1));
                           }
                        },
                        onGoToArtist: () async {
                           final service = SearchService();
                           final results = await service.search(song.artist, 'artist');
                           if (results.isNotEmpty && context.mounted) {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistPage(artist: results.first)));
                           }
                        },
                      );
                    },
                    onReorder: (oldIdx, newIdx) {
                       if (playlist.title == "Liked Songs") {
                          libraryNotifier.reorderLikedSongs(oldIdx, newIdx);
                       } else if (playlist.title != "My Top 50") {
                          libraryNotifier.reorderPlaylistTracks(playlist.title, oldIdx, newIdx);
                       }
                    },
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 140)),
              ],
            ),
            if (hasSong) Align(alignment: Alignment.bottomCenter, child: Container(margin: const EdgeInsets.only(bottom: 10, left: 8, right: 8), child: const MiniPlayer())),
          ],
        ),
      ),
    );
  }
}

// A track list item in a playlist supporting horizontal swipes for deleting or viewing the artist.
class _SwipeablePlaylistTile extends StatefulWidget {
  final int index; 
  final Song song; final VoidCallback onTap; final VoidCallback onDelete; final VoidCallback onGoToArtist;
  const _SwipeablePlaylistTile({super.key, required this.index, required this.song, required this.onTap, required this.onDelete, required this.onGoToArtist});
  @override State<_SwipeablePlaylistTile> createState() => _SwipeablePlaylistTileState();
}

class _SwipeablePlaylistTileState extends State<_SwipeablePlaylistTile> {
  double _dragExtent = 0;
  bool _confirmingDelete = false;
  bool _confirmingArtist = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (details) { setState(() { _dragExtent += details.delta.dx; _dragExtent = _dragExtent.clamp(-150.0, 150.0); }); },
      onHorizontalDragEnd: (details) {
        if (_dragExtent < -60) {
           setState(() { _confirmingDelete = true; _confirmingArtist = false; _dragExtent = -100; });
        } else if (_dragExtent > 60) {
           setState(() { _confirmingArtist = true; _confirmingDelete = false; _dragExtent = 100; });
        } else {
           setState(() { _dragExtent = 0; _confirmingDelete = false; _confirmingArtist = false; });
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: Row(children: [
                if (_dragExtent > 0 || _confirmingArtist)
                  Expanded(child: Container(color: Colors.black, alignment: Alignment.centerLeft, child: GestureDetector(onTap: () { widget.onGoToArtist(); setState(() { _dragExtent = 0; _confirmingArtist = false; }); }, child: Container(width: 100, color: Colors.blueAccent, alignment: Alignment.center, child: const Icon(Icons.person, color: Colors.white))))),
                const Spacer(),
                if (_dragExtent < -60 || _confirmingDelete)
                  Expanded(child: Container(color: Colors.black, alignment: Alignment.centerRight, child: GestureDetector(onTap: () { widget.onDelete(); setState(() { _dragExtent = 0; _confirmingDelete = false; }); }, child: Container(width: 100, color: Colors.red, alignment: Alignment.center, child: const Icon(Icons.delete, color: Colors.white))))),
          ])),
          Transform.translate(
            offset: Offset(_dragExtent, 0),
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                tileColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: SizedBox(width: 48, height: 48, child: AuvyImage(path: widget.song.image, width: 48, height: 48, fit: BoxFit.cover)),
                title: Text(widget.song.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                subtitle: Text(widget.song.artist, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                trailing: ReorderableDragStartListener(
                   index: widget.index,
                   child: const Icon(Icons.drag_handle, color: Colors.white54, size: 24),
                ),
                onTap: widget.onTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}