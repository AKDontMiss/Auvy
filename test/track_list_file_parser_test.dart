import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/services/track_list_file_parser.dart';

/// Fixtures use the ACTUAL shapes Spotify's "Download your data" export ships —
/// `Playlist1.json`, `YourLibrary.json` and both generations of the streaming
/// history file — because a parser written against a guessed shape is a parser
/// that fails on the one file the user actually has.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('auvy_parser_test');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> write(String name, Object json) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString(json is String ? json : jsonEncode(json));
    return f;
  }

  test('Spotify Playlist1.json — playlists, order, local tracks', () async {
    final f = await write('Playlist1.json', {
      'playlists': [
        {
          'name': 'Late Night',
          'lastModifiedDate': '2026-01-02',
          'items': [
            {
              'track': {
                'trackName': 'Dandelions',
                'artistName': 'Ruth B.',
                'albumName': 'Safe Haven',
                'trackUri': 'spotify:track:abc'
              },
              'episode': null,
              'localTrack': null,
              'addedDate': '2026-01-01'
            },
            {
              'track': {
                'trackName': 'Runaway',
                'artistName': 'AURORA',
                'albumName': 'All My Demons',
                'trackUri': 'spotify:track:def'
              },
            },
            // A podcast episode in a playlist: not a song, must not become one.
            {'track': null, 'episode': {'episodeName': 'Some Pod'}},
            // A local file the user added.
            {
              'localTrack': {'trackName': 'Home Demo', 'artistName': 'Me'}
            },
          ]
        },
        {'name': 'Empty', 'items': []},
      ]
    });

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    expect(parsed!.sourceApp, 'Spotify');
    expect(parsed.groups.length, 1, reason: 'the empty playlist is skipped');
    final g = parsed.groups.first;
    expect(g.name, 'Late Night');
    expect(g.kind, GroupKind.playlist);
    expect(g.queries, [
      'Dandelions Ruth B.',
      'Runaway AURORA',
      'Home Demo Me',
    ]);
  });

  test('Spotify YourLibrary.json — liked tracks', () async {
    final f = await write('YourLibrary.json', {
      'tracks': [
        {'artist': 'Ruth B.', 'album': 'Safe Haven', 'track': 'Dandelions',
          'uri': 'spotify:track:abc'},
        {'artist': 'Aya Nakamura', 'album': 'NAKAMURA', 'track': 'Djadja',
          'uri': 'spotify:track:xyz'},
      ],
      'albums': [
        {'artist': 'AURORA', 'album': 'All My Demons', 'uri': 'spotify:album:1'}
      ],
      'shows': [],
      'episodes': [],
    });

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    expect(parsed!.groups.length, 1);
    expect(parsed.groups.first.kind, GroupKind.liked);
    expect(parsed.groups.first.name, 'Liked Songs');
    expect(parsed.groups.first.queries,
        ['Dandelions Ruth B.', 'Djadja Aya Nakamura']);
  });

  test('Spotify streaming history (old shape) ranks by plays and drops skips',
      () async {
    final f = await write('StreamingHistory_music_0.json', [
      {'endTime': '2026-01-01 10:00', 'artistName': 'A', 'trackName': 'One',
        'msPlayed': 200000},
      {'endTime': '2026-01-01 11:00', 'artistName': 'A', 'trackName': 'One',
        'msPlayed': 210000},
      {'endTime': '2026-01-01 12:00', 'artistName': 'B', 'trackName': 'Two',
        'msPlayed': 190000},
      // Under 30s — a skip, not a listen.
      {'endTime': '2026-01-01 13:00', 'artistName': 'C', 'trackName': 'Three',
        'msPlayed': 4000},
    ]);

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    final q = parsed!.groups.first.queries;
    expect(q.first, 'One A', reason: 'two plays outranks one');
    expect(q, isNot(contains('Three C')));
    expect(q.length, 2);
  });

  test('Spotify streaming history (current shape)', () async {
    final f = await write('Streaming_History_Audio_2026_1.json', [
      {
        'ts': '2026-01-01T10:00:00Z',
        'ms_played': 240000,
        'master_metadata_track_name': 'Dandelions',
        'master_metadata_album_artist_name': 'Ruth B.',
      },
      {
        'ts': '2026-01-01T10:05:00Z',
        'ms_played': 1000,
        'master_metadata_track_name': 'Skipped',
        'master_metadata_album_artist_name': 'Nobody',
      },
    ]);

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    expect(parsed!.groups.first.queries, ['Dandelions Ruth B.']);
  });

  test('Exportify-style CSV, quoted fields and commas inside them', () async {
    final f = await write(
        'my_playlist.csv',
        'Track URI,Track Name,Artist Name(s),Album Name\n'
        'spotify:track:1,"Hello, Goodbye","The Beatles",Magical Mystery Tour\n'
        'spotify:track:2,Dandelions,Ruth B.,Safe Haven\n'
        '\n');

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    expect(parsed!.groups.first.name, 'my playlist');
    expect(parsed.groups.first.queries,
        ['Hello, Goodbye The Beatles', 'Dandelions Ruth B.']);
  });

  test('a generic json list of tracks still imports', () async {
    final f = await write('songs_export.json', [
      {'title': 'One', 'artist': 'A'},
      {'title': 'Two', 'artists': ['B', 'C']},
      {'name': 'Three', 'albumArtist': 'D'},
    ]);

    final parsed = await TrackListFileParser.parse(f);
    expect(parsed, isNotNull);
    expect(parsed!.groups.first.queries, ['One A', 'Two B', 'Three D']);
  });

  test('nothing usable returns null rather than an empty import', () async {
    final settings = await write('config.json', {'theme': 'dark', 'volume': 5});
    expect(await TrackListFileParser.parse(settings), isNull);

    final notJson = File('${tmp.path}/random.json');
    await notJson.writeAsString('this is not json at all');
    expect(await TrackListFileParser.parse(notJson), isNull);
  });

  test('a re-added track is not imported twice, and order is kept', () async {
    final f = await write('Playlist1.json', {
      'playlists': [
        {
          'name': 'Dupes',
          'items': [
            {'track': {'trackName': 'One', 'artistName': 'A'}},
            {'track': {'trackName': 'Two', 'artistName': 'B'}},
            {'track': {'trackName': 'One', 'artistName': 'A'}},
          ]
        }
      ]
    });
    final parsed = await TrackListFileParser.parse(f);
    expect(parsed!.groups.first.queries, ['One A', 'Two B']);
  });
}
