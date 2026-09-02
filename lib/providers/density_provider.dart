import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How tightly the app packs its lists.
///
/// Why this works as one setting
///
/// The obvious way to build a density control is to invent a spacing scale and
/// convert every `EdgeInsets` and `SizedBox` in the app to it — hundreds of
/// independent call sites, most of which are not list rows at all. That was the
/// reason this kept being deferred.
///
/// The funnel that makes it tractable is Flutter's own: `ThemeData.visualDensity`
/// and `ListTileThemeData`. Auvy's list rows are `ListTile`s (library shelves and
/// items, search results, playlist and album tracks, artist tracks, home rows),
/// and `ListTile` reads both of those from the ambient theme. So a single value
/// in `MaterialApp.theme` reaches every row in the app without touching a single
/// call site, and it reaches Material's buttons and chips consistently at the
/// same time, which is exactly what "density" should mean.
///
/// Why the theme funnel alone was NOT enough
///
/// The paragraph above is true and was still not the whole story. Reported as
/// "density only does anything on the album page", and that was exactly right:
///
///  1. `visualDensity` adjusts a ListTile's MINIMUM height. A row whose content
///     already exceeds that minimum is sized by its content, and the minimum
///     never comes into play. Most song rows set `contentPadding` with a
///     vertical value AND a 50–56px leading cover, which together clear the
///     minimum at every density, so the setting moved nothing. Album page
///     happened to use `vertical: 0`, which is the only reason it responded.
///
///  2. Some lists are not ListTiles at all. The queue sheet builds its rows by
///     hand with a hardcoded inset, so no theme value could ever reach it.
///
/// Hence the three helpers below. The theme funnel still does the broad work;
/// these let the handful of rows that opt out of it opt back in, without
/// inventing a spacing scale for the whole app.
///
/// STILL SCOPED AND LABELLED AS "LISTS". What it does NOT change: single-purpose
/// layouts with their own proportions — the mini-player, the player controls,
/// the share card. Stretching those would break them rather than make the app
/// feel denser. The setting says "lists" so it does not promise otherwise.
enum AppDensity { compact, comfortable, spacious }

extension AppDensityValues on AppDensity {
  String get label => switch (this) {
        AppDensity.compact => 'Compact',
        AppDensity.comfortable => 'Comfortable',
        AppDensity.spacious => 'Spacious',
      };

  String get blurb => switch (this) {
        AppDensity.compact => 'More on screen, tighter rows',
        AppDensity.comfortable => 'The default spacing',
        AppDensity.spacious => 'Roomier, easier to hit',
      };

  /// Fed to `ThemeData.visualDensity`. The vertical axis only: squeezing rows
  /// HORIZONTALLY moves the artwork away from the screen edge and makes the
  /// leading image look mis-aligned against section headers, which read as a bug
  /// rather than a density choice.
  ///
  /// Flutter clamps this to ±4, and each unit is 4 logical pixels of padding, so
  /// −1 ≈ 8px shorter rows and +1 ≈ 8px taller.
  /// WIDENED after the first range (−1.5 / 0 / +1.0) was reported as
  /// invisible, and it was: about 10px of swing per row, which on a two-line
  /// song row is under 15% and reads as nothing. A preference nobody can see the
  /// effect of is worse than no preference, because the only way to tell whether
  /// it did anything is to doubt it.
  ///
  /// ±3 is 12px of padding each way. Combined with [minVerticalPadding] below the
  /// full range is roughly 52px → 104px per row: about 13 songs on screen at
  /// Compact against 6–7 at Spacious. Unmistakable, which is the point.
  ///
  /// Safe at the compact end because ListTile's height has a FLOOR — the two text
  /// lines set a minimum that padding reduction cannot eat into, so the row stops
  /// shrinking rather than clipping its own content.
  VisualDensity get visual => switch (this) {
        AppDensity.compact => const VisualDensity(vertical: -3.0),
        AppDensity.comfortable => VisualDensity.standard,
        AppDensity.spacious => const VisualDensity(vertical: 3.0),
      };

  /// ListTile's own vertical breathing room, which `visualDensity` alone does not
  /// fully control — a two-line row keeps its minimum padding regardless, so this
  /// is what actually tightens a title+artist song row.
  double get minVerticalPadding => switch (this) {
        AppDensity.compact => 0.0,
        AppDensity.comfortable => 4.0,
        AppDensity.spacious => 14.0,
      };

  /// Vertical padding for a row that sets its OWN `contentPadding`, or builds
  /// itself by hand.
  ///
  /// Setting `contentPadding` on a ListTile REPLACES the themed value, so any
  /// row passing a vertical number here was pinning its height at every density.
  /// Those call sites now pass this instead of a literal.
  double get rowVerticalPadding => switch (this) {
        AppDensity.compact => 0.0,
        AppDensity.comfortable => 4.0,
        AppDensity.spacious => 12.0,
      };

  /// Scale a row's leading cover.
  ///
  /// THE ARTWORK IS THE REAL FLOOR. Padding can go to zero and a 56px cover
  /// still forces a 56px row, which is why trimming padding alone looked like
  /// it did nothing on the pages with the biggest covers. Scaling the image is
  /// what actually lets a compact row be compact.
  ///
  /// Deliberately gentle (0.82x to 1.12x): the cover is the thing you scan a
  /// list by, and a genuinely small one costs more than the row height saves.
  double artwork(double base) => switch (this) {
        AppDensity.compact => (base * 0.82).roundToDouble(),
        AppDensity.comfortable => base,
        AppDensity.spacious => (base * 1.12).roundToDouble(),
      };

  /// The gap between a title and the line under it, for hand-built rows.
  /// Small numbers, but on a list of thirty they are the difference between
  /// tight and airy.
  double get lineGap => switch (this) {
        AppDensity.compact => 1.0,
        AppDensity.comfortable => 3.0,
        AppDensity.spacious => 5.0,
      };
}

/// The current density, readable WITHOUT a `ref`.
///
/// Row builders are scattered across a dozen files, several of them plain
/// StatelessWidgets or private helper methods with no WidgetRef to hand.
/// Threading a provider through all of them to read one enum would be a lot of
/// churn for no behavioural gain, so this mirrors the provider the same way
/// `ListeningPolicy` already mirrors the other appearance settings.
///
/// SAFE BECAUSE THE ROOT REBUILDS. MyApp watches [densityProvider] and rebuilds
/// MaterialApp when it changes, so every row below re-reads this in the same
/// frame the setting is applied. It is a cache of provider state, never the
/// source of truth — write it only from [DensityNotifier].
AppDensity densityNow = AppDensity.comfortable;

class DensityNotifier extends StateNotifier<AppDensity> {
  DensityNotifier() : super(AppDensity.comfortable) {
    _load();
  }

  static const String _kName = 'app_density_name';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kName);
    if (name == null) return;
    state = AppDensity.values
        .firstWhere((d) => d.name == name, orElse: () => AppDensity.comfortable);
    densityNow = state;
  }

  Future<void> setDensity(AppDensity d) async {
    state = d;
    densityNow = d;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, d.name);
  }
}

final densityProvider =
    StateNotifierProvider<DensityNotifier, AppDensity>((ref) {
  return DensityNotifier();
});
