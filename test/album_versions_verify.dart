// Verifies the "Other versions" filter on the album page.
//
// The problem it solves: an album browse response carries more than the album's
// other editions — it also has "More from this artist" and recommendation
// shelves, and the parser flattens EVERY shelf into one untitled item list, so
// shelf identity cannot be used to filter. Taking all album-typed items showed
// unrelated records, and the same release repeated under several browse ids made
// the album list itself half a dozen times.
//
// Two rules, both tested here against the real functions:
//   1. base title must match  → only editions of THIS album survive
//   2. distinct full titles   → duplicates collapse, real editions do not
//
// Run: flutter test test/album_versions_verify.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/services/search_service.dart';

void main() {
  group('base title strips edition decoration', () {
    const same = <String>[
      'After Hours',
      'After Hours (Deluxe)',
      'After Hours (Deluxe Edition)',
      'After Hours [Remastered]',
      'After Hours (Remastered 2019)',
      'After Hours - Deluxe',
      'After Hours — Deluxe Edition',
      'After Hours (Explicit)',
      'After Hours (Clean)',
      'AFTER HOURS',
    ];
    test('every edition of one album reduces to the same base', () {
      final base = SearchService.albumBaseTitle('After Hours');
      expect(base, isNotEmpty);
      for (final t in same) {
        expect(SearchService.albumBaseTitle(t), base, reason: t);
      }
    });

    test('different albums do NOT collide', () {
      final base = SearchService.albumBaseTitle('After Hours');
      for (final other in const [
        'Dawn FM',
        'Starboy',
        'Beauty Behind the Madness',
        'My Dear Melancholy',
        'After Laughter', // deliberately similar, still different
      ]) {
        expect(SearchService.albumBaseTitle(other), isNot(base), reason: other);
      }
    });
  });

  group('full title keeps editions apart', () {
    test('standard and deluxe normalise differently', () {
      expect(
        SearchService.normalizeAlbumTitle('After Hours'),
        isNot(SearchService.normalizeAlbumTitle('After Hours (Deluxe)')),
      );
    });

    test('the same edition written differently collapses to one', () {
      expect(
        SearchService.normalizeAlbumTitle('After Hours (Deluxe)'),
        SearchService.normalizeAlbumTitle('after hours [deluxe]'),
      );
    });
  });

  group('end to end: what survives the filter', () {
    // Mirrors the loop in getAlbumOtherVersions, which cannot be called here
    // without a live browse response.
    List<String> filter(String self, List<String> candidates) {
      final selfBase = SearchService.albumBaseTitle(self);
      final seenTitles = <String>{SearchService.normalizeAlbumTitle(self)};
      final out = <String>[];
      for (final c in candidates) {
        if (SearchService.albumBaseTitle(c) != selfBase) continue;
        if (!seenTitles.add(SearchService.normalizeAlbumTitle(c))) continue;
        out.add(c);
      }
      return out;
    }

    test('drops itself, drops duplicates, keeps real editions', () {
      final kept = filter('After Hours', [
        'After Hours', // itself, from a recommendation shelf
        'After Hours', // …again, different browse id
        'After Hours', // …and again
        'After Hours (Deluxe)', // a genuine other edition
        'after hours [deluxe]', // the same edition, written differently
        'Dawn FM', // unrelated — "More from this artist"
        'Starboy', // unrelated
        'Blinding Lights', // unrelated single
      ]);
      expect(kept, ['After Hours (Deluxe)']);
    });

    test('multiple genuine editions all survive', () {
      final kept = filter('Thriller', [
        'Thriller',
        'Thriller (Remastered)',
        'Thriller (Special Edition)',
        'Thriller (Remastered)', // duplicate
        'Bad', // unrelated
      ]);
      expect(kept.length, 2);
      expect(kept, contains('Thriller (Remastered)'));
      expect(kept, contains('Thriller (Special Edition)'));
      expect(kept, isNot(contains('Bad')));
    });

    test('a RENAMED edition is deliberately excluded (documented trade-off)', () {
      // "Thriller 25" reduces to "thriller25", not "thriller", so it does not
      // survive. That is the cost of requiring base titles to be EQUAL.
      //
      // The alternative — accepting a candidate whose base merely STARTS WITH
      // this album's base — would let a short title drag in unrelated records:
      // "Bad" would match "Bad Romance", "Bad Blood" and "Bad Guy". Missing a
      // renamed anniversary edition is the lesser harm, and it is the direction
      // asked for: unrelated entries appearing was the reported problem.
      final kept = filter('Thriller', ['Thriller 25 (Deluxe)']);
      expect(kept, isEmpty);

      // Short titles stay safe, which is what that strictness buys.
      expect(filter('Bad', ['Bad Romance', 'Bad Blood', 'Bad Guy']), isEmpty);
    });
  });
}
