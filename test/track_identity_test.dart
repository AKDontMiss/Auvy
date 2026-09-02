import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/track_identity.dart';

/// The cases this matcher exists for, and the ones it must NOT match.
///
/// The reported bug: play a song from a playlist, open its album from the player
/// page, and the album's row for that same recording stayed unmarked because the
/// album edition carries a different id.
void main() {
  bool same(String aTitle, String aArtist, String bTitle, String bArtist,
          {String aId = 'idA', String bId = 'idB', String? bAlt}) =>
      isSameTrack(
        playingId: aId,
        playingTitle: aTitle,
        playingArtist: aArtist,
        rowId: bId,
        rowAltId: bAlt,
        rowTitle: bTitle,
        rowArtist: bArtist,
      );

  group('matches the same recording across pages', () {
    test('identical title and artist, different ids', () {
      expect(same('Dandelions', 'Ruth B.', 'Dandelions', 'Ruth B.'), isTrue);
    });

    test('id match still wins outright', () {
      expect(same('anything', 'x', 'other', 'y', aId: 'same', bId: 'same'),
          isTrue);
    });

    test('conformed alt id', () {
      expect(
          same('a', 'x', 'b', 'y', aId: 'audio1', bId: 'video1', bAlt: 'audio1'),
          isTrue);
    });

    test('video noise in the title', () {
      expect(
          same('Dandelions (Official Video)', 'Ruth B.', 'Dandelions',
              'Ruth B.'),
          isTrue);
      expect(same('Runaway [Lyrics]', 'Aurora', 'Runaway', 'Aurora'), isTrue);
      expect(same('Song (4K Remaster)', 'A', 'Song', 'A'), isTrue);
    });

    test('feat credited on one side only', () {
      expect(
          same('Real Nigga (feat. 21 Savage)', 'Metro Boomin', 'Real Nigga',
              'Metro Boomin'),
          isTrue);
      expect(same('Track ft. Someone', 'A', 'Track', 'A'), isTrue);
    });

    test('extra credited artists on one side only', () {
      expect(same('Track', 'Metro Boomin, 21 Savage', 'Track', 'Metro Boomin'),
          isTrue);
      expect(same('Track', 'A & B', 'Track', 'A'), isTrue);
    });

    test('punctuation and case differences', () {
      expect(same("Don't Stop", 'Artist', 'dont stop', 'artist'), isTrue);
    });

    test('album row with no per-track credit', () {
      expect(same('Nakamura', 'Aya Nakamura', 'Nakamura', ''), isTrue);
    });
  });

  group('does not match different recordings', () {
    test('a remix is not the original', () {
      expect(same('Song (Remix)', 'A', 'Song', 'A'), isFalse);
      expect(same('Song - Live', 'A', 'Song', 'A'), isFalse);
    });

    test('same title, different artist', () {
      expect(same('Hello', 'Adele', 'Hello', 'Lionel Richie'), isFalse);
    });

    test('different titles', () {
      expect(same('Hello', 'Adele', 'Hometown Glory', 'Adele'), isFalse);
    });

    test('an empty title can only ever match by id', () {
      expect(same('', '', '', ''), isFalse);
    });
  });

  group('collection tiles must not match a track by title alone', () {
    // The home mosaic stores a radio station or a playlist AS a Song, so a
    // collection named after a track lit up whenever that track played — two
    // tiles both claiming to be the current track.
    test('requireArtist refuses the title-only fallback', () {
      bool match({required bool requireArtist}) => isSameTrack(
            playingId: 'realVideoId',
            playingTitle: "I Think We're Alone Now",
            playingArtist: 'Tiffany',
            rowId: 'collection_entry',
            rowTitle: "I Think We're Alone Now",
            rowArtist: '', // a playlist / station carries no credit
            requireArtist: requireArtist,
          );
      expect(match(requireArtist: false), isTrue,
          reason: 'a track row still matches leniently');
      expect(match(requireArtist: true), isFalse,
          reason: 'a collection tile must not');
    });

    test('a url-keyed row (radio, podcast) matches by address only', () {
      // A station id IS its stream url, and two stations can share a song title.
      expect(
          isSameTrack(
            playingId: 'vid123',
            playingTitle: 'Dandelions',
            playingArtist: 'Ruth B.',
            rowId: 'https://stream.example/live',
            rowTitle: 'Dandelions',
            rowArtist: 'Ruth B.',
          ),
          isFalse);
      // …but the same address still matches itself.
      expect(
          isSameTrack(
            playingId: 'https://stream.example/live',
            playingTitle: 'whatever',
            playingArtist: '',
            rowId: 'https://stream.example/live',
            rowTitle: 'whatever',
            rowArtist: '',
          ),
          isTrue);
    });
  });

  group('normalisation', () {
    test('noise stripping does not corrupt the remaining title', () {
      expect(normalizedTrackTitle('Dandelions (Official Music Video)'),
          equals(normalizedTrackTitle('Dandelions')));
    });

    test('unknown artist reads as no credit at all', () {
      expect(normalizedPrimaryArtist('Unknown Artist'), isEmpty);
    });

    test('empty title yields no opinion', () {
      expect(normalizedTrackTitle('   '), isEmpty);
    });

    test('the memo returns the same answer every time', () {
      final first = normalizedTrackTitle('Song (Official Video)');
      expect(normalizedTrackTitle('Song (Official Video)'), equals(first));
      expect(normalizedPrimaryArtist('A, B'), equals('a'));
    });
  });
}
