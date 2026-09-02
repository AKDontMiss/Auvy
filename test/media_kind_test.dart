import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';

/// Locks the media classification down.
///
/// This exists because the test it replaced was written inline in five places as
/// `id.startsWith('http') && albumTitle != 'Podcast'`, and the moment a third
/// kind of http-id media appeared (audiobook chapters) every one of those five
/// silently misclassified it as a live stream — which hid the seek bar. The
/// failure was invisible: it compiled, it ran, and it looked like a styling
/// choice.
///
/// The point of these cases is that adding a FOURTH kind cannot quietly break
/// the other three.
void main() {
  Song song({
    String id = 'dQw4w9WgXcQ',
    String albumTitle = 'Some Album',
    String albumId = '',
  }) =>
      Song(
        id: id,
        title: 'T',
        artist: 'A',
        image: '',
        albumTitle: albumTitle,
        albumId: albumId,
      );

  group('mediaKind', () {
    test('a normal track is music', () {
      expect(song().mediaKind, MediaKind.music);
    });

    test('a podcast episode is a podcast, not a live stream', () {
      // An episode has BOTH an http id and the Podcast marker. Order matters:
      // the http test must not win.
      final ep = song(id: 'https://cdn.example/ep123.mp3', albumTitle: 'Podcast');
      expect(ep.mediaKind, MediaKind.podcast);
    });

    test('an audiobook chapter is an audiobook, not a live stream', () {
      final ch = song(
        id: 'https://ia800608.us.archive.org/14/items/x/x_01_64kb.mp3',
        albumTitle: 'Bleak House',
        albumId: kAudiobookMarker,
      );
      expect(ch.mediaKind, MediaKind.audiobook);
    });

    test('a radio station is a live stream', () {
      final st = song(id: 'http://stream.example/live', albumTitle: 'ROCK');
      expect(st.mediaKind, MediaKind.liveStream);
    });
  });

  group('hasSeekablePosition — the seek bar gate', () {
    test('only a live stream lacks a position', () {
      expect(song().hasSeekablePosition, isTrue);
      expect(
        song(id: 'https://cdn.example/ep.mp3', albumTitle: 'Podcast')
            .hasSeekablePosition,
        isTrue,
      );
      // THE REGRESSION THIS FILE EXISTS FOR: a chapter you cannot scrub is
      // not an audiobook.
      expect(
        song(
          id: 'https://archive.org/x_01_64kb.mp3',
          albumId: kAudiobookMarker,
        ).hasSeekablePosition,
        isTrue,
      );
      expect(
        song(id: 'http://stream.example/live').hasSeekablePosition,
        isFalse,
      );
    });
  });

  group('isSpokenWord — shared speed memory', () {
    test('podcasts and audiobooks share it; music and radio do not', () {
      expect(
        song(id: 'https://cdn.example/ep.mp3', albumTitle: 'Podcast')
            .isSpokenWord,
        isTrue,
      );
      expect(
        song(id: 'https://archive.org/a.mp3', albumId: kAudiobookMarker)
            .isSpokenWord,
        isTrue,
      );
      expect(song().isSpokenWord, isFalse);
      expect(song(id: 'http://stream.example/live').isSpokenWord, isFalse);
    });
  });
}
