import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The accent that follows the playing track's artwork.
///
/// The colour itself is not new — [playerColorProvider] has extracted it per
/// track for the player screen all along. The feature only lets it out into the
/// rest of the app, and everything that can go wrong here is about the two
/// providers now pointing at each other.
void main() {
  final theme = codeOf('lib/providers/theme_provider.dart');
  final main = codeOf('lib/main.dart');

  group('the two providers must not form a cycle', () {
    test('playerColorProvider READS the theme, it does not watch it', () {
      // WITH `ref.watch`, writing the accent from this provider's value rebuilds
      // the provider that produced it:
      //
      //   artwork colour -> applyDynamic -> themeProvider changes ->
      //   playerColorProvider rebuilt -> state resets to the theme colour
      //
      // applyDynamic's equality guard stops that looping forever, but the
      // rebuild is itself the bug — see the next test.
      final body = theme.substring(
        theme.indexOf('final playerColorProvider'),
        theme.indexOf('final pureBlackProvider'),
      );
      expect(body.contains('ref.watch(themeProvider)'), isFalse,
          reason: 'playerColorProvider watches themeProvider again. With the '
              'accent following the artwork, that is a cycle.');
      expect(body.contains('PlayerColorNotifier(ref)'), isTrue,
          reason: 'The notifier no longer takes the ref it needs to resolve its '
              'fallback colour on demand.');
    });

    test('turning the mode OFF must not wipe the artwork colour', () {
      // restoreManual() sets themeProvider back to the chosen accent. While
      // playerColorProvider watched it, that rebuilt the notifier seeded with
      // that accent — so the player page lost the playing track's colour and
      // snapped to the accent until the next track.
      //
      // Resolving the fallback through a getter is what decouples the two.
      expect(theme.contains('Color get globalDefault => _ref.read(themeProvider)'),
          isTrue,
          reason: 'globalDefault is captured at construction again, which ties '
              "this provider's lifetime back to the accent.");
    });
  });

  group('an artwork colour is not a preference', () {
    test('applyDynamic writes no prefs', () {
      final body = theme.substring(
        theme.indexOf('void applyDynamic('),
        theme.indexOf('void restoreManual('),
      );
      expect(body.contains('prefs'), isFalse,
          reason: 'A song colour is being saved as the accent. That overwrites '
              'the colour the user chose, and switching the mode off would '
              'leave them on whatever happened to be playing.');
    });

    test('applyDynamic does not touch the launcher icon', () {
      final body = theme.substring(
        theme.indexOf('void applyDynamic('),
        theme.indexOf('void restoreManual('),
      );
      expect(body.contains('AppIconService'), isFalse,
          reason: 'AppIconService flips activity-aliases. Doing that per TRACK '
              'thrashes the launcher and can make the home-screen icon '
              'visibly disappear and reappear.');
    });

    test('it short-circuits when the colour has not changed', () {
      // Also the thing that keeps the provider interaction from ping-ponging.
      final body = theme.substring(theme.indexOf('void applyDynamic('));
      expect(body.startsWith(RegExp(r'void applyDynamic\(Color color\) \{\s*'
          r'if \(color == state\) return;')), isTrue,
          reason: 'The equality guard is gone.');
    });

    test('the manual accent is remembered so it can be restored', () {
      expect(theme.contains('_manualAccent = color;'), isTrue,
          reason: 'setThemeColor no longer records the chosen colour.');
      expect(theme.contains('_manualAccent = Color(colorValue);'), isTrue,
          reason: 'A cold start does not seed _manualAccent, so toggling the '
              'mode on first launch would restore the hardcoded default '
              'instead of the accent actually in use.');
    });
  });

  group('wiring', () {
    test('the listener lives at the root, not in the player', () {
      // The point of the setting is that the colour reaches the whole app, and
      // the player screen is the one place it already worked. Listening at the
      // root keeps the accent tracking the queue while browsing elsewhere.
      expect(main.contains('ref.listen(playerColorProvider'), isTrue);
      expect(main.contains('ref.listen(dynamicAccentProvider'), isTrue,
          reason: 'Nothing applies the change when the switch is flipped, so '
              'the toggle appears to do nothing until the song changes.');
    });

    test('the mode is off by default and persisted', () {
      expect(theme.contains('DynamicAccentNotifier() : super(false)'), isTrue,
          reason: 'This must be opt-in.');
      expect(theme.contains("kPref = 'auvy_dynamic_accent'"), isTrue);
    });
  });
}
