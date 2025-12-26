import 'package:spotify/spotify.dart';
import 'package:auvy/data/dummy_data.dart';

// Service used to fetch music metadata and top hits via the Spotify API.
class SpotifyService {
  final _credentials = SpotifyApiCredentials(
    "4d972326041244e79c20a0bdd38c7bcc",       
    "7c7456edb3ec499082e069a5ca9aef60"
  );

  late final SpotifyApi _spotify;

  SpotifyService() {
    _spotify = SpotifyApi(_credentials);
  }

  // Fetches a list of top tracks for a predefined artist ID.
  Future<List<Song>> fetchTopHits() async {
    try {
      final tracks = await _spotify.artists.getTopTracks(
        '1Xyo4u8uXC1ZmMpatF05PJ', 
        'US'
      );

      List<Song> songs = [];

      for (var track in tracks) {
        String imageUrl = "https://via.placeholder.com/300";
        if (track.album?.images != null && track.album!.images!.isNotEmpty) {
          imageUrl = track.album!.images!.first.url!;
        }

        songs.add(Song(
          id: track.id ?? '', 
          title: track.name ?? 'Unknown',
          artist: track.artists?.first.name ?? 'Unknown',
          image: imageUrl
        ));
      }

      return songs;
    } catch (e) {
      print("❌ Error fetching Spotify Data: $e");
      return [];
    }
  }
}