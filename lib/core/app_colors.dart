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
