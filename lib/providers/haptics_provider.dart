import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/services/haptic_service.dart';

/// Settings toggle for haptic feedback. Mirrors its value into
/// [HapticService.enabled] so every call site keeps working without a ref.
class HapticsNotifier extends StateNotifier<bool> {
  HapticsNotifier() : super(HapticService.enabled) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('auvy_haptics_enabled') ?? true;
    HapticService.enabled = enabled;
    state = enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    HapticService.enabled = enabled;
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auvy_haptics_enabled', enabled);
  }
}

final hapticsProvider = StateNotifierProvider<HapticsNotifier, bool>((ref) {
  return HapticsNotifier();
});
