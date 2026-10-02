import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks Android to exempt Auvy from battery optimization. On some devices
/// (e.g. Samsung/One UI "put app to sleep") optimization cuts the network with
/// the screen off, even for a media foreground service, which stalls the next
/// track. Prompts once (tracked in prefs); Settings can ask again.
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
