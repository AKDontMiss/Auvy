import 'dart:async';
// cos/sin/pi are for the equal-power volume ramp. See _rampVolume.
import 'dart:math' show Random, min, max, pow, cos, sin, pi;
import 'dart:convert';
import 'package:auvy/logic/media_kind.dart';
// File — the wake-up alarm pre-caches one track to disk (prepareAlarmTrack).
import 'dart:io' show File;
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
import 'package:auvy/logic/adaptive_bitrate.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/core/image_cache_manager.dart';
import 'package:auvy/services/http_pool.dart';

// Declare the parts
part '../logic/player_playback.dart';
part '../logic/player_queue.dart';
part '../logic/player_system.dart';
part '../logic/player_smart.dart';

enum RepeatMode { off, all, one }
enum AudioQuality { low, medium, high, auto }
final audioIntensityProvider = ValueNotifier<double>(0.0);
final currentPositionProvider = ValueNotifier<Duration>(Duration.zero);

/// Live radio: how far behind the live edge the listener is
///
/// A live stream has no timeline to scrub, so "LIVE" was shown unconditionally —
/// including while PAUSED, which is the one moment it is certainly not true.
///
/// Pausing a live stream and resuming leaves you behind whatever you missed, so
/// the gap is tracked explicitly: it grows while paused, then holds steady once
/// playing again (both the stream and the listener advance at 1×, so the offset
/// cannot shrink on its own — only rejoining the live edge clears it).
///
/// Whether audio actually RESUMES from the pause point is a property of the
/// stream, not of this value: an HLS stream with a DVR window can, a plain
/// ICY/MP3 stream cannot and the engine rejoins at the live edge. So treat this
/// as "how much has aired since you paused", which is exactly what the
/// "GO LIVE" action discards.
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

  /// True while playback is STUCK buffering, not merely starting.
  ///
  /// SEPARATE FROM [isLoading] ON PURPose. isLoading covers "a new track is
  /// being set up", which is expected and brief. This one means "we are playing,
  /// and no audio is coming out" — a mid-load or mid-track stall, typically a
  /// googlevideo URL dying because the network path moved. Without it the UI
  /// showed a playing track making no sound, which reads as a broken app.
  ///
  /// Only set after the stall has PERSISTED (see the onBuffering listener), so an
  /// ordinary track start never trips it.
  final bool isStalled;
  final Song? currentSong;
  final Duration position, duration;
  final List<Song> queue, originalQueue, history;
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
  /// Sleep at END OF TRACK: when true, playback pauses when the current track
  /// finishes instead of advancing the queue. Session-only, like the timer.
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
    List<Song>? history, bool? isShuffle, RepeatMode? repeatMode, double? volume, double? swipeProgress,
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
      recentlyAttemptedPreloads: recentlyAttemptedPreloads ?? this.recentlyAttemptedPreloads, //  4. UPDATE THIS
      userQueue: userQueue ?? this.userQueue,
      contextQueue: contextQueue ?? this.contextQueue,
      autoplayQueue: autoplayQueue ?? this.autoplayQueue,
      userQueueEndIndex: userQueueEndIndex ?? this.userQueueEndIndex,
      originalQueue: originalQueue ?? this.originalQueue, 
      currentIndex: currentIndex ?? this.currentIndex, 
      history: history ?? this.history, 
      isShuffle: isShuffle ?? this.isShuffle, 
      repeatMode: repeatMode ?? this.repeatMode,
      swipeProgress: swipeProgress ?? this.swipeProgress,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      podcastSpeed: podcastSpeed ?? this.podcastSpeed,
      locationName: locationName ?? this.locationName,
      playbackSource: playbackSource ?? this.playbackSource,
      // [clearContext] EXISTS BECAUSE `?? this.x` CANNOT SET THESE BACK TO NULL,
      // And that made the playback context stick forever.
      //
      // Playing a track from Search, Quick Picks or a radio row passes no
      // context, which reads here as "leave it alone", so the album or playlist
      // the user had played BEFORE stayed recorded as the current context. The
      // home mosaic lights a collection tile when that collection is the context,
      // so an unrelated playlist kept showing the playing animation alongside the
      // track actually playing. Anything else keyed on context inherited the same
      // stale value.
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
    );
  }

  List<Song> get fullQueue => queue; 
  double get progress => duration.inMilliseconds == 0 ? 0.0 : position.inMilliseconds / duration.inMilliseconds;
}

final lastRemovedItemProvider = StateProvider<RemovedQueueItem?>((ref) => null);
final smartShuffleModeProvider = StateProvider<bool>((ref) => false);

/// Ids that SMART SHUFFLE added to the queue, so the queue sheet can mark them.
///
/// Without this the feature was invisible: it wove recommendations between the
/// user's own tracks and nothing said which were which, so an unfamiliar song
/// looked like the app had gone wrong rather than like a suggestion. Spotify
/// badges its Smart Shuffle insertions for exactly this reason — a suggestion you
/// can't identify is indistinguishable from a bug.
///
/// Cleared when smart shuffle is switched off; entries for tracks that leave the
/// queue are harmless (the badge is only read for rows that exist).
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

  /// How long a device-loss pause stays eligible for auto-resume. Reconnecting
  /// within a few minutes is the same listening session; reconnecting the next
  /// morning is not, and starting music then would be exactly the surprise this
  /// whole mechanism is meant to avoid.
  /// (Not private: read from the `player_system.dart` extension.)
  static const Duration deviceResumeWindow = Duration(minutes: 10);

  bool _isPreloading = false;
  final List<Completer<void>> _mutationQueue = [];
  final List<StreamSubscription> _subscriptions = [];
  // Transient stream-failure blocks (id → expiry). IN-MEMORY ONLY — these are
  // "this track wouldn't load, skip it for a few minutes" markers, NOT user
  // dislikes. They used to be written into the PERSISTED blacklist: if the app
  // closed before the 5-minute un-block timer fired, the track stayed
  // blacklisted forever and playSong() silently skipped it every time after —
  // the "auto-skips a track out of nowhere" bug.
  final Map<String, DateTime> _failureBlocks = {};
  String? _lastProcessedSongId;
  String? _preloadedSongId;

  // Prewarm settle window
  //
  // Pre-warming the next track resolves its stream AND pulls its opening ~1MB.
  // That is worth paying once for the track you are about to hear, and pure waste
  // for one you skip past. Observed live: three skips in nine seconds cost three
  // resolves and three pre-pulls, of which two were for tracks that never played.
  //
  // So a CHANGED next-track has to hold still briefly before it is warmed. The
  // position tick calls the preloader about twice a second, which is what advances
  // this — no timer needed.
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
  // The autoplay refill currently in flight, shared so the emergency path in
  // playNext can AWAIT the same refill instead of no-oping against a flag and
  // then giving up with the queue still empty (playback used to just stop).
  Future<void>? _refillInFlight;
  // Throttles how often the high-frequency native position tick is folded into
  // the full PlayerState. The live position drives the UI via
  // currentPositionProvider (a ValueListenable), so PlayerState.position only
  // needs to be "recent enough" for save/resume — writing it every tick
  // rebuilt every ref.watch(playerProvider) consumer ~2×/sec for nothing.
  int _lastPosStateWriteMs = 0;
  // A manual seek in flight. The native engine keeps reporting a few positions
  // from BEFORE the jump while ExoPlayer re-buffers; without this the progress
  // bar snapped back to the old spot for a beat and then leapt forward (the
  // "slider glitches back then jumps" bug). seek() sets these and shows the
  // target optimistically; onPosition ignores stale ticks until the engine's
  // clock lands near the target (or the failsafe window passes).
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
  // Songs we've already attempted to background auto-cache this session (success
  // OR fail). Guards against the redownload loop: a track whose auto-cache failed
  // used to stay isCached=false, so every pause/resume re-armed the 10s timer and
  // re-downloaded it from scratch — draining data on a repeating progress bar.
  final Set<String> _autoCacheAttempted = {};
  Timer? _cacheCleanupTimer;
  Timer? _preloadTimer;
  Timer? _recoveryTimer;
  Timer? _sleepTimer; // armed by setSleepTimer (player_system.dart)
  /// Fires shortly BEFORE _sleepTimer to start the volume ramp-down.
  Timer? _sleepFadeTimer;
  /// The ramp itself, once _sleepFadeTimer has fired.
  ///
  /// ONE CANCELLABLE TIMER, ON PURPOSE. The ramp used to be twenty bare
  /// `Timer`s that nobody held a reference to, so nothing could stop them:
  /// cancelling the sleep timer and arming a new one left the OLD ramp still
  /// running, and because its bail-out test was only "is a sleep timer armed?"
  /// the freshly-armed one satisfied it, so a two-hour timer faded itself to
  /// near-silence inside the first twenty seconds. See _startSleepFadeOut.
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

  /// Where the adaptive bitrate ladder currently stands. Read and advanced by
  /// `_refreshBitrateCeiling` in player_system.dart before every resolve.
  ///
  /// Declared HERE rather than beside that method because player_system.dart is
  /// an extension, and extensions cannot hold instance fields.
  ///
  /// Deliberately not part of PlayerState: it is a transport detail nothing
  /// renders, and putting it in state would rebuild every listening widget on
  /// each resolve.
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
  }

  /// Swap in freshly-refetched metadata for a track WITHOUT touching playback.
  ///
  /// NOTHING RESTARTS, AND THE ID NEVER MOVES. A refetch corrects what a track
  /// SAYS about itself — cover, title, artist, album, and [fresh] carries the same
  /// id by construction (see `mergeRefetched`). So this only rewrites descriptive
  /// fields in state and refreshes the notification's MediaItem; the audio, the
  /// position and the queue order are untouched.
  ///
  /// Every queue list is covered, not just the visible one. `queue` is what the UI
  /// shows, but `originalQueue` is what un-shuffling restores and
  /// `userQueue`/`contextQueue`/`autoplayQueue` are what the next track comes from
  /// — a refetch that fixed only the visible copy would let the old cover walk
  /// straight back in the moment the queue was rebuilt.
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

  void updateContext({
    String? contextId,
    String? contextType,
    String? contextTitle,
  }) {
    currentState = currentState.copyWith(
      contextId: contextId,
      contextType: contextType,
      contextTitle: contextTitle,
    );
    _saveSettings();
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

  /// SMART SHUFFLE, part 2: besides the artist interleave, fetch a few taste
  /// recommendations and weave one in after every ~4 upcoming tracks. This is
  /// the Spotify-style distinction the mode is named for — normal shuffle
  /// reorders the tracks you have, smart shuffle also ADDS tracks you'll
  /// probably like. Turning shuffle off restores the original snapshot, which
  /// drops the injected tracks again.
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

  /// Mirror a Listen Together host's queue onto this device.
  ///
  /// DISPLAY AND MUTATION ONLY — THIS MUST NOT REACH THE NATIVE ENGINE.
  /// The host stays the authority for what actually plays (the room document
  /// drives that), so this writes Dart state only. Pushing a mirrored queue into
  /// the engine would have every guest auto-advancing on its own clock and
  /// fighting the host.
  ///
  /// The three buckets are mirrored separately, NOT flattened.
  ///
  /// A first version assigned the whole queue to contextQueue and emptied the
  /// other two. The queue sheet builds its sections and its drag targets from
  /// these buckets, so the listener saw the same tracks under the wrong heading
  /// ("Playing From" where the host said "Autoplay") and reordering computed a
  /// different drop index than the host would — reported as the sheet behaving
  /// oddly. Keeping the buckets keeps both devices structurally identical.
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
    _audioSession?.setActive(false);
    // The handler's own stop, not the deprecated AudioService.stop() global —
    // that one routes through a compatibility shim to the same place.
    _audioHandler?.stop();
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