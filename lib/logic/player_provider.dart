import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/audio_service.dart';
import 'package:auvy/logic/search_service.dart';

// Defines the available repetition modes for playback.
enum LoopMode { off, all, one }

// State model for the music player tracking playback details, queue, and settings.
class PlayerState {
  final bool isPlaying, isLoading, isShuffle,isManualMode;
  final Song? currentSong;
  final Duration position, duration;
  final List<Song> queue, originalQueue, history;
  final int currentIndex;
  final LoopMode loopMode;
  final double volume, speed, audioIntensity;
  final String playbackSource;

  PlayerState({
    this.isPlaying = false, this.currentSong, this.position = Duration.zero, this.duration = Duration.zero,
    this.isLoading = false, this.queue = const [], this.originalQueue = const [], this.currentIndex = -1,
    this.history = const [], this.isShuffle = false, this.loopMode = LoopMode.off, this.volume = 1.0,
    this.speed = 1.0, this.playbackSource = "Unknown", this.audioIntensity = 0.0,
    this.isManualMode = false, 
  });

  // Returns a copy of the player state with modified fields.
  PlayerState copyWith({ bool? isPlaying, Song? currentSong, Duration? position, Duration? duration, bool? isLoading, List<Song>? queue, List<Song>? originalQueue, int? currentIndex, List<Song>? history, bool? isShuffle, LoopMode? loopMode, double? volume, double? speed, String? playbackSource, double? audioIntensity, bool? isManualMode }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying, 
      currentSong: currentSong ?? this.currentSong, 
      position: position ?? this.position, 
      duration: duration ?? this.duration, 
      isLoading: isLoading ?? this.isLoading, 
      queue: queue ?? this.queue, 
      originalQueue: originalQueue ?? this.originalQueue, 
      currentIndex: currentIndex ?? this.currentIndex, 
      history: history ?? this.history, 
      isShuffle: isShuffle ?? this.isShuffle, 
      loopMode: loopMode ?? this.loopMode, 
      volume: volume ?? this.volume, 
      speed: speed ?? this.speed, 
      playbackSource: playbackSource ?? this.playbackSource, 
      audioIntensity: audioIntensity ?? this.audioIntensity,
      isManualMode: isManualMode ?? this.isManualMode, 
    );
  }
  
  // Calculates the current playback progress as a percentage.
  double get progress => duration.inMilliseconds == 0 ? 0.0 : position.inMilliseconds / duration.inMilliseconds;
}

// Controller that manages audio playback logic, queueing, and persistence.
class PlayerNotifier extends StateNotifier<PlayerState> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final SearchService _searchService = SearchService();
  final AudioService _audioService = AudioService();
  Timer? _intensityTimer;
  final Random _random = Random();
  bool _isResolvingCurrent = false; 
  bool _isPreloading = false;
  int _retryCount = 0;
  
  PlayerNotifier() : super(PlayerState()) {
    _initPersistence();

    // Listens for playback events to handle buffering and errors.
    _audioPlayer.playbackEventStream.listen((event) {
      if (event.processingState == ProcessingState.buffering && state.isPlaying) {
        print("⚠️ Buffer underrun detected, attempting recovery...");
      }
    }, onError: (Object e, StackTrace st) {
      if (state.currentSong != null && _retryCount < 3) {
         _retryCount++;
         final currentPos = _audioPlayer.position;
         _loadAndPlay(state.currentSong!, startFrom: currentPos);
      }
    });

    // Updates state based on the current track position and manages preloading/recovery.
    _audioPlayer.positionStream.listen((pos) { 
      state = state.copyWith(position: pos); 
      if (state.progress > 0.8 && !_isPreloading) _preloadNext(); 
      
      // Proactive recovery integrated: attempt fix if buffer is critically low
      if (state.isPlaying && _audioPlayer.bufferedPosition.inSeconds - pos.inSeconds < 5) {
        _proactiveRecovery();
      }
    });

    _audioPlayer.durationStream.listen((dur) => state = state.copyWith(duration: dur ?? Duration.zero));

    // Handles automatic song transitions and visual intensity updates.
    _audioPlayer.playerStateStream.listen((ps) {
        bool loading = ps.processingState == ProcessingState.buffering || ps.processingState == ProcessingState.loading;
        state = state.copyWith(isPlaying: ps.playing, isLoading: loading);
        if (ps.playing) _startIntensityTracking(); else _stopIntensityTracking();
        
        if (ps.processingState == ProcessingState.completed) playNext(autoAdvance: true);
    });
  }

  // Attempt to recover playback seamlessly if a network stream fails or buffers excessively.
  Future<void> _proactiveRecovery() async {
    if (state.currentSong == null || _isResolvingCurrent) return;
    
    _isResolvingCurrent = true;
    print("🔍 Buffer critical. Attempting proactive fix...");

    final stream = await _audioService.getStreamInfo(
      state.currentSong!.title, 
      state.currentSong!.artist, 
      songId: state.currentSong!.id
    );

    if (stream != null && mounted) {
      final currentPos = _audioPlayer.position;
      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.parse(stream['url']!), headers: {'User-Agent': stream['user_agent']!}),
        initialPosition: currentPos, 
        preload: true
      );
    }
    _isResolvingCurrent = false;
  }

  // Restores player settings and queue from shared preferences.
  Future<void> _initPersistence() async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getString('auvy_history');
    final queueJson = prefs.getString('auvy_queue');
    final originalQueueJson = prefs.getString('auvy_original_queue'); 
    final currentSongJson = prefs.getString('auvy_current_song');
    final savedPositionMs = prefs.getInt('auvy_position') ?? 0;
    final shuffle = prefs.getBool('auvy_shuffle') ?? false;
    final loopIdx = prefs.getInt('auvy_loop') ?? 0;
    final vol = prefs.getDouble('auvy_volume') ?? 1.0;
    final manual = prefs.getBool('auvy_manual_mode') ?? false;

    List<Song> history = historyJson != null ? (jsonDecode(historyJson) as List).map((s) => Song.fromMap(s)).toList() : [];
    List<Song> queue = queueJson != null ? (jsonDecode(queueJson) as List).map((s) => Song.fromMap(s)).toList() : [];
    List<Song> originalQueue = originalQueueJson != null ? (jsonDecode(originalQueueJson) as List).map((s) => Song.fromMap(s)).toList() : queue; 
    Song? current = currentSongJson != null ? Song.fromMap(jsonDecode(currentSongJson)) : null;

    int currentIndex = (current != null) ? queue.indexWhere((s) => s.id == current!.id) : -1;

    state = state.copyWith(
      history: history,
      queue: queue,
      originalQueue: originalQueue,
      currentSong: current,
      currentIndex: currentIndex,
      position: Duration(milliseconds: savedPositionMs),
      isShuffle: shuffle,
      loopMode: LoopMode.values[loopIdx],
      isManualMode: manual,
      volume: vol
    );

    _audioPlayer.setVolume(vol);
    if (current != null) { _loadAndPlay(current, startFrom: Duration(milliseconds: savedPositionMs), playImmediately: false); }
  }

  // Persists the current queue, history, and user preferences to disk.
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auvy_history', jsonEncode(state.history.take(50).map((s) => s.toMap()).toList()));
    await prefs.setString('auvy_queue', jsonEncode(state.queue.map((s) => s.toMap()).toList()));
    await prefs.setString('auvy_original_queue', jsonEncode(state.originalQueue.map((s) => s.toMap()).toList())); 
    await prefs.setBool('auvy_manual_mode', state.isManualMode); 
    if (state.currentSong != null) {
      await prefs.setString('auvy_current_song', jsonEncode(state.currentSong!.toMap()));
    }
    await prefs.setInt('auvy_position', state.position.inMilliseconds);
    await prefs.setBool('auvy_shuffle', state.isShuffle);
    await prefs.setInt('auvy_loop', state.loopMode.index);
    await prefs.setDouble('auvy_volume', state.volume);
  }

  // Pre-resolves the stream URL for the next song in the queue for faster loading.
  Future<void> _preloadNext() async { 
    final nextIdx = state.currentIndex + 1; 
    if (nextIdx < state.queue.length) { 
      _isPreloading = true; 
      await _audioService.getStreamInfo(state.queue[nextIdx].title, state.queue[nextIdx].artist, songId: state.queue[nextIdx].id); 
    } 
  }
  
  // Starts a periodic timer to simulate audio intensity for visualizers.
  void _startIntensityTracking() { _intensityTimer?.cancel(); _intensityTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) { if (state.isPlaying) state = state.copyWith(audioIntensity: ((0.3 + (sin(DateTime.now().millisecondsSinceEpoch / 200) * 0.2)) + _random.nextDouble() * 0.5) * state.volume); }); }
  
  // Stops the visualizer intensity tracking.
  void _stopIntensityTracking() { _intensityTimer?.cancel(); state = state.copyWith(audioIntensity: 0.0); }
  
  // Automatically adds related tracks to the queue if discovery is enabled and the queue is short.
  Future<void> _topUpQueue() async {
    if (state.currentSong == null) return;
    if (state.loopMode != LoopMode.off || state.isManualMode) return;

    int upcomingCount = state.queue.length - (state.currentIndex + 1);
    if (upcomingCount >= 10) return;

    int needed = 10 - upcomingCount;

    try {
      final results = await _searchService.search(state.currentSong!.artist, 'track');
      final existingIds = state.queue.map((s) => s.id).toSet();
      final newTracks = results.where((s) => !existingIds.contains(s.id)).take(needed).toList();

      if (newTracks.isNotEmpty) {
        state = state.copyWith(
          queue: [...state.queue, ...newTracks],
          originalQueue: [...state.originalQueue, ...newTracks], 
        );
        _saveSettings();
      }
    } catch (_) {}
  }

  // Toggles between manual queue control and automatic discovery mode.
  void toggleManualMode() {
    final nextMode = !state.isManualMode;
    
    if (nextMode) {
      final currentList = state.currentSong != null ? [state.currentSong!] : <Song>[];
      state = state.copyWith(
        isManualMode: true,
        queue: currentList,
        currentIndex: 0,
      );
    } else {
      state = state.copyWith(isManualMode: false);
      _topUpQueue();
    }
    
    _saveSettings();
  }

  // Appends a list of songs to the end of the current queue.
  void addListToQueue(List<Song> songs) { 
    if (songs.isEmpty) return; 
    if (state.queue.isEmpty) playSong(songs.first, newQueue: songs, source: "Queue"); 
    else {
      state = state.copyWith(queue: [...state.queue, ...songs], originalQueue: [...state.originalQueue, ...songs]); 
      _topUpQueue(); 
    }
    _saveSettings(); 
  }
  
  // Toggles the presence of a song in the upcoming queue.
  bool toggleQueue(Song song) { 
    final futureStart = state.currentIndex + 1; 
    if (futureStart >= state.queue.length) { addToQueue(song); return true; } 
    final idx = state.queue.sublist(futureStart).indexWhere((s) => s.id == song.id); 
    if (idx != -1) { 
      final nq = List<Song>.from(state.queue); nq.removeAt(futureStart + idx); 
      state = state.copyWith(queue: nq); _saveSettings(); return false; 
    } else { addToQueue(song); return true; } 
  }

  // Adds a single song to the end of the queue.
  void addToQueue(Song song) { 
    if (state.queue.isEmpty) playSong(song, source: "Queue"); 
    else {
      state = state.copyWith(queue: [...state.queue, song], originalQueue: [...state.originalQueue, song]); 
      _topUpQueue();
    }
    _saveSettings(); 
  }
  
  // Reorders items in the upcoming section of the queue.
  void reorderQueue(int old, int neu) { 
    if (old < neu) neu -= 1; 
    final start = state.currentIndex + 1; 
    final rOld = start + old, rNeu = start + neu; 
    if (rOld >= state.queue.length || rNeu >= state.queue.length) return; 
    final nq = List<Song>.from(state.queue); final s = nq.removeAt(rOld); nq.insert(rNeu, s); 
    state = state.copyWith(queue: nq); 
    _saveSettings(); 
  }

  // Loads and plays a specific song, optionally updating the entire queue.
  Future<void> playSong(Song song, {List<Song>? newQueue, int? index, String source = "Unknown", bool playImmediately = true}) async { 
    List<Song> activeQueue = newQueue ?? (state.queue.isNotEmpty ? state.queue : [song]);
    int activeIndex = index ?? activeQueue.indexWhere((s) => s.id == song.id); 
    
    if (activeIndex == -1) { 
       activeIndex = state.currentIndex + 1;
       activeQueue = List.from(activeQueue)..insert(activeIndex, song);
    } 
    
    final history = List<Song>.from(state.history)..removeWhere((s) => s.id == song.id)..insert(0, song); 
    
    state = state.copyWith(
        currentSong: song, 
        isLoading: true, 
        queue: activeQueue, 
        originalQueue: List.from(activeQueue), 
        currentIndex: activeIndex, 
        history: history, 
        speed: 1.0, 
        playbackSource: source
    ); 

    _isPreloading = false; 
    _retryCount = 0;
    _audioPlayer.setSpeed(1.0); 
    _saveSettings();
    _topUpQueue();
    
    await _loadAndPlay(song, playImmediately: playImmediately); 
  }

  // Cycles through loop modes: off, repeat all, and repeat one.
  void cycleLoopMode() { 
    final nextMode = LoopMode.values[(state.loopMode.index + 1) % 3];
    state = state.copyWith(loopMode: nextMode); 
    if (nextMode == LoopMode.off) {
      _topUpQueue();
    }
    _saveSettings(); 
  }

  // Resolves the stream URL and begins playback for a specific track.
  Future<void> _loadAndPlay(Song song, {Duration? startFrom, bool playImmediately = true}) async { 
    try { 
      final stream = await _audioService.getStreamInfo(song.title, song.artist, songId: song.id); 
      if (stream != null) { 
        final source = AudioSource.uri(
          Uri.parse(stream['url']!), 
          headers: {
            'User-Agent': stream['user_agent']!, 
            'Referer': 'https://music.youtube.com/', 
            'Origin': 'https://music.youtube.com', 
            'Connection': 'keep-alive',
            'Range': 'bytes=0-'
          }
        ); 
        await _audioPlayer.setAudioSource(source, preload: true, initialPosition: startFrom ?? Duration.zero); 
        if (playImmediately) _audioPlayer.play(); 
      }
    } catch (_) { state = state.copyWith(isLoading: false); } 
  }

  // Advances to the next track in the queue, respecting loop settings.
  void playNext({bool autoAdvance = false}) { 
    if (autoAdvance && state.loopMode == LoopMode.one) { 
      _audioPlayer.seek(Duration.zero); 
      return; 
    } 
    
    if (state.queue.isEmpty) return; 

    if (state.loopMode == LoopMode.all) {
      final finishedSong = state.queue[state.currentIndex];
      final rotatedQueue = List<Song>.from(state.queue)
        ..removeAt(state.currentIndex)
        ..add(finishedSong);
      
      state = state.copyWith(queue: rotatedQueue);
      playSong(state.queue[state.currentIndex], index: state.currentIndex, source: state.playbackSource);
      return;
    }
    
    int next = state.currentIndex + 1; 
    if (next >= state.queue.length) { 
       _topUpQueue().then((_) {
          if (state.currentIndex + 1 < state.queue.length) {
            playNext(autoAdvance: autoAdvance);
          }
       });
       return; 
    } 
    
    playSong(state.queue[next], index: next, source: state.playbackSource); 
  }

  // Restarts the current track or moves to the previous track in the queue.
  void playPrevious() { 
    if (_audioPlayer.position.inSeconds > 5) _audioPlayer.seek(Duration.zero); 
    else { 
      int prev = state.currentIndex - 1; 
      if (prev >= 0) playSong(state.queue[prev], index: prev, source: state.playbackSource); 
    } 
  }

  // Shuffles the current queue or restores the original playback order.
  void toggleShuffle() { 
    final isTurningOff = state.isShuffle; 
    
    if (isTurningOff) {
      final originalList = List<Song>.from(state.originalQueue);
      final currentId = state.currentSong?.id;
      final newIndex = originalList.indexWhere((s) => s.id == currentId);
      
      state = state.copyWith(
        isShuffle: false,
        queue: originalList,
        currentIndex: newIndex != -1 ? newIndex : state.currentIndex,
      );
    } else {
      final List<Song> shuffledList = List<Song>.from(state.originalQueue)..shuffle();
      final currentSong = state.currentSong;
      if (currentSong != null) {
        shuffledList.removeWhere((s) => s.id == currentSong.id);
        shuffledList.insert(state.currentIndex, currentSong);
      }
      state = state.copyWith(isShuffle: true, queue: shuffledList);
    }
    _saveSettings(); 
  }

  // Controls playback status and player parameters.
  void togglePlay() { if (state.isPlaying) _audioPlayer.pause(); else _audioPlayer.play(); }
  void seek(dynamic val) { if (val is double) _audioPlayer.seek(Duration(milliseconds: (state.duration.inMilliseconds * val).round())); else if (val is Duration) _audioPlayer.seek(val); }
  void setSpeed(double s) { _audioPlayer.setSpeed(s); state = state.copyWith(speed: s); }
  void seekForward() { final p = state.position + const Duration(seconds: 5); if (p < state.duration) _audioPlayer.seek(p); else playNext(); }
  void seekBackward() => _audioPlayer.seek(state.position - const Duration(seconds: 5));
  void setVolume(double v) { _audioPlayer.setVolume(v); state = state.copyWith(volume: v); _saveSettings(); }

  @override void dispose() { _intensityTimer?.cancel(); _audioPlayer.dispose(); super.dispose(); }
}

// Global provider for the audio player logic.
final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>((ref) => PlayerNotifier());