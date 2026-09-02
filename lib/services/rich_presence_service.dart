import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/logic/session_cookie_manager.dart' show appSecureStorage;

/// Discord Rich Presence — "Listening to Auvy" on the user's profile.
///
/// Publishing an activity on a USER's profile requires a Gateway session
/// authenticated with the account's own client token (the OAuth bearer from
/// the regular Discord login has no gateway access — that's why this has its
/// own WebView sign-in, see PresenceLoginActivity). This is the same mechanism
/// Android Discord-RPC apps (Kizzy et al.) use:
///
///   • wss gateway v10: HELLO → IDENTIFY → presence updates (op 3)
///   • album art through the application's external-assets endpoint
///     (`mp:external/…` keys), cached per URL
///   • presence clears automatically when the socket drops, so a killed app
///     never leaves a stale "Listening to" on the profile
///
/// Connection lifecycle is playback-driven: the socket comes up on the first
/// push while playing, presence clears on pause/stop, and the socket is torn
/// down after ~8 minutes of silence to save battery.
class RichPresenceService {
  RichPresenceService._();
  static final RichPresenceService _instance = RichPresenceService._();
  factory RichPresenceService() => _instance;

  // Same Discord application as the OAuth login (account_provider).
  static const String _appId = '1454840399909883988';
  static const String _tokenKey = 'auvy_discord_rpc_token';
  static const String _enabledKey = 'auvy_discord_rpc_enabled';
  // MainActivity registers openPresenceLogin on the cookie channel.
  static const MethodChannel _channel = MethodChannel('com.auvy.app/cookies');

  String? _token;
  bool _enabled = false;
  bool _loaded = false;
  // Set on a 4004 close (bad token) — stops reconnect storms until the user
  // re-links the account.
  bool _authFailed = false;

  WebSocket? _ws;
  bool _ready = false;
  Timer? _heartbeat;
  int? _seq;
  Timer? _idleDisconnect;
  DateTime? _lastConnectAttempt;
  Future<void>? _connecting;

  // Last published activity, for dedupe (pushes arrive ~1×/sec while playing).
  String? _lastSongId;
  bool _lastShowing = false;
  int _lastStartMs = 0;
  int _pushGen = 0; // latest-wins guard across the async gaps below

  // imageUrl → "mp:external/…" (Discord re-serves the art from its CDN).
  final Map<String, String> _assetCache = {};
  Map<String, dynamic>? _pendingPresence; // queued until READY

  bool get isEnabled => _enabled;
  bool get hasAccount => _token != null && _token!.isNotEmpty;

  // One-shot diagnostic guard so the per-tick push gate doesn't spam logcat.
  bool _diagGateLogged = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? false;
      _token = await appSecureStorage.read(key: _tokenKey);
    } catch (e) {
      print('WARN: Discord RPC state load failed: $e');
    }
    print('Discord loaded: enabled=$_enabled '
        'hasToken=${_token != null && _token!.isNotEmpty}');
  }

  /// Opens the Discord sign-in WebView, stores the captured token and enables
  /// presence. Returns true on success.
  Future<bool> connectAccount() async {
    await ensureLoaded();
    try {
      final token = await _channel.invokeMethod<String>('openPresenceLogin');
      if (token == null || token.isEmpty) return false;
      _token = token;
      _authFailed = false;
      await appSecureStorage.write(key: _tokenKey, value: token);
      await setEnabled(true);
      return true;
    } catch (e) {
      print('ERROR: Discord RPC connect failed: $e');
      return false;
    }
  }

  Future<void> setEnabled(bool value) async {
    await ensureLoaded();
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {}
    if (!value) {
      await _teardown(clearPresenceFirst: true);
    }
  }

  /// Forget the account entirely (token + presence + socket).
  Future<void> disconnectAccount() async {
    await ensureLoaded();
    await _teardown(clearPresenceFirst: true);
    _token = null;
    _enabled = false;
    _assetCache.clear();
    try {
      await appSecureStorage.delete(key: _tokenKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, false);
    } catch (_) {}
  }

  /// Mirror the player state onto the profile. Cheap and self-deduping — wired
  /// to the audio handler's broadcast, so it's called on every state tick.
  void push({
    required String? songId,
    required String title,
    required String artist,
    required String album,
    required String imageUrl,
    required bool isPlaying,
    required int positionMs,
    required int durationMs,
  }) {
    if (!_loaded) {
      // First call of the session — load prefs, the next tick applies them.
      unawaited(ensureLoaded());
      return;
    }
    if (!_enabled || !hasAccount || _authFailed) {
      if (!_diagGateLogged) {
        _diagGateLogged = true;
        print('Discord push gated: enabled=$_enabled '
            'hasAccount=$hasAccount authFailed=$_authFailed');
      }
      return;
    }

    // Live radio URLs / nothing loaded → nothing sensible to show.
    final bool showable =
        isPlaying && songId != null && !songId.startsWith('http') && title.isNotEmpty;

    if (!showable) {
      if (_lastShowing) {
        _lastShowing = false;
        _lastSongId = null;
        _pushGen++;
        unawaited(_clearPresence());
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final startMs = now - positionMs;
    // Same track, still playing, clock within a few seconds of what Discord is
    // already extrapolating → nothing to send. A seek shifts startMs beyond
    // the window and re-pushes with corrected timestamps.
    if (_lastShowing &&
        songId == _lastSongId &&
        (startMs - _lastStartMs).abs() < 7500) {
      return;
    }

    _lastShowing = true;
    _lastSongId = songId;
    _lastStartMs = startMs;
    _idleDisconnect?.cancel();

    final gen = ++_pushGen;
    unawaited(_publish(
      gen: gen,
      title: title,
      artist: artist,
      album: album,
      imageUrl: imageUrl,
      startMs: startMs,
      endMs: durationMs > 0 ? startMs + durationMs : null,
    ));
  }

  Future<void> _publish({
    required int gen,
    required String title,
    required String artist,
    required String album,
    required String imageUrl,
    required int startMs,
    int? endMs,
  }) async {
    try {
      print('Discord publishing "Listening to Auvy": $title — $artist');
      await _ensureConnected();
      if (gen != _pushGen) return; // superseded while connecting

      String? asset;
      if (imageUrl.startsWith('http')) {
        asset = await _externalAsset(imageUrl);
        if (gen != _pushGen) return;
      }

      final activity = <String, dynamic>{
        'application_id': _appId,
        'name': 'Auvy',
        // Type 0 ("Playing Auvy") renders far more reliably for presence set via
        // a user-account gateway token than type 2 ("Listening"), which several
        // Discord clients silently drop for non-bot sessions. Rich details/state
        // (song / artist) still show underneath.
        'type': 0,
        'details': title,
        if (artist.isNotEmpty) 'state': artist,
        'assets': {
          if (asset != null) 'large_image': asset,
          if (album.isNotEmpty && album != 'null') 'large_text': album,
        },
        'timestamps': {
          'start': startMs,
          if (endMs != null) 'end': endMs,
        },
      };
      _sendPresence([activity]);
    } catch (e) {
      print('WARN: Discord RPC publish failed: $e');
    }
  }

  Future<void> _clearPresence() async {
    try {
      if (_ws == null) return; // nothing shown anywhere
      _sendPresence(const []);
      // Keep the session briefly for a quick resume, then let it go.
      _idleDisconnect?.cancel();
      _idleDisconnect = Timer(const Duration(minutes: 8), () {
        _teardown(clearPresenceFirst: false);
      });
    } catch (_) {}
  }

  void _sendPresence(List<dynamic> activities) {
    final payload = {
      'op': 3,
      'd': {
        'since': null,
        'activities': activities,
        'status': 'online',
        'afk': false,
      },
    };
    final ws = _ws;
    if (ws == null || !_ready) {
      _pendingPresence = payload; // flushed on READY
      return;
    }
    ws.add(jsonEncode(payload));
  }

  // Gateway plumbing

  Future<void> _ensureConnected() {
    if (_ws != null) return _connecting ?? Future.value();
    final inFlight = _connecting;
    if (inFlight != null) return inFlight;

    // Backoff: never hammer the gateway more than once per 15s.
    final last = _lastConnectAttempt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 15)) {
      return Future.value();
    }
    _lastConnectAttempt = DateTime.now();

    final future = _connectInner().whenComplete(() => _connecting = null);
    _connecting = future;
    return future;
  }

  Future<void> _connectInner() async {
    final token = _token;
    if (token == null) return;
    print('Discord gateway connecting…');
    try {
      final ws = await WebSocket.connect(
        'wss://gateway.discord.gg/?v=10&encoding=json',
      ).timeout(const Duration(seconds: 12));
      _ws = ws;
      _ready = false;

      ws.listen((raw) {
        try {
          _onGatewayMessage(ws, jsonDecode(raw as String) as Map<String, dynamic>);
        } catch (_) {}
      }, onDone: () {
        final code = ws.closeCode;
        print('Discord gateway closed (code $code)'
            '${code == 4004 ? " — BAD TOKEN, stopping" : ""}');
        if (code == 4004) {
          // Authentication failed — the token is dead; stop until re-linked.
          _authFailed = true;
        }
        _cleanupSocket(ws);
      }, onError: (_) {
        _cleanupSocket(ws);
      }, cancelOnError: true);
    } catch (e) {
      print('ERROR: Discord gateway connect failed: $e');
      _ws = null;
    }
  }

  void _onGatewayMessage(WebSocket ws, Map<String, dynamic> msg) {
    final op = msg['op'] as int?;
    if (msg['s'] != null) _seq = msg['s'] as int?;

    switch (op) {
      case 10: // HELLO
        final interval = (msg['d']?['heartbeat_interval'] as num?)?.toInt() ?? 41250;
        _heartbeat?.cancel();
        _heartbeat = Timer.periodic(Duration(milliseconds: interval), (_) {
          try {
            ws.add(jsonEncode({'op': 1, 'd': _seq}));
          } catch (_) {}
        });
        ws.add(jsonEncode({
          'op': 2,
          'd': {
            'token': _token,
            'properties': {'os': 'Android', 'browser': 'Discord Android', 'device': 'Auvy'},
            'compress': false,
            'large_threshold': 50,
          },
        }));
        break;
      case 1: // gateway asks for an immediate heartbeat
        try {
          ws.add(jsonEncode({'op': 1, 'd': _seq}));
        } catch (_) {}
        break;
      case 9: // invalid session — drop; the next push reconnects fresh
        _cleanupSocket(ws);
        break;
      case 0:
        if (msg['t'] == 'READY') {
          _ready = true;
          print('Discord gateway READY — presence live');
          final pending = _pendingPresence;
          _pendingPresence = null;
          if (pending != null) {
            try {
              ws.add(jsonEncode(pending));
            } catch (_) {}
          }
        }
        break;
    }
  }

  void _cleanupSocket(WebSocket ws) {
    if (_ws != ws) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _ws = null;
    _ready = false;
    // Force the next push to republish the full activity after a reconnect
    // (Discord dropped it with the session).
    _lastShowing = false;
    _lastSongId = null;
  }

  Future<void> _teardown({required bool clearPresenceFirst}) async {
    _idleDisconnect?.cancel();
    _idleDisconnect = null;
    final ws = _ws;
    if (ws != null) {
      if (clearPresenceFirst && _ready) {
        try {
          _sendPresence(const []);
          // Give the frame a moment to flush before closing.
          await Future.delayed(const Duration(milliseconds: 250));
        } catch (_) {}
      }
      try {
        await ws.close();
      } catch (_) {}
      _cleanupSocket(ws);
    }
    _pendingPresence = null;
    _lastShowing = false;
    _lastSongId = null;
  }

  /// Register the album art with Discord's media proxy so it can render on the
  /// profile ("mp:external/…"). Cached per URL; failures just mean no artwork.
  Future<String?> _externalAsset(String imageUrl) async {
    final cached = _assetCache[imageUrl];
    if (cached != null) return cached;
    final token = _token;
    if (token == null) return null;
    try {
      final resp = await http
          .post(
            Uri.parse('https://discord.com/api/v9/applications/$_appId/external-assets'),
            headers: {'Authorization': token, 'Content-Type': 'application/json'},
            body: jsonEncode({'urls': [imageUrl]}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List<dynamic>;
        final path = list.isNotEmpty
            ? (list.first as Map<String, dynamic>)['external_asset_path'] as String?
            : null;
        if (path != null && path.isNotEmpty) {
          if (_assetCache.length > 100) _assetCache.clear();
          final value = 'mp:$path';
          _assetCache[imageUrl] = value;
          return value;
        }
      } else {
        print('WARN: Discord external-asset ${resp.statusCode}');
      }
    } catch (e) {
      print('WARN: Discord external-asset failed: $e');
    }
    return null;
  }
}
