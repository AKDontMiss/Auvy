import 'package:flutter/material.dart';

/// The app's fixed neutral colours.
///
/// The accent colour is user-chosen and lives in `themeProvider`; everything here
/// is a neutral that must look identical wherever it is used.
class AppColors {
  // Surfaces and backgrounds
  static const Color matteBlack = Color(0xFF181818);
  static const Color navBackground = Color(0xFF121212);

  /// The surface for anything floating above the app: bottom-sheet cards and
  /// dialog panels.
  ///
  /// Kept as one value so every sheet and dialog matches. `dialogTheme` and
  /// `bottomSheetTheme` in main.dart read it from here. Use it directly only for a
  /// sheet that paints its own floating card (a transparent route with a custom
  /// Container); dialogs should not set their own background.
  static const Color modalPanel = Color(0xFF17171C);

  // Faded overlays (withValues rather than the deprecated withOpacity).
  static final Color whiteFaded10 = Colors.white.withValues(alpha: 0.1);
  static final Color whiteFaded08 = Colors.white.withValues(alpha: 0.08);
  static final Color whiteFaded04 = Colors.white.withValues(alpha: 0.04);
}

/// The colour in the library's themed images' names (`liked_songs_purple.webp`
/// and the rest): the preset the accent is, or cyan for any other colour. Shared
/// by the library, the playlist page and Android Auto, so all three match.
String themedArtSuffix(Color accent) {
  final argb = accent.toARGB32();
  if (argb == Colors.purpleAccent.toARGB32()) return 'purple';
  if (argb == Colors.greenAccent.toARGB32()) return 'green';
  if (argb == Colors.orangeAccent.toARGB32()) return 'orange';
  if (argb == Colors.redAccent.toARGB32()) return 'red';
  if (argb == Colors.pinkAccent.toARGB32()) return 'pink';
  return 'cyan';
}
