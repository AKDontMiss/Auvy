// Playback control: play/pause, seeking, speed, loading a track, fades,
// repeat modes, audio effects, podcast bookmarks and live radio.
part of '../providers/player_provider.dart';

// When the play/pause haptic last fired. A stalling stream can flip play state
// many times a second; this throttles the haptic to one per 300 ms so the phone
// doesn't buzz constantly. Real taps are always further apart.
DateTime? _lastPlayPauseHapticAt;

// Bumped by every new volume ramp so an older ramp stops writing volumes.
// Without it two overlapping fades interleave their writes and the volume
// wobbles on a fast skip.
//
// Top-level because this file's members live in an extension, which cannot
// declare fields. Safe because there is only one player.
int _fadeGeneration = 0;

/// Resume bookmarks for podcast episodes and audiobook chapters (JSON map of
/// idHash → position). The key still says "podcast" because renaming it would
/// lose every bookmark already saved on a device.
const String _podcastPositionsKey = 'auvy_podcast_positions';

extension PlayerPlaybackController on PlayerNotifier {

  /// [haptic] is false for automatic play/pause (headphone unplug, interruptions,
  /// auto-resume on device connect, sleep timer), which should not buzz as if the
  /// user tapped.
  void togglePlay({bool haptic = true}) {
    if (!mounted) return;
    _validateSyncState();

    final now = DateTime.now();
    if (haptic) {
      // Only a deliberate tap passes haptic: true, so it also means the user took
      // manual control. That cancels any pending "resume when the headset comes back":
      // if you pause yourself, reconnecting headphones must not start music again.
      // (See _pausedByDeviceLoss in _initAudioSession.)
      _pausedByDeviceLoss = null;
      if (_lastPlayPauseHapticAt == null ||
          now.difference(_lastPlayPauseHapticAt!) >
              const Duration(milliseconds: 300)) {
        _lastPlayPauseHapticAt = now;
        HapticService.medium();
      }
    }

    // Cold start: session restore rebuilds `currentSong` and the mini-player but
    // never hands the track to the native player, so there is nothing to resume.
    // Load it properly instead, from the restored position. Also covers any state
    // where the player was stopped.
    final cold = currentState.currentSong;
    if (!currentState.isPlaying &&
        cold != null &&
        _nativeLoadedSongId != cold.id) {
      _inactivityTimer?.cancel();
      _startCacheTimer(cold);
      unawaited(_loadAndPlay(cold, startFrom: currentState.position));
      // _loadAndPlay manages isLoading/isPlaying from here.
      currentState = currentState.copyWith(miniPlayerVisible: true);
      return;
    }

    final bool isHardwarePlaying = currentState.isPlaying;
    if (isHardwarePlaying) {
      // A pause the user asked for. The disconnect handler uses it to tell this
      // apart from the automatic pause on unplugging, so unplugging right after a
      // deliberate pause never schedules a resume on reconnect.
      if (haptic) _deliberatePauseAt = now;
      _stopCacheTimer();
      NativeAudioEngine.pause();
      _resetInactivityTimer();
      // Save the exact pause position so a later app kill restores here.
      _persistPositionOnly();
      // Spoken word: bookmark where the listener stopped, from the live player
      // position (PlayerState.position can be up to a second old).
      final cs = currentState.currentSong;
      if (cs != null && cs.isSpokenWord) {
        _savePodcastPosition(cs, currentPositionProvider.value);
      }
      // Live radio: start counting how far behind live the listener falls.
      if (_isLiveRadio(cs)) radioPausedAtProvider.value = DateTime.now();
    } else {
      _inactivityTimer?.cancel();
      if (currentState.currentSong != null) {
        _startCacheTimer(currentState.currentSong!);
      }
      // Add the paused span to the running gap. It then stays constant, since both
      // the broadcast and the listener move at 1×.
      final pausedAt = radioPausedAtProvider.value;
      if (pausedAt != null && _isLiveRadio(currentState.currentSong)) {
        radioBehindLiveProvider.value =
            radioBehindLiveProvider.value + DateTime.now().difference(pausedAt);
      }
      radioPausedAtProvider.value = null;
      NativeAudioEngine.resume();
    }
    currentState = currentState.copyWith(
      isPlaying: !isHardwarePlaying,
      // Starting playback always brings the mini-player back, including after it was
      // swiped away and the same song is resumed.
      miniPlayerVisible:
          !isHardwarePlaying ? true : currentState.miniPlayerVisible,
    );
  }

  void seek(dynamic val) {
    Duration target;
    if (val is double) {
      // A percentage seek before the duration is known would snap to the start, so
      // ignore it until the player reports a duration.
      if (currentState.duration <= Duration.zero) return;
      target = Duration(
          milliseconds: (currentState.duration.inMilliseconds * val).round());
    } else if (val is Duration) {
      target = val;
    } else {
      return;
    }
    if (target < Duration.zero) target = Duration.zero;
    final dur = currentState.duration;
    if (dur > const Duration(milliseconds: 500) && target >= dur) {
      target = dur - const Duration(milliseconds: 100);
    } else if (dur > Duration.zero && target > dur) {
      target = dur;
    }
    print('DIAG: seek -> target=${target.inMilliseconds}ms (dur=${dur.inMilliseconds}ms)');

    // Show the target position right away and hold it while the player completes
    // the jump. The native clock still emits a couple of pre-seek positions, which
    // would make the slider snap back; onPosition (player_system.dart) drops them
    // while _pendingSeekTarget is set.
    _pendingSeekTarget = target;
    _pendingSeekAt = DateTime.now();
    currentPositionProvider.value = target;
    currentState = currentState.copyWith(position: target);
    NativeAudioEngine.seek(target);
  }

  void setSpeed(double s) {
    if (!mounted) return;
    try {
      NativeAudioEngine.setSpeed(s);
    } catch (_) {}
    // Podcasts remember their pace: a speed chosen during an episode becomes the
    // default for future episodes.
    if (currentState.currentSong?.albumTitle == 'Podcast') {
      currentState = currentState.copyWith(speed: s, podcastSpeed: s);
      _saveSettingsDebounced();
    } else {
      currentState = currentState.copyWith(speed: s);
    }
  }

  void setSeekJumpSeconds(int seconds) {
    if (!mounted) return;
    currentState = currentState.copyWith(seekJumpSeconds: seconds);
    _saveSettingsDebounced();
  }

  void togglePauseOnZeroVolume() {
    if (!mounted) return;
    currentState = currentState.copyWith(
        pauseOnZeroVolume: !currentState.pauseOnZeroVolume);
    _saveSettingsDebounced();
  }

  // Skip buttons start from the live clock (currentPositionProvider), not
  // PlayerState.position, which is updated about once a second and would make
  // repeated taps jump from a stale position.
  void seekForward() {
    final step = Duration(seconds: currentState.seekJumpSeconds);
    final newPos = currentPositionProvider.value + step;
    seek(newPos > currentState.duration ? currentState.duration : newPos);
  }

  void seekBackward() {
    final step = Duration(seconds: currentState.seekJumpSeconds);
    final newPos = currentPositionProvider.value - step;
    seek(newPos < Duration.zero ? Duration.zero : newPos);
  }
  
  void setVolume(double v) {
    if (!mounted) return;
    NativeAudioEngine.setVolume(v);
    currentState = currentState.copyWith(volume: v);
    if (currentState.pauseOnZeroVolume && v <= 0.001 && currentState.isPlaying) {
      togglePlay(haptic: false);
    }
    _saveSettings();
  }
  
  void toggleAudioNormalization() {
    if (!mounted) return;
    currentState = currentState.copyWith(
        audioNormalizationEnabled: !currentState.audioNormalizationEnabled);
    _applyAudioNormalization();
    _saveSettings();
  }

  void setLoopRegion(Duration? start, Duration? end) {
    if (!mounted) return;
    if (start == null || end == null || end <= start) {
      clearLoopRegion();
      return;
    }
    currentState = currentState.copyWith(
      clearLoop: false,
      loopStart: start,
      loopEnd: end,
    );
  }

  void setLoopStart(Duration start) {
    if (!mounted) return;
    final curEnd = currentState.loopEnd;
    if (curEnd != null && start >= curEnd) {
      currentState = currentState.copyWith(
        loopStart: start,
        clearLoop: false,
        loopEnd: null,
      );
    } else {
      currentState = currentState.copyWith(loopStart: start);
    }
  }

  void setLoopEnd(Duration end) {
    if (!mounted) return;
    final curStart = currentState.loopStart;
    if (curStart != null && end <= curStart) return;
    currentState = currentState.copyWith(loopEnd: end);
  }

  void clearLoopRegion() {
    if (!mounted) return;
    currentState = currentState.copyWith(clearLoop: true);
  }

  Future<void> playPrevious() async {
    HapticService.light();

    if (currentPositionProvider.value.inSeconds > 3 && _navIndex == 0) {
      seek(Duration.zero); // optimistic — the bar snaps to 0:00 instantly
      return;
    }

    final history = currentState.history;
    final targetIndex = _navIndex + 1;

    if (targetIndex < history.length) {
      _navIndex++;
      final previousSong = history[_navIndex];
      await playSong(
        previousSong,
        source: currentState.playbackSource,
        locationName: currentState.locationName,
        isNextOrPrev: true,
      );
    } else {
      seek(Duration.zero);
    }
  }

  Future<void> playSong(Song inputSong, { 
    List<Song>? newQueue,
    int? index,
    bool isManual = true,
    String source = "Library",
    String? locationName,   
    bool playImmediately = true,
    String? contextId,
    String? contextType,
    String? contextTitle,
    bool isNextOrPrev = false,
    bool viaQueueAdvance = false,
    // The native player already moved to this track on its own (gapless
    // advance), so update Dart state and UI but don't issue a new play, which
    // would restart the track with a gap.
    bool alreadyPlayingNatively = false,
    // Internal: ids already visited by this chain of audio-only swaps. Set only by
    // playSong's own recursion. Kept per call rather than on the notifier because
    // plays can overlap, and a shared field would let one chain stop another.
    Set<String>? conformChain,
  }) async {
    if (!mounted) return;
    // A new track cancels any pending error-recovery retry, so an old retry can't
    // later reload the now-current track. (See _handlePlaybackError.)
    _recoveryTimer?.cancel();
    _pendingNetworkRetry = null;

    // Audio-only mode: swap a music video for its studio audio version.
    //
    // A music video is a different cut (intros, dialogue, interludes), which isn't
    // what an audio-only listener wants. Swap it for the matching audio song, or
    // play the video's own audio if none exists. Plain audio tracks skip all of
    // this.
    //
    // A tagged music video always swaps. Albums and playlists also contain video
    // rows with an empty musicVideoType, so an untagged track inside a collection
    // is treated as a possible video too, but only when it isn't stored locally,
    // and only with a strict title match so a real audio track is never replaced.
    final bool confirmedVideo = inputSong.isMusicVideo;
    // A 16:9 `i.ytimg.com/vi/...` thumbnail reliably marks a video even when
    // musicVideoType is empty (audio tracks have square art). This catches
    // untagged videos from any source: search, home feed, autoplay, mixes.
    final bool videoThumb = inputSong.looksLikeVideo;

    // The thumbnail check is trusted like a tagged video: it is not blocked by the
    // local-copy check and needs no strict title match. Those guards exist for the
    // weak "untagged inside a collection" signal; applying them here meant a video
    // that had been auto-cached could never be swapped again.
    final bool untaggedInCollection = inputSong.musicVideoType.isEmpty &&
        (contextType == 'album' || contextType == 'playlist') &&
        !_cacheManager.isCached(inputSong.id);
    final bool isVideo = confirmedVideo || videoThumb || untaggedInCollection;
    if (!isVideo && !inputSong.id.startsWith('http')) {
      // Log both inputs to the decision, so a video that wasn't detected is
      // visible in the log instead of looking like an ordinary audio track.
      if (inputSong.image.contains('ytimg') || inputSong.image.contains('youtube.com')) {
        print('Audio-only: "${inputSong.title}" NOT treated as a video '
            '(mvType="${inputSong.musicVideoType}", '
            'image=${inputSong.image.split('/').take(4).join('/')}…) — '
            'if this is a video, the detector needs to learn this shape');
      }
    }
    if (!currentState.processVideosEnabled &&
        isVideo &&
        !inputSong.id.startsWith('http')) {
      // Cached: if the list overlay (conform_provider) already resolved this video
      // while the user was scrolling, this returns immediately. Strict matching only
      // for the weak signal; for a tagged video or a 16:9 still it would reject good
      // matches that differ by a suffix like "(Official Audio)".
      final rawAudio = await _searchService.conformToAudioCached(
          inputSong, strict: !(confirmedVideo || videoThumb));
      if (!mounted) return;
      // Take the audio but keep the edition: use the matched audio's id and stream
      // but the original cover and album, so a deluxe track's artwork doesn't switch
      // to the standard edition mid-play.
      final audio = rawAudio == null
          ? null
          : SearchService.mergeConformedAudio(inputSong, rawAudio);
      // Stop swap loops. Two recordings of one song can each match the other (A→B→A),
      // and with both answers cached the loop spins without any network and freezes
      // the app. Refusing an id already visited in this chain stops at the first
      // repeat; the track we hold is a fine answer, since the same lookup nominated
      // it.
      final chain = {...?conformChain, inputSong.id};
      if (audio != null && chain.contains(audio.id)) {
        print('WARN: conform loop refused: "${inputSong.title}" and ${audio.id} '
            'each conform to the other — playing this one as-is '
            '(chain: ${chain.length})');
      } else if (audio != null && audio.id != inputSong.id) {
        print('Audio-only: swapped video "${inputSong.title}" → audio "${audio.title}" (${audio.id})');
        // Swap video → audio everywhere in the live queue before recursing. The audio
        // has a new id; without the swap it wouldn't be found in the queue, so playSong
        // would treat it as a new play and drop the album/playlist context.
        Song swap(Song s) => s.id == inputSong.id ? audio : s;
        currentState = currentState.copyWith(
          queue: currentState.queue.map(swap).toList(),
          userQueue: currentState.userQueue.map(swap).toList(),
          contextQueue: currentState.contextQueue.map(swap).toList(),
          autoplayQueue: currentState.autoplayQueue.map(swap).toList(),
          originalQueue: currentState.originalQueue.map(swap).toList(),
        );
        final mappedQueue = newQueue?.map(swap).toList();
        return playSong(
          audio,
          newQueue: mappedQueue,
          index: index,
          isManual: isManual,
          source: source,
          locationName: locationName,
          playImmediately: playImmediately,
          contextId: contextId,
          contextType: contextType,
          contextTitle: contextTitle,
          isNextOrPrev: isNextOrPrev,
          viaQueueAdvance: viaQueueAdvance,
          conformChain: chain,
        );
      } else {
        print('Audio-only: no audio version for video "${inputSong.title}" — playing its audio');
      }
    }

    final song = inputSong.copyWith(
      artist: inputSong.artist.replaceAll(RegExp(r'\bGeneral\b', caseSensitive: false), 'Unknown Artist').trim(),
      albumTitle: inputSong.albumTitle.replaceAll(RegExp(r'\bGeneral\b', caseSensitive: false), 'Single').trim(),
    );

    // The pending play debounce is cancelled further down, just before its
    // replacement is scheduled. Cancelling it here, before the early returns,
    // could leave a quick duplicate tap with isLoading stuck and nothing scheduled.

    if (currentState.isLoading && _currentFetchId == song.id) return;

    if (effectiveBlacklist.contains(song.id)) {
      final isDisliked = currentState.blacklistedIds.contains(song.id) ||
          ref.read(intelligenceProvider).blacklistedIds.contains(song.id);
      // A temporary failure block never overrides a direct tap. The block stops queue
      // advance from looping onto a failing stream, but a fresh attempt usually
      // works. Queue advance (automatic or the next button) still honours it.
      if (!isDisliked && !viaQueueAdvance && !isNextOrPrev) {
        _failureBlocks.remove(song.id);
        print('Manual play overrides temp failure block: ${song.title}');
      } else {
        if (!isDisliked) {
          final left = _failureBlocks[song.id]?.difference(DateTime.now()).inSeconds ?? 0;
          print('AUTO-SKIP "${song.title}" — temp failure block (${left}s left). '
              'If this track plays fine manually, the block was a false positive.');
        }
        // Remove the blocked track from every lane before skipping: playNext() plays
        // queue[1], which is this track, so otherwise the skip would recurse onto it
        // forever.
        List<Song> stripped(List<Song> l) => l.where((s) => s.id != song.id).toList();
        final su = stripped(currentState.userQueue);
        final sc = stripped(currentState.contextQueue);
        final sa = stripped(currentState.autoplayQueue);
        currentState = currentState.copyWith(
          userQueue:         su,
          contextQueue:      sc,
          autoplayQueue:     sa,
          queue: [
            if (currentState.currentSong != null) currentState.currentSong!,
            ...su, ...sc, ...sa,
          ],
          userQueueEndIndex: su.length,
        );
        if (isManual) await playNext();
        return;
      }
    }
    
    _currentFetchId = song.id;
    _fetchDebounceTimer?.cancel();
    _fetchDebounceTimer = Timer(const Duration(seconds: 5), () {
      _currentFetchId = null;
    });

    if (!isNextOrPrev && currentState.currentSong?.id == song.id) {
       togglePlay();
       return;
    }

    // Leaving a podcast mid-episode? Bookmark the exact second first.
    final leaving = currentState.currentSong;
    if (leaving != null && leaving.isSpokenWord && leaving.id != song.id) {
      _savePodcastPosition(leaving, currentPositionProvider.value);
    }

    _lastProcessedSongId = song.id;
    if (!isNextOrPrev) _navIndex = 0;
    _isProcessingTransition = true;

    // The listener's repeat mode is never changed behind their back, including
    // when an autoplay track starts.

    // Plays are credited once the track is actually heard (about 30 s, or half of a
    // short track; see player_system's position handler), not when it starts, so
    // tap-then-skip doesn't inflate My Top 50 or skew recommendations. Reset the
    // per-track flag for the new track.
    _currentPlayRecorded = false;

    // Music only: podcast "lyrics" are feed transcripts (lyricsProvider) and radio
    // has none.
    //
    // Fetched after a short dwell (see _kLyricsDwell), not immediately, so a run
    // of quick skips costs one lyrics lookup for the track the listener stays on.
    _lyricsDwellTimer?.cancel();
    if (!song.id.startsWith('http')) {
      _lyricsDwellTimer = Timer(_kLyricsDwell, () {
        // Still the same track? A late timer must not fetch lyrics for something no
        // longer playing.
        if (!mounted || currentState.currentSong?.id != song.id) return;
        _preloadLyrics(song);
      });
    }

    _preloadedSongId = null;
    _isPreloading = false;

    List<Song> userQueueSegment = List.from(currentState.userQueue);
    List<Song> contextQueueSegment = [];
    List<Song> autoplayQueueSegment = [];
    bool advancedIntoAutoplay = false;
    // True when this play just moves forward inside the current queue (no new
    // context). Used below to keep `originalQueue`, which Repeat All and
    // un-shuffle depend on.
    bool advancedWithinQueue = isNextOrPrev;

    if (newQueue != null && newQueue.isNotEmpty) {
      final songIndex = index ?? newQueue.indexWhere((s) => s.id == song.id);
      if (songIndex != -1) {
        contextQueueSegment = newQueue.sublist(songIndex + 1);
      } else {
        contextQueueSegment = [...newQueue];
      }
    } else if (isNextOrPrev) {
      // Moving through history (previous, or forward again): leave the upcoming
      // queue exactly as it is.
      contextQueueSegment  = List.from(currentState.contextQueue);
      autoplayQueueSegment = List.from(currentState.autoplayQueue);
    } else {
      // No new context. If the song is already upcoming (auto-advance or a skip),
      // move forward within the existing queue: drop entries up to and including it
      // and keep the rest. Clearing the lanes here would wipe a hand-built queue and
      // trigger a refill after every track.
      final userIdx = currentState.userQueue.indexWhere((s) => s.id == song.id);
      final ctxIdx  = currentState.contextQueue.indexWhere((s) => s.id == song.id);
      final autoIdx = currentState.autoplayQueue.indexWhere((s) => s.id == song.id);

      advancedWithinQueue = userIdx != -1 || ctxIdx != -1 || autoIdx != -1;

      if (userIdx != -1) {
        userQueueSegment     = currentState.userQueue.sublist(userIdx + 1);
        contextQueueSegment  = List.from(currentState.contextQueue);
        autoplayQueueSegment = List.from(currentState.autoplayQueue);
      } else if (ctxIdx != -1) {
        contextQueueSegment  = currentState.contextQueue.sublist(ctxIdx + 1);
        autoplayQueueSegment = List.from(currentState.autoplayQueue);
      } else if (autoIdx != -1) {
        autoplayQueueSegment = currentState.autoplayQueue.sublist(autoIdx + 1);
        advancedIntoAutoplay = true;
      }
      // Otherwise a brand-new standalone play: keep the user lane, drop context and
      // autoplay (they belonged to the old context).

      // Repeat All makes the queue circular: re-append the finished track at the end
      // so the whole queue loops, not just the last track.
      final finished = currentState.currentSong;
      if (currentState.repeatMode == RepeatMode.all &&
          (userIdx != -1 || ctxIdx != -1 || autoIdx != -1) &&
          finished != null &&
          finished.id != song.id &&
          !finished.id.startsWith('http')) {
        if (autoplayQueueSegment.isNotEmpty) {
          autoplayQueueSegment = [...autoplayQueueSegment, finished];
        } else {
          contextQueueSegment = [...contextQueueSegment, finished];
        }
      }
    }

    // The playing track must never also be upcoming, by id or as a different-id
    // twin with the same title and artist (e.g. the video version after
    // audio-only mode swapped in the audio).
    String _sig(Song s) =>
        '${s.title.toLowerCase().trim()}_${s.artist.toLowerCase().trim()}';
    final _curSig = _sig(song);
    bool _dupOfCurrent(Song s) => s.id == song.id || _sig(s) == _curSig;
    userQueueSegment = userQueueSegment.where((s) => !_dupOfCurrent(s)).toList();
    contextQueueSegment = contextQueueSegment.where((s) => !_dupOfCurrent(s)).toList();
    autoplayQueueSegment = autoplayQueueSegment.where((s) => !_dupOfCurrent(s)).toList();

    final activeQueue = [
      song,
      ...userQueueSegment,
      ...contextQueueSegment,
      ...autoplayQueueSegment
    ];

    _consecutiveErrors = 0;
    _lastProcessedSongId = song.id;

    // A different station, or leaving radio, starts at the live edge; the previous
    // station's pause gap doesn't carry over.
    if (!_isLiveRadio(song) || song.id != currentState.currentSong?.id) {
      radioPausedAtProvider.value = null;
      radioBehindLiveProvider.value = Duration.zero;
    }

    // "Recently played": every track that starts playing goes to the front of the
    // history (deduped). Skipped for previous/next navigation so walking back
    // doesn't reorder the list being walked.
    List<Song>? updatedHistory;
    if (!isNextOrPrev &&
        !ListeningPolicy.historyPaused &&
        !song.id.startsWith('http') &&
        song.albumTitle != 'Podcast' &&
        song.albumTitle != 'RADIO') {
      updatedHistory =
          [song, ...currentState.history.where((s) => s.id != song.id)].take(_kHistoryCap).toList();
      // Absolute time, not "N minutes ago": history is backed up and may be restored
      // on another device days later. See [_historyPlayedAt].
      _historyPlayedAt[song.id] = DateTime.now().millisecondsSinceEpoch;
      final curDevice = DeviceInfoService.currentDeviceName;
      if (curDevice.isNotEmpty) _historyPlayedDevice[song.id] = curDevice;
    }

    currentState = currentState.copyWith(
      currentSong: song,
      // Native gapless advance is already playing this track, so it isn't loading.
      isLoading: !alreadyPlayingNatively,
      miniPlayerVisible: true,
      queue: activeQueue,
      history: updatedHistory,
      historyPlayedAt: Map<String, int>.from(_historyPlayedAt),
      historyPlayedDevice: Map<String, String>.from(_historyPlayedDevice),
      // Keep the pre-shuffle order while shuffle is on, so turning shuffle off can
      // restore it. Also keep it when just advancing inside the queue: the queue
      // shrinks as it plays, and re-snapshotting would leave Repeat All with nothing
      // to loop by the last track. Only a genuinely new context replaces it.
      originalQueue: (currentState.isShuffle || advancedWithinQueue)
          ? currentState.originalQueue
          : List.from(activeQueue),
      currentIndex: 0,
      userQueue: userQueueSegment,
      contextQueue: contextQueueSegment,
      autoplayQueue: autoplayQueueSegment,
      userQueueEndIndex: userQueueSegment.length,
      playbackSource: advancedIntoAutoplay ? "Recommended" : source,
      // The "playing from" label.
      //
      // Autoplay reads "Based on <artist>" rather than "<artist> Radio", because Radio
      // is a separate feature (live stations) the listener didn't start.
      //
      // Without an explicit location the label is null and the player hides the
      // line. Falling back to the album name showed "Playing from Home" above an
      // unrelated album title. Every flow that has a collection (album, playlist,
      // library, mood, audiobook) passes locationName, and queue advances carry it
      // forward.
      locationName: advancedIntoAutoplay
          ? "Based on ${song.artist}"
          : locationName,
      contextId: contextId,
      contextType: contextType,
      contextTitle: contextTitle,
      // A new play that named no collection has none, so clear the previous one.
      // Only for a manual start: queue advances, next/previous and native gapless
      // hand-overs continue the same context and keep it.
      clearContext: contextType == null &&
          isManual &&
          !isNextOrPrev &&
          !viaQueueAdvance &&
          !alreadyPlayingNatively,
      position: Duration.zero,
      duration: Duration.zero,
    );

    // One log line per track change with the values the home mosaic and the
    // "playing from" label are built from (source, context type/title and the
    // displayed locationName, noting whether it was carried over), so a wrong
    // label can be traced from the log.
    //
    // `contextWasCleared` must use the same expression as `clearContext` above; if
    // that gains a condition, this must too, or the log reports clears that didn't
    // happen.
    final contextWasCleared = contextType == null &&
        isManual &&
        !isNextOrPrev &&
        !viaQueueAdvance &&
        !alreadyPlayingNatively;
    final inheritedLoc = locationName == null && !isManual;
    print('origin: source=${contextWasCleared ? "(cleared) " : ""}'
        '${advancedIntoAutoplay ? "Recommended" : source} '
        'ctxType=${contextType ?? "-"} ctxTitle=${contextTitle ?? "-"} '
        'loc=${(advancedIntoAutoplay ? "Based on ${song.artist}" : locationName) ?? "-"}'
        '${inheritedLoc ? " (inherited)" : ""} '
        'for "${song.title}"');
    // A new track cancels any in-flight seek, so its stale target isn't held
    // against the new track's first position updates.
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    currentPositionProvider.value = Duration.zero; // snap the progress bar to 0 for the new track
    clearLoopRegion();

    // Every new song starts at natural pitch.
    if (currentState.pitch != 1.0) {
      try {
        NativeAudioEngine.setPitch(1.0);
      } catch (_) {}
      currentState = currentState.copyWith(pitch: 1.0);
    }

    // Music always starts at normal speed; spoken word at the listener's saved
    // pace.
    final startSpeed =
        // Audiobooks share the podcast speed: a listener who prefers 1.25x means it
        // for narration in general.
        song.isSpokenWord ? currentState.podcastSpeed : 1.0;
    try {
      NativeAudioEngine.setSpeed(startSpeed);
    } catch (_) {}
    if (currentState.speed != startSpeed) {
      currentState = currentState.copyWith(speed: startSpeed);
    }
    _updateMediaItem(song);
    
    if (song.image.isNotEmpty) {
      ref.read(playerColorProvider.notifier).updateFromImage(song.image);
    }

    // Adaptive debounce. A single tap or a natural track end starts loading
    // immediately. Only a burst of skips (another play within 600 ms) waits a
    // moment, so mashing "next" loads one track instead of one per tap.
    final requestAt = DateTime.now();
    final bool skipStorm = _lastPlayRequestAt != null &&
        requestAt.difference(_lastPlayRequestAt!) < const Duration(milliseconds: 600);
    _lastPlayRequestAt = requestAt;
    final debounce =
        skipStorm ? const Duration(milliseconds: 450) : Duration.zero;

    // Cancel the previous pending play only now that this one is committed (see
    // the note near the top of this method).
    _playDebounceTimer?.cancel();
    _playDebounceTimer = Timer(debounce, () async {
      if (!mounted) return;

      if (_lastProcessedSongId == song.id) {
        try {
          if (alreadyPlayingNatively) {
            // Native already switched to this track (gapless): don't reload it, which
            // would restart it. State and UI were updated above; just clear the loading
            // flag. Top-up, lyrics and next-track preload below still run.
            // Record that the player holds this track, so the next pause→play resumes
            // instead of reloading.
            _nativeLoadedSongId = song.id;
            if (mounted && currentState.isLoading) {
              currentState = currentState.copyWith(isLoading: false);
            }
          } else {
          // Cache first: if the track is already on disk, play the local file for an
          // instant start and no network use. Not for live radio streams.
          final cachedPath =
              song.id.startsWith('http') ? null : _cacheManager.getCachedPath(song.id);

          if (cachedPath != null) {
            print('Playing from local cache: ${song.title}');
            await NativeAudioEngine.playTrack(
              song.id, cachedPath,
              localPath: cachedPath,
              autoPlay: playImmediately,
            );
          } else if (song.id.startsWith('http')) {
            // Radio / podcast: a direct URL; resolve it.
            print('Resolving direct stream for: ${song.title}');
            final stream = await _audioService
                .getStreamWithFallback(song.id, song.title, song.artist)
                .timeout(const Duration(seconds: 15));
            final directAudioUrl = stream?['url'];
            if (directAudioUrl == null || directAudioUrl.isEmpty) {
              throw Exception("No playable stream found for ${song.title}");
            }
            if (_lastProcessedSongId != song.id) return;
            await NativeAudioEngine.playTrack(
              song.id, directAudioUrl,
              userAgent: stream?['user_agent'],
              contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
              autoPlay: playImmediately,
            );
          } else {
            // YouTube track: hand the video id to the native player and let it resolve
            // the stream itself, with its own retry and play cache. This keeps the Dart
            // lookup out of the way of the track change; the native resolveStream callback
            // (player_system) resolves on demand, usually from the warm cache.
            print('Native-resolving stream: ${song.title}');
            await NativeAudioEngine.playTrack(
              song.id, '',
              autoPlay: playImmediately,
            );
          }

          // The player now holds this track, so a later play tap can resume instead of
          // reloading (see togglePlay's cold-start check).
          _nativeLoadedSongId = song.id;

          // Spoken word (podcast episodes and audiobook chapters) resumes where the
          // listener left off. Music always starts from the top.
          if (song.isSpokenWord) {
            final resume = await _getPodcastResumePosition(song);
            if (resume != null && resume > const Duration(seconds: 10)) {
              await NativeAudioEngine.seek(resume);
              currentPositionProvider.value = resume;
              print('Resuming ${song.mediaKind == MediaKind.audiobook ? "chapter" : "podcast"} '
                  'at ${resume.inMinutes}m${resume.inSeconds % 60}s');
            }
            // Only podcasts have sponsor breaks; checking an audiobook would waste a feed
            // fetch.
            if (song.mediaKind == MediaKind.podcast) {
              // Costs a feed fetch, so playback doesn't wait for it.
              unawaited(_loadSponsorBreaks(song));
            }
          }

          if (playImmediately) {
            _fadeIn(currentState.volume);
          }
          } // end !alreadyPlayingNatively (gapless: skip the native reload)

          // Refill with recommendations only when the queue is about to run out, never
          // over a queue the user built. The refresh button in the queue sheet
          // (refreshAutoplay) triggers it manually. Threshold 2 leaves a full track of
          // headroom for a slow network.
          final upcoming = userQueueSegment.length +
              contextQueueSegment.length +
              autoplayQueueSegment.length;
          // Only music gets a top-up. A radio station's "artist" is "Live Radio •
          // <country>", and searching for that filled the queue with unrelated tracks;
          // podcasts and audiobooks don't want one either. (_topUpQueueInner also refuses
          // them; this just saves the trip.)
          if (upcoming <= 2 &&
              song.mediaKind == MediaKind.music &&
              currentState.repeatMode == RepeatMode.off) {
            Timer(const Duration(milliseconds: 300), () => _topUpQueue());
          }

          _startCacheTimer(song);
          _preloadNextTrack();
          _saveSettingsDebounced();
        } catch (e) {
          print("ALERT: [Auvy Loader Error] Native stream compilation failed: $e");
          // Nothing usable is loaded, so a later play tap must reload rather than resume.
          _nativeLoadedSongId = null;
          // Pass along that this play was meant to be audible, so the retry doesn't load
          // the track paused.
          _handlePlaybackError(e, intendedPlaying: playImmediately);
        } finally {
          if (mounted) {
            _isProcessingTransition = false;
            currentState = currentState.copyWith(isLoading: false);
          }
        }
      }
    });
  }

  void dismissMiniPlayer() {
    if (!mounted) return;
    NativeAudioEngine.pause();
    NativeAudioEngine.seek(Duration.zero);
    currentPositionProvider.value = Duration.zero;
    currentState = currentState.copyWith(
      miniPlayerVisible: false,
      isPlaying: false,
      position: Duration.zero,
    );
  }

  void updateSwipeProgress(double progress) {
    if (!mounted) return;
    currentState = currentState.copyWith(swipeProgress: progress);
  }

  void toggleGaplessPlayback() {
    if (!mounted) return;
    currentState = currentState.copyWith(gaplessPlayback: !currentState.gaplessPlayback);
    _saveSettings();
  }

  /// How long a track start fades in: a short click-suppression window, not an
  /// audible effect, so the track simply begins without a hard edge.
  static const Duration _kStartFade = Duration(milliseconds: 380);

  /// One volume ramp, shared by every fade in the player.
  ///
  /// Equal-power curve: gain follows sin(t·π/2) going up and cos(t·π/2) going
  /// down. A straight amplitude line sounds uneven because hearing is roughly
  /// logarithmic.
  ///
  /// Time-driven: progress comes from a Stopwatch rather than a step count, so a
  /// fade finishes on time even when platform-channel writes are slow; it just
  /// takes coarser steps.
  Future<void> _rampVolume({
    required double from,
    required double to,
    required Duration over,
  }) async {
    final generation = ++_fadeGeneration;
    if (over <= Duration.zero || from == to) {
      NativeAudioEngine.setVolume(to);
      return;
    }
    // 50 Hz: smooth enough to be inaudible as steps, while a multi-second fade is
    // still only a few hundred channel writes.
    const tick = Duration(milliseconds: 20);
    final fadingIn = to >= from;
    final watch = Stopwatch()..start();
    NativeAudioEngine.setVolume(from);

    while (true) {
      await Future.delayed(tick);
      // A newer ramp owns the volume now, or the notifier is gone.
      if (!mounted || generation != _fadeGeneration) return;
      final t = (watch.elapsedMilliseconds / over.inMilliseconds).clamp(0.0, 1.0);
      // Progress along `from`→`to`, shaped so the gain follows the equal-power curve
      // in both directions.
      final shaped = fadingIn ? sin(t * pi / 2) : 1 - cos(t * pi / 2);
      NativeAudioEngine.setVolume(from + (to - from) * shaped);
      if (t >= 1.0) break;
    }
    if (mounted && generation == _fadeGeneration) {
      NativeAudioEngine.setVolume(to);
    }
  }

  Future<void> _fadeIn(double targetVolume) async {
    if (!currentState.crossfadeEnabled) {
      NativeAudioEngine.setVolume(targetVolume);
      return;
    }
    await _rampVolume(from: 0.0, to: targetVolume, over: _kStartFade);
  }

  Future<void> _loadAndPlay(Song song, {Duration? startFrom, bool playImmediately = true}) async {
    try {
      if (!mounted) return;
      print('_loadAndPlay: "${song.title}" (${song.id}) from $startFrom, playImmediately=$playImmediately');
      currentState = currentState.copyWith(
        isLoading: true, 
        currentSong: song,
      );

      _applyAudioNormalization();
      _updateMediaItem(song);
      if (song.image.isNotEmpty) {
        ref.read(playerColorProvider.notifier).updateFromImage(song.image);
      }

      // Cache first: play the local file when the track is cached.
      final cachedPath =
          song.id.startsWith('http') ? null : _cacheManager.getCachedPath(song.id);
      if (cachedPath != null) {
        await NativeAudioEngine.playTrack(
          song.id, cachedPath,
          localPath: cachedPath,
          autoPlay: playImmediately,
        );
      } else if (song.id.startsWith('http')) {
        // Radio / podcast direct stream: resolve the playable URL.
        final stream = await _audioService
            .getStreamWithFallback(song.id, song.title, song.artist)
            .timeout(const Duration(seconds: 15));
        final url = stream?['url'];
        if (url == null || url.isEmpty) {
          throw Exception("No valid stream URLs found");
        }
        await NativeAudioEngine.playTrack(
          song.id, url,
          userAgent: stream?['user_agent'],
          contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
          autoPlay: playImmediately,
        );
      } else {
        // YouTube: hand the video id to the native player, which resolves the stream
        // itself (with retries), keeping the Dart lookup off the critical path.
        await NativeAudioEngine.playTrack(song.id, '', autoPlay: playImmediately);
      }

      // The player now holds this track, so a later togglePlay can resume instead of
      // reloading.
      _nativeLoadedSongId = song.id;

      if (startFrom != null && startFrom > Duration.zero) {
        await NativeAudioEngine.seek(startFrom);
      }
      
      if (playImmediately && mounted) {
        if (startFrom == null || startFrom == Duration.zero) {
          NativeAudioEngine.setVolume(0.0);
          await NativeAudioEngine.resume();
          _fadeInAudio(); 
        } else {
          await NativeAudioEngine.resume();
        }
      }
      
      if (mounted) currentState = currentState.copyWith(isLoading: false, isPlaying: playImmediately);

    } catch (e) {
      // The load failed and the player holds nothing usable, so a later play tap
      // must not try to resume.
      _nativeLoadedSongId = null;
      if (mounted) currentState = currentState.copyWith(isLoading: false);
      _handlePlaybackError(e, intendedPlaying: playImmediately);
    }
  }

  /// Fade in after a resume, using the same ramp as every other fade.
  Future<void> _fadeInAudio() =>
      _rampVolume(from: 0.0, to: currentState.volume, over: _kStartFade);


  void _validateSyncState() {
    // Queue sync with the native side is handled there; Dart owns the queue.
  }

  void _startCacheTimer(Song song) {
    if (song.id.startsWith('http')) return; // live radio — never cached
    _cacheTimer?.cancel();

    if (_cacheManager.isCached(song.id)) return;
    // Already tried this song this session (success or failure); never retry, or
    // a failing auto-cache would re-run on every pause/resume.
    if (_autoCacheAttempted.contains(song.id)) return;

    // Auto-cache: after 10 s of listening, copy the track into the "Cached" folder
    // if the native play cache already holds all of it. A track skipped within a
    // few seconds is never cached.
    _cacheTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || currentState.currentSong?.id != song.id) return;
      // Skip if it's already cached or downloaded.
      if (_cacheManager.isCached(song.id)) return;
      // Promotion only, with no network: the empty url tells cacheTrack to copy the
      // bytes the native play cache already has, and to do nothing if it doesn't
      // have the whole track yet. The end-of-track handler (player_system
      // onTrackEnded) promotes it once it has streamed end to end. Because it only
      // copies local bytes, it needs no Wi-Fi or data-saver check.
      _autoCacheAttempted.add(song.id);
      try {
        await _cacheManager.cacheTrack(song, '', isExplicitDownload: false);
      } catch (_) {}
    });
  }

  void _stopCacheTimer() {
    _cacheTimer?.cancel();
  }


  /// The native player no longer holds a media item (stopped, or the session was
  /// torn down), so the next play tap must load rather than resume. See the
  /// cold-start branch in [togglePlay].
  void markNativeUnloaded() => _nativeLoadedSongId = null;

  void stopAndDismiss() async {
    if (!mounted) return;
    _navIndex = 0;
    if (currentState.crossfadeEnabled) {
      await _startCrossfade();
    }
    NativeAudioEngine.stop();
    _nativeLoadedSongId = null;

    currentState = currentState.copyWith(
      isPlaying: false,
      currentSong: null,
      position: Duration.zero,
      miniPlayerVisible: false,
    );

    // Tear down the media session too, or the notification stays up showing
    // nothing.
    try {
      await _audioHandler?.stop();
    } catch (_) {}
  }

  void setRepeatMode(RepeatMode mode) {
    if (!mounted) return;
    if (currentState.repeatMode == mode) return;

    currentState = currentState.copyWith(repeatMode: mode);

    // A repeat-mode change must drop the pre-buffered next track. With gapless
    // playback the native player, not Dart, moves on at the end of a track, into
    // whatever `_preloadNextTrack` prepared:
    //   • Repeat One: nothing may be prepared, or the player moves to the next
    //     song instead of looping.
    //   • Off / All: the correct next track may differ from the prepared one.
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    _preloadedSongId = null;
    if (mode != RepeatMode.one && currentState.isPlaying) {
      Future.microtask(() => _preloadNextTrack());
    }

    // Turning on Repeat All late (say on an album's last track) leaves only the
    // current track upcoming, so rebuild the loop from the full context.
    if (mode == RepeatMode.all) _reseedRepeatAllLoop();

    if (mode == RepeatMode.off && currentState.autoplayQueue.length < 5) {
      Future.microtask(() => _topUpQueue());
    }

    _saveSettings();
  }

  void cycleRepeatMode() {
    if (!mounted) return;
    final modes = [RepeatMode.off, RepeatMode.all, RepeatMode.one];
    final currentIdx = modes.indexOf(currentState.repeatMode);
    final nextMode = modes[(currentIdx + 1) % modes.length];
    setRepeatMode(nextMode);
  }

  void setPitch(double pitch) {
    if (!mounted) return;
    final clamped = pitch.clamp(0.25, 4.0);
    NativeAudioEngine.setPitch(clamped); // real pitch shift on the native engine
    currentState = currentState.copyWith(pitch: clamped);
    _saveSettingsDebounced();
  }

  void setPitchSemitones(int semitones) {
    final ratio = pow(2.0, semitones / 12.0).toDouble();
    setPitch(ratio);
  }

  void toggleSilenceSkipping() {
    if (!mounted) return;
    final next = !currentState.silenceSkippingEnabled;
    currentState = currentState.copyWith(silenceSkippingEnabled: next);
    _saveSettingsDebounced();
    // Turn on the native silence trimmer.
    NativeAudioEngine.setSkipSilence(next);
  }

  void toggleEq() async {
    if (!mounted) return;
    final next = !currentState.eqEnabled;
    currentState = currentState.copyWith(eqEnabled: next);
    _saveSettingsDebounced();
    // Push to the native equalizer (bound to the player's audio session). When off,
    // native disables the effect but keeps the bands, so re-enabling restores them.
    NativeAudioEngine.setEqualizer(next, currentState.eqBands);
  }

  void applyEqBands(List<double> bands, {bool persist = true}) {
    if (bands.length != 5) return;
    final clamped = bands.map((v) => v.clamp(-12.0, 12.0)).toList();

    if (persist && mounted) {
      currentState = currentState.copyWith(eqBands: clamped);
      _saveSettingsDebounced();
    }
    // Apply live while a band slider is dragged.
    NativeAudioEngine.setEqualizer(currentState.eqEnabled, clamped);
  }

  /// Sends the current track's loudness correction to the native player.
  ///
  /// Loudness comes from YouTube's `audioConfig.loudnessDb`, stored per video id
  /// when the stream resolves (player_system's stream resolver); `Song.loudness`
  /// is the fallback for podcasts and radio. The gain is sent in millibels:
  /// positive boosts through LoudnessEnhancer, negative trims player volume, so a
  /// quiet master can be raised as well as a loud one lowered.
  void _applyAudioNormalization() {
    if (!mounted) return;
    final song = currentState.currentSong;
    if (song == null) return;

    // Gain first, then volume: setVolume applies the current trim, so calling it
    // first would scale this track by the previous track's correction. Native also
    // recomputes the trim inside setNormalizationGain, so the order is a second
    // safeguard.

    if (!currentState.audioNormalizationEnabled) {
      NativeAudioEngine.setNormalizationGain(false, 0);
      NativeAudioEngine.setVolume(currentState.volume);
      return;
    }

    final double? measured = _loudnessByVideoId[song.id] ?? song.loudness;
    if (measured == null) {
      // No loudness for this track (not resolved yet, or a local file): clear any
      // correction left from the previous track instead of carrying it over.
      NativeAudioEngine.setNormalizationGain(false, 0);
      NativeAudioEngine.setVolume(currentState.volume);
      return;
    }

    // `loudnessDb` is the content's measured level, not a gain to apply. Typical
    // values of -8 to -10 are loud masters, and correcting to the -14 streaming
    // target gives cuts of about 5 dB, which is what normalization should do.
    // Reading it as a gain would boost ordinary tracks by 10+ dB and clip. If
    // normalized playback feels quieter than other apps, it can be turned off in
    // Settings.
    const double targetLoudness = -14.0;
    final double correctionDb = targetLoudness - measured;

    // Asymmetric limits: a cut is always safe, while a large boost amplifies noise
    // and clips. A bad source value could otherwise ask for +20 dB.
    final int gainMb = (correctionDb * 100).round().clamp(-2000, 700);
    NativeAudioEngine.setNormalizationGain(true, gainMb);
    NativeAudioEngine.setVolume(currentState.volume);
  }


  /// Fades the current track down to silence.
  ///
  /// A fade-out, not a crossfade; the only caller is [stopAndDismiss]. Continuity
  /// between tracks comes from native gapless playback instead: a true crossfade
  /// needs two streams playing at once, and fading one stream out and the next in
  /// leaves an audible dip.
  Future<void> _startCrossfade() async {
    if (!mounted ||
        !currentState.crossfadeEnabled ||
        currentState.repeatMode == RepeatMode.one) {
      return;
    }
    await _rampVolume(
      from: currentState.volume,
      to: 0.0,
      over: currentState.crossfadeDuration,
    );
    // Restore the volume, or the next playback starts silent.
    if (mounted) NativeAudioEngine.setVolume(currentState.volume);
  }

  // Spoken-word bookmarks: pausing, switching away or restarting the app resumes
  // at the same second later. Finished items clear their bookmark.

  Future<void> _savePodcastPosition(Song episode, Duration position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_podcastPositionsKey);
      final Map<String, dynamic> map =
          raw != null ? Map<String, dynamic>.from(jsonDecode(raw)) : {};
      final key = episode.id.hashCode.toString();
      if (position.inSeconds > 5) {
        // Store the real episode length next to the position. The feed's
        // <itunes:duration> is often missing or approximate (inserted ads change the
        // file length), while the player knows the true duration once playing.
        //
        // Only trust currentState.duration if it belongs to this episode; this is also
        // called for the episode being left, when the state may already describe the
        // next track. A previously learned duration is never overwritten with 0.
        final int liveMs = (currentState.currentSong?.id == episode.id)
            ? currentState.duration.inMilliseconds
            : 0;
        final prev = map[key];
        final int prevMs = (prev is Map && prev['d'] is int) ? prev['d'] as int : 0;
        final int totalMs = liveMs > 0 ? liveMs : prevMs;
        map[key] = {
          'p': position.inMilliseconds,
          if (totalMs > 0) 'd': totalMs,
          // When it was last listened to, so "Continue listening" offers the episode the
          // listener is actually in the middle of rather than the newest one started.
          't': DateTime.now().millisecondsSinceEpoch,
        };
        // Log once per item, not on every 5-second write, to confirm bookmarking ran.
        if (_lastBookmarkedId != episode.id) {
          _lastBookmarkedId = episode.id;
          print('bookmarking "${episode.title}" '
              '(${episode.mediaKind.name}) from ${position.inSeconds}s');
        }
      } else {
        if (map.containsKey(key)) {
          print('bookmark cleared for "${episode.title}" — '
              'back at the start or finished');
        }
        map.remove(key); // back at the start / finished → no bookmark
      }
      // Cap the ledger at 200 entries, dropping the least recently played.
      if (map.length > 200) {
        final sortedKeys = map.keys.toList()
          ..sort((a, b) {
            final tA = (map[a] is Map && map[a]['t'] is int) ? map[a]['t'] as int : 0;
            final tB = (map[b] is Map && map[b]['t'] is int) ? map[b]['t'] as int : 0;
            return tA.compareTo(tB);
          });
        for (int i = 0; i < sortedKeys.length - 200; i++) {
          map.remove(sortedKeys[i]);
        }
      }
      await prefs.setString(_podcastPositionsKey, jsonEncode(map));
    } catch (e) {
      // Losing a bookmark loses someone's place in a long book, so log it.
      print('WARN: could not save the resume position for '
          '"${episode.title}": $e');
    }
  }

  /// The last item bookmarked, so the log line is written once instead of every
  /// five seconds.
  static String? _lastBookmarkedId;

  // Live radio.

  /// Whether [s] is a live stream. Asks MediaKind rather than guessing from a URL
  /// id, because podcast episodes and audiobook chapters have URL ids too and
  /// must not get radio behaviour (gap tracking, "go live").
  bool _isLiveRadio(Song? s) => s != null && s.mediaKind == MediaKind.liveStream;

  /// Rejoins the broadcast at the live edge, discarding the accumulated gap.
  /// Reconnects rather than seeks, since a live stream usually has no window to
  /// seek within.
  Future<void> goLiveRadio() async {
    final s = currentState.currentSong;
    if (!_isLiveRadio(s)) return;
    HapticService.medium();
    radioPausedAtProvider.value = null;
    radioBehindLiveProvider.value = Duration.zero;
    // Force a real reload; the player already holds this item and would otherwise
    // continue from the stale buffer.
    _nativeLoadedSongId = null;
    await _loadAndPlay(s!);
  }

  // Sponsor breaks.

  /// Finds the playing episode's ad ranges once, when it starts.
  ///
  /// Only breaks the show itself timestamps are found: chapter JSON, or lines like
  /// "(00:18:36) Sponsors: …" in the notes (see PodcastExtrasService). Dynamically
  /// inserted ads differ per download and can't be found from feed data, so those
  /// still play; this never guesses.
  Future<void> _loadSponsorBreaks(Song song) async {
    _adSkipRanges = const [];
    _adSkipsDone.clear();
    _adRangesForSongId = null;
    if (song.albumTitle != 'Podcast') return;
    try {
      final chapters = await ref.read(podcastChaptersProvider.future);
      // The listener may have switched episodes during the fetch; the old episode's
      // breaks must not be applied to the new one.
      if (!mounted || currentState.currentSong?.id != song.id) return;
      final fallbackEnd = currentState.duration;
      final ranges = <List<int>>[];
      for (final c in chapters) {
        if (!c.isAd) continue;
        final end = c.end ?? fallbackEnd;
        if (end > c.start) {
          ranges.add([c.start.inMilliseconds, end.inMilliseconds]);
        }
      }
      _adSkipRanges = ranges;
      _adRangesForSongId = song.id;
      if (ranges.isNotEmpty) {
        print('${ranges.length} sponsor break(s) armed for "${song.title}"');
      }
    } catch (_) {
      // No chapter data, the common case. Nothing to skip.
    }
  }

  /// Jumps past a sponsor break as soon as playback reaches it.
  void _maybeSkipSponsorBreak(Duration position) {
    if (_adSkipRanges.isEmpty) return;
    final song = currentState.currentSong;
    if (song == null || _adRangesForSongId != song.id) return;
    final ms = position.inMilliseconds;
    for (final r in _adSkipRanges) {
      final start = r[0];
      final end = r[1];
      if (ms < start || ms >= end) continue;
      // Already skipped once: the listener scrubbed back into it and may stay.
      if (_adSkipsDone.contains(start)) return;
      // Only skip a break reached by playing into it. Landing in the middle means the
      // listener sought there on purpose.
      if (ms - start > 4000) return;
      _adSkipsDone.add(start);
      print('skipping sponsor break ${start}ms → ${end}ms');
      seek(Duration(milliseconds: end));
      return;
    }
  }

  Future<Duration?> _getPodcastResumePosition(Song episode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_podcastPositionsKey);
      if (raw == null) return null;
      final map = jsonDecode(raw);
      final entry = map[episode.id.hashCode.toString()];
      // Two formats: a bare int is a bookmark saved before durations were stored and
      // must keep working.
      final ms = (entry is Map) ? entry['p'] : entry;
      if (ms is int && ms > 0) return Duration(milliseconds: ms);
      return null;
    } catch (_) {
      return null;
    }
  }
}