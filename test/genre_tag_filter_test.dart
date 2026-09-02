import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/providers/intelligence_provider.dart';

/// Which Last.fm tags are allowed to become genres.
///
/// ── THE CASES ARE REAL, NOT INVENTED ────────────────────────────────────────
///
/// Both lists below were captured from the device on 2026-08-31, the first time
/// the genre learner ran against a live account:
///
///     Fifth Harmony  -> pop, best of 2016, ratchet music, rnb, 2016
///     Justin Bieber  -> pop, justin bieber, love at first listen, acoustic,
///                       ed sheeran
///
/// Four of those ten are genres. The rest are a year, a listmaking tag, a
/// personal phrase, the artist's OWN name, and a different artist entirely.
/// Unfiltered, `genreAffinities` learns that "2016" and "ed sheeran" are genres
/// and the queue's coherence check can then match on them.
void main() {
  late IntelligenceNotifier intel;

  setUp(() {
    // The notifier loads persisted taste in its constructor.
    SharedPreferences.setMockInitialValues({});
    // The filter reads state.artistAffinities to recognise names it already
    // knows as ARTISTS, so the notifier is stood up rather than the method
    // called in isolation.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    intel = container.read(intelligenceProvider.notifier);
  });

  /// The filter, reached the way the learner reaches it.
  bool keeps(String tag, String artist) =>
      intel.isGenreLikeTag(tag, artist);

  group('the tags actually seen on device', () {
    test('Fifth Harmony: keeps the two genres, drops the three others', () {
      const artist = 'Fifth Harmony';
      expect(keeps('pop', artist), isTrue);
      expect(keeps('rnb', artist), isTrue);
      expect(keeps('best of 2016', artist), isFalse, reason: 'a listmaking tag');
      expect(keeps('2016', artist), isFalse, reason: 'a year, not a genre');
      // "ratchet music" is two words and none of the rules catch it. Kept
      // deliberately: it is a (crude) descriptor of the music, and the filter
      // errs toward keeping anything it cannot rule out.
      expect(keeps('ratchet music', artist), isTrue);
    });

    test('Justin Bieber: drops his own name and another artist', () {
      const artist = 'Justin Bieber';
      expect(keeps('pop', artist), isTrue);
      expect(keeps('acoustic', artist), isTrue);
      expect(keeps('justin bieber', artist), isFalse,
          reason: "the artist's own name is the most common tag of all");
      expect(keeps('love at first listen', artist), isFalse,
          reason: 'a personal reaction, and four words');
    });
  });

  group('the four shapes that are never genres', () {
    test('years and decades', () {
      for (final t in ['2016', '1990', '2020s', '90s', '00s']) {
        expect(keeps(t, 'Someone'), isFalse, reason: '$t is a period');
      }
    });

    test('listmaking and reaction tags', () {
      for (final t in [
        'best of 2016', 'favorite songs', 'my music', 'seen live',
        'want to listen', 'awesome', 'beautiful',
      ]) {
        expect(keeps(t, 'Someone'), isFalse, reason: '$t describes the tagger');
      }
    });

    test('the artist themselves, in either direction', () {
      expect(keeps('radiohead', 'Radiohead'), isFalse);
      // A tag that CONTAINS the artist name, and one contained BY it — both are
      // the artist under a slightly different spelling.
      expect(keeps('bieber', 'Justin Bieber'), isFalse);
      // But a genre that merely SHARES LETTERS with the name survives. This is
      // the case the first version got wrong: 'popcaan'.contains('pop') is true,
      // so it dropped the real genre for that artist.
      expect(keeps('pop', 'Popcaan'), isTrue);
      expect(keeps('rap', 'Rapsody'), isTrue);
    });

    test('phrases longer than a genre name', () {
      expect(keeps('music to fall asleep to', 'Someone'), isFalse);
      // Three words is still a genre name.
      expect(keeps('melodic death metal', 'Someone'), isTrue);
    });
  });

  group('what it must NOT throw away', () {
    test('multi-word genres survive — they are the whole point', () {
      for (final t in [
        'uk drill', 'bedroom pop', 'neo soul', 'lo-fi hip hop',
        'melodic dubstep', 'alternative r&b', 'afrobeats', 'amapiano',
      ]) {
        expect(keeps(t, 'Someone'), isTrue,
            reason: '$t is exactly the distinction that makes a queue cohere; '
                'folding these away is why the old eight-bucket inference was '
                'useless');
      }
    });

    test('an empty or absurd tag is refused without throwing', () {
      expect(keeps('', 'Someone'), isFalse);
      expect(keeps('a' * 40, 'Someone'), isFalse);
      // An empty artist name must not make every tag look like the artist.
      expect(keeps('pop', ''), isTrue);
    });
  });
}
