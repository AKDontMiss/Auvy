import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/data/audiobook_model.dart';

/// These tests exist because the parser below was WRONG on first write and failed
/// silently: the Archive file length is a clock string ("26:22"), not seconds, so
/// double.tryParse returned 0 and every chapter duration rendered blank — looking
/// like a styling choice rather than a parse failure. The fixtures are
/// real responses, trimmed.
void main() {
  group('Audiobook.fromArchive (the catalogue)', () {
    test('parses the advancedsearch shape, list fields included', () {
      final book = Audiobook.fromArchive({
        'identifier': 'bleak_house_cl_librivox',
        'title': 'Bleak House',
        'creator': ['Charles Dickens'],
        'language': ['English'],
        'runtime': 12345,
      });
      expect(book!.archiveId, 'bleak_house_cl_librivox');
      expect(book.author, 'Charles Dickens');
      expect(book.language, 'English');
    });

    test('an identifierless row is rejected — there would be no audio', () {
      expect(Audiobook.fromArchive({'title': 'No Item'}), isNull);
    });
  });

  group('AudiobookChapter.toSong', () {
    test('the id is the stream url, so identity is by address', () {
      const c = AudiobookChapter(
        title: '01 - In Chancery',
        streamUrl: 'https://ia800608.us.archive.org/14/items/x/x_01_64kb.mp3',
        duration: Duration(minutes: 26, seconds: 22),
        index: 0,
      );
      final song = c.toSong(bookTitle: 'Bleak House', author: 'Charles Dickens');
      // An http id is what makes isSameTrack fall back to address identity
      // instead of matching "01 - In Chancery" across unrelated books.
      expect(song.id, startsWith('http'));
      expect(song.id, c.streamUrl);
      expect(song.albumTitle, 'Bleak House');
      expect(song.duration, '26:22');
    });

    test('hours are rendered, not truncated', () {
      const c = AudiobookChapter(
        title: 'Long one',
        streamUrl: 'https://example.org/a.mp3',
        duration: Duration(hours: 1, minutes: 5, seconds: 3),
        index: 0,
      );
      expect(c.toSong(bookTitle: 'B', author: 'A').duration, '1:05:03');
    });
  });
}
