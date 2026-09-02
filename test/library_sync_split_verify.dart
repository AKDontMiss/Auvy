import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/library_sync_split.dart';

/// Pins the incremental library split.
///
/// The property that matters is ROUND-TRIP FIDELITY: whatever goes up must come
/// back identical, or sync becomes a slow way to lose data. The second property
/// is ISOLATION — a damaged part must cost that part and nothing else, which is
/// the entire reason for splitting the monolith in the first place.

Map<String, dynamic> _library() => {
      'allItems': [
        {'title': 'Cached', 'isSystemFolder': true},
        {'title': 'Late night', 'isSystemFolder': false},
      ],
      'likedSongs': [
        {'id': 'a', 'title': 'Alpha'},
        {'id': 'b', 'title': 'Bravo'},
      ],
      'likedAlbums': [
        {'id': 'alb1'}
      ],
      'likedPlaylists': [],
      'subscribedArtists': [
        {'id': 'art1'}
      ],
      'playlistSongs': {
        'Late night': [
          {'id': 'a'}
        ],
        'Road trip': [
          {'id': 'b'},
          {'id': 'c'}
        ],
      },
      'downloadProgressMap': {'a': 1.0},
    };

void main() {
  group('round trip', () {
    test('split then join reproduces the library exactly', () {
      final original = _library();
      final parts = splitLibrary(jsonEncode(original));
      final rejoined = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect(rejoined, equals(original));
    });

    test('each playlist becomes its own part', () {
      // The point of the whole exercise: appending one track must upload one
      // playlist, which is only possible if playlists are separate parts.
      final parts = splitLibrary(jsonEncode(_library()));
      final playlistParts =
          parts.keys.where((k) => k.startsWith('${kLibraryPartPrefix}pl.'));
      expect(playlistParts.length, 2);
    });

    test('changing one playlist changes only that part', () {
      final before = splitLibrary(jsonEncode(_library()));
      final mutated = _library();
      (mutated['playlistSongs'] as Map)['Road trip'] = [
        {'id': 'b'},
        {'id': 'c'},
        {'id': 'd'},
      ];
      final after = splitLibrary(jsonEncode(mutated));

      final changed = <String>[
        for (final k in after.keys)
          if (before[k] != after[k]) k,
      ];
      expect(changed.length, 1);
      expect(changed.single, '${kLibraryPartPrefix}pl.${playlistPartId('Road trip')}');
    });

    test('liking a song leaves every playlist part untouched', () {
      final before = splitLibrary(jsonEncode(_library()));
      final mutated = _library();
      (mutated['likedSongs'] as List).add({'id': 'z', 'title': 'Zulu'});
      final after = splitLibrary(jsonEncode(mutated));

      for (final k in after.keys.where((k) => k.contains('pl.'))) {
        expect(after[k], before[k], reason: '$k should not have changed');
      }
      expect(after['${kLibraryPartPrefix}likedSongs'],
          isNot(before['${kLibraryPartPrefix}likedSongs']));
    });
  });

  group('playlist names', () {
    test('a name with a slash still produces a usable part id', () {
      // Firestore document ids may not contain '/', and playlist names can.
      // Using the name directly here would have made the write fail.
      final parts = splitLibrary(jsonEncode({
        'playlistSongs': {
          'AC/DC favourites': [
            {'id': 'a'}
          ]
        }
      }));
      expect(parts.keys.single, isNot(contains('/')));
      final back = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect((back['playlistSongs'] as Map).keys.single, 'AC/DC favourites');
    });

    test('emoji and non-Latin names survive the round trip', () {
      final parts = splitLibrary(jsonEncode({
        'playlistSongs': {
          '深夜': [
            {'id': 'a'}
          ]
        }
      }));
      final back = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect((back['playlistSongs'] as Map).keys.single, '深夜');
    });

    test('different names get different ids', () {
      expect(playlistPartId('Road trip'), isNot(playlistPartId('Late night')));
      expect(playlistPartId('a'), isNot(playlistPartId('b')));
    });

    test('the same name always gets the same id', () {
      // A drifting id would orphan the old part and re-upload the playlist under
      // a new one on every push — an incremental sync that is never incremental.
      expect(playlistPartId('Road trip'), playlistPartId('Road trip'));
    });
  });

  group('damage isolation', () {
    test('one corrupt playlist part costs only that playlist', () {
      final parts = splitLibrary(jsonEncode(_library()));
      final victim = '${kLibraryPartPrefix}pl.${playlistPartId('Road trip')}';
      parts[victim] = '{not json at all';

      final back = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect((back['playlistSongs'] as Map).containsKey('Road trip'), isFalse);
      expect((back['playlistSongs'] as Map).containsKey('Late night'), isTrue);
      expect((back['likedSongs'] as List).length, 2,
          reason: 'the rest of the library must be untouched');
    });

    test('a corrupt section costs only that section', () {
      final parts = splitLibrary(jsonEncode(_library()));
      parts['${kLibraryPartPrefix}likedSongs'] = '[[[';
      final back = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect(back.containsKey('likedSongs'), isFalse);
      expect((back['allItems'] as List).length, 2);
    });
  });

  group('refusing to guess', () {
    test('unparseable library yields no parts, so the caller can fall back', () {
      // Returning parts here would mean pushing a library we could not read as
      // if we had understood it. Empty tells the caller to push the raw blob.
      expect(splitLibrary('{oh dear'), isEmpty);
    });

    test('null and empty input yield no parts', () {
      expect(splitLibrary(null), isEmpty);
      expect(splitLibrary(''), isEmpty);
    });

    test('joining nothing returns null rather than an empty library', () {
      // null means "fall back to the legacy blob". An empty library object here
      // would look like a successful restore of nothing.
      expect(joinLibrary(const {}), isNull);
      expect(joinLibrary({'unrelated_key': 'x'}), isNull);
    });

    test('a library with no playlists still round-trips', () {
      final parts = splitLibrary(jsonEncode({'likedSongs': [], 'allItems': []}));
      final back = jsonDecode(joinLibrary(parts)!) as Map<String, dynamic>;
      expect(back['likedSongs'], isEmpty);
      expect(back.containsKey('playlistSongs'), isFalse);
    });
  });
}
