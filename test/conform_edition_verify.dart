// Verifies SearchService.mergeConformedAudio — the rule that keeps album
// EDITIONS from bleeding into each other when a music video is swapped for its
// audio twin.
//
// Contract: the PLAYABLE identity (the id that actually streams, and its
// duration) comes from the audio twin; the RELEASE identity (cover, album id,
// album title, year, display title/artist) stays with the row the user opened.
//
// Why it is tested: the swap used to substitute the conformed Song wholesale, so
// a track played out of a deluxe edition could adopt the standard edition's cover
// and album id from a search result — flipping the artwork mid-play and sending a
// later "view album" to the wrong release. The rule is deliberately
// edition-agnostic: it names no "deluxe"/"remaster" anywhere, so it holds for any
// number of versions.
//
// Run: flutter test test/conform_edition_verify.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/search_service.dart';

void main() {
  // A row as it exists inside one specific edition.
  final original = Song(
    id: 'VIDEOoriginal',
    title: 'Blinding Lights',
    artist: 'The Weeknd',
    image: 'https://img/deluxe-cover.jpg',
    albumId: 'MPREb_deluxe',
    albumTitle: 'After Hours (Deluxe)',
    releaseDate: '2020',
    duration: '3:20',
  );

  // The audio equivalent a search returned. It carries a DIFFERENT edition's
  // cover, album and year — which is exactly the hazard being guarded against.
  final audio = Song(
    id: 'AUDIOtwin11',
    title: 'Blinding Lights (Audio)',
    artist: 'The Weeknd - Topic',
    image: 'https://img/standard-cover.jpg',
    albumId: 'MPREb_standard',
    albumTitle: 'After Hours',
    releaseDate: '2019',
    duration: '3:21',
  );

  test('audio identity comes from the conformed twin', () {
    final merged = SearchService.mergeConformedAudio(original, audio);
    expect(merged.id, 'AUDIOtwin11', reason: 'the twin is what plays');
    expect(merged.duration, '3:21');
  });

  test('release identity stays with the edition the user opened', () {
    final merged = SearchService.mergeConformedAudio(original, audio);
    expect(merged.image, 'https://img/deluxe-cover.jpg');
    expect(merged.albumId, 'MPREb_deluxe');
    expect(merged.albumTitle, 'After Hours (Deluxe)');
    expect(merged.releaseDate, '2020');
    expect(merged.title, 'Blinding Lights');
    expect(merged.artist, 'The Weeknd');
  });

  test('a blank original is filled from the twin rather than left empty', () {
    final bare = Song(id: 'VIDEObare', title: '', artist: '', image: '');
    final merged = SearchService.mergeConformedAudio(bare, audio);
    expect(merged.image, 'https://img/standard-cover.jpg');
    expect(merged.albumId, 'MPREb_standard');
    expect(merged.albumTitle, 'After Hours');
    expect(merged.title, 'Blinding Lights (Audio)');
    // Still plays the twin.
    expect(merged.id, 'AUDIOtwin11');
  });

  test('a MUSIC VIDEO row hands over entirely — its thumbnail must not survive',
      () {
    // Regression guard. The first version of mergeConformedAudio kept
    // original.image unconditionally, which defeated the point of conform: a
    // music-video row's picture is a 16:9 VIDEO THUMBNAIL, so swapping the video
    // for its studio audio while keeping the video's thumbnail left letterboxed
    // artwork where a square sleeve belongs. A video row also carries no
    // trustworthy album identity, so preserving its album fields preserved
    // nothing.
    final videoRow = Song(
      id: 'VIDEOrow0001',
      title: 'Blinding Lights (Official Video)',
      artist: 'The Weeknd',
      image: 'https://i.ytimg.com/vi/VIDEOrow0001/hq720.jpg',
      musicVideoType: 'MUSIC_VIDEO_TYPE_OMV',
    );
    expect(videoRow.isMusicVideo, isTrue, reason: 'fixture sanity');

    final merged = SearchService.mergeConformedAudio(videoRow, audio);
    expect(merged.image, audio.image,
        reason: 'the audio version\'s square cover, not the video thumbnail');
    expect(merged.title, audio.title);
    expect(merged.albumId, audio.albumId);
    expect(merged.id, audio.id);
  });

  test('holds for any edition name, not just deluxe', () {
    for (final edition in const [
      'Abbey Road (2019 Mix)',
      'Thriller 25 Anniversary Edition',
      'Album (Clean)',
      'Album (Remastered)',
    ]) {
      final row = original.copyWith(
        albumTitle: edition,
        albumId: 'MPREb_${edition.hashCode}',
        image: 'https://img/$edition.jpg',
      );
      final merged = SearchService.mergeConformedAudio(row, audio);
      expect(merged.albumTitle, edition);
      expect(merged.albumId, 'MPREb_${edition.hashCode}');
      expect(merged.image, 'https://img/$edition.jpg');
      expect(merged.id, 'AUDIOtwin11');
    }
  });
}
