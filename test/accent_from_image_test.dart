import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/providers/theme_provider.dart';

/// `accentFromRgba` — the artwork→accent-colour decision.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
///
/// It replaced `palette_generator`, which is DISCONTINUED. Hand-rolling forty
/// lines to drop a dead dependency is the smaller risk of the two — but only if
/// the replacement is actually verified, and the package's own behaviour was
/// never covered by anything here.
///
/// Tested against hand-written pixels rather than a real image: the decode is a
/// separate function precisely so this half can be checked exactly.
void main() {
  /// RGBA bytes for a run of colours, [n] pixels each.
  Uint8List pixels(List<(Color, int)> runs) {
    final out = <int>[];
    for (final (c, n) in runs) {
      for (var i = 0; i < n; i++) {
        out.addAll([c.red, c.green, c.blue, c.alpha]);
      }
    }
    return Uint8List.fromList(out);
  }

  group('picks the colour a listener would call the cover colour', () {
    test('a solid cover returns that colour', () {
      const teal = Color(0xFF00A0A0);
      final got = accentFromRgba(pixels([(teal, 100)]))!;
      // Quantised to 5 bits per channel then averaged, so allow the rounding.
      expect((got.red - teal.red).abs(), lessThan(10));
      expect((got.green - teal.green).abs(), lessThan(10));
      expect((got.blue - teal.blue).abs(), lessThan(10));
    });

    test('WARN: a vivid colour beats a larger dull one', () {
      // The whole point of preferring "vibrant" over "dominant". A sleeve that is
      // mostly grey card with a coloured band should theme to the band.
      final got = accentFromRgba(pixels([
        (const Color(0xFF808080), 700), // grey, the majority
        (const Color(0xFFE01050), 300), // vivid pink
      ]))!;
      expect(HSLColor.fromColor(got).saturation, greaterThan(0.4),
          reason: 'Returned the dull majority instead of the vivid minority.');
      expect(got.red, greaterThan(got.green));
    });

    test('WARN: but a tiny fleck does NOT beat the sleeve', () {
      // Population is weighted for exactly this: one neon pixel is not the
      // cover's colour, and palette_generator weighted population too.
      final got = accentFromRgba(pixels([
        (const Color(0xFF2050C0), 2000), // a real blue sleeve
        (const Color(0xFF00FF00), 3), // three neon pixels
      ]))!;
      expect(got.blue, greaterThan(got.green),
          reason: 'Three pixels of neon green decided the theme.');
    });
  });

  group('ignores what is not the artwork', () {
    test('transparent pixels are skipped', () {
      // Letterboxed and padded covers are full of them, and counting them makes
      // every cover theme to the same colour.
      final got = accentFromRgba(pixels([
        (const Color(0x00FFFFFF), 900), // fully transparent
        (const Color(0xFFC03040), 100),
      ]))!;
      expect(got.red, greaterThan(got.blue));
    });

    test('near-black and near-white do not become the accent', () {
      // They are almost always background, and an accent derived from them is a
      // grey that reads as broken rather than as a colour choice.
      for (final bg in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
        final got = accentFromRgba(pixels([
          (bg, 1500),
          (const Color(0xFFD08010), 200),
        ]))!;
        expect(HSLColor.fromColor(got).saturation, greaterThan(0.3),
            reason: 'A ${bg == const Color(0xFF000000) ? "black" : "white"} '
                'background produced the accent.');
      }
    });

    test('a fully transparent image returns null rather than a colour', () {
      // Null is what makes the caller fall back to the global accent. Inventing
      // a colour here would theme the player from nothing.
      expect(accentFromRgba(pixels([(const Color(0x00000000), 50)])), isNull);
    });

    test('empty input returns null rather than throwing', () {
      expect(accentFromRgba(Uint8List(0)), isNull);
    });

    test('a truncated final pixel does not throw', () {
      // toByteData should always give whole pixels, but a loop that reads i+3
      // without checking is one malformed buffer away from a range error in the
      // player's own theming path.
      expect(() => accentFromRgba(Uint8List.fromList([255, 0, 0])), returnsNormally);
    });
  });

  group('an all-grey cover still themes', () {
    test('it falls back to the dominant colour', () {
      // No candidate clears the saturation bar, so the honest answer is the most
      // common colour — mirroring `vibrantColor ?? dominantColor`.
      final got = accentFromRgba(pixels([
        (const Color(0xFF9A9A9A), 800),
        (const Color(0xFF4A4A4A), 200),
      ]))!;
      expect(got, isNotNull);
      expect((got.red - got.blue).abs(), lessThan(20),
          reason: 'A grey cover should give a grey, not an invented hue.');
    });
  });

  test('is deterministic — the same cover always themes the same', () {
    // The accent is cached by image path, so a function that answered
    // differently on a second call would make the player change colour on a
    // replay.
    final px = pixels([
      (const Color(0xFF3070B0), 400),
      (const Color(0xFFB03070), 400),
      (const Color(0xFF70B030), 400),
    ]);
    final first = accentFromRgba(px);
    for (var i = 0; i < 5; i++) {
      expect(accentFromRgba(px), first);
    }
  });
}
