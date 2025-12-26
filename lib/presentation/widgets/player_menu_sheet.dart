import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart'; 
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_service.dart';
import 'package:auvy/logic/library_provider.dart'; 
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart'; 

// Modal sheet providing extra options for the currently playing song.
class PlayerMenuSheet extends ConsumerWidget {
  final Song song;

  const PlayerMenuSheet({super.key, required this.song});

  // Searches for and navigates to the album page of the current song.
  void _viewAlbum(BuildContext context) async {
    final service = SearchService();
    Album? foundAlbum;

    try {
      final trackData = await service.getTrackDetails(song.id);
      if (trackData != null && trackData['album'] != null) {
        final albumData = trackData['album'];
        foundAlbum = Album(
          id: albumData['id'].toString(), 
          title: albumData['title'] ?? "Unknown Album",
          image: albumData['cover_medium'] ?? song.image,
          releaseDate: trackData['release_date'] ?? "2024", 
          recordType: "album",
        );
      } else {
        final query = "${song.artist} ${song.title}";
        final searchResults = await service.search(query, 'album');
        if (searchResults.isNotEmpty) {
           final firstResult = searchResults.first;
           foundAlbum = Album(
             id: firstResult.id,
             title: firstResult.title,
             image: firstResult.image,
             releaseDate: '2024',
             recordType: 'album'
           );
        }
      }

      if (foundAlbum != null && context.mounted) {
        Navigator.pop(context); 
        Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumPage(album: foundAlbum!, artistName: song.artist)));
      } else if (context.mounted) {
        AnimatedToast.show(context, text: "Album not found", icon: Icons.error_outline, color: Colors.red);
      }
    } catch (e) {
      if (context.mounted) {
        AnimatedToast.show(context, text: "Connection error", icon: Icons.wifi_off, color: Colors.red);
      }
    }
  }

  // Opens a sheet to select which playlist the song should be added to.
  void _showPlaylistSelector(BuildContext context, WidgetRef ref) {
    final libraryState = ref.read(libraryProvider);
    final userPlaylists = libraryState.allItems.where((item) => item.category == LibraryCategory.playlist && !item.isSystemFolder).toList();
    
    showModalBottomSheet(
      context: context, 
      backgroundColor: const Color(0xFF1E1E1E), 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), 
      builder: (ctx) { 
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16), 
          child: Column(
            mainAxisSize: MainAxisSize.min, 
            children: [
              const Text("Add to Playlist", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), 
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.add_box, color: Colors.white), 
                title: const Text("Create New Playlist", style: TextStyle(color: Colors.white)), 
                onTap: () { Navigator.pop(ctx); _showCreatePlaylistDialog(context, ref); }
              ),
              if (userPlaylists.isNotEmpty) ...[
                const Divider(color: Colors.white12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: userPlaylists.length, 
                    itemBuilder: (context, index) { 
                      final playlist = userPlaylists[index]; 
                      return ListTile(
                        leading: SizedBox(
                          width: 40, 
                          height: 40, 
                          child: AuvyImage(path: playlist.image, width: 40, height: 40)
                        ), 
                        title: Text(playlist.title, style: const TextStyle(color: Colors.white)), 
                        onTap: () { 
                          ref.read(libraryProvider.notifier).addSongToPlaylist(playlist.title, song); 
                          Navigator.pop(ctx); 
                          Navigator.pop(context); 
                          AnimatedToast.show(context, text: "Added to ${playlist.title}", icon: Icons.check, color: const Color(0xFF53B1E1)); 
                        }
                      ); 
                    },
                  ),
                )
              ]
            ],
          ),
        ); 
      }
    );
  }

  // Displays a dialog to name and create a new playlist.
  void _showCreatePlaylistDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context, 
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C), 
        title: const Text("New Playlist", style: TextStyle(color: Colors.white)), 
        content: TextField(controller: controller, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: "Name", hintStyle: TextStyle(color: Colors.white54)), autofocus: true), 
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")), 
          TextButton(onPressed: () { 
            if (controller.text.isNotEmpty) { 
              ref.read(libraryProvider.notifier).addPlaylist(controller.text); 
              ref.read(libraryProvider.notifier).addSongToPlaylist(controller.text, song); 
              Navigator.pop(context); 
              Navigator.pop(context); 
              AnimatedToast.show(context, text: "Playlist Created", icon: Icons.check, color: const Color(0xFF53B1E1)); 
            } 
          }, child: const Text("Create", style: TextStyle(color: const Color(0xFF53B1E1))))
        ]
      )
    );
  }

  // Triggers a visual confirmation for starting a song download.
  void _downloadSong(BuildContext context) {
    Navigator.pop(context); 
    AnimatedToast.show(context, text: "Downloading ${song.title}...", icon: Icons.download_done_rounded, color: const Color(0xFF53B1E1));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(playerProvider.select((s) => s.volume));

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 20, top: 8), decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2)))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFF53B1E1), borderRadius: BorderRadius.circular(24)),
            child: Row(children: [Icon(volume == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.black), Expanded(child: SliderTheme(data: SliderTheme.of(context).copyWith(thumbShape: SliderComponentShape.noThumb, activeTrackColor: Colors.black26, inactiveTrackColor: Colors.transparent, trackHeight: 4), child: Slider(value: volume, onChanged: (val) { ref.read(playerProvider.notifier).setVolume(val); })))])),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBigButton(context, Icons.playlist_add, "Add to playlist", () => _showPlaylistSelector(context, ref)),
              const SizedBox(width: 8),
              _buildBigButton(context, Icons.link, "Copy link", () { Clipboard.setData(ClipboardData(text: "https://music.youtube.com/watch?v=${song.id}")); Navigator.pop(context); AnimatedToast.show(context, text: "Link Copied", icon: Icons.link, color: Color(0xFF53B1E1)); }),
            ],
          ),
          const SizedBox(height: 20),
          _buildListTile(Icons.album_outlined, "View album", () => _viewAlbum(context)), 
          _buildListTile(Icons.download_outlined, "Download", () => _downloadSong(context)),
          _buildListTile(Icons.info_outline, "Details", () { Navigator.pop(context); _showDetailsSheet(context, song); }),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // Opens a separate sheet displaying technical metadata for the song.
  void _showDetailsSheet(BuildContext context, Song song) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (context) { return DraggableScrollableSheet(initialChildSize: 0.6, minChildSize: 0.5, maxChildSize: 0.95, builder: (context, scrollController) { return Container(padding: const EdgeInsets.symmetric(horizontal: 24), decoration: const BoxDecoration(color: Colors.black, borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))), child: ListView(controller: scrollController, children: [const SizedBox(height: 12), Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 20), const Row(children: [Icon(Icons.info_outline, color: Colors.white, size: 22), SizedBox(width: 10), Text("Details", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))]), const SizedBox(height: 30), _detailItem("Title", song.title), _detailItem("Artist", song.artist), _detailItem("Release year", "2024"), _detailItem("Album", "${song.title} (Single)"), _detailItem("Audio type", "audio/mp4"), _detailItem("Itag", "140"), _detailItem("Codecs", "mp4a.40.2"), _detailItem("Bitrate", "128 kbps"), _detailItem("Sample rate", "44.1 kHz"), const SizedBox(height: 20), const Text("Description", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 10), Text("Provided to YouTube by ${song.artist} records. \n\n℗ 2024 ${song.artist} Music Group", style: const TextStyle(color: Colors.grey, fontSize: 14)), const SizedBox(height: 50)])); }); });
  }
  // Helper to build a labeled detail row.
  Widget _detailItem(String label, String value) { return Padding(padding: const EdgeInsets.only(bottom: 20.0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)), const SizedBox(height: 4), Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500))])); }
  // Helper to build a large square action button.
  Widget _buildBigButton(BuildContext context, IconData icon, String label, VoidCallback onTap) { return Expanded(child: GestureDetector(onTap: onTap, child: Container(height: 70, decoration: BoxDecoration(color: const Color(0xFF2C2C2C), borderRadius: BorderRadius.circular(12)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: Colors.white70, size: 26), const SizedBox(height: 4), Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12), textAlign: TextAlign.center)])))); }
  // Helper to build a standard list item for the menu.
  Widget _buildListTile(IconData icon, String title, VoidCallback onTap) { return ListTile(leading: Icon(icon, color: Colors.white70), title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)), contentPadding: EdgeInsets.zero, onTap: onTap); }
}