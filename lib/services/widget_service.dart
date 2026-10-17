import 'package:flutter/services.dart';

/// Bridge to the home-screen player widgets: Android's, and on iPhone the
/// home-screen, lock-screen and Control Center ones (written to the App Group
/// they share with the app; see AuvyWidgetState.swift).
///
/// Dart → widget: [push] mirrors now-playing state (title/artist/artwork/
/// playing/liked, and the accent colour the widget is drawn in). Deduped by
/// signature so the audio handler's per-second broadcast ticks don't cross the
/// platform channel.
///
/// Widget → Dart: Android's LIKE button calls back over the same channel;
/// [onToggleLike] is wired by AuvyAudioHandler (the engine is alive whenever
/// music plays, which is the only time a like can apply). The iPhone widget's
/// buttons arrive as commands instead (see AppCommands).
class WidgetService {
  WidgetService._();

  static const MethodChannel _channel = MethodChannel('com.auvy.app/widget');
  static String? _lastSig;
  static bool _configured = false;

  /// Called when the widget's like button is tapped.
  static void Function()? onToggleLike;

  static void configure() {
    if (_configured) return;
    _configured = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'toggleLike') onToggleLike?.call();
      return null;
    });
  }

  /// Where playback was anchored at the last push: the wall-clock time the
  /// song would have started, given its position. Progress is drawn by the
  /// widgets themselves from this (iOS animates it, Android's clock ticks), so
  /// the per-second position updates never need to cross the channel; only a
  /// seek, a pause or a new song does.
  static int? _lastAnchorMs;
  static bool? _lastPlaying;

  static void push({
    required String title,
    required String artist,
    required String imageUrl,
    required bool isPlaying,
    required bool isLiked,
    required bool hasSong,
    int? accent,
    String context = '',
    int positionMs = 0,
    int durationMs = 0,
    List<String> upNext = const [],
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final anchor = now - positionMs;
    // While playing the anchor holds still, so a jump of more than two seconds
    // is a seek. While paused the anchor drifts and the position is what holds.
    final moved = _lastPlaying != isPlaying ||
        _lastAnchorMs == null ||
        (isPlaying ? (anchor - _lastAnchorMs!).abs() > 2000 : false);
    final sig = '$title|$artist|$imageUrl|$isPlaying|$isLiked|$hasSong|$accent|'
        '$context|$durationMs|${upNext.join('|')}|${isPlaying ? '' : positionMs ~/ 2000}';
    if (sig == _lastSig && !moved) return;
    _lastSig = sig;
    _lastAnchorMs = anchor;
    _lastPlaying = isPlaying;
    // .catchError, not try/catch: invokeMethod fails asynchronously, so a
    // synchronous catch never runs. In a headless engine there is no widget
    // channel, and this would otherwise throw MissingPluginException on every
    // update.
    _channel.invokeMethod('update', {
      'title': title,
      'artist': artist,
      'image': imageUrl,
      'isPlaying': isPlaying,
      'isLiked': isLiked,
      'hasSong': hasSong,
      if (accent != null) 'accent': accent,
      'context': context,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'sampledAtMs': now,
      'upNext': upNext,
    }).catchError((_) {
      // No channel in this engine (headless boot). The home screen widget
      // simply keeps its last contents — nothing worth crashing an isolate over.
      _lastSig = null; // let the next identical push retry once we're back
      return null;
    });
  }
}
