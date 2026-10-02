import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class HapticService {
  /// Global kill-switch, driven by the Settings toggle (see hapticsProvider).
  /// Loaded from prefs at startup; when false every call below is a no-op.
  static bool enabled = true;

  static const MethodChannel _nativeChannel =
      MethodChannel('com.auvy.app/haptics');

  static Future<void> _trigger(String type) async {
    if (!enabled) return;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('vibrate', {'type': type});
        return;
      } catch (_) {}
    }

    // Standard Flutter HapticFeedback fallback
    switch (type) {
      case 'selection':
        await HapticFeedback.selectionClick();
        break;
      case 'light':
        await HapticFeedback.lightImpact();
        break;
      case 'medium':
        await HapticFeedback.mediumImpact();
        break;
      case 'heavy':
        await HapticFeedback.heavyImpact();
        break;
      default:
        await HapticFeedback.lightImpact();
        break;
    }
  }

  /// Micro-tap — toggles, icon switches (heart, shuffle, repeat)
  static Future<void> selection() async {
    return _trigger('selection');
  }

  /// Soft tap — tab switches, scroll snaps, passive list interactions
  static Future<void> light() async {
    return _trigger('light');
  }

  /// Standard tap — play/pause, skip, confirm, add to queue
  static Future<void> medium() async {
    return _trigger('medium');
  }

  /// Strong tap — download complete, playlist saved, major confirmations
  static Future<void> heavy() async {
    return _trigger('heavy');
  }

  /// Double-pulse — destructive actions: remove from queue, blacklist song
  static Future<void> warning() async {
    if (!enabled) return;
    await _trigger('medium');
    await Future.delayed(const Duration(milliseconds: 90));
    await _trigger('heavy');
  }

  /// Light double-tap — success: download finished, song liked, import done
  static Future<void> success() async {
    if (!enabled) return;
    await _trigger('light');
    await Future.delayed(const Duration(milliseconds: 70));
    await _trigger('light');
  }
}
