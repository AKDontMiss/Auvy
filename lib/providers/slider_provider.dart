import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The progress-bar styles the player offers. Saved by name, not index (see
/// [SliderStyleNotifier._load]), so styles can be reordered or removed without
/// switching existing users to a different one. An unknown name falls back to
/// [material].
enum SliderStyle { material, minimal, waveform, segmented, timeline, liquid, comet, elastic, pulse, flow }

class SliderStyleNotifier extends StateNotifier<SliderStyle> {
  SliderStyleNotifier() : super(SliderStyle.material) {
    _load();
  }

  static const String _kName = 'slider_style_name';
  static const String _kLegacyIndex = 'slider_style_index';

  /// The OLD index order, kept solely to migrate saved selections once.
  /// Removed styles map to [SliderStyle.material] — the new default, so someone
  /// who had picked `neon` lands on a real style instead of an out-of-range read.
  static const List<SliderStyle> _legacyOrder = [
    SliderStyle.liquid,     // 0 liquid
    SliderStyle.material,   // 1 neon      → removed
    SliderStyle.waveform,   // 2 waveform
    SliderStyle.material,   // 3 modern    → removed (was the old default)
    SliderStyle.material,   // 4 material
    SliderStyle.segmented,  // 5 segmented
    SliderStyle.material,   // 6 gradient  → removed
    SliderStyle.timeline,   // 7 timeline
  ];

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    final name = prefs.getString(_kName);
    if (name != null) {
      // 'arc' was replaced by 'flow'. Named here rather than left to the
      // orElse below, so someone who had chosen it keeps a deliberate style
      // instead of being silently reset to the default.
      final wanted = name == 'arc' ? 'flow' : name;
      // Started unawaited by the constructor, so the notifier may be disposed by now
      // (a rebuild on sign-in or restore); writing state would throw.
      if (!mounted) return;
      state = SliderStyle.values.firstWhere((s) => s.name == wanted,
          orElse: () => SliderStyle.material);
      if (wanted != name) await prefs.setString(_kName, state.name);
      return;
    }

    // One-time migration from the legacy index; the old key is then removed.
    final legacy = prefs.getInt(_kLegacyIndex);
    if (legacy != null && legacy >= 0 && legacy < _legacyOrder.length) {
      // Started unawaited by the constructor, so the notifier may be disposed by now
      // (a rebuild on sign-in or restore); writing state would throw.
      if (!mounted) return;
      state = _legacyOrder[legacy];
      await prefs.setString(_kName, state.name);
      await prefs.remove(_kLegacyIndex);
    }
  }

  Future<void> setStyle(SliderStyle style) async {
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, style.name);
  }
}

final sliderStyleProvider =
    StateNotifierProvider<SliderStyleNotifier, SliderStyle>((ref) {
  return SliderStyleNotifier();
});
