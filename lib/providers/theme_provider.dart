import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/core/image_cache_manager.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/app_icon_service.dart';
import 'package:auvy/services/radio_schedule_service.dart';

// Provides global manual accent color
final themeProvider = StateNotifierProvider<ThemeNotifier, Color>((ref) {
  return ThemeNotifier();
});

// Dynamic colour for the player page.
//
// Reads themeProvider rather than watching it. The theme is only the fallback
// colour (when artwork can't be read), and watching it would rebuild this
// provider whenever the accent changes. With [dynamicAccentProvider] following
// this provider, that creates a loop, and turning the dynamic accent off would
// reset the player page to the manual accent until the next track.
final playerColorProvider = StateNotifierProvider<PlayerColorNotifier, Color>((ref) {
  return PlayerColorNotifier(ref);
});

/// The accent follows the artwork of whatever is playing, using the colour
/// [playerColorProvider] already extracts.
///
/// It doesn't overwrite the accent you chose: [ThemeNotifier] keeps the manual
/// colour in `_manualAccent` and prefs, and artwork colours go through
/// [ThemeNotifier.applyDynamic], which never writes to disk. Turning this off
/// brings your own accent straight back.
final dynamicAccentProvider =
    StateNotifierProvider<DynamicAccentNotifier, bool>((ref) {
  return DynamicAccentNotifier();
});

class DynamicAccentNotifier extends StateNotifier<bool> {
  DynamicAccentNotifier() : super(false) {
    _load();
  }

  static const String kPref = 'auvy_dynamic_accent';

  Future<void> reloadFromStorage() async {
    await _load();
    print('OK: DynamicAccentNotifier reloaded from storage -> dynamicAccent=$state');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Disposed-during-await guard — see the identical note on the loaders
    // above. The constructor starts this and never awaits it.
    if (!mounted) return;
    final v = prefs.getBool(kPref);
    if (v != null && v != state) state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPref, v);
  }
}

/// Pure black (AMOLED) backdrop: [DynamicBackground] paints solid `#000000`
/// instead of the accent-tinted gradient, so OLED pixels can stay off. Only the
/// app backdrop changes; the player keeps its artwork ambience.
final pureBlackProvider = StateNotifierProvider<PureBlackNotifier, bool>((ref) {
  return PureBlackNotifier();
});

class PureBlackNotifier extends StateNotifier<bool> {
  PureBlackNotifier() : super(false) {
    _load();
  }

  static const String kPref = 'auvy_pure_black';

  Future<void> reloadFromStorage() async {
    await _load();
    print('OK: PureBlackNotifier reloaded from storage -> pureBlack=$state');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Disposed-during-await guard — see the identical note on the loaders
    // above. The constructor starts this and never awaits it.
    if (!mounted) return;
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

  /// Resets the accent to Cyan for a new user. `_wipeLocalUserData` keeps
  /// device settings like theme on logout, but on an account change the incoming
  /// account shouldn't inherit the previous user's colour (and launcher icon). A
  /// returning account gets its accent back from the cloud backup
  /// (`app_theme_color`, re-applied by `_applyRestoredSettings`). Clears the pref
  /// too, so a later read can't bring the old colour back.
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

  Future<void> reloadFromStorage() async {
    await _loadTheme();
    AppIconService.applyForAccent(state);
    print('OK: ThemeNotifier reloaded from storage -> accent=#${state.value.toRadixString(16)}');
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    // Disposed-during-await guard — see the identical note on the loaders
    // below. The constructor starts this and never awaits it.
    if (!mounted) return;
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

  /// Shows an artwork colour as the app accent without saving it:
  ///  • **No prefs write.** A song colour isn't a preference; saving it would
  ///    overwrite the accent the user picked.
  ///  • **No launcher icon change.** [AppIconService] switches activity-aliases,
  ///    and doing that per track would make the home-screen icon flicker.
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

  PlayerColorNotifier(this._ref) : super(_ref.read(themeProvider)) {
    _initListener();
  }

  void _initListener() {
    _ref.listen<Song?>(
      playerProvider.select((s) => s.currentSong),
      (prev, next) {
        if (next != null) {
          _updateForSong(next);
        }
      },
      fireImmediately: true,
    );
  }

  void _updateForSong(Song song) {
    String path = song.image;
    if (song.id.startsWith('http') || song.albumTitle == 'RADIO') {
      final schedule = RadioScheduleService.getScheduleForStation(song);
      final liveProg = schedule.firstWhere(
        (p) => p.isLiveNow,
        orElse: () => schedule.first,
      );
      if (liveProg.imageUrl != null && liveProg.imageUrl!.isNotEmpty) {
        path = liveProg.imageUrl!;
      }
    }
    if (path.isNotEmpty) {
      updateFromImage(path);
    }
  }

  // Cache extracted colours by image path/url. Decoding and quantizing runs
  // on the UI isolate, which janks the player page on every song change;
  // caching makes replays/skip-backs instant.
  static final Map<String, Color> _cache = {};

  static ImageProvider? _buildImageProvider(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('assets/')) {
      return AssetImage(trimmed);
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      String resolvedUrl = trimmed;
      // 1. YouTube maxresdefault fix: maxresdefault returns 404 for non-HD videos.
      // hqdefault (480x360) is guaranteed to exist on YouTube, never 404s,
      // and downscales cleanly to our 80x80 palette target.
      if (resolvedUrl.contains('ytimg.com')) {
        resolvedUrl = resolvedUrl.replaceAll(
          RegExp(r'/(?:maxresdefault|sddefault|mqdefault|default)\.jpg'),
          '/hqdefault.jpg',
        );
      }

      // 2. Check local file cache first (AudioCacheManager)
      try {
        final localPath = AudioCacheManager().getLocalPathFromUrl(trimmed);
        if (localPath != null && File(localPath).existsSync()) {
          return FileImage(File(localPath));
        }
      } catch (_) {}

      // 3. Use CachedNetworkImageProvider with CustomImageCacheManager
      return CachedNetworkImageProvider(
        resolvedUrl,
        cacheManager: CustomImageCacheManager(),
      );
    }

    try {
      final file = File(trimmed);
      if (file.existsSync()) {
        return FileImage(file);
      }
    } catch (_) {}

    return null;
  }

  Future<void> updateFromImage(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;

    final cached = _cache[trimmed];
    if (cached != null) {
      if (mounted) state = cached;
      return;
    }

    try {
      final img = _buildImageProvider(trimmed);
      if (img == null) return;

      // Downscale to 80x80 before quantizing: the dominant/vibrant colour is
      // unchanged but the work drops ~10x, so it no longer stalls the UI.
      final dynamicColor = await _accentFromImage(img);
      if (dynamicColor != null) {
        final result = _ensureVibrancy(dynamicColor);
        if (_cache.length > 120) _cache.clear();
        _cache[trimmed] = result;
        if (mounted) state = result;
      }
    } catch (_) {
      // In case of error, preserve existing state rather than overwriting with bad fallback
    }
  }

  Color _ensureVibrancy(Color color) {
    HSLColor hsl = HSLColor.fromColor(color);
    if (hsl.lightness < 0.4) hsl = hsl.withLightness(0.6);
    return hsl.toColor();
  }
}

/// The accent colour of [provider]'s image, or null if it can't be read.
///
/// A small local replacement for the discontinued `palette_generator`
/// (`vibrantColor ?? dominantColor` at 80×80). It approximates its swatch
/// targets; the result goes through `_ensureVibrancy` anyway, so a stable,
/// reasonably vivid colour is all that matters.
Future<Color?> _accentFromImage(ImageProvider provider) async {
  ui.Image? image;
  try {
    // ResizeImage downscales in the decoder, so only 6,400 pixels ever exist, and
    // the full-resolution bitmap stays out of the image cache.
    image = await _resolve(ResizeImage(provider, width: 80, height: 80));
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return accentFromRgba(data.buffer.asUint8List());
  } catch (_) {
    return null;
  } finally {
    // The decoded bitmap holds native memory; dispose it, or every track change
    // leaks a texture.
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

    // Two candidates, like the two swatches before. Vibrant: saturated and
    // mid-lightness, weighted by how much of the cover it covers, so a tiny fleck of
    // neon can't win. Near-black and near-white are excluded; they're usually
    // background and give a grey accent.
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
      if (!completer.isCompleted) {
        completer.complete(info.image.clone());
      }
      info.dispose();
    },
    onError: (e, st) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(e, st);
    },
  );
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 5));
}

/// Preference state for player playback controls color.
class PlayerControlsColorState {
  /// 'white' (default), 'accent', 'artwork', or 'custom'
  final String mode;
  final Color customColor;

  const PlayerControlsColorState({
    this.mode = 'white',
    this.customColor = Colors.white,
  });

  PlayerControlsColorState copyWith({
    String? mode,
    Color? customColor,
  }) {
    return PlayerControlsColorState(
      mode: mode ?? this.mode,
      customColor: customColor ?? this.customColor,
    );
  }

  Color resolve(Color appAccent, Color artworkColor) {
    switch (mode) {
      case 'accent':
        return appAccent;
      case 'artwork':
        return artworkColor;
      case 'custom':
        return customColor;
      case 'white':
      default:
        return Colors.white;
    }
  }
}

final playerControlsColorProvider =
    StateNotifierProvider<PlayerControlsColorNotifier, PlayerControlsColorState>(
        (ref) {
  return PlayerControlsColorNotifier();
});

class PlayerControlsColorNotifier
    extends StateNotifier<PlayerControlsColorState> {
  PlayerControlsColorNotifier() : super(const PlayerControlsColorState()) {
    _load();
  }

  static const String kPrefMode = 'auvy_controls_color_mode';
  static const String kPrefCustom = 'auvy_controls_color_custom';

  Future<void> reloadFromStorage() async {
    await _load();
    print('OK: PlayerControlsColorNotifier reloaded from storage -> mode=${state.mode}');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(kPrefMode) ?? 'white';
    final customVal = prefs.getInt(kPrefCustom);
    final customColor = customVal != null ? Color(customVal) : Colors.white;
    // Disposed-during-await guard — see the identical note on the loaders
    // above. The constructor starts this and never awaits it.
    if (!mounted) return;
    state = PlayerControlsColorState(mode: mode, customColor: customColor);
  }

  Future<void> setMode(String mode) async {
    state = state.copyWith(mode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefMode, mode);
  }

  Future<void> setCustomColor(Color color) async {
    state = state.copyWith(mode: 'custom', customColor: color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefMode, 'custom');
    await prefs.setInt(kPrefCustom, color.value);
  }
}

/// Resolves the live, active color for player controls (play, next, prev, repeat, queue, like).
final resolvedControlsColorProvider = Provider<Color>((ref) {
  final controlsState = ref.watch(playerControlsColorProvider);
  final appAccent = ref.watch(themeProvider);
  final artworkColor = ref.watch(playerColorProvider);
  return controlsState.resolve(appAccent, artworkColor);
});

/// Artwork halo/glow behavior in the player:
/// - 'reactive': Pulses dynamically with beat & audio intensity (default)
/// - 'vibrant': Continuous rich luminous bloom + beat reactive
/// - 'subtle': Delicate soft halo rim
/// - 'off': Clean, no colored shadow glow
final artworkGlowModeProvider =
    StateNotifierProvider<ArtworkGlowNotifier, String>((ref) {
  return ArtworkGlowNotifier();
});

class ArtworkGlowNotifier extends StateNotifier<String> {
  static const String kPrefGlow = 'auvy_artwork_glow_mode';

  ArtworkGlowNotifier() : super('reactive') {
    _load();
  }

  Future<void> reloadFromStorage() async {
    await _load();
    print('OK: ArtworkGlowNotifier reloaded from storage -> glow=$state');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Started unawaited by the constructor, so the notifier may be disposed by now
    // (a rebuild on sign-in or restore); writing state would throw.
    if (!mounted) return;
    state = prefs.getString(kPrefGlow) ?? 'reactive';
  }

  Future<void> setGlow(String mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefGlow, mode);
  }
}

/// Player page backdrop style:
/// - 'blurred': blurred artwork (default)
/// - 'black':   pure black (saves power on OLED screens)
/// - 'radial':  a radial gradient tinted with the track's colour
/// - 'aurora':  a two-colour animated gradient
final playerBackgroundStyleProvider =
    StateNotifierProvider<PlayerBackgroundStyleNotifier, String>((ref) {
  return PlayerBackgroundStyleNotifier();
});

class PlayerBackgroundStyleNotifier extends StateNotifier<String> {
  static const String kPrefBg = 'auvy_player_bg_style';

  PlayerBackgroundStyleNotifier() : super('blurred') {
    _load();
  }

  Future<void> reloadFromStorage() async {
    await _load();
    print('OK: PlayerBackgroundStyleNotifier reloaded from storage -> style=$state');
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Started unawaited by the constructor, so the notifier may be disposed by now
    // (a rebuild on sign-in or restore); writing state would throw.
    if (!mounted) return;
    state = prefs.getString(kPrefBg) ?? 'blurred';
  }

  Future<void> setStyle(String style) async {
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefBg, style);
  }
}

