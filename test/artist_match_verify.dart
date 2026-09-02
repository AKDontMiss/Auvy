import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/services/search_service.dart';

import 'helpers/source_text.dart';

/// The artist name-matching rule used by `SearchService.resolveArtistIdForTrack`
/// and `pickArtistMatch`.
///
/// ── THIS FILE USED TO TEST A COPY, AND REGISTERED NO TESTS AT ALL ────────
///
/// It carried the note "Mirrors the implementation exactly" and then re-declared
/// `_normalised` / `_artistNameWords` / `nameMatches` locally. Two consequences,
/// both bad:
///
///   • It could not fail for the reason that matters. The rule could drift in
///     `search_service.dart` and these sixteen cases would keep passing against
///     the mirror — which is the precise opposite of what a verification file is
///     for. This codebase works hard elsewhere to keep one rule in one place
///     (see `_hiddenBecauseReachable`, `_pendingQueueIndexOf`); a test holding a
///     second copy undoes that.
///   • It never ran. `main()` looped and printed its own tally instead of
///     registering `test()` cases, so `flutter test` reported "No tests were
///     found" and the whole suite skipped it silently. The 16 "passed" lines
///     only ever appeared when someone ran the file by hand.
///
/// It now calls `SearchService.artistNameMatches` — the real thing, which is
/// already public and static for exactly this reason.
void main() {
  group('artistNameMatches', () {
    // [want, candidate, expected]
    const accepts = <List<Object>>[
      ['The Weeknd', 'The Weeknd'],
      // YouTube's channel suffixes must not defeat a match.
      ['The Weeknd', 'The Weeknd - Topic'],
      ['The Weeknd', 'TheWeekndVEVO'],
      // Punctuation and fused-vs-spaced spellings fold together.
      ['Tyler, The Creator', 'Tyler The Creator'],
      ['AC/DC', 'ACDC'],
      ['Florence + The Machine', 'Florence and The Machine'],
      ['Sigrid', 'Sigrid'],
      // Non-Latin scripts must still resolve — an ASCII-only character class
      // erased these entirely and left a word set that could never match, so
      // those artists were unreachable.
      ['방탄소년단', '방탄소년단'],
      ['Земфира', 'Земфира'],
      ['宇多田ヒカル', '宇多田ヒカル'],
    ];

    const rejects = <List<Object>>[
      // THE WRONG-ARTIST BUGS. Every one of these passed under the old
      // substring rule, and each opened a different artist's page than the one
      // that was tapped.
      ['Drake', 'Drake Bell'],
      ['The Weeknd', 'Weeknd'],
      ['The Weeknd', 'Starboy'],
      ['Indila', 'Indila Tribute Band'],
      ['Eminem', 'Eminem Karaoke'],
      ['방탄소년단', '블랙핑크'],
    ];

    for (final c in accepts) {
      test('accepts "${c[0]}" ≈ "${c[1]}"', () {
        expect(
            SearchService.artistNameMatches(c[0] as String, c[1] as String),
            isTrue,
            reason: 'These name the same artist; refusing the match means the '
                'artist page cannot be reached at all.');
      });
    }

    for (final c in rejects) {
      test('rejects "${c[0]}" ≠ "${c[1]}"', () {
        expect(
            SearchService.artistNameMatches(c[0] as String, c[1] as String),
            isFalse,
            reason: 'Accepting this opens a DIFFERENT artist than the one '
                'tapped — the failure this rule exists to stop.');
      });
    }

    test('an empty want matches anything, and an empty candidate matches nothing',
        () {
      // Asymmetric on purpose: no requested name means "no opinion", while a
      // candidate with no usable characters cannot be confirmed as anyone.
      expect(SearchService.artistNameMatches('', 'Anyone'), isTrue);
      expect(SearchService.artistNameMatches('Sigrid', ''), isFalse);
      expect(SearchService.artistNameMatches('Sigrid', '!!!'), isFalse);
    });
  });

  test('this file tests the real rule, not a copy of it', () {
    // The mirror is what made the old version unable to fail. If someone
    // reintroduces a local implementation, the cases above stop guarding
    // anything and nothing else would say so.
    final src = File('test/artist_match_verify.dart').readAsStringSync();
    expect(src.contains('SearchService.artistNameMatches'), isTrue,
        reason: 'The cases no longer call the implementation.');
    // MATCHED ON POSITION, AND IT TOOK TWO TRIES TO GET THAT RIGHT.
    //
    // First attempt searched for the old file's "Mirrors the implementation
    // exactly" note — and failed instantly, because the doc comment above QUOTES
    // that note while explaining the problem. Second attempt listed the mirrored
    // function signatures as literal strings — and failed because the list
    // itself put those strings in the file. A sentinel has to be written so it
    // cannot describe itself.
    //
    // What actually distinguishes a mirror is WHERE it lives: a re-declared
    // helper sits at top level, as all three did. Anchoring at column 0 cannot
    // match anything inside main(), so this check is invisible to itself.
    // See helpers/source_text.dart — that trick is shared now rather than
    // re-derived, because it took three attempts to get right.
    expect(
        hasTopLevelDeclaration('test/artist_match_verify.dart',
            const ['Set<String>', 'bool', 'String', 'List<String>']),
        isFalse,
        reason: 'This file declares a top-level helper again, which is how it '
            'came to test a copy of the rule instead of the rule. Call '
            'SearchService.artistNameMatches — it is public and static so that '
            'this file does not need one.');
  });
}
