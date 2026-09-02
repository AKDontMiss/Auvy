import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks Android to exempt Auvy from battery optimization — THE fix for Samsung/
/// One UI "put app to sleep", which overrides even a mediaPlayback foreground
/// service and cuts the network with the screen off (stalling next-track
/// playback until the phone is woken). Prompts ONCE (tracked in prefs); the user
/// can re-trigger it from Settings.
class BatteryOptimizationService {
  static const _channel = MethodChannel('com.auvy.app/cookies');
  static const _askedKey = 'auvy_asked_battery_opt_v1';

  /// Whether Auvy is already exempt from battery optimization.
  static Future<bool> isExempt() async {
    try {
      return (await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations')) ??
          false;
    } catch (_) {
      return true; // unknown → don't nag
    }
  }

  /// One-time prompt on startup when not already exempt.
  static Future<void> maybePromptOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) == true) return;
      if (await isExempt()) {
        await prefs.setBool(_askedKey, true);
        return;
      }
      await prefs.setBool(_askedKey, true);
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Explicit request (from a Settings row / retry banner).
  static Future<void> request() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
