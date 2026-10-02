import 'dart:async';
// cos/sin/pi are for the equal-power volume ramp. See _rampVolume.
import 'dart:math' show Random, min, max, pow, cos, sin, pi, log, ln2;
import 'dart:convert';
import 'package:auvy/logic/media_kind.dart';
// File — the wake-up alarm pre-caches one track to disk (prepareAlarmTrack).
import 'dart:io' show File, Platform;
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/services/artist_metadata_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/core/native_audio_engine.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:auvy/logic/download_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/audio_service.dart' as auvy_audio;
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/scrobble_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/podcast_extras_provider.dart';
import 'package:auvy/logic/playback_error_handler.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/logic/media_artwork_cache.dart';
import 'package:auvy/core/auvy_audio_handler.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/services/lyrics_service.dart';
// Recently-played history is part of the cloud backup, so saving it schedules a
// (debounced) push. See _saveSettings.
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/logic/playback_handoff.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/logic/adaptive_bitrate.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/core/image_cache_manager.dart';
import 'package:auvy/services/event_log.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/icy_metadata_service.dart';
import 'package:auvy/services/radio_schedule_service.dart';
import 'package:auvy/services/device_info_service.dart';

// Declare the parts
part '../logic/player_playback.dart';
part '../logic/player_queue.dart';
part '../logic/player_system.dart';
part '../logic/player_smart.dart';

enum RepeatMode { off, all, one }
enum AudioQuality { low, medium, high, auto }
final audioIntensityProvider = ValueNotifier<double>(0.0);
final currentPositionProvider = ValueNotifier<Duration>(Duration.zero);

/// Live radio: how far behind the live edge the listener is. It grows while
/// paused and then holds steady (stream and listener both advance at 1×); only
/// rejoining the live edge clears it, so "LIVE" isn't shown while it isn't true.
///
/// Whether audio actually resumes from the pause point depends on the stream (an
/// HLS stream with a DVR window can; a plain ICY/MP3 stream rejoins at the live
/// edge), so read this as "how much has aired since you paused", which is what
/// "GO LIVE" discards.
final radioBehindLiveProvider = ValueNotifier<Duration>(Duration.zero);

/// When the live stream was paused; null while playing. The UI ticks off this so
/// the gap counts up in real time while paused.
final radioPausedAtProvider = ValueNotifier<DateTime?>(null);

class RemovedQueueItem {
  final Song song;
  final int index;
  final DateTime timestamp;
  final List<Song> userQueue;
  final List<Song> contextQueue;
  final List<Song> autoplayQueue;
  
  RemovedQueueItem({
    required this.song,
    required this.index,
    required this.timestamp,
    required this.userQueue,
    required this.contextQueue,
    required this.autoplayQueue,
  });
}

class PlayerState {
  final bool isPlaying, isLoading, isShuffle;

  /// True while playback is stuck buffering, not merely starting. Separate from
  /// [isLoading], which covers the expected, brief setup of a new track. This
  /// means "playing, but no audio is coming out" (typically a stream URL dying
  /// after a network change). Set only once the stall has persisted (see the
  /// onBuffering listener).
  final bool isStalled;
  final Song? currentSong;
  final Duration position, duration;
  final List<Song> queue, originalQueue, history;
  final Map<String, int> historyPlayedAt;
  final Map<String, String> historyPlayedDevice;
  final int currentIndex;
  final List<Song> userQueue;        // Explicitly added by user
  final List<Song> contextQueue;     // From current playback context
  final List<Song> autoplayQueue;    // Algorithm-generated
  final int userQueueEndIndex;       // Where user queue ends in combined queue
  final RepeatMode repeatMode;
  final double volume, speed;
  /// Remembered playback speed for PODCASTS only. Music always starts at 1.0×,
  /// but podcast listeners keep a preferred pace — Auvy re-applies it whenever
  /// a podcast episode starts (persisted across launches).
  final double podcastSpeed;
  final String? locationName;
  final String playbackSource;
  final String? contextId, contextType, contextTitle;
  final Set<String> blacklistedIds; // Store IDs of blocked songs  
  final bool crossfadeEnabled;
  final int maxCacheSizeMB;
  final Duration crossfadeDuration;
  final bool audioNormalizationEnabled;
  final AudioQuality audioQuality;
  final bool gaplessPlayback;
  final bool explicitContentPreferred;
  /// When true, plugging in / connecting headphones or a Bluetooth device
  /// auto-resumes a loaded-but-paused track (as if the user tapped play).
  /// Default OFF — the phone connecting to audio hardware should not start
  /// music on its own unless the user opted in.
  final bool autoPlayOnConnect;
  /// When false (default), Auvy fetches ONLY audio — music-video (OMV/UGC)
  /// versions are hidden from search so the user only ever gets the original
  /// audio track. When true, video versions are allowed to surface.
  final bool processVideosEnabled;
  /// When set, playback pauses at this wall-clock time (sleep timer). Null =
  /// no timer armed. Session-only by design — it never persists to disk.
  final DateTime? sleepTimerEndsAt;
  /// The duration option (in minutes) the user armed the sleep timer with —
  /// so the settings UI can highlight the matching pill. Null = no timer.
  final int? sleepTimerMinutes;
  /// "Sleep at end of track": when true, playback pauses when the current track
  /// finishes instead of advancing. Session-only, like the timer.
  final bool sleepAtEndOfTrack;
  final Set<String> recentlyAttemptedPreloads;

  // DSP / EQ fields (see player_playback.dart for implementations)
  // These map onto Android's DSP chain:
  //   silence skipping → loudness normalization → pitch/tempo → 5-band EQ
  final bool silenceSkippingEnabled;   // Android SilenceSkippingAudioProcessor
  final double pitch;                  // 1.0 = natural; 2^(N/12) per semitone
  final bool eqEnabled;                // Master EQ on/off switch
  /// 5 bands: [60Hz, 230Hz, 910Hz, 3600Hz, 14000Hz], values in dB (−12 … +12)
  final List<double> eqBands;
  final bool miniPlayerVisible; // Controls if miniplayer exists in the tree
  final double swipeProgress;
  final int seekJumpSeconds; // 5, 10, 15, or 30s seek jump
  final bool pauseOnZeroVolume; // Automatically pause when volume reaches 0
  /// A-B loop points. When [isLoopActive] is true, playback automatically
  /// loops between [loopStart] and [loopEnd].
  final Duration? loopStart;
  final Duration? loopEnd;

  bool get isLoopActive =>
      loopStart != null && loopEnd != null && loopEnd! > loopStart!;

  int get pitchSemitones =>
      pitch <= 0 ? 0 : (12.0 * (log(pitch) / ln2)).round();

  PlayerState({
    this.isPlaying = false, 
    this.currentSong, 
    this.miniPlayerVisible = false,
    this.position = Duration.zero, 
    this.duration = Duration.zero,
    this.isLoading = false,
    this.isStalled = false,
    this.maxCacheSizeMB = 500, 
    this.queue = const [], 
    this.userQueue = const [],
    this.contextQueue = const [],
    this.autoplayQueue = const [],
    this.userQueueEndIndex = -1,
    this.originalQueue = const [], 
    this.currentIndex = -1,
    this.history = const [], 
    this.historyPlayedAt = const {},
    this.historyPlayedDevice = const {},
    this.isShuffle = false, 
    this.repeatMode = RepeatMode.off,
    this.volume = 1.0,
    this.swipeProgress = 0.0,
    this.speed = 1.0,
    this.podcastSpeed = 1.0,
    this.playbackSource = "Library",
    this.locationName, 
    this.contextId, 
    this.contextType, 
    this.contextTitle,
    this.crossfadeEnabled = false,
    this.crossfadeDuration = const Duration(seconds: 5),
    this.audioNormalizationEnabled = true,
    this.audioQuality = AudioQuality.auto,
    this.gaplessPlayback = true,
    this.explicitContentPreferred = true,
    this.autoPlayOnConnect = false,
    this.processVideosEnabled = false,
    this.sleepTimerEndsAt,
    this.sleepTimerMinutes,
    this.sleepAtEndOfTrack = false,
    this.blacklistedIds = const {},
    this.recentlyAttemptedPreloads = const {},
    this.silenceSkippingEnabled = false,
    this.pitch = 1.0,
    this.eqEnabled = false,
    this.eqBands = const [0.0, 0.0, 0.0, 0.0, 0.0],
    this.seekJumpSeconds = 10,
    this.pauseOnZeroVolume = false,
    this.loopStart,
    this.loopEnd,
  });

  PlayerState copyWith({ 
    List<Song>? userQueue,
    List<Song>? contextQueue,
    List<Song>? autoplayQueue,
    int? userQueueEndIndex,
    int? maxCacheSizeMB,
    Set<String>? blacklistedIds,
    Set<String>? recentlyAttemptedPreloads,
    bool? isPlaying, bool? miniPlayerVisible, Song? currentSong, Duration? position, Duration? duration, String? locationName,
    bool? isLoading, bool? isStalled, List<Song>? queue, List<Song>? originalQueue, int? currentIndex, 
    List<Song>? history,
    Map<String, int>? historyPlayedAt,
    Map<String, String>? historyPlayedDevice,
    bool? isShuffle, RepeatMode? repeatMode, double? volume, double? swipeProgress,
    double? speed, double? podcastSpeed, String? playbackSource,
    String? contextId, String? contextType, String? contextTitle,
    /// Wipes the three context fields instead of inheriting them. See the
    /// assignment below for why a null cannot do this on its own.
    bool clearContext = false,
    bool? crossfadeEnabled, Duration? crossfadeDuration, bool? audioNormalizationEnabled,
    AudioQuality? audioQuality, bool? gaplessPlayback, bool? explicitContentPreferred,
    bool? autoPlayOnConnect,
    bool? processVideosEnabled,
    // copyWith can't null a field via `??`, so clearing the sleep timer takes
    // an explicit flag instead of a sentinel value.
    DateTime? sleepTimerEndsAt, int? sleepTimerMinutes, bool clearSleepTimer = false,
    bool? sleepAtEndOfTrack,
    bool? silenceSkippingEnabled, double? pitch, bool? eqEnabled, List<double>? eqBands,
    int? seekJumpSeconds, bool? pauseOnZeroVolume,
    Duration? loopStart, Duration? loopEnd, bool clearLoop = false,
  }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying, 
      miniPlayerVisible: miniPlayerVisible?? this.miniPlayerVisible,
      currentSong: currentSong ?? this.currentSong, 
      position: position ?? this.position, 
      duration: duration ?? this.duration, 
      isLoading: isLoading ?? this.isLoading,
      isStalled: isStalled ?? this.isStalled, 
      queue: queue ?? this.queue, 
      maxCacheSizeMB: maxCacheSizeMB ?? this.maxCacheSizeMB, 
      blacklistedIds: blacklistedIds ?? this.blacklistedIds,
      recentlyAttemptedPreloads: recentlyAttemptedPreloads ?? this.recentlyAttemptedPreloads,
      userQueue: userQueue ?? this.userQueue,
      contextQueue: contextQueue ?? this.contextQueue,
      autoplayQueue: autoplayQueue ?? this.autoplayQueue,
      userQueueEndIndex: userQueueEndIndex ?? (userQueue != null ? userQueue.length : this.userQueueEndIndex),
      originalQueue: originalQueue ?? this.originalQueue, 
      currentIndex: currentIndex ?? this.currentIndex, 
      history: history ?? this.history, 
      historyPlayedAt: historyPlayedAt ?? this.historyPlayedAt,
      historyPlayedDevice: historyPlayedDevice ?? this.historyPlayedDevice,
      isShuffle: isShuffle ?? this.isShuffle, 
      repeatMode: repeatMode ?? this.repeatMode,
      swipeProgress: swipeProgress ?? this.swipeProgress,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      podcastSpeed: podcastSpeed ?? this.podcastSpeed,
      locationName: locationName ?? this.locationName,
      playbackSource: playbackSource ?? this.playbackSource,
      // [clearContext] exists because `?? this.x` can't set these back to null. A play
      // from Search, Quick Picks or a radio row passes no context, and without an
      // explicit clear the previous album or playlist would stay recorded as the
      // current context (and keep its home mosaic tile animating).
      contextId: clearContext ? null : (contextId ?? this.contextId),
      contextType: clearContext ? null : (contextType ?? this.contextType),
      contextTitle: clearContext ? null : (contextTitle ?? this.contextTitle),
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      audioNormalizationEnabled: audioNormalizationEnabled ?? this.audioNormalizationEnabled,
      audioQuality: audioQuality ?? this.audioQuality,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      explicitContentPreferred: explicitContentPreferred ?? this.explicitContentPreferred,
      autoPlayOnConnect: autoPlayOnConnect ?? this.autoPlayOnConnect,
      processVideosEnabled: processVideosEnabled ?? this.processVideosEnabled,
      sleepTimerEndsAt: clearSleepTimer ? null : (sleepTimerEndsAt ?? this.sleepTimerEndsAt),
      sleepTimerMinutes: clearSleepTimer ? null : (sleepTimerMinutes ?? this.sleepTimerMinutes),
      sleepAtEndOfTrack:
          clearSleepTimer ? false : (sleepAtEndOfTrack ?? this.sleepAtEndOfTrack),
      silenceSkippingEnabled: silenceSkippingEnabled ?? this.silenceSkippingEnabled,
      pitch: pitch ?? this.pitch,
      eqEnabled: eqEnabled ?? this.eqEnabled,
      eqBands: eqBands ?? this.eqBands,
      seekJumpSeconds: seekJumpSeconds ?? this.seekJumpSeconds,
      pauseOnZeroVolume: pauseOnZeroVolume ?? this.pauseOnZeroVolume,
      loopStart: clearLoop ? null : (loopStart ?? this.loopStart),
      loopEnd: clearLoop ? null : (loopEnd ?? this.loopEnd),
    );
  }

  List<Song> get fullQueue => queue; 
  double get progress => duration.inMilliseconds == 0 ? 0.0 : position.inMilliseconds / duration.inMilliseconds;
}

final lastRemovedItemProvider = StateProvider<RemovedQueueItem?>((ref) => null);
final smartShuffleModeProvider = StateProvider<bool>((ref) => false);

/// Ids that smart shuffle added to the queue, so the queue sheet can mark them
/// as suggestions. Cleared when smart shuffle is turned off; ids for tracks that
/// left the queue are harmless.
final smartShuffleInjectedProvider = StateProvider<Set<String>>((ref) => {});
// True while a manual Autoplay refresh (queue sheet ↻) is fetching. The sheet
// swaps the refresh glyph for a spinner and ignores taps so the button gives
// immediate feedback instead of feeling frozen during the network fetch.
final autoplayRefreshingProvider = StateProvider<bool>((ref) => false);

class PlayerNotifier extends StateNotifier<PlayerState> {
  // --- SHARED PROPERTIES (Keep these here) ---
  final Ref ref; 
  final SearchService _searchService; 
  final auvy_audio.AudioService _audioService;
  final AudioCacheManager _cacheManager; 
  late final PlaybackErrorHandler _errorHandler;
  final LyricsService _lyricsService; 
  int _consecutiveSkips = 0;
  int _navIndex = 0;
  String? _currentFetchId; 
  Timer? _fetchDebounceTimer; 
  Timer? _playDebounceTimer;
  Timer? _positionTicker;
  Timer? _inactivityTimer;
  
  // Timers and State Flags
  bool _isProcessingTransition = false;
  bool _isProcessingMutation = false;
  // Set once _initPersistence finished loading saved settings — automated
  // behaviors (device-connect auto-resume) must not act on cold defaults.
  bool _persistenceLoaded = false;

  /// Another device's playing state that arrived before the saved queue had
  /// loaded; taken once it has (see _receiveHandoff).
  Map<String, dynamic>? _pendingHandoff;

  /// For noticing a pause, which the next push should carry to other devices.
  bool _wasPlayingForHandoff = false;

  /// The handoff hooks as registered, kept so dispose can tell whether they are
  /// still this notifier's (tear-offs are not guaranteed to compare equal).
  Future<Map<String, dynamic>?> Function()? _handoffSnapshotHook;
  void Function(Map<String, dynamic>)? _receiveHandoffHook;
  bool _playInterrupted = false;

  /// When Auvy paused ITSELF because the output device went away (Bluetooth
  /// headset disconnected / headphones unplugged), or null if the current pause
  /// has some other cause — the user pressed pause, a call came in, etc.
  ///
  /// This is what separates "resume what you were listening to, because your
  /// headphones came back" from "start playing because a headset connected".
  /// Only the first is wanted by default; the second is the opt-in
  /// `autoPlayOnConnect` setting. See `_initAudioSession`.
  DateTime? _pausedByDeviceLoss;

  /// Last moment the engine was seen playing, and the last deliberate pause.
  /// Together they let the disconnect handler record [_pausedByDeviceLoss] even
  /// when native's own becoming-noisy pause has already set `isPlaying` false.
  /// [_deliberatePauseAt] keeps this honest: a pause the user asked for never
  /// allows a resume, however soon a disconnect follows.
  DateTime? _lastPlayingAt;
  DateTime? _deliberatePauseAt;

  /// How wide the "native just paused us" window is. It's a race between two
  /// callbacks reacting to one hardware event (milliseconds), so two seconds is
  /// generous without catching pauses with other causes. Not private: read from
  /// the `player_system.dart` extension.
  static const Duration deviceLossPauseGrace = Duration(seconds: 2);

  /// How long a device-loss pause stays eligible for auto-resume. Reconnecting
  /// within a few minutes is the same listening session; reconnecting the next
  /// morning is not, and starting music then would be exactly the surprise this
  /// whole mechanism is meant to avoid.
  /// (Not private: read from the `player_system.dart` extension.)
  static const Duration deviceResumeWindow = Duration(minutes: 10);

  bool _isPreloading = false;
  final List<Completer<void>> _mutationQueue = [];
  final List<StreamSubscription> _subscriptions = [];
  // Temporary stream-failure blocks (id → expiry). In memory only: "this track
  // wouldn't load, skip it for a few minutes", not a dislike, so they must never
  // survive a restart.
  final Map<String, DateTime> _failureBlocks = {};
  String? _lastProcessedSongId;
  String? _preloadedSongId;

  // Settle window for pre-warming. Warming the next track costs a stream lookup
  // and ~1 MB, so a newly changed "next" track must stay next briefly first; the
  // position tick calls the preloader about twice a second, so no timer is needed.
  String? _nextSettleId;
  DateTime? _nextSettleAt;
  int _consecutiveErrors = 0;
  // Consecutive tracks whose stream RESOLVE failed with no successful playback
  // in between. 3+ in a row is a network outage (Doze/radio-sleep DNS blackout:
  // every host lookup fails, so every queued track reads as "no playable
  // stream"), not three broken tracks — the queue must stop being eaten by
  // auto-skips. Reset on real audible progress (player_system onPosition).
  int _autoAdvanceFailStreak = 0;
  // Consecutive tracks whose self-heal hit the no-progress cap (fresh URLs keep
  // 403ing). ≥2 in a row = a googlevideo CDN/IP GATE storm (Samsung Wi-Fi flap
  // under Doze), not per-track rot, so hold + back off instead of cascade-
  // skipping the whole queue. Reset on real audible progress (onPosition).
  int _gateFailStreak = 0;
  // Retry armed by the last recoverable playback error; the connectivity
  // listener fires it the moment the network returns instead of letting it
  // wait out its backoff timer.
  void Function()? _pendingNetworkRetry;
  // Timestamp of the previous playSong request — drives the ADAPTIVE transition
  // debounce (a lone tap / natural track end starts instantly; only a rapid
  // skip-storm coalesces behind a short delay).
  DateTime? _lastPlayRequestAt;
  // The autoplay refill in flight, shared so the emergency path in playNext can
  // await it instead of giving up with an empty queue.
  Future<void>? _refillInFlight;
  // Throttles how often the high-frequency native position tick is folded into
  // the full PlayerState. The live position drives the UI via
  // currentPositionProvider (a ValueListenable), so PlayerState.position only
  // needs to be "recent enough" for save/resume — writing it every tick
  // rebuilt every ref.watch(playerProvider) consumer ~2×/sec for nothing.
  int _lastPosStateWriteMs = 0;
  // A seek in flight. Native keeps reporting a few pre-seek positions while it
  // re-buffers; seek() shows the target immediately and onPosition ignores stale
  // ticks until the clock lands near it (or a failsafe passes).
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekAt;
  StreamSubscription? _connectivitySubscription;

  // Podcast sponsor auto-skip
  // Ad ranges (`[startMs, endMs]`) for the playing episode, resolved once when it
  // starts rather than per position tick. Only ranges the SHOW ITSELF labelled as
  // a sponsor break land here. See PodcastExtrasService, so this never guesses
  // at dynamically-inserted ads it cannot see.
  List<List<int>> _adSkipRanges = const [];
  // Which episode the ranges belong to, so a tick for the NEXT episode can never
  // be measured against the previous one's breaks.
  String? _adRangesForSongId;
  // Breaks already auto-skipped. If the listener deliberately scrubs back into
  // one, it must not be yanked forward again.
  final Set<int> _adSkipsDone = {};

  // Controllers
  AudioHandler? _audioHandler;
  AudioSession? _audioSession;
  Timer? _persistenceTimer;
  Timer? _queueSyncTimer;
  Timer? _refillDebounce;
  Timer? _cacheTimer;
  // Songs already tried for background auto-cache this session (success or
  // failure), so a failed auto-cache isn't re-downloaded on every pause/resume.
  final Set<String> _autoCacheAttempted = {};
  Timer? _cacheCleanupTimer;
  Timer? _preloadTimer;
  Timer? _recoveryTimer;
  Timer? _sleepTimer; // armed by setSleepTimer (player_system.dart)
  /// Fires shortly BEFORE _sleepTimer to start the volume ramp-down.
  Timer? _sleepFadeTimer;
  /// The fade ramp, once _sleepFadeTimer has fired: one cancellable timer, so
  /// cancelling or re-arming the sleep timer stops the old ramp. See
  /// _startSleepFadeOut.
  Timer? _sleepFadeRamp;
  // LISTEN-THRESHOLD play crediting: true once the CURRENT track has been
  // counted as a real "play" (heard past the threshold in the position handler).
  // Reset to false as each new track loads (player_playback.playSong), so a
  // track only ever credits once per play and tap-then-skip credits nothing.
  bool _currentPlayRecorded = false;

  // Which song the NATIVE engine currently holds a media item for, or null when
  // it holds nothing. Dart state and the engine are NOT the same thing: a cold
  // start restores `currentSong` + the mini-player from prefs WITHOUT loading
  // anything natively, so `resume()` at that point is a no-op on an empty
  // ExoPlayer. togglePlay consults this to decide resume-vs-load.
  String? _nativeLoadedSongId;

  // videoId → the track's measured loudness in dB, captured from YouTube's
  // `playerConfig.audioConfig` during stream resolution (the only place it is
  // exposed). Feeds volume normalization; bounded so it can't grow unbounded.
  final Map<String, double> _loudnessByVideoId = {};

  /// The data-saver flag each track was RESOLVED under, so a mid-track
  /// re-resolve asks for the same format even if the network changed underneath
  /// it. See the note in the resolver for what happens without this.
  ///
  /// Bounded the same way as [_loudnessByVideoId]: a listening session can touch
  /// thousands of ids and none of them matter once the track is over.
  final Map<String, bool> _lowQualityPin = {};

  /// Where the adaptive bitrate ladder currently stands, read and advanced by
  /// `_refreshBitrateCeiling` in player_system.dart before every resolve. Declared
  /// here because extensions can't hold fields, and kept out of PlayerState because
  /// nothing renders it and it would rebuild every listener on each resolve.
  BitrateDecision bitrateDecision = const BitrateDecision();

  PlayerState get currentState => state;
  set currentState(PlayerState newState) => state = newState;
  PlayerNotifier(
    this.ref, this._searchService, 
    this._audioService, this._cacheManager, this._lyricsService,
  ) : super(PlayerState()) {
    _errorHandler = PlaybackErrorHandler();
    // BEFORE every other init. The first native call happens inside these,
    // and if this engine has no native player that call is the one that must
    // trigger the teardown. See _onNativePlatformLost.
    NativeAudioEngine.onPlatformLost = _onNativePlatformLost;
    _probeNativePlatform();
    _initMediaControls();
    _initAudioSession();
    _initPlayer();
    _initPersistence();
    _startQueueSyncVerification();
    _startCacheCleanup();
    // Carry what is playing to the account's other devices, and take theirs.
    CloudSyncService.handoffSnapshot = _handoffSnapshotHook = _handoffSnapshot;
    CloudSyncService.onHandoff = _receiveHandoffHook = _receiveHandoff;
    // A pause is worth a push (it goes up when the app is left), so another
    // device opened later starts from where this one stopped, not from a guess.
    addListener((s) {
      if (_wasPlayingForHandoff && !s.isPlaying && s.currentSong != null) {
        CloudSyncService.instance.scheduleBackup(urgency: BackupUrgency.listening);
      }
      _wasPlayingForHandoff = s.isPlaying;
    }, fireImmediately: false);
  }

  /// Swaps in refetched metadata for a track without touching playback. [fresh]
  /// has the same id (see `mergeRefetched`), so only descriptive fields change in
  /// state and in the notification's MediaItem; audio, position and queue order are
  /// untouched. Every queue list is updated (`queue`, `originalQueue` and the three
  /// lanes), or the old cover would come back when the queue is rebuilt.
  void applyRefreshedMetadata(Song fresh) {
    final id = fresh.id;
    if (id.isEmpty) return;
    List<Song> swap(List<Song> list) {
      if (!list.any((s) => s.id == id)) return list;
      return list.map((s) => s.id == id ? fresh : s).toList();
    }

    final isCurrent = currentState.currentSong?.id == id;
    currentState = currentState.copyWith(
      currentSong: isCurrent ? fresh : currentState.currentSong,
      queue: swap(currentState.queue),
      originalQueue: swap(currentState.originalQueue),
      history: swap(currentState.history),
      userQueue: swap(currentState.userQueue),
      contextQueue: swap(currentState.contextQueue),
      autoplayQueue: swap(currentState.autoplayQueue),
    );
    // The lockscreen/notification holds its own copy of the artwork and title.
    if (isCurrent) _updateMediaItem(fresh);
  }

  Future<void> _lockMutation(Future<void> Function() action) async {
    final completer = Completer<void>();
    _mutationQueue.add(completer);
    if (!_isProcessingMutation) _processNextMutation();
    return completer.future.then((_) => action());
  }

  void _processNextMutation() async {
    if (_mutationQueue.isEmpty) {
      _isProcessingMutation = false;
      return;
    }
    _isProcessingMutation = true;
    final next = _mutationQueue.removeAt(0);
    next.complete();
  }

  Future<void> cycleShuffleMode() async {
    final bool isSmartNow = ref.read(smartShuffleModeProvider);

    if (!state.isShuffle && !isSmartNow) {
      // Off → normal shuffle
      ref.read(smartShuffleModeProvider.notifier).state = false;
      toggleShuffle(); // player_queue.dart — modifies ConcatenatingAudioSource in place, no restart

    } else if (state.isShuffle && !isSmartNow) {
      // Normal → smart shuffle
      ref.read(smartShuffleModeProvider.notifier).state = true;
      if (state.contextQueue.isNotEmpty || state.autoplayQueue.isNotEmpty) {
        final smartCtx  = _smartShuffle(List.from(state.contextQueue));
        final smartAuto = _smartShuffle(List.from(state.autoplayQueue));
        final newFull = [
          if (state.currentSong != null) state.currentSong!,
          ...state.userQueue, ...smartCtx, ...smartAuto,
        ];
        currentState = state.copyWith(
          contextQueue: smartCtx, autoplayQueue: smartAuto, queue: newFull,
        );
        Future.microtask(() => _updateAudioPlayerQueue(newFull, 0, updateCurrentTrack: false));
        // Part 2 of what makes it SMART: weave in fresh recommendations
        // (normal shuffle only reorders; smart shuffle also ADDS tracks).
        _injectSmartShuffleRecs();
      }

    } else {
      // SMART (or any active) → OFF
      ref.read(smartShuffleModeProvider.notifier).state = false;
      // Forget which rows were suggestions. The tracks themselves STAY (they are
      // in the queue and may already have been played); only the label goes, since
      // "suggested by smart shuffle" stops being true once the mode is off.
      ref.read(smartShuffleInjectedProvider.notifier).state = {};
      if (state.isShuffle) toggleShuffle(); // restores original order
    }

    _saveSettings();
  }

  /// Smart shuffle, part 2: besides interleaving artists, fetch a few taste
  /// recommendations and weave one in after roughly every 4 upcoming tracks, so
  /// smart shuffle adds tracks you'll probably like rather than only reordering.
  /// Turning shuffle off restores the original snapshot, dropping them again.
  Future<void> _injectSmartShuffleRecs() async {
    try {
      if (!ref.read(smartShuffleModeProvider)) return;
      if (ref.read(connectivityProvider).isOffline) return;

      // Weave into the context queue when it has room, else the autoplay tail.
      final bool useCtx = state.contextQueue.length >= 4;
      if (!useCtx && state.autoplayQueue.length < 4) return; // nothing to weave into

      final taste = ref.read(intelligenceProvider);
      final intelNotifier = ref.read(intelligenceProvider.notifier);
      final baseLen = useCtx ? state.contextQueue.length : state.autoplayQueue.length;
      final wanted = (baseLen ~/ 4).clamp(2, 8);
      final candidates = await _generateSeededRecommendations(
        seedCount: wanted * 2,
        taste: taste,
        intelNotifier: intelNotifier,
      );
      // Mode toggled off (or queue replaced) while we were fetching → discard.
      if (!ref.read(smartShuffleModeProvider) || !state.isShuffle) return;

      String sig(Song s) => '${s.title.toLowerCase()}_${s.artist.toLowerCase()}';
      final existingIds = {
        if (state.currentSong != null) state.currentSong!.id,
        ...state.queue.map((s) => s.id),
        ...state.blacklistedIds,
      };
      final existingSigs = {...state.queue.map(sig)};
      final picks = <Song>[];
      for (final c in candidates) {
        if (existingIds.contains(c.id) || existingSigs.contains(sig(c))) continue;
        picks.add(c);
        existingIds.add(c.id);
        existingSigs.add(sig(c));
        if (picks.length >= wanted) break;
      }
      if (picks.isEmpty) return;

      final base = useCtx ? state.contextQueue : state.autoplayQueue;
      final woven = <Song>[];
      var pi = 0;
      for (var i = 0; i < base.length; i++) {
        woven.add(base[i]);
        if ((i + 1) % 4 == 0 && pi < picks.length) woven.add(picks[pi++]);
      }
      while (pi < picks.length) {
        woven.add(picks[pi++]);
      }

      final newCtx = useCtx ? woven : state.contextQueue;
      final newAuto = useCtx ? state.autoplayQueue : woven;
      final newFull = [
        if (state.currentSong != null) state.currentSong!,
        ...state.userQueue, ...newCtx, ...newAuto,
      ];
      currentState = state.copyWith(
        contextQueue: newCtx, autoplayQueue: newAuto, queue: newFull,
      );
      // Remember WHICH tracks were suggestions, so the queue can label them.
      ref.read(smartShuffleInjectedProvider.notifier).state = {
        ...ref.read(smartShuffleInjectedProvider),
        ...picks.map((s) => s.id),
      };
      Future.microtask(() => _updateAudioPlayerQueue(newFull, 0, updateCurrentTrack: false));
      print('Smart shuffle wove ${picks.length} recommendation(s) into the queue');
    } catch (e) {
      print('WARN: Smart shuffle injection failed: $e');
    }
  }

  /// Mirrors a Listen Together host's queue onto this device.
  ///
  /// Dart state only; this must not reach the native player. The host decides what
  /// plays (the room document drives that), and pushing the queue to the engine
  /// would have every guest advancing on its own clock.
  ///
  /// The three lanes are mirrored separately, not flattened, because the queue
  /// sheet builds its sections and drag targets from them; this keeps both devices
  /// structurally identical.
  void adoptRemoteQueue({
    required List<Song> userQueue,
    required List<Song> contextQueue,
    required List<Song> autoplayQueue,
    String? contextTitle,
  }) {
    final cur = state.currentSong;
    final full = <Song>[
      if (cur != null) cur,
      ...userQueue,
      ...contextQueue,
      ...autoplayQueue,
    ];
    if (full.isEmpty) return;
    state = state.copyWith(
      queue: full,
      originalQueue: full,
      userQueue: userQueue,
      contextQueue: contextQueue,
      autoplayQueue: autoplayQueue,
      userQueueEndIndex: userQueue.length,
      // The current track is always first in a mirrored queue, so played tracks
      // can never leak into the upcoming list the way they did when the flat
      // slice carried them.
      currentIndex: 0,
      contextTitle: contextTitle,
    );
  }

  @override
  void dispose() {
    // Static hooks, so they must not outlive this notifier.
    if (identical(CloudSyncService.handoffSnapshot, _handoffSnapshotHook)) {
      CloudSyncService.handoffSnapshot = null;
    }
    if (identical(CloudSyncService.onHandoff, _receiveHandoffHook)) {
      CloudSyncService.onHandoff = null;
    }
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _playDebounceTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    _connectivitySubscription?.cancel();
    _preloadTimer?.cancel();
    _recoveryTimer?.cancel();
    _queueSyncTimer?.cancel(); 
    _persistenceTimer?.cancel();
    _cacheTimer?.cancel(); 
    _fetchDebounceTimer?.cancel();
    _lyricsDwellTimer?.cancel();
    _positionTicker?.cancel();
    _inactivityTimer?.cancel();
    _refillDebounce?.cancel();
    // Both fire a state write; left running they'd touch a disposed notifier.
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    // The ramp writes to the audio engine on a 250ms tick; a periodic timer left
    // running past dispose keeps doing that forever.
    _sleepFadeRamp?.cancel();
    _stallTimer?.cancel();
    _stallTimer = null;
    _audioSession?.setActive(false);
    // The handler's own stop, not the deprecated AudioService.stop() global —
    // that one routes through a compatibility shim to the same place.
    _audioHandler?.stop();
    NativeAudioEngine.clearListeners();
    super.dispose();
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>((ref) {
  return PlayerNotifier(
    ref, 
    ref.read(searchServiceProvider),
    auvy_audio.AudioService(), 
    AudioCacheManager(), 
    LyricsService(),
  );
});