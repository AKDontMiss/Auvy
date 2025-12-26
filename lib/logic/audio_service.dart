import 'package:auvy/data/youtube_client_config.dart';
import 'package:auvy/logic/metrolist_client.dart';

// Handles high-level audio searching and stream resolving.
class AudioService {
  final MetrolistClient _metrolist = MetrolistClient();

  // Finds the best available stream for a song title and artist.
  Future<Map<String, String>?> getStreamInfo(String title, String artist, {String? songId}) async {
    final query = "$title $artist official explicit song";
    
    try {
      final searchResults = await _metrolist.search(query);
      if (searchResults.isEmpty) return null;

      List<Map<String, dynamic>> explicitTracks = [];
      List<Map<String, dynamic>> otherTracks = [];

      // Filter results to prefer explicit versions and avoid radio edits.
      for (var track in searchResults) {
        final tTitle = track['title'].toString().toLowerCase();
        final isExplicit = track['isExplicit'] == true;
        
        final banned = ['clean', 'radio edit', 'censored', 'version edit', 'edit'];
        final isBanned = banned.any((k) => tTitle.contains(k));

        if (isExplicit && !isBanned) {
          explicitTracks.add(track);
        } else if (!isBanned) {
          otherTracks.add(track);
        }
      }

      String? targetVideoId;
      if (explicitTracks.isNotEmpty) {
        targetVideoId = explicitTracks.first['videoId'];
      } else if (otherTracks.isNotEmpty) {
        targetVideoId = otherTracks.first['videoId'];
      } else {
        targetVideoId = searchResults.first['videoId'];
      }

      // Cycle through client configurations until a valid stream is found.
      for (final client in YouTubeClientConfig.all) {
        final url = await _metrolist.getStreamUrl(targetVideoId!, client);
        if (url != null) {
          return {'url': url, 'user_agent': client.userAgent};
        }
      }
    } catch (e) {
      print("❌ Audio Service Error: $e");
    }
    return null;
  }
}