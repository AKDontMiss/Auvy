import 'package:flutter/material.dart';
import 'package:auvy/data/dummy_data.dart';

// Utility class containing static methods to show context menus for songs and albums.
class ContentMenus {
  
  // Displays a sheet with various actions related to a specific song.
  static void showSongMenu(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header section showing song info.
              ListTile(
                leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(song.image, width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey,width:50,height:50))),
                title: Text(song.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text("${song.artist} • 3:44", style: const TextStyle(color: Colors.grey)),
                trailing: const Icon(Icons.favorite_border, color: Colors.white),
              ),
              const Divider(color: Colors.white12),
              // Interactive menu options for the song.
              _buildMenuItem(Icons.playlist_play, "Play next"),
              _buildMenuItem(Icons.queue_music, "Add to queue"),
              _buildMenuItem(Icons.playlist_add, "Add to playlist"),
              _buildMenuItem(Icons.download_outlined, "Download"),
              _buildMenuItem(Icons.person_outline, "View artist"),
              _buildMenuItem(Icons.refresh, "Refetch"),
            ],
          ),
        );
      },
    );
  }

  // Displays a sheet with various actions related to a specific album.
  static void showAlbumMenu(BuildContext context, String title, String artist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header section showing album info.
              ListTile(
                leading: Container(width: 50, height: 50, color: Colors.grey[800], child: const Icon(Icons.album, color: Colors.white)),
                title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text("$artist • 3:44", style: const TextStyle(color: Colors.grey)),
              ),
              const Divider(color: Colors.white12),
              
              // Interactive menu options for the album.
              _buildMenuItem(Icons.sensors, "Start radio"),
              _buildMenuItem(Icons.playlist_play, "Play next"),
              _buildMenuItem(Icons.queue_music, "Add to queue"),
              _buildMenuItem(Icons.info_outline, "Details"), 
              _buildMenuItem(Icons.person_outline, "View artist"),
              _buildMenuItem(Icons.album_outlined, "View album"),
              _buildMenuItem(Icons.refresh, "Refetch"),
            ],
          ),
        );
      },
    );
  }

  // Helper method to create a standardized menu item.
  static Widget _buildMenuItem(IconData icon, String text) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
      onTap: () {},
      visualDensity: VisualDensity.compact,
    );
  }
}