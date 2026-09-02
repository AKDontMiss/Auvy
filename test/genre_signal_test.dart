import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The genre signal the queue scorer runs on.
///
/// ── WHAT WAS WRONG ──────────────────────────────────────────────────────────
///
/// `getSongScore`'s largest term — commented "THE KEY QUEUE FIX" — asked
/// `_extractSongGenres` for a song's genre, and that inferred genre by matching
/// eight keywords against the TITLE and ALBUM NAME. Real tracks do not carry
/// their genre in their title, so it returned EMPTY for nearly every candidate,
/// fell into the mismatch branch, and applied a flat `-3`. A constant ranks
/// nothing: the term that was supposed to keep a queue coherent was inert.
///
/// Two changes, and this file guards both: genre now comes from LEARNED ARTIST
/// TAGS (persisted, one lookup per artist), and "we do not know this song's
/// genre" no longer counts as "this song is the wrong genre".
void main() {
  final intel = codeOf('lib/providers/intelligence_provider.dart');

  group('genre comes from the artist, not the song title', () {
    test('the state carries a persisted artist -> genres map', () {
      expect(intel.contains('final Map<String, List<String>> artistGenres;'), isTrue,
          reason: 'The artist genre map is gone, so the scorer is back to '
              'guessing genre from track titles.');
      // A field that is never persisted relearns from zero on every launch, which
      // for a network-backed lookup means paying for it again every launch.
      for (final site in [
        'this.artistGenres = const {},', // constructor default
        'Map<String, List<String>>? artistGenres,', // copyWith parameter
        'artistGenres: artistGenres ?? this.artistGenres,', // copyWith body
        "setString('intel_artist_genres'", // save
        "getString('intel_artist_genres')", // load
        // Handed to the state on load, THROUGH THE CAP. The map was unbounded —
        // one entry per artist ever played, kept forever and re-parsed at every
        // startup — so the cap is applied on load as well as on learn, or an
        // install that already overflowed would stay over it.
        'artistGenres: _cappedGenres(artistGenres),',
      ]) {
        expect(intel.contains(site), isTrue,
            reason: 'artistGenres is not wired at: $site — a field missing one '
                'of these six sites silently loses data.');
      }
    });

    test('the lookup happens on a PLAY, once per artist, never in the scorer', () {
      final learn = intel.substring(intel.indexOf('void _learnGenresForArtist('));
      final body = learn.substring(0, learn.indexOf('void recordPlay('));
      expect(body.contains('state.artistGenres.containsKey(key)'), isTrue,
          reason: 'The once-ever guard is gone, so every play re-requests tags '
              'for an artist already known.');
      expect(body.contains('_genreLookupsInFlight'), isTrue,
          reason: 'Nothing stops two plays starting two lookups for the same '
              'artist.');
      expect(body.contains('_genreLookupsThisSession >= _maxGenreLookupsPerSession'),
          isTrue,
          reason: 'The per-session cap is gone: a first-run library scan could '
              'fire one request per artist with no ceiling.');
      // The scorer is synchronous and runs per candidate. An await in it would be
      // a network call per song in a ranking loop.
      final scorer = intel.substring(intel.indexOf('double getSongScore('),
          intel.indexOf('String _dayPartKey('));
      expect(scorer.contains('await'), isFalse,
          reason: 'getSongScore now awaits something. It is called once per '
              'candidate over hundreds of songs.');
      expect(scorer.contains('getTrackTags'), isFalse,
          reason: 'The scorer is fetching tags itself.');
    });

    test('ARTIST tags are asked for before track tags', () {
      // The answer is cached PER ARTIST, so asking about one track is the wrong
      // question: track tags are sparse, and an untagged track recorded "this
      // artist has no genres" permanently. Caught on device as
      // `genres learned for "Major Lazer": none known`.
      final learn = intel.substring(intel.indexOf('void _learnGenresForArtist('));
      final body = learn.substring(0, learn.indexOf('void recordPlay('));
      final artistCall = body.indexOf('getArtistTags(artist)');
      final trackCall = body.indexOf('getTrackTags(');
      expect(artistCall, greaterThan(-1),
          reason: 'The learner is back to asking only about one TRACK.');
      expect(trackCall, greaterThan(artistCall),
          reason: 'The track fallback runs before the artist lookup.');
      expect(body.contains('tags.isEmpty && trackTitle'), isTrue,
          reason: 'The track lookup is no longer conditional, so every artist '
              'costs two requests instead of one.');
    });

    test('the log names which source answered', () {
      final learn = intel.substring(intel.indexOf('void _learnGenresForArtist('));
      final body = learn.substring(0, learn.indexOf('void recordPlay('));
      expect(body.contains('viaTrack'), isTrue,
          reason: '"none known" means two different things — Last.fm has '
              'nothing, or the track asked about was untagged — and the line '
              'no longer distinguishes them.');
    });

    test('an artist with no tags is remembered as having none', () {
      final learn = intel.substring(intel.indexOf('void _learnGenresForArtist('));
      final body = learn.substring(0, learn.indexOf('void recordPlay('));
      // Storing nothing and storing an empty list look the same in the map only
      // if the guard checks containsKey rather than truthiness — which it does,
      // above. This asserts the write happens even for an empty result.
      expect(body.contains('key: genres,'), isTrue,
          reason: 'The result is only stored when non-empty, so an artist '
              'Last.fm knows nothing about is re-requested on every play.');
    });
  });

  group('not knowing is not a mismatch', () {
    test('the empty case is its own branch, before the penalty', () {
      final block = intel.substring(intel.indexOf('final songMatchesContext ='));
      // Anchored on CODE: the '5. Time-of-day' heading below it is a comment,
      // which codeOf has already removed.
      final upTo = block.substring(0, block.indexOf('state.timeOfDayAffinities'));
      final empty = upTo.indexOf('inferredGenres.isEmpty');
      final penalty = upTo.indexOf('score -= 3.0');
      expect(empty, greaterThan(-1),
          reason: 'The unknown-genre case is gone, so it falls into the '
              'mismatch branch again and every candidate takes a flat -3.');
      expect(empty, lessThan(penalty),
          reason: 'The penalty is reachable before the empty check.');
    });

    test('context matching is set membership, not a substring', () {
      final block = intel.substring(intel.indexOf('final songMatchesContext ='));
      final line = block.substring(0, block.indexOf(';') + 1);
      expect(line.contains('inferredGenres.contains(ctx)'), isTrue);
      // These are the accidents: "pop" in Popcaan, "rap" in Rapsody/Wrapped.
      expect(line.contains('song.artist.toLowerCase().contains'), isFalse,
          reason: 'Substring matching on the ARTIST name is back — the '
              'coherence reward fires on spelling accidents.');
      expect(line.contains('song.title.toLowerCase().contains'), isFalse,
          reason: 'Substring matching on the TITLE is back.');
    });

    test('the title-word patterns are anchored on word boundaries', () {
      expect(intel.contains(r"r'(?<![\w-])(?:'"), isTrue,
          reason: 'The title genre words are matched by bare contains() again, '
              'so "pop" matches Popcaan and "garage" matches "Garageband".');
      // Compiled once, not per candidate: this runs inside a ranking loop.
      expect(intel.contains('static final Map<String, RegExp> _titleGenrePatterns'),
          isTrue,
          reason: 'The patterns are rebuilt per call again — twelve RegExp '
              'compilations per song scored.');
    });
  });

  group('there is exactly ONE genre inference', () {
    test('home_provider asks the intelligence provider instead of guessing', () {
      final home = codeOf('lib/providers/home_provider.dart');
      expect(home.contains('intelNotifier.genresFor(song)'), isTrue,
          reason: 'The feed builds its genre topics from its own rule again.');
      expect(home.contains('_extractGenreKeywords'), isFalse,
          reason: 'The duplicate inference is back. Its version searched title, '
              'album AND ARTIST with a bare contains(), so Metallica became '
              '"metal", Popcaan "pop" and Rapsody "rap" — and those became real '
              'shelves on the home screen.');
    });

    test('no file outside the intelligence provider infers genre from text', () {
      // The shape to catch: a hardcoded genre word list. One is the rule; two is
      // two behaviours that disagree, which is what this cost last time.
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.path.endsWith('intelligence_provider.dart')) continue;
        final code = codeOf(f.path);
        // Three genre words in one literal list is not a coincidence.
        final hits = ["'hip-hop'", "'dubstep'", "'techno'", "'reggae'"]
            .where(code.contains)
            .length;
        if (hits >= 3) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'These carry their own genre vocabulary: '
              '${offenders.join(', ')}');
    });
  });

  group('the scorer stays cheap enough to call per candidate', () {
    test('song genres are memoised and the memo is bounded', () {
      expect(intel.contains('_songGenreMemo'), isTrue,
          reason: 'The per-song memo is gone.');
      expect(intel.contains('if (_songGenreMemo.length > 800) _songGenreMemo.clear();'),
          isTrue,
          reason: 'The memo is unbounded — it would grow for every song ever '
              'ranked, which is the leak trackMetadata already had to cap.');
    });

    test('learning something new invalidates the memo', () {
      // Otherwise a newly-learned artist keeps scoring against the empty answer
      // cached before the tags arrived — the fix would appear not to work.
      final learn = intel.substring(intel.indexOf('void _learnGenresForArtist('));
      final body = learn.substring(0, learn.indexOf('void recordPlay('));
      expect(body.contains('_songGenreMemo.clear()'), isTrue,
          reason: 'The memo survives a genre being learned, so songs by that '
              'artist keep their stale empty genre list.');
    });
  });

  test('the comment no longer claims the weights are a normalised blend', () {
    // The labels say 20%/15%/25%/30% while the Markov term is `* 10.0`, the
    // top-5 bonus is a flat `+5` and freshness is `+5/-8`. Nothing sums to 1.
    // Keeping the labels is fine; claiming they balance is not.
    final doc = docsOf('lib/providers/intelligence_provider.dart');
    // The header was sentence-cased in the 2026-09-02 comment pass; what has to
    // survive is the WARNING, not its capitalisation.
    expect(doc.contains('are intent, NOT weights'), isTrue,
        reason: 'The doc comment above getSongScore no longer warns that the '
            'percentages are not real weights — the next person to tune it will '
            'assume 0.20 -> 0.30 means something it does not.');
  });
}
