import 'package:flutter/services.dart';

/// The Dart side of the native (media3/ExoPlayer) player.
///
/// Auvy does NOT play audio through a Flutter plugin. Playback lives in Kotlin
/// so it survives Doze, and this class is the whole conversation with it: one
/// MethodChannel out, a set of static callbacks back in.
///
/// Two things make this file unusual, AND both are load-bearing.
///
/// 1. [_streamResolver] is a call INWARD. The native ResolvingDataSource asks
///    Dart for a fresh stream URL when it needs bytes and has none valid —
///    expiry, a 403, or an IP change, and blocks its loader thread until Dart
///    answers. So that callback must stay cheap and must never deadlock by
///    calling back into native synchronously.
/// 2. Everything is STATIC. audio_service can boot this app in a HEADLESS
///    Flutter engine (a Bluetooth connect, a headset button, Android Auto, a
///    media-resumption probe) where MainActivity never ran and these channels
///    were never registered. See the note on the unreachable flag below for the
///    runaway that caused.

class NativeAudioEngine {
  static const MethodChannel _channel = MethodChannel('com.auvy.app/native_player');

  static void Function(bool? playWhenReady)? _onError;
  static void Function(Duration position, Duration duration, bool isPlaying)? _onPosition;
  static void Function()? _onTrackEnded;
  static void Function(bool isPlaying)? _onIsPlayingChanged;
  static void Function(bool buffering)? _onBuffering;
  // GAPLESS: native fired an AUTO transition to the pre-buffered upcoming item.
  static void Function(String videoId)? _onNativeAutoAdvance;
  // Media volume reached zero. See the "pause when muted" setting.
  static void Function()? _onVolumeMuted;
  // Native → Dart LAZY stream resolver. The native ResolvingDataSource calls
  // this (blocking on its loader thread) to get a FRESH stream URL for a
  // videoId whenever it must fetch bytes and has no valid cached URL (expiry /
  // 403 / IP-change). Returns {url, userAgent, contentLength} or null.
  static Future<Map<String, dynamic>?> Function(String videoId,
      {int expectContentLength})? _streamResolver;
  static bool _handlerInstalled = false;

  /// Set once the native side proves unreachable, and never cleared.
  ///
  /// THIS IS NOT DEFENSIVE PADDING — it is the fix for a real runaway.
  /// audio_service boots this app in a HEADLESS Flutter engine whenever the
  /// service is started with no Activity: a Bluetooth connect, a headset
  /// button, Android Auto, or SystemUI's media-resumption probe. That engine is
  /// built with `new FlutterEngine(applicationContext)` and only receives pub
  /// plugins via GeneratedPluginRegistrant, so the channels MainActivity
  /// registers BY HAND (native_player, widget) do not exist in it at all.
  ///
  /// Every call below then threw MissingPluginException. Most are called
  /// fire-and-forget, so the throws surfaced as UNHANDLED async errors that no
  /// caller could see, the player never learned playback was impossible, and it
  /// retried the whole track-start sequence every few seconds — forever. One
  /// observed session: 875 foreground-service restarts, 9m33s of CPU on the
  /// main thread, ~2400 leaked executor threads, and memory climbing while
  /// nothing played. Latching on the FIRST failure is what makes that
  /// impossible: after it, every call is a cheap no-op.
  static bool _platformGone = false;

  /// False once the native player is known to be unreachable in this engine.
  static bool get platformAvailable => !_platformGone;

  /// Fired ONCE, the moment the native side is first found missing, so the
  /// player can shut the session down instead of retrying into a void.
  static void Function()? onPlatformLost;

  /// Clear the latch because an Activity has attached and re-registered the
  /// hand-rolled channels on THIS engine.
  ///
  /// This is the escape hatch for a shared engine, AND it is NOT optional.
  ///
  /// MainActivity extends audio_service's AudioServiceActivity, which hands the
  /// Activity the engine audio_service already cached rather than building a new
  /// one. So one engine can be headless first and have a screen later:
  ///
  ///   1. app swiped away, process dies
  ///   2. headset connects -> audio_service starts a HEADLESS engine, runs main()
  ///   3. no native_player channel yet -> this latches, main() skips the app
  ///   4. user opens Auvy -> MainActivity attaches to THAT SAME ENGINE and
  ///      registers native_player for real
  ///
  /// Without a reset, step 4 leaves the app permanently mute and blank: the
  /// channel exists, but every call still short-circuits on the latch from step
  /// 3. Called from the platform side on attach. See MainActivity
  /// .configureFlutterEngine and the `auvy/engine_lifecycle` channel.
  static void onActivityAttached() {
    if (!_platformGone) return;
    _platformGone = false;
    _handlerInstalled = false;
    _installHandler();
  }

  /// Every native call goes through here.
  ///
  /// Returns null instead of throwing: these are control commands, and a player
  /// that cannot set its volume must not take the whole isolate down with an
  /// unhandled error. Callers that need to know ask [platformAvailable].
  static Future<T?> _call<T>(String method, [dynamic args]) async {
    if (_platformGone) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Latch, so the retry storm described above cannot happen.
      //
      // THE LATCH IS NOT PERMANENT ANY MORE. See [onActivityAttached].
      // This used to say "a handler that was never registered on this engine
      // cannot appear later, so retrying is pure waste". That is false for THIS
      // app, and the false premise cost a black screen: MainActivity extends
      // AudioServiceActivity, which reuses audio_service's cached engine, so the
      // channels MainActivity registers by hand DO appear later — the moment an
      // Activity attaches to the engine that started out headless.
      if (!_platformGone) {
        _platformGone = true;
        onPlatformLost?.call();
      }
      return null;
    } catch (_) {
      // A real native-side failure (bad args, player not ready). Transient, so
      // do NOT latch — just swallow it the way these calls always did.
      return null;
    }
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlayerError':
          // playWhenReady = the user's play/pause INTENT at the moment of the
          // error (survives the error, unlike isPlaying which already went
          // false at the buffer underrun). Null from older native builds.
          final e = (call.arguments as Map?) ?? const {};
          _onError?.call(e['playWhenReady'] as bool?);
          break;
        case 'onPosition':
          final a = (call.arguments as Map?) ?? const {};
          _onPosition?.call(
            Duration(milliseconds: (a['positionMs'] as num?)?.toInt() ?? 0),
            Duration(milliseconds: (a['durationMs'] as num?)?.toInt() ?? 0),
            a['isPlaying'] as bool? ?? false,
          );
          break;
        case 'onTrackEnded':
          _onTrackEnded?.call();
          break;
        case 'onIsPlayingChanged':
          final a = (call.arguments as Map?) ?? const {};
          _onIsPlayingChanged?.call(a['isPlaying'] as bool? ?? false);
          break;
        // Media volume just hit ZERO (native ContentObserver). Only the
        // transition to 0 is reported, never repeats while already muted.
        case 'onVolumeMuted':
          _onVolumeMuted?.call();
          break;
        case 'onNativeAutoAdvance':
          final a = (call.arguments as Map?) ?? const {};
          _onNativeAutoAdvance?.call((a['videoId'] as String?) ?? '');
          break;
        // ExoPlayer entered or left BUFFERING. Raw signal: every track start
        // buffers briefly, so the LISTENER decides whether a stall has lasted
        // long enough to be worth telling the user about.
        case 'onBuffering':
          final a = (call.arguments as Map?) ?? const {};
          _onBuffering?.call(a['buffering'] as bool? ?? false);
          break;
        case 'resolveStream':
          // Native asks for a fresh stream URL (lazy resolution / re-resolve).
          final a = (call.arguments as Map?) ?? const {};
          final vid = (a['videoId'] as String?) ?? '';
          final resolver = _streamResolver;
          if (resolver == null || vid.isEmpty) return null;
          // Non-zero = a MID-TRACK re-resolve, and the value is the contentLength
          // of the format already playing. The resolver must return that same
          // format: a different one is a different file, and the byte offset the
          // player is about to ask for would be meaningless in it.
          final expect = (a['expectContentLength'] as num?)?.toInt() ?? 0;
          return await resolver(vid, expectContentLength: expect);
      }
      return null;
    });
  }

  /// Register the lazy stream resolver the native ResolvingDataSource calls to
  /// (re)resolve a videoId's stream URL on demand.
  static void setStreamResolver(
      Future<Map<String, dynamic>?> Function(String videoId,
              {int expectContentLength})
          resolver) {
    _streamResolver = resolver;
    _installHandler();
  }

  /// Register playback-feedback callbacks. Only the non-null ones are updated,
  /// so callers can set just what they need. The native ExoPlayer pushes
  /// [onPosition] ~twice a second (real position + duration + isPlaying),
  /// [onTrackEnded] when a track finishes, and [onIsPlayingChanged] on
  /// play/pause — this is what keeps the UI clock in sync.
  static void setListeners({
    void Function(bool? playWhenReady)? onError,
    void Function(Duration position, Duration duration, bool isPlaying)? onPosition,
    void Function()? onTrackEnded,
    void Function(bool isPlaying)? onIsPlayingChanged,
    void Function(String videoId)? onNativeAutoAdvance,
    void Function()? onVolumeMuted,
    void Function(bool buffering)? onBuffering,
  }) {
    if (onError != null) _onError = onError;
    if (onPosition != null) _onPosition = onPosition;
    if (onTrackEnded != null) _onTrackEnded = onTrackEnded;
    if (onIsPlayingChanged != null) _onIsPlayingChanged = onIsPlayingChanged;
    if (onNativeAutoAdvance != null) _onNativeAutoAdvance = onNativeAutoAdvance;
    if (onBuffering != null) _onBuffering = onBuffering;
    if (onVolumeMuted != null) _onVolumeMuted = onVolumeMuted;
    _installHandler();
  }

  /// Back-compat: register only the fatal-error self-heal callback.
  static void setErrorListener(void Function() callback) {
    setListeners(onError: (_) => callback());
  }

  // Pass the resolved URL, the user-agent of the client that produced it, and
  // the content length. The native side needs the UA (googlevideo 403s on a
  // mismatch) and the length (to bound the Range request — open-ended 403s).
  static Future<void> playTrack(
    String videoId,
    String streamUrl, {
    String? userAgent,
    int? contentLength,
    bool autoPlay = true,
    String? localPath,
  }) async {
    await _call<void>('playVideo', {
      'videoId': videoId,
      'url': streamUrl,
      'autoPlay': autoPlay,
      if (userAgent != null && userAgent.isNotEmpty) 'userAgent': userAgent,
      if (contentLength != null && contentLength > 0) 'contentLength': contentLength,
      // When set, the native engine plays this fully-downloaded local file
      // directly (instant, no stalls, instant seek) and ignores the stream URL.
      if (localPath != null && localPath.isNotEmpty) 'localPath': localPath,
    });
  }

  /// Pre-warm the NEXT track: seed its URL + pull its first ~1 MB into the play
  /// cache so the transition to it starts instantly from cache. YouTube ids only.
  static Future<void> prewarmNext(String videoId, String url,
      {String? userAgent, int? contentLength}) async {
    if (videoId.isEmpty || url.isEmpty || videoId.startsWith('http')) return;
    try {
      await _call<void>('prewarmNext', {
        'videoId': videoId,
        'url': url,
        if (userAgent != null && userAgent.isNotEmpty) 'userAgent': userAgent,
        if (contentLength != null && contentLength > 0) 'contentLength': contentLength,
      });
    } catch (_) {}
  }

  /// GAPLESS: queue the (already audio-conformed) NEXT track natively so
  /// ExoPlayer pre-buffers it and transitions to it with ZERO gap. Only used
  /// when the gapless setting is on; otherwise [prewarmNext] is used. YouTube
  /// ids only. Native de-dups if this track is already the queued upcoming.
  /// [localPath] — a fully downloaded file for the next track. When given, the
  /// upcoming item is built straight from disk and [url] is not needed.
  ///
  /// THIS IS WHAT MAKES A DOWNLOADED ALBUM GAPLESS. Arming the upcoming used
  /// to require a resolved stream URL, so the caller only did it for tracks that
  /// needed resolving — meaning cached tracks, where the bytes are already on
  /// disk and a seamless join is trivial, fell back to the Dart reload path and
  /// had an audible seam between them.
  static Future<void> setUpcoming(String videoId, String url,
      {String? userAgent, int? contentLength, String? localPath}) async {
    if (videoId.isEmpty || videoId.startsWith('http')) return;
    try {
      await _call<void>('setUpcoming', {
        'videoId': videoId,
        'url': url,
        if (userAgent != null && userAgent.isNotEmpty) 'userAgent': userAgent,
        if (contentLength != null && contentLength > 0) 'contentLength': contentLength,
        if (localPath != null && localPath.isNotEmpty) 'localPath': localPath,
      });
    } catch (_) {}
  }

  /// Jump to the already-buffered upcoming item instead of preparing it again.
  ///
  /// Returns false, and changes nothing — unless the armed item really is
  /// [videoId]. The match is made natively because that is where the truth is:
  /// Dart keeps no record of what setUpcoming armed, and the queue can be
  /// reordered between a check here and the call landing there. A false result
  /// simply means the caller should prepare the track the ordinary way.
  static Future<bool> advanceToUpcoming(String videoId) async {
    if (videoId.isEmpty) return false;
    try {
      return await _call<bool>('advanceToUpcoming', {'videoId': videoId}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Drop the gapless upcoming item (on skip/prev/reorder/remove) so ExoPlayer
  /// doesn't roll into a now-stale next track.
  static Future<void> clearUpcoming() async {
    try {
      await _call<void>('clearUpcoming');
    } catch (_) {}
  }

  static Future<void> pause() async => _call<void>('pause');
  static Future<void> resume() async => _call<void>('resume');
  static Future<void> stop() async => _call<void>('stop');

  /// Drop EVERY cached stream URL held natively. googlevideo URLs are bound to
  /// the egress IP they were resolved from, so after a WiFi<->mobile switch they
  /// all 403 — clearing them makes the next chunk fetch re-resolve fresh on the
  /// new network. Fire-and-forget; safe to call on any connectivity change.
  static Future<void> clearUrlCache() async {
    try {
      await _call<void>('clearUrlCache');
    } catch (_) {/* native player not up yet — nothing cached to clear */}
  }

  /// "Save-from-stream": if the WHOLE track is already in the native media3
  /// play-cache (streamed end-to-end), copy those bytes to [targetPath] with
  /// ZERO network. Returns {'promoted': bool, 'bytes'|'reason': ...} or null.
  /// Only succeeds when the full track is cached from byte 0.
  static Future<Map<String, dynamic>?> promoteFromPlayCache(
      String videoId, String targetPath, {int contentLength = 0}) async {
    try {
      final res = await _call<dynamic>('promoteFromPlayCache', {
        'videoId': videoId,
        'targetPath': targetPath,
        'contentLength': contentLength,
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return null;
    } catch (_) {
      return null;
    }
  }
  /// Is ANY app currently playing music on this device (`AudioManager
  /// .isMusicActive`)? Used to reject misrouted media-button PLAY commands — see
  /// `AuvyAudioHandler.play`. Returns false if the answer can't be determined,
  /// so an unavailable check never blocks a legitimate play.
  static Future<bool> isMusicActive() async {
    try {
      return await _call<bool>('isMusicActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> seek(Duration position) async =>
      _call<void>('seek', {'positionMs': position.inMilliseconds});
  static Future<void> setSpeed(double speed) async =>
      _call<void>('setSpeed', {'speed': speed});
  static Future<void> setVolume(double volume) async =>
      _call<void>('setVolume', {'volume': volume});

  /// Real pitch shift (independent of speed) via ExoPlayer PlaybackParameters.
  static Future<void> setPitch(double pitch) async =>
      _call<void>('setPitch', {'pitch': pitch});

  /// Drive the native 5-band Equalizer bound to the ExoPlayer audio session.
  /// [bands] are dB values for 60/230/910/3600/14000 Hz.
  static Future<void> setEqualizer(bool enabled, List<double> bands) async =>
      _call<void>('setEqualizer', {'enabled': enabled, 'bands': bands});

  /// ExoPlayer's built-in silence trimmer. Before this the "Skip silence"
  /// setting only flipped a Dart bool and persisted it — it never reached the
  /// engine, so the toggle did nothing.
  static Future<void> setSkipSilence(bool enabled) async =>
      _call<void>('setSkipSilence', {'enabled': enabled});

  /// Volume normalization. [gainMb] is the correction in MILLIBELS derived from
  /// YouTube's `audioConfig.loudnessDb` for the current track (positive = boost
  /// a quiet master via LoudnessEnhancer, negative = trim a loud one via the
  /// player volume). Clamped to ±20 dB natively.
  static Future<void> setNormalizationGain(bool enabled, int gainMb) async =>
      _call<void>(
          'setNormalizationGain', {'enabled': enabled, 'gainMb': gainMb});

  /// What the network is actually doing, for the adaptive bitrate ladder.
  ///
  /// `bitrateEstimate` is media3's measured throughput in bps, or
  /// [kNoEstimate] (-1) before it has seen enough traffic — those two are
  /// deliberately distinguishable, because treating "don't know yet" as "bad"
  /// makes every cold start begin at the lowest quality.
  ///
  /// `stalls` is READ-AND-CLEARED natively: it answers "has anything gone wrong
  /// since I last decided?", so a running total would re-trigger the same
  /// downgrade long after the network recovered.
  static Future<({int bitrateEstimate, int stalls})> getNetworkStats() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getNetworkStats');
      return (
        bitrateEstimate: (r?['bitrateEstimate'] as num?)?.toInt() ?? -1,
        stalls: (r?['stalls'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // An older native build, or the player not up yet. "No estimate, nothing
      // broken" leaves the ladder exactly where it was.
      return (bitrateEstimate: -1, stalls: 0);
    }
  }
}
