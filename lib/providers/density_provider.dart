import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How tightly the app packs its lists.
///
/// Flutter's `ThemeData.visualDensity` and `ListTileThemeData` reach every
/// `ListTile` (library, search, playlist, album and artist tracks, home rows) from
/// one value in `MaterialApp.theme`, and Material buttons and chips too, without
/// touching call sites.
///
/// The theme alone isn't enough: `visualDensity` only changes a ListTile's
/// minimum height, and rows with vertical `contentPadding` and a 50–56 px cover
/// already exceed it; some lists (e.g. the queue sheet) aren't ListTiles at all.
/// The helpers below let those rows opt in.
///
/// Limited to lists, and labelled that way: the mini-player, player controls and
/// share card keep their own proportions.
enum AppDensity { compact, comfortable, spacious }

extension AppDensityValues on AppDensity {
  String get label => switch (this) {
        AppDensity.compact => 'Compact',
        AppDensity.comfortable => 'Comfortable',
        AppDensity.spacious => 'Spacious',
      };

  String get blurb => switch (this) {
        AppDensity.compact => 'Shorter rows, more songs on screen',
        AppDensity.comfortable => 'The default',
        AppDensity.spacious => 'Taller rows and bigger covers, easier to tap',
      };

  /// Fed to `ThemeData.visualDensity`, vertical axis only (horizontal squeezing
  /// misaligns artwork with section headers). Flutter clamps it to ±4, each unit 4
  /// logical pixels. ±3 plus [minVerticalPadding] below gives roughly 52 px to
  /// 104 px per row (about 13 songs on screen at Compact vs 6–7 at Spacious), a
  /// clearly visible difference. Safe at the compact end because the two text lines
  /// set a minimum height, so rows stop shrinking instead of clipping.
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

  /// Scales a row's leading cover. The cover sets a floor on row height (a 56 px
  /// cover forces a 56 px row), so scaling it is what lets compact rows be compact.
  /// Gentle (0.82x to 1.12x), since the cover is what people scan lists by.
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

/// The current density, readable without a `ref`, for row builders that are
/// plain StatelessWidgets or helpers. Safe because MyApp watches
/// [densityProvider] and rebuilds MaterialApp when it changes, so every row
/// re-reads this in the same frame. A mirror of provider state: write it only
/// from [DensityNotifier].
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
    // Started unawaited by the constructor, so the notifier may be disposed by now
    // (a rebuild on sign-in or restore); writing state would throw.
    if (!mounted) return;
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
