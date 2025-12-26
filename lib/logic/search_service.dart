import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/data/dummy_data.dart'; 
import 'package:auvy/data/artist_model.dart';

// Service for searching and fetching music metadata from the Deezer API.
class SearchService {
  static const String _baseUrl = "https://api.deezer.com";
  static final Map<String, dynamic> _cache = {};

  // Generic search method for tracks, artists, albums, or playlists.
  Future<List<Song>> search(String query, String type) async {
    final cacheKey = "search_$type:$query";
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey] as List<Song>;
    if (query.trim().isEmpty) return [];
    
    String apiType = type == 'track' ? '' : '/$type';

    try {
      final uri = Uri.parse("$_baseUrl/search$apiType").replace(queryParameters: {'q': query, 'limit': '25'});
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['data'] == null) return [];
        final List<dynamic> items = data['data'];

        final results = items.map((item) {
          final id = item['id'].toString();
          if (type == 'artist') {
            return Song(id: 'artist_$id', title: item['name'] ?? 'Unknown', artist: 'Artist', image: item['picture_xl'] ?? item['picture_medium'] ?? '');
          } else if (type == 'album') {
            return Song(id: 'album_$id', title: item['title'] ?? 'Unknown', artist: item['artist']?['name'] ?? 'Unknown', image: item['cover_medium'] ?? '', albumId: id, albumTitle: item['title'] ?? '');
          } else if (type == 'playlist') {
            return Song(id: 'playlist_$id', title: item['title'] ?? 'Unknown', artist: "${item['nb_tracks']} tracks", image: item['picture_medium'] ?? '');
          } else {
            return Song(id: 'track_$id', title: item['title'] ?? 'Unknown', artist: item['artist']?['name'] ?? 'Unknown', image: item['album']?['cover_medium'] ?? '', albumId: item['album']?['id']?.toString() ?? '', albumTitle: item['album']?['title'] ?? '');
          }
        }).toList();

        _cache[cacheKey] = results;
        return results;
      }
    } catch (_) {}
    return [];
  }

  // Removes prefixes from IDs before API calls.
  String _cleanId(String id) => id.contains('_') ? id.split('_').last : id;

  // Fetches top tracks for a specific artist.
  Future<List<Song>> getArtistTopTracks(String artistId) async {
    final cleanId = _cleanId(artistId);
    try {
      final uri = Uri.parse("$_baseUrl/artist/$cleanId/top?limit=30");
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> items = data['data'];
        return items.map((item) => Song(id: 'track_${item['id']}', title: item['title'], artist: item['artist']['name'], image: item['album']['cover_medium'], albumId: item['album']['id'].toString(), albumTitle: item['album']['title'] ?? '')).toList();
      }
    } catch (_) {}
    return [];
  }

  // Retrieves all tracks within an album.
  Future<List<Song>> getAlbumTracks(String albumId) async {
    final cleanId = _cleanId(albumId);
    try {
      final albumResponse = await http.get(Uri.parse("$_baseUrl/album/$cleanId"));
      String albumCover = albumResponse.statusCode == 200 ? jsonDecode(albumResponse.body)['cover_medium'] ?? '' : '';
      final uri = Uri.parse("$_baseUrl/album/$cleanId/tracks?limit=500");
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['data'] as List).map((item) => Song(id: 'track_${item['id']}', title: item['title'], artist: item['artist']['name'], image: albumCover, albumId: cleanId, albumTitle: '')).toList();
      }
    } catch (_) {}
    return [];
  }

  // Retrieves all tracks within a playlist.
  Future<List<Song>> getPlaylistTracks(String playlistId) async {
    final cleanId = _cleanId(playlistId);
    try {
      final uri = Uri.parse("$_baseUrl/playlist/$cleanId/tracks?limit=500");
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['data'] as List).map((item) => Song(id: 'track_${item['id']}', title: item['title'], artist: item['artist']['name'], image: item['album']?['cover_medium'] ?? '', albumId: item['album']?['id']?.toString() ?? '', albumTitle: item['album']?['title'] ?? '')).toList();
      }
    } catch (_) {}
    return [];
  }

  // Fetches an artist's discography.
  Future<List<Album>> getArtistDiscography(String artistId) async { 
    final cleanId = _cleanId(artistId);
    try { 
      final uri = Uri.parse("$_baseUrl/artist/$cleanId/albums?limit=50"); 
      final response = await http.get(uri); 
      if (response.statusCode == 200) { 
        final data = jsonDecode(response.body); 
        return (data['data'] as List).map((item) => Album.fromJson(item)).toList(); 
      } 
    } catch (_) {} return []; 
  }
  
  // Finds artists related to a given artist.
  Future<List<Song>> getRelatedArtists(String artistId) async { 
    final cleanId = _cleanId(artistId);
    try { 
      final uri = Uri.parse("$_baseUrl/artist/$cleanId/related?limit=10"); 
      final response = await http.get(uri); 
      if (response.statusCode == 200) { 
        final data = jsonDecode(response.body); 
        return (data['data'] as List).map((item) => Song(id: 'artist_${item['id']}', title: item['name'], artist: 'Artist', image: item['picture_medium'])).toList(); 
      } 
    } catch (_) {} return []; 
  }
  
  // Fetches public playlists featuring a specific artist.
  Future<List<Song>> getArtistPlaylists(String artistId) async { 
    final cleanId = _cleanId(artistId);
    try { 
      final uri = Uri.parse("$_baseUrl/artist/$cleanId/playlists?limit=10"); 
      final response = await http.get(uri); 
      if (response.statusCode == 200) { 
        final data = jsonDecode(response.body); 
        return (data['data'] as List).map((item) => Song(id: 'playlist_${item['id']}', title: item['title'], artist: "${item['nb_tracks']} tracks", image: item['picture_medium'])).toList(); 
      } 
    } catch (_) {} return []; 
  }
  
  // Fetches detailed metadata for a single track.
  Future<Map<String, dynamic>?> getTrackDetails(String trackId) async { 
    final cleanId = _cleanId(trackId);
    try { 
      final uri = Uri.parse("$_baseUrl/track/$cleanId"); 
      final response = await http.get(uri); 
      if (response.statusCode == 200) return jsonDecode(response.body); 
    } catch (_) {} return null; 
  }
}