import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:auvy/data/youtube_client_config.dart';

// Client for interacting directly with YouTube Music internal APIs.
class MetrolistClient {
  static const String _playerUrl = "https://music.youtube.com/youtubei/v1/player";
  static const String _searchUrl = "https://music.youtube.com/youtubei/v1/search";

  // Generates a random string to identify the playback session.
  String _generateCPN() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
    return List.generate(16, (i) => chars[Random().nextInt(chars.length)]).join();
  }

  // Searches for songs and parses relevant metadata from the raw API response.
  Future<List<Map<String, dynamic>>> search(String query) async {
    final payload = {
      "context": {
        "client": { "clientName": "WEB_REMIX", "clientVersion": "1.20240310.01.00", "hl": "en", "gl": "US" }
      },
      "query": query,
      "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D" 
    };

    try {
      final response = await http.post(Uri.parse(_searchUrl), body: jsonEncode(payload));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic>? contents = data['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'];
        
        if (contents == null) return [];

        List<Map<String, dynamic>> results = [];
        for (var section in contents) {
          final shelf = section['musicShelfRenderer'];
          if (shelf != null && shelf['contents'] != null) {
            for (var item in shelf['contents']) {
              final track = item['musicResponsiveListItemRenderer'];
              if (track != null) {
                final vId = track['playlistItemData']?['videoId'];
                final titleRuns = track['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
                final durationRuns = track['flexColumns']?[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
                
                final bool isExplicit = track['badges']?.any((b) => b['musicInlineBadgeRenderer']?['icon']?['iconType'] == 'EXPLICIT') ?? false;

                String duration = "0:00";
                if (durationRuns != null && durationRuns.isNotEmpty) {
                  duration = durationRuns.last['text'];
                }

                if (vId != null) {
                  results.add({
                    'videoId': vId, 
                    'title': titleRuns?[0]['text'], 
                    'durationText': duration,
                    'isExplicit': isExplicit,
                  });
                }
              }
            }
          }
        }
        return results;
      }
    } catch (_) {}
    return [];
  }

  // Retrieves the direct stream URL for a specific video ID using a client configuration.
  Future<String?> getStreamUrl(String videoId, YouTubeClientConfig client) async {
    final Map<String, dynamic> body = {
      "context": {
        "client": { 
          "clientName": client.name, 
          "clientVersion": client.version, 
          "hl": "en", "gl": "US",
          "userAgent": client.userAgent,
        }
      },
      "videoId": videoId,
      "playbackContext": {
        "contentPlaybackContext": {
          "signatureTimestamp": 20120 
        }
      }
    };

    final headers = {
      "User-Agent": client.userAgent,
      "Content-Type": "application/json",
      "X-Youtube-Client-Name": client.clientId,
      "X-Youtube-Client-Version": client.version,
      "Origin": "https://music.youtube.com",
    };

    try {
      final response = await http.post(Uri.parse(_playerUrl), headers: headers, body: jsonEncode(body));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final streamingData = data['streamingData'];
        
        if (streamingData == null) return null;

        if (streamingData['hlsManifestUrl'] != null) return streamingData['hlsManifestUrl'];
        
        final formats = streamingData['adaptiveFormats'] as List<dynamic>?;
        if (formats != null) {
          final audioStreams = formats.where((f) => f['mimeType'].toString().contains('audio')).toList();
          audioStreams.sort((a, b) {
            if (a['itag'] == 251) return -1;
            if (b['itag'] == 251) return 1;
            return (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0);
          });
          
          if (audioStreams.isNotEmpty) {
            String url = audioStreams.first['url'];
            return url.contains('cpn=') ? url : "$url&cpn=${_generateCPN()}";
          }
        }
      }
    } catch (_) {}
    return null;
  }
}