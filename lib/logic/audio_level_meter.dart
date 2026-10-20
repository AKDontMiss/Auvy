import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/providers/player_provider.dart' show audioIntensityProvider;

/// Feeds [audioIntensityProvider], the 0..1 value the player cover's glow
/// follows ("With the music" and "Bright" in Appearance). Nothing used to set
/// it, so the glow never moved.
///
/// The native players measure the music as it plays (iOS: the audio tap; Android:
/// a pass-through processor in the player's audio chain). This reads that level
/// about 20 times a second, only while something on screen wants it
/// ([acquire]/[release]) and the app is in front, and smooths it into a light
/// that rises with each beat and falls back gently. The glow draws exactly
/// this value, with no animation of its own, so it costs at most one frame per
/// reading and none once the music has gone quiet.
class AudioLevelMeter with WidgetsBindingObserver {
  AudioLevelMeter._();
  static final AudioLevelMeter instance = AudioLevelMeter._();

  static const Duration tick = Duration(milliseconds: 50);

  int _users = 0;
  Timer? _timer;

  /// Told each raw reading (the RMS the native player measured), for anything
  /// that wants the music's loudness itself rather than the glow's smoothed
  /// value: the waveform slider fills in the shape of a song with no file yet
  /// from these.
  /// Readings arrive only while someone holds the meter ([acquire]).
  final List<void Function(double rms)> _readingListeners = [];
  void addReadingListener(void Function(double rms) listener) => _readingListeners.add(listener);
  void removeReadingListener(void Function(double rms) listener) => _readingListeners.remove(listener);
  bool _observing = false;
  bool _metering = false;
  bool _polling = false;
  double _value = 0;
  double _floor = 0.02;

  void acquire() {
    _users++;
    if (_users == 1) {
      if (!_observing) {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      }
      _start();
    }
  }

  void release() {
    if (_users == 0) return;
    _users--;
    if (_users == 0) {
      _stop();
      if (_observing) {
        WidgetsBinding.instance.removeObserver(this);
        _observing = false;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // In the background nothing shows the glow: no polling, no native metering.
    if (_users == 0) return;
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _stop();
    }
  }

  void _start() {
    if (_timer != null) return;
    if (!_metering) {
      _metering = true;
      unawaited(NativeAudioEngine.setMetering(true));
    }
    _timer = Timer.periodic(tick, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (_metering) {
      _metering = false;
      unawaited(NativeAudioEngine.setMetering(false));
    }
    _value = 0;
    audioIntensityProvider.value = 0;
  }

  Future<void> _poll() async {
    if (_polling) return; // a slow reply never stacks calls up
    _polling = true;
    try {
      final rms = await NativeAudioEngine.getLevel();
      if (_timer == null) return;
      for (final listener in List.of(_readingListeners)) {
        listener(rms);
      }
      _value = settle(smooth(_value, intensityFor(rms, _floor)));
      // Each change the glow is told about is a frame, and on Android a frame
      // renders the whole player page. A step too small to see is skipped.
      if (worthShowing(audioIntensityProvider.value, _value)) {
        audioIntensityProvider.value = _value;
      }
      // A slowly learned floor, so a quiet track still pulses rather than
      // sitting dark: it follows the quiet parts down quickly and up slowly.
      if (rms > 0) _floor = rms < _floor ? _floor * 0.9 + rms * 0.1 : _floor * 0.999 + rms * 0.001;
    } finally {
      _polling = false;
    }
  }

  /// RMS → 0..1 on a decibel scale: about -40 dB (quiet) to -8 dB (loud
  /// master), relative to the track's own quiet floor so dynamics show.
  @visibleForTesting
  static double intensityFor(double rms, [double floor = 0.02]) {
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10;
    final floorDb = 20 * math.log(floor.clamp(0.001, 0.2)) / math.ln10;
    final lo = math.max(-40.0, floorDb - 3);
    const hi = -8.0;
    final x = ((db - lo) / (hi - lo)).clamp(0.0, 1.0);
    return x * x; // beats stand out; the quiet bed stays low
  }

  /// Fast rise, gentle fall.
  @visibleForTesting
  static double smooth(double current, double target) =>
      target > current ? current + (target - current) * 0.6 : current + (target - current) * 0.18;

  /// The gentle fall approaches zero without reaching it, which would keep the
  /// glow redrawing for minutes after the music stops. Below this it is dark.
  @visibleForTesting
  static double settle(double v) => v < 0.003 ? 0 : v;

  /// Whether [next] differs enough from what the glow [shown] to be seen: a
  /// change of 0.004 moves the glow's alpha by about half a step in 255 and
  /// its blur by a sixth of a pixel. Going dark always shows.
  @visibleForTesting
  static bool worthShowing(double shown, double next) =>
      next == 0 ? shown != 0 : (next - shown).abs() >= 0.004;
}
