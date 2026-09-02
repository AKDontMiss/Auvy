import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One alternative launcher icon.
class AppIconOption {
  /// Manifest variant key. `''` is the default icon (MainActivity itself).
  final String variant;
  final String label;

  /// Flutter asset used for the PREVIEW swatch. The launcher reads the mipmap
  /// resources instead — `res/mipmap-*/ic_launcher_<variant>.png`, generated from
  /// these same 512px sources, because a launcher can't see Flutter assets.
  final String asset;

  const AppIconOption(
      {required this.variant, required this.label, required this.asset});
}

/// Picks the app's launcher icon (Settings → Appearance → App icon).
///
/// Android has no "set icon" API: each icon is a separate launcher component
/// (`<activity-alias>`) and you enable the one you want. All of that lives in
/// [AlternateIconManager] on the native side; this just names the options and
/// remembers the choice so the UI can show which is active.
class AppIconService {
  const AppIconService._();

  static const MethodChannel _channel = MethodChannel('com.auvy.app/icon');
  static const String _kPref = 'auvy_app_icon_variant';

  static const List<AppIconOption> options = [
    AppIconOption(variant: '', label: 'Default', asset: 'assets/icons/app_icon.webp'),
    AppIconOption(variant: 'purple', label: 'Purple', asset: 'assets/icons/app_icon_purple.webp'),
    AppIconOption(variant: 'pink', label: 'Pink', asset: 'assets/icons/app_icon_pink.webp'),
    AppIconOption(variant: 'red', label: 'Red', asset: 'assets/icons/app_icon_red.webp'),
    AppIconOption(variant: 'orange', label: 'Orange', asset: 'assets/icons/app_icon_orange.webp'),
    AppIconOption(variant: 'green', label: 'Green', asset: 'assets/icons/app_icon_green.webp'),
  ];

  /// Accent colour → icon variant.
  ///
  /// Keyed on the exact ARGB values offered by the Appearance picker, so the icon
  /// tracks the accent and no separate icon picker is needed. Any colour that
  /// isn't one of the six presets — notably an artwork-derived accent — falls
  /// through to the stock icon rather than guessing at a nearest match, because
  /// switching the launcher icon on every track change would be absurd.
  static String variantForAccent(Color accent) {
    switch (accent.toARGB32()) {
      case 0xFFE040FB: // Colors.purpleAccent
        return 'purple';
      case 0xFF69F0AE: // Colors.greenAccent
        return 'green';
      case 0xFFFFAB40: // Colors.orangeAccent
        return 'orange';
      case 0xFFFF5252: // Colors.redAccent
        return 'red';
      case 0xFFFF4081: // Colors.pinkAccent
        return 'pink';
      default: // includes the 0xFF53B1E1 cyan default
        return '';
    }
  }

  /// Records that the launcher icon should match [accent].
  ///
  /// Only WRITES the preference — it deliberately does not switch the icon now.
  /// Switching means disabling the alias the running task was launched from, and
  /// Android removes a task whose root component is disabled, so applying it
  /// live closed the app the instant the accent changed. `AlternateIconManager`
  /// picks this up in `MainActivity.onStop`, where it's invisible.
  static Future<void> applyForAccent(Color accent) async {
    final wanted = variantForAccent(accent);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPref, wanted);
  }

  /// Asset for the in-app artwork (splash, about, login) matching [accent], so
  /// the launcher icon and the icon shown inside the app never disagree.
  static String assetForAccent(Color accent) {
    final variant = variantForAccent(accent);
    return variant.isEmpty
        ? 'assets/icons/app_icon.webp'
        : 'assets/icons/app_icon_$variant.webp';
  }

  static Future<String> current() async =>
      (await SharedPreferences.getInstance()).getString(_kPref) ?? '';

  /// Returns true when the switch was applied. The pref is only written on
  /// success, so a failed switch can't leave Settings claiming an icon the
  /// launcher isn't showing.
  static Future<bool> setIcon(String variant) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('setIcon', {'variant': variant}) ??
          false;
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kPref, variant);
      }
      return ok;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
