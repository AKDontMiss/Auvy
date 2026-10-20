import 'dart:io' show Platform;

import 'package:auvy/services/event_log.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// The Dart side of the native audio player (ExoPlayer on Android, AVPlayer on
/// iOS).
///
/// Playback runs natively rather than through a Flutter plugin so it keeps going
/// with the screen off. This class is the whole bridge: one MethodChannel out and
/// a set of static callbacks in.
///
/// Two details matter:
/// 1. [_streamResolver] is called *by* native code, which blocks its loader
///    thread until Dart returns a fresh stream URL (after expiry, a 403 or a
///    network change). It must stay fast and never call back into native
///    synchronously.
/// 2. Everything is static, because audio_service can start the app in a
///    headless engine (Bluetooth connect, headset button, Android Auto) where
///    the native channels are not registered. See [_platformGone].

class NativeAudioEngine {
  static const MethodChannel _channel = MethodChannel('com.auvy.app/native_player');

  static void Function(bool? playWhenReady)? _onError;
  static void Function(Duration position, Duration duration, bool isPlaying)? _onPosition;

  /// Position updates received while not playing: a counter the performance
  /// sampler reports, to spot a position feed that failed to stop.
  static int positionUpdatesWhilePaused = 0;
  static void Function()? _onTrackEnded;
  static void Function(bool isPlaying, {bool? playWhenReady})? _onIsPlayingChanged;
  static void Function(bool buffering)? _onBuffering;
  // Gapless: native moved on to the pre-buffered next item by itself.
  static void Function(String videoId)? _onNativeAutoAdvance;
  // Media volume reached zero. See the "pause when muted" setting.
  static void Function()? _onVolumeMuted;
  // ICY internet radio stream metadata (StreamTitle, station name, bitrate) decoded natively by ExoPlayer.
  static void Function(String? streamTitle, String? stationName, String? genre, String? bitrate)? _onIcyMetadata;
  // Native → Dart stream resolver. Called (blocking the native loader thread)
  // whenever the player needs bytes and has no valid URL. Returns
  // {url, userAgent, contentLength} or null.
  static Future<Map<String, dynamic>?> Function(String videoId,
      {int expectContentLength})? _streamResolver;
  static bool _handlerInstalled = false;

  /// Set once the native side proves unreachable in this engine.
  ///
  /// In a headless engine the hand-registered channels do not exist, so every call
  /// would throw and the player would keep retrying. After the first failure every
  /// call becomes a cheap no-op instead. Cleared by [onActivityAttached].
  static bool _platformGone = false;

  /// False once the native player is known to be unreachable in this engine.
  static bool get platformAvailable => !_platformGone;

  /// Fired once, when the native side is first found missing, so the player can
  /// stop instead of retrying.
  static void Function()? onPlatformLost;

  /// A song's whole file is on the device: the one about to play, or the next,
  /// fetched ahead (TrackWaveform listens, to read its waveform).
  static void Function(String videoId)? onFetched;

  /// Clears [_platformGone] when an Activity attaches and registers the channels.
  ///
  /// The same engine can start headless and gain a screen later (MainActivity
  /// reuses audio_service's cached engine), so without this reset the app would stay
  /// silent after being opened. Called from MainActivity.configureFlutterEngine via
  /// the `auvy/engine_lifecycle` channel.
  static void onActivityAttached() {
    if (!_platformGone) return;
    _platformGone = false;
    _handlerInstalled = false;
    _installHandler();
  }

  /// Every native call goes through here. Returns null instead of throwing, so a
  /// failed control command cannot crash the isolate; callers that need to know
  /// check [platformAvailable].
  static Future<T?> _call<T>(String method, [dynamic args]) async {
    if (_platformGone) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Channel not registered in this engine: latch so calls stop retrying (cleared
      // again by [onActivityAttached]).
      if (!_platformGone) {
        _platformGone = true;
        onPlatformLost?.call();
      }
      return null;
    } catch (_) {
      // A real native-side failure (bad args, player not ready). Transient, so do not
      // latch.
      return null;
    }
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlayerError':
          // playWhenReady is the user's play/pause intent at the moment of the error,
          // which survives the error unlike isPlaying. Null from older native builds.
          final e = (call.arguments as Map?) ?? const {};
          _onError?.call(e['playWhenReady'] as bool?);
          break;
        case 'onPosition':
          final a = (call.arguments as Map?) ?? const {};
          if (isStaleTick(a['videoId'] as String?, _expectedVideoId)) break;
          final playing = a['isPlaying'] as bool? ?? false;
          // An update while paused carries no new position. A few are normal (a seek or
          // a duration resolving while paused); a steadily climbing count means the feed
          // did not stop.
          if (!playing) positionUpdatesWhilePaused++;
          _onPosition?.call(
            Duration(milliseconds: (a['positionMs'] as num?)?.toInt() ?? 0),
            Duration(milliseconds: (a['durationMs'] as num?)?.toInt() ?? 0),
            tickPlaying(playing,
                requested: _requested,
                requestedAgoMs:
                    DateTime.now().millisecondsSinceEpoch - _requestedAtMs,
                windowMs: _requestWindowMs),
          );
          break;
        case 'onNativeNote':
          // A diagnostic line from the native side, forwarded so it appears in the
          // exported activity log (native logs otherwise stay in logcat).
          final n = (call.arguments as Map?) ?? const {};
          final msg = n['msg']?.toString() ?? '';
          if (msg.isNotEmpty) logEvent('native: $msg');
          break;
        case 'onTrackEnded':
          _onTrackEnded?.call();
          break;
        case 'onIsPlayingChanged':
          final a = (call.arguments as Map?) ?? const {};
          final isPlaying = a['isPlaying'] as bool? ?? false;
          final playWhenReady = a['playWhenReady'] as bool?;
          // The player has acted on the request: ticks from here on are current.
          // Its actual state, not playWhenReady: an iPhone restates "not playing,
          // about to" the moment it is asked to resume, and its ticks keep saying
          // "not playing" until AVPlayer really starts.
          if (isPlaying == _requested) _requested = null;
          _onIsPlayingChanged?.call(isPlaying, playWhenReady: playWhenReady);
          break;
        // Media volume just hit ZERO (native ContentObserver). Only the
        // transition to 0 is reported, never repeats while already muted.
        case 'onVolumeMuted':
          _onVolumeMuted?.call();
          break;
        case 'onNativeAutoAdvance':
          final a = (call.arguments as Map?) ?? const {};
          final next = (a['videoId'] as String?) ?? '';
          if (next.isNotEmpty) _expectedVideoId = next;
          _onNativeAutoAdvance?.call(next);
          break;
        // Native entered or left buffering. Every track start buffers briefly, so the
        // listener decides whether a stall has lasted long enough to report.
        case 'onBuffering':
          final a = (call.arguments as Map?) ?? const {};
          _onBuffering?.call(a['buffering'] as bool? ?? false);
          break;
        case 'onFetched':
          final a = (call.arguments as Map?) ?? const {};
          final id = '${a['videoId'] ?? ''}';
          if (id.isNotEmpty) onFetched?.call(id);
          break;
        case 'onIcyMetadata':
          final a = (call.arguments as Map?) ?? const {};
          _onIcyMetadata?.call(
            (a['streamTitle'] as String?)?.trim(),
            (a['stationName'] as String?)?.trim(),
            (a['genre'] as String?)?.trim(),
            (a['bitrate'] as String?)?.trim(),
          );
          break;
        case 'resolveStream':
          // Native asks for a fresh stream URL.
          final a = (call.arguments as Map?) ?? const {};
          final vid = (a['videoId'] as String?) ?? '';
          final resolver = _streamResolver;
          if (resolver == null || vid.isEmpty) return null;
          // Non-zero means a mid-track re-resolve; the value is the byte length of the
          // format already playing, and the resolver must return that same format so the
          // next byte offset still makes sense.
          final expect = (a['expectContentLength'] as num?)?.toInt() ?? 0;
          try {
            return await resolver(vid, expectContentLength: expect);
          } catch (_) {
            return null;
          }
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

  /// Registers playback callbacks; only non-null ones are replaced. Native sends
  /// [onPosition] about twice a second, [onTrackEnded] when a track finishes and
  /// [onIsPlayingChanged] on play/pause.
  static void setListeners({
    void Function(bool? playWhenReady)? onError,
    void Function(Duration position, Duration duration, bool isPlaying)? onPosition,
    void Function()? onTrackEnded,
    void Function(bool isPlaying, {bool? playWhenReady})? onIsPlayingChanged,
    void Function(String videoId)? onNativeAutoAdvance,
    void Function()? onVolumeMuted,
    void Function(bool buffering)? onBuffering,
    void Function(String? streamTitle, String? stationName, String? genre, String? bitrate)? onIcyMetadata,
  }) {
    if (onError != null) _onError = onError;
    if (onPosition != null) _onPosition = onPosition;
    if (onTrackEnded != null) _onTrackEnded = onTrackEnded;
    if (onIsPlayingChanged != null) _onIsPlayingChanged = onIsPlayingChanged;
    if (onNativeAutoAdvance != null) _onNativeAutoAdvance = onNativeAutoAdvance;
    if (onBuffering != null) _onBuffering = onBuffering;
    if (onVolumeMuted != null) _onVolumeMuted = onVolumeMuted;
    if (onIcyMetadata != null) _onIcyMetadata = onIcyMetadata;
    _installHandler();
  }

  /// Clears all callbacks and the stream resolver, so static fields do not keep a
  /// disposed [PlayerNotifier] alive.
  static void clearListeners() {
    _onError = null;
    _onPosition = null;
    _onTrackEnded = null;
    _onIsPlayingChanged = null;
    _onNativeAutoAdvance = null;
    _onBuffering = null;
    _onVolumeMuted = null;
    _onIcyMetadata = null;
    _streamResolver = null;
    print('NativeAudioEngine: all static listeners and resolvers cleared');
  }

  // Plays a resolved URL. Native needs the user agent of the client that produced
  // it (googlevideo rejects a mismatch) and the content length (to send bounded
  // Range requests).
  static Future<void> playTrack(
    String videoId,
    String streamUrl, {
    String? userAgent,
    int? contentLength,
    bool autoPlay = true,
    String? localPath,
  }) async {
    _expectedVideoId = videoId;
    // A load includes fetching the start of the stream, so it gets longer than
    // a pause or resume to confirm.
    if (autoPlay) _request(true, windowMs: 5000);
    await _call<void>('playVideo', {
      'videoId': videoId,
      'url': streamUrl,
      'autoPlay': autoPlay,
      if (userAgent != null && userAgent.isNotEmpty) 'userAgent': userAgent,
      if (contentLength != null && contentLength > 0) 'contentLength': contentLength,
      // When set, native plays this downloaded file directly and ignores the URL.
      if (localPath != null && localPath.isNotEmpty) 'localPath': localPath,
    });
  }

  /// Names the next track when gapless is off: native seeds its URL and fetches
  /// it whole in the current track's last 25 seconds, so the switch starts from
  /// disk. YouTube ids only.
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

  /// Gapless: names the next track to queue natively so it starts with no gap.
  /// Used when the gapless setting is on (otherwise [prewarmNext]). YouTube ids
  /// only; native ignores a repeat of the already-queued track. Both players
  /// fetch the next file in the current track's last 25 seconds; Android then
  /// queues it, iOS never does (see AuvyPlayer.setUpcoming).
  ///
  /// [localPath] builds the next item straight from a downloaded file, so
  /// downloaded albums play gaplessly too.
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

  /// Switches to the already-buffered next item instead of preparing it again.
  ///
  /// Returns false and changes nothing unless the queued item really is [videoId]
  /// (checked natively, where the truth is). On false, prepare the track normally.
  static Future<bool> advanceToUpcoming(String videoId) async {
    if (videoId.isEmpty) return false;
    try {
      final moved =
          await _call<bool>('advanceToUpcoming', {'videoId': videoId}) ?? false;
      if (moved) _expectedVideoId = videoId;
      return moved;
    } catch (_) {
      return false;
    }
  }

  /// Drops the queued gapless item (on skip, previous, reorder or remove) so the
  /// player cannot roll into a stale next track.
  static Future<void> clearUpcoming() async {
    try {
      await _call<void>('clearUpcoming');
    } catch (_) {}
  }

  static Future<void> pause() async {
    _request(false);
    return _call<void>('pause');
  }

  static Future<void> resume() async {
    _request(true);
    return _call<void>('resume');
  }

  /// What Dart last asked the player for, until the player confirms it.
  static bool? _requested;
  static int _requestedAtMs = 0;
  static int _requestWindowMs = 1000;

  static void _request(bool playing, {int windowMs = 1000}) {
    _requested = playing;
    _requestedAtMs = DateTime.now().millisecondsSinceEpoch;
    _requestWindowMs = windowMs;
  }

  /// The play state a position tick may report.
  ///
  /// A tick carries the player's state as it was when the tick was sent, so one
  /// sent just before a pause or resume can land just after it and undo it for
  /// a moment; an iPhone's ticks also say "not playing" while AVPlayer is
  /// getting ready to start. A pause could flip back to playing for a few
  /// milliseconds (the play button, widgets and notification updated three times
  /// and a Listen Together host published the flip to every listener), and an
  /// iPhone host published paused, playing within 20 ms at most starts. Until
  /// the player confirms the request (onIsPlayingChanged), or for [windowMs]
  /// if it never does, a tick can't contradict it.
  @visibleForTesting
  static bool tickPlaying(bool reported,
          {required bool? requested,
          required int requestedAgoMs,
          int windowMs = 1000}) =>
      requested != null && requestedAgoMs < windowMs && reported != requested
          ? requested
          : reported;
  static Future<void> stop() async {
    _expectedVideoId = null;
    return _call<void>('stop');
  }

  /// The song the player was last told to play, or moved on to by itself.
  static String? _expectedVideoId;

  /// Whether a position tick is about a song other than [expected].
  ///
  /// After a skip the previous song stays in the player until the new one is
  /// ready (an iPhone fetches the whole file first), and its ticks kept coming.
  /// Read as the new song's, they put its progress bar at the old position
  /// for a moment, could end its loading state early, and a Listen Together
  /// host published them (listeners jumped well into the next song, then back).
  /// A tick that names no song (an older native build,
  /// a source without an id) is kept.
  @visibleForTesting
  static bool isStaleTick(String? tickVideoId, String? expected) =>
      tickVideoId != null &&
      tickVideoId.isNotEmpty &&
      expected != null &&
      expected.isNotEmpty &&
      tickVideoId != expected;

  /// Drops every cached stream URL. googlevideo URLs are tied to the IP they were
  /// resolved from, so after a Wi-Fi ↔ mobile switch they all fail; clearing them
  /// forces fresh ones on the new network.
  static Future<void> clearUrlCache() async {
    try {
      await _call<void>('clearUrlCache');
    } catch (_) {/* native player not up yet — nothing cached to clear */}
  }

  /// If the native player holds the whole track (the file it fetched to play it,
  /// or a stream's play cache), copies it to [targetPath] with no network use.
  /// The name predates the fetched files. Returns {'promoted': bool,
  /// 'bytes' | 'reason': ...} or null.
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
  /// iOS only: fixes a downloaded MP4 that declares its duration twice.
  ///
  /// YouTube serves fragmented MP4 whose header also states the full duration.
  /// AVFoundation adds the two, so a 3:30 track shows as 7:00 and goes silent
  /// halfway. Native zeroes that header field in place and skips any file that is
  /// not a fragmented MP4. Runs when a download lands (playback repairs too).
  /// Returns true only when bytes were written.
  ///
  /// Android returns false without a call: ExoPlayer reads these files correctly.
  static Future<bool> repairAudioFile(String path) async {
    if (!Platform.isIOS || path.isEmpty) return false;
    try {
      return await _call<bool>('repairAudioFile', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether any app is currently playing music. Used to ignore misrouted
  /// media-button PLAY commands (see `AuvyAudioHandler.play`). False when unknown,
  /// so it never blocks a real play.
  static Future<bool> isMusicActive() async {
    try {
      return await _call<bool>('isMusicActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether another app is audible right now. Android answers only once
  /// Auvy's own output has settled after a pause (its `isMusicActive` counts
  /// Auvy too); iOS's `isOtherAudioPlaying` never counts Auvy. False when
  /// unknown, so it never blocks a real press.
  static Future<bool> otherAppIsPlaying() async {
    try {
      return await _call<bool>(Platform.isIOS ? 'isMusicActive' : 'otherAppIsPlaying') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android: makes a headset's PAUSE pause and its PLAY play
  /// (LiteralMediaKeys.java); audio_service alone toggles on either. Needs the
  /// audio service running, so it is called after AudioService.init. True when
  /// in place; false on iOS (its remote commands already arrive as play, pause
  /// and toggle) or if audio_service changed.
  static Future<bool> useLiteralMediaKeys() async {
    if (!Platform.isAndroid) return false;
    try {
      return await const MethodChannel('auvy/engine').invokeMethod<bool>('installMediaKeys') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android: whether Android Auto is projecting right now (AuvyApplication reads
  /// the car host's connection state). False on iOS and when unknown.
  static Future<bool> androidAutoConnected() async {
    if (!Platform.isAndroid) return false;
    try {
      return await const MethodChannel('auvy/engine').invokeMethod<bool>('carConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> seek(Duration position) async =>
      _call<void>('seek', {'positionMs': position.inMilliseconds});

  /// Turns the native level meter on or off (the player cover's glow; see
  /// AudioLevelMeter). Off costs nothing.
  static Future<void> setMetering(bool on) async => _call<void>('setMetering', {'on': on});

  /// How loud the music is right now: RMS of the last buffer, 0..1, and 0 when
  /// paused or metering is off.
  static Future<double> getLevel() async => (await _call<num>('getLevel'))?.toDouble() ?? 0;

  /// A song's real waveform: its loudness in [buckets] equal slices, 0..1
  /// relative to the loudest, decoded from the file being played, or from the
  /// fetched file of the song named by [videoId] (the next one, fetched ahead),
  /// with the video id it belongs to. Null while there is no whole file to read
  /// (the song is still being fetched, or is a stream) or the content is long
  /// (a podcast).
  static Future<({String videoId, List<double> peaks})?> waveform({int buckets = 400, String? videoId}) async {
    // [videoId]: answer only for that song, so a song still loading isn't
    // mistaken for the one before it, and that one isn't decoded for nothing.
    final raw = await _call<Map<dynamic, dynamic>>(
        'waveform', {'buckets': buckets, 'videoId': ?videoId});
    final peaks = raw?['peaks'];
    if (peaks is! List || peaks.isEmpty) return null;
    return (
      videoId: '${raw!['videoId'] ?? ''}',
      peaks: [for (final p in peaks) (p as num).toDouble().clamp(0.0, 1.0)],
    );
  }
  static Future<void> setSpeed(double speed) async =>
      _call<void>('setSpeed', {'speed': speed});
  static Future<void> setVolume(double volume) async =>
      _call<void>('setVolume', {'volume': volume});

  /// Real pitch shift (independent of speed) via ExoPlayer PlaybackParameters.
  static Future<void> setPitch(double pitch) async =>
      _call<void>('setPitch', {'pitch': pitch});

  /// Sets the native 5-band equaliser. [bands] are dB values for
  /// 60 / 230 / 910 / 3600 / 14000 Hz.
  static Future<void> setEqualizer(bool enabled, List<double> bands) async =>
      _call<void>('setEqualizer', {'enabled': enabled, 'bands': bands});

  /// ExoPlayer's built-in silence skipping.
  static Future<void> setSkipSilence(bool enabled) async =>
      _call<void>('setSkipSilence', {'enabled': enabled});

  /// Volume normalisation. [gainMb] is the correction in millibels from YouTube's
  /// `loudnessDb` for the track (positive boosts a quiet master, negative trims a
  /// loud one). Clamped to ±20 dB natively.
  static Future<void> setNormalizationGain(bool enabled, int gainMb) async =>
      _call<void>(
          'setNormalizationGain', {'enabled': enabled, 'gainMb': gainMb});

  /// Network measurements for the adaptive bitrate ladder.
  ///
  /// `bitrateEstimate` is measured throughput in bps, or [kNoEstimate] (-1) before
  /// enough traffic has been seen ("unknown" must not be treated as "slow").
  /// `stalls` counts mid-track stalls since the last read (native resets it).
  static Future<({int bitrateEstimate, int stalls})> getNetworkStats() async {
    if (_platformGone) return (bitrateEstimate: -1, stalls: 0);
    try {
      // Bounded: this is read before every preload, so a channel that never answers
      // must not block the next track. A timeout falls through to "no estimate".
      final r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getNetworkStats')
          .timeout(const Duration(seconds: 1));
      return (
        bitrateEstimate: (r?['bitrateEstimate'] as num?)?.toInt() ?? -1,
        stalls: (r?['stalls'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // Older native build or player not ready: no estimate, ladder unchanged.
      return (bitrateEstimate: -1, stalls: 0);
    }
  }
}
