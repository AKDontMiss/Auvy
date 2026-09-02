import 'package:flutter/services.dart';

/// Bridge to the Android home-screen player widget.
///
/// Dart → widget: [push] mirrors now-playing state (title/artist/artwork/
/// playing/liked) into the widget. Deduped by signature so the audio
/// handler's per-second broadcast ticks don't cross the platform channel.
///
/// Widget → Dart: the widget's LIKE button calls back over the same channel;
/// [onToggleLike] is wired by AuvyAudioHandler (the engine is alive whenever
/// music plays, which is the only time a like can apply).
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

  static void push({
    required String title,
    required String artist,
    required String imageUrl,
    required bool isPlaying,
    required bool isLiked,
    required bool hasSong,
  }) {
    final sig = '$title|$artist|$imageUrl|$isPlaying|$isLiked|$hasSong';
    if (sig == _lastSig) return;
    _lastSig = sig;
    // .catchError, NOT try/catch. invokeMethod returns a Future, so the
    // failure is ASYNCHRONOUS and a synchronous catch around it never runs —
    // this block looked guarded for as long as it existed while every failure
    // went straight to the unhandled-error handler. Observed live: the app
    // booted in a headless engine with no widget channel and spat
    // "Unhandled Exception: MissingPluginException ... method update" on a loop.
    _channel.invokeMethod('update', {
      'title': title,
      'artist': artist,
      'image': imageUrl,
      'isPlaying': isPlaying,
      'isLiked': isLiked,
      'hasSong': hasSong,
    }).catchError((_) {
      // No channel in this engine (headless boot), or non-Android. The home
      // screen widget simply keeps its last contents — nothing worth crashing
      // an isolate over.
      _lastSig = null; // let the next identical push retry once we're back
      return null;
    });
  }
}
