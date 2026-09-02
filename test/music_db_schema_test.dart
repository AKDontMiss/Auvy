import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/music_db_schema.dart';

/// The point of the schema layer is that NO app is special. These fixtures are
/// three genuinely different shapes: the InnerTune-family schema (verified
/// against a real backup), a plainer one-table player, and a hostile file.
void main() {
  Future<MusicDbMap?> discover(Map<String, List<String>> schema) =>
      MusicDbMap.discoverWith(
          schema.keys, (t) async => schema[t] ?? const []);

  group('InnerTune-family schema (real, verified against a backup)', () {
    final schema = {
      'song': [
        'id', 'title', 'duration', 'thumbnailUrl', 'albumId', 'albumName',
        'explicit', 'year', 'liked', 'likedDate', 'totalPlayTime', 'inLibrary',
        'isLocal', 'isDownloaded'
      ],
      'artist': ['id', 'name', 'thumbnailUrl', 'channelId', 'bookmarkedAt'],
      'album': ['id', 'title', 'year', 'thumbnailUrl', 'bookmarkedAt'],
      'playlist': ['id', 'name', 'browseId', 'createdAt', 'bookmarkedAt'],
      'song_artist_map': ['songId', 'artistId', 'position'],
      'playlist_song_map': ['id', 'playlistId', 'songId', 'position'],
      'event': ['id', 'songId', 'timestamp', 'playTime'],
      'search_history': ['id', 'query'],
      'playCount': ['song', 'year', 'month', 'count'],
      'format': ['id', 'itag', 'mimeType'],
      'android_metadata': ['locale'],
    };

    test('every table is found', () async {
      final map = await discover(schema);
      expect(map, isNotNull);
      expect(map!.tracks.name, 'song');
      expect(map.artists?.name, 'artist');
      expect(map.albums?.name, 'album');
      expect(map.playlists?.name, 'playlist');
      expect(map.playlistTracks?.name, 'playlist_song_map');
      expect(map.trackArtists?.name, 'song_artist_map');
      expect(map.events?.name, 'event');
      expect(map.searches?.name, 'search_history');
      expect(map.playCounts?.name, 'playCount');
    });

    test('columns resolve to the right ones, not merely to something', () async {
      final map = (await discover(schema))!;
      expect(map.tracks['id'], 'id');
      expect(map.tracks['title'], 'title');
      expect(map.tracks['image'], 'thumbnailUrl');
      expect(map.tracks['albumName'], 'albumName');
      expect(map.tracks['liked'], 'liked');
      expect(map.tracks['likedDate'], 'likedDate');
      expect(map.tracks['totalPlayTime'], 'totalPlayTime');
      expect(map.events?['song'], 'songId');
      expect(map.events?['timestamp'], 'timestamp');
      expect(map.playlistTracks?['playlist'], 'playlistId');
      expect(map.playlistTracks?['position'], 'position');
      expect(map.playCounts?['count'], 'count');
    });

    test('title wins over name when a table has both', () async {
      final map = (await discover({
        'song': ['id', 'title', 'name'],
      }))!;
      expect(map.tracks['title'], 'title');
    });
  });

  group('a different player entirely', () {
    test('one flat table, snake_case, artist on the row', () async {
      final map = await discover({
        'tracks': [
          '_id', 'track_name', 'artist_name', 'album_name', 'artwork_url',
          'duration_ms', 'is_favorite', 'date_added', 'play_count'
        ],
        'playlists': ['_id', 'name'],
        'playlist_track': ['playlist_id', 'track_id', 'sort_order'],
        'listening_history': ['track_id', 'played_at'],
      });
      expect(map, isNotNull);
      expect(map!.tracks.name, 'tracks');
      expect(map.tracks['id'], '_id');
      expect(map.tracks['title'], 'track_name');
      expect(map.tracks['artist'], 'artist_name');
      expect(map.tracks['image'], 'artwork_url');
      expect(map.tracks['duration'], 'duration_ms');
      expect(map.tracks['liked'], 'is_favorite');
      expect(map.playlists?.name, 'playlists');
      expect(map.playlistTracks?.name, 'playlist_track');
      expect(map.playlistTracks?['position'], 'sort_order');
      expect(map.events?.name, 'listening_history');
      expect(map.events?['timestamp'], 'played_at');
    });

    test('a renamed fork is still matched by substring', () async {
      final map = await discover({
        'music_songs_v2': ['id', 'title', 'artist'],
      });
      expect(map, isNotNull);
      expect(map!.tracks.name, 'music_songs_v2');
    });
  });

  group('refusals', () {
    test('a database with no track-shaped table maps to nothing', () async {
      expect(
          await discover({
            'settings': ['key', 'value'],
            'cache': ['url', 'blob'],
          }),
          isNull);
    });

    test('a track table with no title is unusable', () async {
      expect(
          await discover({
            'song': ['id', 'duration', 'bitrate'],
          }),
          isNull);
    });

    test('an identifier that is not an identifier is ignored, not escaped',
        () async {
      // A crafted backup naming a column so it would break out of the query.
      const nasty = 'x"; DROP TABLE song; --';
      expect(isSafeIdentifier(nasty), isFalse);
      final map = await discover({
        'song': ['id', 'title', nasty],
      });
      expect(map, isNotNull);
      expect(map!.tracks.columns.values, isNot(contains(nasty)));
    });

    test('a table whose NAME is unsafe is not selected', () async {
      expect(
          await discover({
            'song"; DROP TABLE x; --': ['id', 'title'],
          }),
          isNull);
    });
  });
}
