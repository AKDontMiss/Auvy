import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_service.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/widgets/mini_player.dart';

// Provider responsible for fetching all track metadata for a specific album ID.
final albumTracksProvider = FutureProvider.family<List<Song>, String>((ref, albumId) async {
  return await SearchService().getAlbumTracks(albumId);
});

// Detailed view for an album, displaying its cover, release info, and tracklist.
class AlbumPage extends ConsumerWidget {
  final Album album;
  final String artistName;

  const AlbumPage({super.key, required this.album, required this.artistName});

  // Displays a snackbar notification simulating an album download process.
  void _startDownload(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [Icon(Icons.download, color: Colors.black), SizedBox(width: 8), Text("Downloading album...", style: TextStyle(color: Colors.black))]),
        backgroundColor: const Color(0xFF53B1E1), 
        duration: const Duration(seconds: 2),
      )
    );
    Future.delayed(const Duration(seconds: 3), () {
        if(context.mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(
               content: Text("Download complete!", style: TextStyle(color: Colors.black)), 
               backgroundColor: Color(0xFF53B1E1) 
             )
           );
        }
    });
  }

  // Notifies the user that the sharing options are being opened.
  void _shareAlbum(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Opening Share Sheet..."), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(albumTracksProvider(album.id));
    final isLiked = ref.watch(libraryProvider.select((s) => ref.read(libraryProvider.notifier).isAlbumLiked(album.title)));
    final hasSong = ref.watch(playerProvider.select((s) => s.currentSong != null));
    final isShuffleOn = ref.watch(playerProvider.select((s) => s.isShuffle));

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // Header with a large album cover and blurred background.
              SliverAppBar(
                backgroundColor: const Color(0xFF121212),
                pinned: true,
                expandedHeight: 350,
                leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.white),
                    onPressed: () => _shareAlbum(context),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 60),
                      Container(width: 200, height: 200, decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20)]), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(album.image, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey)))),
                      const SizedBox(height: 20),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(album.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold))),
                      Text("$artistName • ${album.releaseDate.split('-')[0]}", style: const TextStyle(color: Colors.grey, fontSize: 14)),
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
                      Row(
                        children: [
                          IconButton(icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Color(0xFF53B1E1) : Colors.white, size: 28), onPressed: () => ref.read(libraryProvider.notifier).toggleAlbumLike(album, artistName)),
                          IconButton(
                            icon: const Icon(Icons.download_outlined, color: Colors.white, size: 28), 
                            onPressed: () => _startDownload(context), 
                          ),
                          IconButton(icon: const Icon(Icons.more_vert, color: Colors.white, size: 28), onPressed: () => ContentMenus.showAlbumMenu(context, album.title, artistName)),
                        ],
                      ),
                      
                      Row(
                        children: [
                          InkWell(
                            onTap: () {
                              tracksAsync.whenData((tracks) {
                                if (tracks.isNotEmpty) {
                                  ref.read(playerProvider.notifier).playSong(tracks.first, newQueue: tracks);
                                }
                              });
                            },
                            child: Container(
                              height: 45, width: 90,
                              decoration: BoxDecoration(color: const Color(0xFF53B1E1), borderRadius: BorderRadius.circular(24)),
                              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.play_arrow, color: Colors.black), Text("Play", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))]),
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () {
                               ref.read(playerProvider.notifier).toggleShuffle(); 
                            },
                            child: Container(
                              height: 45, width: 100,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2C2C2C), 
                                borderRadius: BorderRadius.circular(24),
                                border: isShuffleOn ? Border.all(color: Color(0xFF53B1E1), width: 2) : null, 
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center, 
                                children: [
                                  Icon(Icons.shuffle, color: isShuffleOn ? Color(0xFF53B1E1) : Colors.white, size: 20), 
                                  const SizedBox(width: 4), 
                                  Text("Shuffle", style: TextStyle(color: isShuffleOn ? Color(0xFF53B1E1) : Colors.white, fontWeight: FontWeight.bold))
                                ]
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Renders the list of tracks contained within the album.
              tracksAsync.when(
                data: (tracks) => SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = tracks[index];
                      final fullSong = Song(id: song.id, title: song.title, artist: song.artist, image: album.image, audioUrl: song.audioUrl);
                      return ListTile(
                        leading: Text("${index + 1}", style: const TextStyle(color: Colors.grey)),
                        title: Text(fullSong.title, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(fullSong.artist, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                        trailing: IconButton(icon: const Icon(Icons.more_vert, color: Colors.grey), onPressed: () => ContentMenus.showSongMenu(context, fullSong)),
                        onTap: () => ref.read(playerProvider.notifier).playSong(fullSong, newQueue: tracks, index: index, source: "Album"), 
                      );
                    },
                    childCount: tracks.length,
                  ),
                ),
                loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator(color: Colors.white))),
                error: (e, s) => SliverToBoxAdapter(child: Center(child: Text("Error: $e"))),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
          if (hasSong) Align(alignment: Alignment.bottomCenter, child: Container(color: const Color(0xFF121212), child: const MiniPlayer())),
        ],
      ),
    );
  }
}