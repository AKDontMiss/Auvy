import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/library_integrity.dart';

/// Pins [libraryHasUserContent], the check that decides whether a write is
/// allowed to replace someone's playlists.
///
/// Written after a real data-loss bug: a background folder refresh could persist
/// the EMPTY startup state over a full library and then push the emptiness to
/// the cloud, so the user lost every playlist, like and followed artist
/// overnight. This function is what now refuses that write, which makes a false
/// TRUE here the expensive direction — it would wave the empty save through
/// again. Every "false" case below is therefore a shape a wiped library can
/// actually take.

/// A library as it exists on a fresh install: system folders only.
///
/// Round-tripped through JSON on purpose. Production always hands this function
/// the output of `jsonDecode`, which is `List<dynamic>` / `Map<String, dynamic>`
/// — a literal here would be inferred as a much tighter type and quietly test
/// something the app never actually passes in.
Map<String, dynamic> _emptyLibrary() =>
    jsonDecode(jsonEncode(_freshLiteral())) as Map<String, dynamic>;

Map<String, dynamic> _freshLiteral() => {
      'allItems': [
        {'title': 'Cached', 'isSystemFolder': true},
        {'title': 'Downloads', 'isSystemFolder': true},
        {'title': 'Liked Songs', 'isSystemFolder': true},
        {'title': 'My Top 50', 'isSystemFolder': true},
        {'title': 'Your Artists', 'isSystemFolder': true},
        {'title': 'Liked Albums', 'isSystemFolder': true},
      ],
      'likedSongs': [],
      'likedAlbums': [],
      'likedPlaylists': [],
      'subscribedArtists': [],
      'playlistSongs': {'Cached': [], 'Downloads': []},
    };

void main() {
  test('a fresh install has no user content', () {
    expect(libraryHasUserContent(_emptyLibrary()), isFalse);
  });

  test('an empty map has no user content', () {
    expect(libraryHasUserContent({}), isFalse);
  });

  test('one liked song counts', () {
    final lib = _emptyLibrary()..['likedSongs'] = [
        {'id': 'a', 'title': 'Alpha'}
      ];
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('one liked album counts', () {
    final lib = _emptyLibrary()..['likedAlbums'] = [
        {'id': 'x'}
      ];
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('one liked playlist counts', () {
    final lib = _emptyLibrary()..['likedPlaylists'] = [
        {'title': 'Someone else\'s mix'}
      ];
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('one followed artist counts', () {
    final lib = _emptyLibrary()..['subscribedArtists'] = [
        {'id': 'artist'}
      ];
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('a user-created playlist in the grid counts, even while empty', () {
    // The case that matters most for the Edit-button fix too: a playlist you
    // just made has no tracks yet, and losing it is still losing something.
    final lib = _emptyLibrary();
    (lib['allItems'] as List).add({'title': 'Late night', 'isSystemFolder': false});
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('tracks in a user playlist count', () {
    final lib = _emptyLibrary()..['playlistSongs'] = {
        'Cached': [],
        'Road trip': [
          {'id': 'a'}
        ],
      };
    expect(libraryHasUserContent(lib), isTrue);
  });

  test('a full Cached folder is NOT user content', () {
    // The whole point of the system-title skip. Cached and Downloads fill
    // themselves from disk, so counting them would let a wiped library pass the
    // moment anything had been streamed — which is always.
    final lib = _emptyLibrary()..['playlistSongs'] = {
        'Cached': [
          {'id': 'a'},
          {'id': 'b'}
        ],
        'Downloads': [
          {'id': 'c'}
        ],
      };
    expect(libraryHasUserContent(lib), isFalse);
  });

  test('a system folder missing its flag is still not user content', () {
    // Saves written by older builds carry the title but not isSystemFolder.
    // Matching on title as well is what stops those reading as user playlists.
    final lib = _emptyLibrary()..['allItems'] = [
        {'title': 'Cached'},
        {'title': 'Downloads'},
        {'title': 'Liked Songs'},
      ];
    expect(libraryHasUserContent(lib), isFalse);
  });

  test('unexpected types do not throw', () {
    // This runs inside a guard against data loss. Throwing here would take out
    // the save path itself, which is the failure it exists to prevent.
    expect(
      libraryHasUserContent({
        'allItems': 'not a list',
        'likedSongs': 42,
        'playlistSongs': ['not a map'],
        'subscribedArtists': null,
      }),
      isFalse,
    );
  });

  test('a null entry inside allItems is skipped, not fatal', () {
    final lib = _emptyLibrary();
    (lib['allItems'] as List).add(null);
    expect(libraryHasUserContent(lib), isFalse);
  });
}
