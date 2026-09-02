import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/services/search_service.dart';

/// `SearchService.cleanDisplayTitle` — the function that decides what every
/// track title in the app actually reads as.
///
/// ── WHY THIS NEEDED TESTS ───────────────────────────────────────────────────
///
/// It is called from `_mapJsonToSong`, so it runs on EVERY row of EVERY search,
/// browse and radio response — and it had no test at all. Two distinct ways it
/// can go wrong, and they pull in opposite directions:
///
///   • too timid, and lists show "Blinding Lights (Official Music Video)";
///   • too greedy, and it eats part of a real title — "(feat. …)", "(Live)",
///     "(Remastered 2020)" are not decorations, and a song called "Video Games"
///     must survive a function whose whole job is removing the word "video".
///
/// The greedy direction is the dangerous one: it corrupts the library's own
/// record of what a track is called, and it is invisible until someone notices a
/// title looks wrong.
void main() {
  String clean(String s) => SearchService.cleanDisplayTitle(s);

  group('leaves a real title alone', () {
    for (final t in const [
      'Blinding Lights',
      'Video Games',
      // THE GREEDY-STRIP TRAP. Both of these contain the decoration words the
      // function removes, as ordinary parts of the title. A pattern that is not
      // anchored to a bracket or to the end of the string eats them.
      'Music Video Hero',
    ]) {
      test('"$t"', () => expect(clean(t), t));
    }

    test('trims surrounding whitespace but changes nothing else', () {
      expect(clean('  Blinding Lights  '), 'Blinding Lights');
    });
  });

  group('strips bracketed decorations', () {
    for (final t in const [
      'Blinding Lights (Official Video)',
      'Blinding Lights (Official Music Video)',
      'Blinding Lights [Official Video]',
      'Blinding Lights (Lyric Video)',
      'Blinding Lights (Official Audio)',
      'Blinding Lights (Visualizer)',
      // Both spellings — the pattern carries [sz] for exactly this.
      'Blinding Lights (Visualiser)',
      'Blinding Lights (MV)',
      'Blinding Lights (HD Video)',
      'Blinding Lights (Official Lyrics)',
    ]) {
      test('"$t"', () => expect(clean(t), 'Blinding Lights'));
    }

    test('case does not matter — YouTube titles are inconsistent', () {
      expect(clean('Blinding Lights (OFFICIAL VIDEO)'), 'Blinding Lights');
      expect(clean('Blinding Lights (official music video)'), 'Blinding Lights');
    });

    test('a decoration in the middle still goes, leaving the rest', () {
      expect(clean('Blinding Lights (Official Video) (Remastered)'),
          'Blinding Lights (Remastered)');
    });
  });

  group('strips trailing un-bracketed decorations', () {
    for (final t in const [
      'Blinding Lights - Official Video',
      'Blinding Lights | Official Music Video',
      // En dash, which YouTube uses as often as a hyphen.
      'Blinding Lights – Lyric Video',
      'Blinding Lights Official Video',
    ]) {
      test('"$t"', () => expect(clean(t), 'Blinding Lights'));
    }
  });

  group('WARN: preserves parts of the title that only LOOK like decorations', () {
    // These are the ones that matter. Each is a real distinction between
    // recordings, and losing it makes two different tracks read identically —
    // which also breaks the edition-matching that depends on the title.
    for (final t in const [
      'Blinding Lights (feat. Someone)',
      'Blinding Lights (Remastered 2020)',
      'Blinding Lights (Live)',
      'Blinding Lights (Acoustic)',
    ]) {
      test('"$t"', () => expect(clean(t), t));
    }
  });

  group('never returns nothing', () {
    test('a title that is ENTIRELY a decoration comes back unchanged', () {
      // Stripping would leave an empty string, and a blank row is worse than a
      // decorated one — there would be nothing to identify the track by.
      expect(clean('(Official Video)'), '(Official Video)');
    });

    test('an empty input stays empty rather than throwing', () {
      expect(clean(''), '');
      expect(clean('   '), '');
    });
  });

  group('tidies what a strip leaves behind', () {
    test('a dangling separator is removed', () {
      expect(clean('Blinding Lights -'), 'Blinding Lights');
    });

    test('a dangling opening bracket is removed', () {
      expect(clean('Blinding Lights ('), 'Blinding Lights');
    });
  });

  test('is idempotent — cleaning a clean title changes nothing', () {
    // _mapJsonToSong can see the same title again through a different path (a
    // conform lookup, a refetch), so a second pass must be a no-op. A pattern
    // that trimmed one more character each time would corrupt titles slowly.
    for (final t in const [
      'Blinding Lights (Official Video)',
      'Blinding Lights (feat. Someone)',
      'Video Games',
      '(Official Video)',
    ]) {
      final once = clean(t);
      expect(clean(once), once, reason: 'second pass changed "$once"');
    }
  });
}
