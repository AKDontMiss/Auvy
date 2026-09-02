import 'package:flutter/services.dart';

class HapticService {
  /// Global kill-switch, driven by the Settings toggle (see hapticsProvider).
  /// Loaded from prefs at startup; when false every call below is a no-op.
  static bool enabled = true;

  /// Micro-tap — toggles, icon switches (heart, shuffle, repeat)
  static Future<void> selection() async {
    if (!enabled) return;
    return HapticFeedback.selectionClick();
  }

  /// Soft tap — tab switches, scroll snaps, passive list interactions
  static Future<void> light() async {
    if (!enabled) return;
    return HapticFeedback.lightImpact();
  }

  /// Standard tap — play/pause, skip, confirm, add to queue
  static Future<void> medium() async {
    if (!enabled) return;
    return HapticFeedback.mediumImpact();
  }

  /// Strong tap — download complete, playlist saved, major confirmations
  static Future<void> heavy() async {
    if (!enabled) return;
    return HapticFeedback.heavyImpact(); // was vibrate() — far less harsh
  }

  /// Double-pulse — destructive actions: remove from queue, blacklist song
  static Future<void> warning() async {
    if (!enabled) return;
    await HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.heavyImpact();
  }

  /// Light double-tap — success: download finished, song liked, import done
  static Future<void> success() async {
    if (!enabled) return;
    await HapticFeedback.lightImpact();
    await Future.delayed(const Duration(milliseconds: 70));
    await HapticFeedback.lightImpact();
  }
}
