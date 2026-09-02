import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The artist page's About card: where it sits, and what it shows.
///
/// ── WHY IT MOVED ────────────────────────────────────────────────────────────
///
/// It was the LAST sliver on the page, below every release shelf and below
/// "Fans might also like", while its own comment described the placement as
/// "Prominent & Noticeable". A first-time visitor — the only person who needs to
/// be told who an artist is — never scrolled that far.
///
/// Source scans rather than a pumped widget: the card is a private class inside a
/// ConsumerWidget that watches three providers, and what these guard is ORDER and
/// CONTENT, both of which read directly.
void main() {
  final artist = codeOf('lib/presentation/pages/artist_page.dart');

  group('it sits under the header, not at the bottom', () {
    test('About comes before the first content shelf', () {
      final about = artist.indexOf('_ArtistBioCard(');
      final topSongs = artist.indexOf('"Top songs"');
      expect(about, greaterThan(-1), reason: 'The About card is gone.');
      expect(topSongs, greaterThan(-1), reason: 'The Top songs shelf is gone.');
      expect(about, lessThan(topSongs),
          reason: 'About is back below the music. It was last on the page for '
              'a long time precisely because nothing checked this.');
    });

    test('it is still rendered unconditionally', () {
      // It hides ITSELF when neither YouTube nor Wikipedia has anything. Wrapping
      // the call site in a condition instead would mean a missing YouTube blurb
      // suppressed a perfectly good Wikipedia one.
      final block = artist.substring(
          artist.indexOf('if (data != null) ...['), artist.indexOf('"Top songs"'));
      expect(block.contains('if (data.description'), isFalse,
          reason: 'The card is conditional at the call site again, which defeats '
              'its own fallback.');
    });
  });

  group('what the card shows', () {
    test('the audience figure is typeset apart from its unit', () {
      // "1.2M" large over "SUBSCRIBERS" small. As one 9.5px all-caps pill it was
      // the smallest text in the panel, despite being the fact people scan for.
      expect(artist.contains('final subsCount ='), isTrue);
      expect(artist.contains('final subsUnit ='), isTrue);
      expect(artist.contains('subsLabel'), isFalse,
          reason: 'The single combined label is back.');
    });

    test('both shapes of the subscriber string are handled', () {
      // YouTube hands this over already worded ("1.2M subscribers") or as a bare
      // count, so the unit cannot simply be assumed.
      final decl = artist.substring(artist.indexOf('final subsUnit ='));
      final expr = decl.substring(0, decl.indexOf(';'));
      expect(expr.contains("contains('subscriber')"), isTrue,
          reason: 'The already-worded case is no longer detected, so a count '
              'that says "subscribers" would be labelled twice.');
    });

    test('there is ONE expand affordance, not two', () {
      expect(artist.contains('AnimatedRotation'), isTrue,
          reason: 'The rotating chevron is gone.');
      expect(artist.contains('"READ MORE"'), isFalse,
          reason: 'The READ MORE button is back alongside the chevron. The card '
              'has always been tappable anywhere; two controls for one action '
              'is one too many.');
    });

    test('the biography still says which source it came from', () {
      // It switches between YouTube Music and Wikipedia depending on which has
      // more, and the two read very differently. Silently swapping is worse than
      // no attribution.
      expect(artist.contains('Source: \${wiki.source}'), isTrue);
      expect(artist.contains('Source: YouTube Music'), isTrue);
    });

    test('collapsed to two lines, because it now sits above the music', () {
      final decl = artist.substring(artist.indexOf('maxLines: _expanded ? null :'));
      expect(decl.startsWith('maxLines: _expanded ? null : 2'), isTrue,
          reason: 'Every extra collapsed line here pushes the artist\'s own '
              'tracks further down the screen.');
    });
  });
}
