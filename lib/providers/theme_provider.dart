import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/app_icon_service.dart';

// Provides global manual accent color
final themeProvider = StateNotifierProvider<ThemeNotifier, Color>((ref) {
  return ThemeNotifier();
});

// Provides dynamic color for PlayerPage UI elements
//
// READS themeProvider, DOES NOT WATCH IT, and that distinction is load-bearing
// now that [dynamicAccentProvider] exists.
//
// With `ref.watch`, this provider was rebuilt every time the accent changed.
// That was harmless while the accent only changed when the user picked a colour,
// and became a cycle the moment the accent started FOLLOWING this provider:
//
//   artwork colour extracted -> ThemeNotifier.applyDynamic -> themeProvider
//   changes -> this provider is disposed and rebuilt -> its state resets to the
//   theme colour -> the listener fires again
//
// The equality guard in applyDynamic stopped it looping forever, but the rebuild
// itself is the bug: switching the setting OFF calls restoreManual(), which sets
// themeProvider back to the chosen accent, which rebuilt this notifier seeded
// with that accent, so the player page lost the playing track's artwork colour
// and snapped to the accent until the next track.
//
// The theme is only ever a FALLBACK here (the colour to show when artwork cannot
// be read), so a subscription was never needed. Reading it on demand keeps the
// fallback current without tying this provider's lifetime to it.
final playerColorProvider = StateNotifierProvider<PlayerColorNotifier, Color>((ref) {
  return PlayerColorNotifier(ref);
});

/// Accent follows the ARTWORK of whatever is playing.
///
/// The colour itself already existed — [playerColorProvider] has extracted it
/// per track for the player screen all along. All this adds is letting that
/// colour out of the player and into the rest of the app.
///
/// IT DOES NOT OVERWRITE THE ACCENT YOU CHOSE. [ThemeNotifier] keeps the manual
/// colour in `_manualAccent` and in prefs, and artwork colours are pushed
/// through [ThemeNotifier.applyDynamic], which never writes to disk. Turn this
/// off and your own accent comes straight back — the alternative (letting each
/// song save its colour as the new preference) means the setting silently eats
/// the choice it was supposed to be layered on top of.
final dynamicAccentProvider =
    StateNotifierProvider<DynamicAccentNotifier, bool>((ref) {
  return DynamicAccentNotifier();
});

class DynamicAccentNotifier extends StateNotifier<bool> {
  DynamicAccentNotifier() : super(false) {
    _load();
  }

  static const String kPref = 'auvy_dynamic_accent';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(kPref);
    if (v != null && v != state) state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPref, v);
  }
}

/// Pure black (AMOLED) backdrop.
///
/// Auvy's app backdrop is a radial gradient tinted with the accent colour, which
/// looks premium on an LCD and lights up an OLED panel that could otherwise have
/// those pixels switched off entirely. With this on, [DynamicBackground] paints
/// solid `#000000` instead. Only the app backdrop changes: the player still
/// carries the artwork ambience, because that IS the now-playing screen.
final pureBlackProvider = StateNotifierProvider<PureBlackNotifier, bool>((ref) {
  return PureBlackNotifier();
});

class PureBlackNotifier extends StateNotifier<bool> {
  PureBlackNotifier() : super(false) {
    _load();
  }

  static const String kPref = 'auvy_pure_black';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(kPref);
    if (v != null && v != state) state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPref, v);
  }
}

class ThemeNotifier extends StateNotifier<Color> {
  /// The accent a brand-new install starts on — 'Cyan' in the theme picker.
  ///
  /// Named rather than repeated as a literal because three places need to agree
  /// on it: this constructor, [resetToDefault], and AppIconService's fallback.
  static const Color defaultAccent = Color(0xFF53B1E1);

  ThemeNotifier() : super(defaultAccent) {
    _loadTheme();
  }

  /// Put the accent back to Cyan for a genuinely NEW user.
  ///
  /// The theme is a device setting, which is why it leaked visually.
  /// `_wipeLocalUserData` deliberately keeps theme/quality/EQ — correct for a
  /// logout, wrong for an account CHANGE: the incoming account opened the app
  /// wearing the previous user's colour (and launcher icon). A returning account
  /// still gets its own accent straight back, because `app_theme_color` is part
  /// of the cloud backup and `_applyRestoredSettings` re-applies it.
  ///
  /// Clears the pref as well as the live state, so a later read cannot resurrect
  /// the old colour.
  Future<void> resetToDefault() async {
    state = defaultAccent;
    _manualAccent = defaultAccent;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('app_theme_color');
    } catch (_) {}
    // Keep the launcher icon in step — otherwise a new user gets a cyan app with
    // the previous user's coloured icon.
    AppIconService.applyForAccent(defaultAccent);
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt('app_theme_color');
    if (colorValue != null) {
      state = Color(colorValue);
      // Seeded here as well as in setThemeColor: on a cold start nothing has
      // called the setter yet, so without this a first-launch toggle of the
      // dynamic accent would restore the hardcoded default instead of the
      // colour actually in use.
      _manualAccent = Color(colorValue);
    }
  }

  /// The colour the user actually chose, remembered while an artwork colour is
  /// being shown over the top of it.
  Color _manualAccent = defaultAccent;

  Future<void> setThemeColor(Color color) async {
    state = color;
    _manualAccent = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme_color', color.value);
    // The launcher icon follows the accent, so the home screen matches the app
    // instead of needing its own picker. Fire-and-forget: a launcher that refuses
    // the component change must not block the colour from being applied.
    AppIconService.applyForAccent(color);
  }

  /// Show an artwork colour as the app accent, WITHOUT persisting it.
  ///
  /// Two deliberate omissions, both of which would be bugs rather than features:
  ///
  ///  • **No prefs write.** A song colour is not a preference. Saving it would
  ///    overwrite the accent the user picked, and turning the mode back off
  ///    would leave them on whatever happened to be playing at the time.
  ///  • **No launcher icon change.** [AppIconService] enables and disables
  ///    activity-aliases; doing that per TRACK would thrash the launcher, and on
  ///    many launchers the home-screen icon visibly disappears and reappears
  ///    while it re-reads the component. The icon stays on the chosen accent.
  void applyDynamic(Color color) {
    if (color == state) return;
    state = color;
  }

  /// Put the manually chosen accent back when the mode is switched off.
  void restoreManual() {
    if (state != _manualAccent) state = _manualAccent;
  }
}

// Logic for artwork-based color
class PlayerColorNotifier extends StateNotifier<Color> {
  final Ref _ref;

  /// The colour to fall back on when artwork cannot be read. Resolved on each
  /// use rather than captured at construction, so it follows a manual accent
  /// change without this provider having to be rebuilt for it.
  Color get globalDefault => _ref.read(themeProvider);

  PlayerColorNotifier(this._ref) : super(_ref.read(themeProvider));

  // Cache extracted colours by image path/url. Decoding and quantizing runs
  // on the UI isolate, which janks the player page on every song change;
  // caching makes replays/skip-backs instant.
  static final Map<String, Color> _cache = {};

  Future<void> updateFromImage(String path) async {
    if (path.isEmpty) return;

    final cached = _cache[path];
    if (cached != null) {
      if (mounted) state = cached;
      return;
    }

    try {
      final ImageProvider img = path.startsWith('http')
          ? NetworkImage(path)
          : FileImage(File(path)) as ImageProvider;

      // Downscale to 80x80 before quantizing: the dominant/vibrant colour is
      // unchanged but the work drops ~10x, so it no longer stalls the UI.
      final dynamicColor = await _accentFromImage(img) ?? globalDefault;
      final result = _ensureVibrancy(dynamicColor);

      if (_cache.length > 120) _cache.clear();
      _cache[path] = result;
      // The palette decode is async; the notifier can be disposed mid-await
      // (app teardown / scope rebuild). Guard against "used after dispose".
      if (mounted) state = result;
    } catch (e) {
      if (mounted) state = globalDefault;
    }
  }

  Color _ensureVibrancy(Color color) {
    HSLColor hsl = HSLColor.fromColor(color);
    if (hsl.lightness < 0.4) hsl = hsl.withLightness(0.6);
    return hsl.toColor();
  }
}

/// The accent colour of [provider]'s image, or null if it cannot be read.
///
/// Why this is hand-rolled
///
/// It replaces `PaletteGenerator.fromImageProvider(size: 80x80,
/// maximumColorCount: 8)` and its `vibrantColor ?? dominantColor` pick.
/// `palette_generator` is DISCONTINUED — no further fixes, and this used two
/// lines of its API. Forty lines of local code with no dependency is the smaller
/// risk of the two, and it removes a package from the supply chain.
///
/// It is an APPROXIMATION of palette_generator's swatch targets, deliberately:
/// the result feeds an accent colour that then goes through `_ensureVibrancy`
/// anyway, so exactness was never what mattered — only that a cover produces a
/// stable, reasonably vivid colour.
Future<Color?> _accentFromImage(ImageProvider provider) async {
  ui.Image? image;
  try {
    // ResizeImage does the downscale in the decoder, so the 6,400 pixels below
    // are the only ones that ever exist — same reasoning as the old `size:`
    // argument, and it also keeps the decoded bitmap out of the image cache at
    // full resolution.
    image = await _resolve(ResizeImage(provider, width: 80, height: 80));
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return accentFromRgba(data.buffer.asUint8List());
  } catch (_) {
    return null;
  } finally {
    // THE DECODED BITMAP HOLDS NATIVE MEMORY. palette_generator disposed its
    // own; hand-rolling means owning that. Without this, every track change
    // leaks an 80x80 texture handle.
    image?.dispose();
  }
}

/// The accent colour of raw RGBA pixels, or null if there is nothing to read.
///
/// Split from the decode deliberately: this half is the whole decision and is
/// pure, so it can be tested against hand-written pixels instead of against a
/// real image, and separating it keeps the I/O half down to resolve-and-hand-over.
@visibleForTesting
Color? accentFromRgba(Uint8List bytes) {
  {
    // Quantise to 5 bits per channel and keep running sums, so the colour
    // returned is the average of its bucket rather than a rounded-off corner of
    // it — the rounding is what makes hand-rolled quantisers look muddy.
    final count = <int, int>{};
    final rSum = <int, int>{};
    final gSum = <int, int>{};
    final bSum = <int, int>{};
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      // Transparent pixels say nothing about the artwork, and letterboxed
      // covers are full of them.
      if (bytes[i + 3] < 128) continue;
      final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
      final key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      count[key] = (count[key] ?? 0) + 1;
      rSum[key] = (rSum[key] ?? 0) + r;
      gSum[key] = (gSum[key] ?? 0) + g;
      bSum[key] = (bSum[key] ?? 0) + b;
    }
    if (count.isEmpty) return null;

    Color avg(int key) => Color.fromARGB(255, rSum[key]! ~/ count[key]!,
        gSum[key]! ~/ count[key]!, bSum[key]! ~/ count[key]!);

    // Two candidates, mirroring the two swatches the old code asked for.
    //
    // VIBRANT: saturated and mid-lightness, weighted by how much of the cover it
    // covers — a tiny fleck of neon should not beat the record sleeve's own
    // colour. Near-black and near-white are excluded: they are almost always
    // background, and they produce a grey accent that looks broken.
    int? bestVibrant;
    double bestVibrantScore = 0;
    int? bestDominant;
    var bestDominantCount = 0;

    for (final key in count.keys) {
      final n = count[key]!;
      if (n > bestDominantCount) {
        bestDominantCount = n;
        bestDominant = key;
      }
      final hsl = HSLColor.fromColor(avg(key));
      if (hsl.lightness < 0.15 || hsl.lightness > 0.9) continue;
      final mid = 1.0 - ((hsl.lightness - 0.5).abs() * 2);
      final score = n * hsl.saturation * (0.35 + 0.65 * mid);
      if (score > bestVibrantScore) {
        bestVibrantScore = score;
        bestVibrant = key;
      }
    }

    // Prefer vibrant, but only when it really is colourful — a washed-out
    // "vibrant" pick is worse than the honest dominant colour. Same order the
    // old `vibrantColor ?? dominantColor` expressed.
    if (bestVibrant != null) {
      final c = avg(bestVibrant);
      if (HSLColor.fromColor(c).saturation >= 0.2) return c;
    }
    return bestDominant == null ? null : avg(bestDominant);
  }
}

/// Await an [ImageProvider] into a decoded [ui.Image].
Future<ui.Image> _resolve(ImageProvider provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      // clone(): the stream owns `info.image` and will dispose it when the last
      // listener goes away, so the caller needs a handle of its own.
      completer.complete(info.image.clone());
      info.dispose();
    },
    onError: (e, st) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(e, st);
    },
  );
  stream.addListener(listener);
  return completer.future;
}