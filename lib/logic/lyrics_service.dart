import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/data/lyrics_model.dart';

// Service responsible for fetching song lyrics from the LRCLIB API.
class LyricsService {
  static const String _baseUrl = "https://lrclib.net/api";

  // Searches for lyrics based on track name, artist, and optional album name.
  Future<LyricsData?> getLyrics(String track, String artist, {String? album}) async {
    try {
      final cleanTrack = track.split('(')[0].split('-')[0].trim();
      
      final queryParams = {
        'track_name': cleanTrack,
        'artist_name': artist,
      };

      if (album != null && album.isNotEmpty) {
        queryParams['album_name'] = album;
      }
      
      final uri = Uri.parse("$_baseUrl/get").replace(queryParameters: queryParams);

      print("🔍 Searching Lyrics: $uri");
      final response = await http.get(uri);

      // Returns parsed lyrics data if found; attempts a broader search if 404 occurs.
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return LyricsData.fromJson(data);
      } else if (response.statusCode == 404) {
        if (album != null) {
          return getLyrics(track, artist);
        }
        return null;
      }
      return null;
    } catch (e) {
      print("❌ Lyrics Error: $e");
      return null;
    }
  }
}