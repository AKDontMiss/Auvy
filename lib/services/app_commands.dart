import 'package:flutter/services.dart';

/// Commands from outside Auvy's screens, over one channel on both platforms.
///
/// What sends them:
///   iPhone   Siri and the Shortcuts app (App Intents), the home-screen and
///            lock-screen widgets, the Control Center button, the icon's
///            long-press menu, `auvy://` links.
///   Android  the icon's long-press menu and pinned playlist shortcuts, the
///            Quick Settings tile, Android's voice search, links shared or opened
///            into Auvy.
///
/// Each is a name and arguments. Native keeps any that arrive before Dart is
/// listening (a cold start from a shortcut) and hands them over on
/// [attachPlayback]. Playback commands run as soon as the audio handler is up;
/// the ones that need a screen ([_screenCommands]) wait for [attachScreen].
///
/// The handler's answer goes back to the sender: Siri speaks it ("Playing Liked
/// Songs", "Your Top 50 is empty").
class AppCommands {
  AppCommands._();

  static const MethodChannel _channel = MethodChannel('com.auvy.app/commands');

  /// Commands that open something on screen. Every other command is playback.
  static const _screenCommands = {'openLink', 'openSearch', 'openNowPlaying'};

  static Future<String?> Function(String name, Map<String, dynamic> args)? _playback;
  static Future<String?> Function(String name, Map<String, dynamic> args)? _screen;
  static final List<(String, Map<String, dynamic>)> _waitingForScreen = [];
  static bool _listening = false;

  /// Called by the audio handler once it can play. Takes any commands that
  /// arrived during startup.
  static Future<void> attachPlayback(
      Future<String?> Function(String name, Map<String, dynamic> args) handler) async {
    _playback = handler;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onCall);
    }
    try {
      final pending = await _channel.invokeMethod<List<dynamic>>('ready') ?? const [];
      for (final raw in pending) {
        if (raw is! Map) continue;
        await _dispatch((raw['command'] ?? '').toString(), _args(raw['args']));
      }
    } on MissingPluginException {
      // A headless engine (Android's media-button or widget boot) has no
      // command channel; nothing can be waiting in it.
    } catch (e) {
      print('command: could not take pending commands: $e');
    }
  }

  /// Called by the main layout once there is a screen to open things on.
  static void attachScreen(
      Future<String?> Function(String name, Map<String, dynamic> args) handler) {
    _screen = handler;
    final waiting = List.of(_waitingForScreen);
    _waitingForScreen.clear();
    for (final (name, args) in waiting) {
      handler(name, args);
    }
  }

  static void detachScreen(Future<String?> Function(String, Map<String, dynamic>) handler) {
    if (identical(_screen, handler)) _screen = null;
  }

  /// Runs a command from inside the app (a pasted link in Search, say), through
  /// the same path as one from outside.
  static Future<String?> run(String name, [Map<String, dynamic> args = const {}]) =>
      _dispatch(name, args);

  /// The user's playlist names, for Siri's playlist picker and the long-press
  /// menu. Native keeps the last list, so Siri can offer them with Auvy closed.
  static void publishPlaylists(List<String> names) {
    _channel.invokeMethod('setPlaylists', {'names': names}).catchError((_) => null);
  }

  /// Android: puts a shortcut on the home screen that plays [name]. False when
  /// the launcher can't pin shortcuts.
  static Future<bool> pinPlaylist(String name, {String image = ''}) async {
    try {
      return await _channel.invokeMethod<bool>('pinPlaylist', {'name': name, 'image': image}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Whether a web link sits on the clipboard, asked without reading it (no
  /// paste prompt on iPhone, no "pasted" notice on Android). [changeCount]
  /// identifies the copy, so the same one isn't offered twice. Null when the
  /// platform can't say.
  static Future<({int changeCount, bool hasUrl})?> clipboardHint() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('clipboardHint');
      if (raw == null) return null;
      return (
        changeCount: (raw['changeCount'] as num?)?.toInt() ?? 0,
        hasUrl: raw['hasURL'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Android: opens Auvy's "Open by default" settings, where music links can be
  /// allowed to open in Auvy. False where there is no such screen (iPhone).
  static Future<bool> openLinkSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openLinkSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'run') return null;
    final raw = call.arguments;
    if (raw is! Map) return null;
    return _dispatch((raw['command'] ?? '').toString(), _args(raw['args']));
  }

  static Map<String, dynamic> _args(Object? raw) =>
      raw is Map ? raw.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

  static Future<String?> _dispatch(String name, Map<String, dynamic> args) async {
    if (name.isEmpty) return null;
    // Where it came from and what, never the arguments themselves: a link or a
    // search is listening history.
    print('command: $name from ${args['from'] ?? 'unknown'}'
        '${args['held'] == true ? ' (held until start-up)' : ''}');
    try {
      // A link from Siri plays in the background; one shared into the app opens
      // the sheet.
      if (_screenCommands.contains(name) && args['background'] != true) {
        final screen = _screen;
        if (screen == null) {
          _waitingForScreen.add((name, args));
          return null;
        }
        return await screen(name, args);
      }
      final playback = _playback;
      if (playback == null) {
        print('command: $name arrived before the player was ready');
        return null;
      }
      return await playback(name, args);
    } catch (e) {
      print('ERROR: command $name failed: $e');
      return "Auvy couldn't do that right now.";
    }
  }
}
