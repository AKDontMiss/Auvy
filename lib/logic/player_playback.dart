// Manages the physical movement of the "needle" on the audio, including play/pause, seeking, and speed.
part of '../providers/player_provider.dart';

// Timestamp of the last play/pause haptic. Used to throttle the toggle haptic so
// it can never "machine-gun": when a stalling stream rapidly flips play-state,
// togglePlay can be driven many times a second, and without this guard every
// flip fires a vibration — the constant buzzing the user feels. A genuine user
// tap is always far more than 300ms apart, so this only suppresses the runaway.
DateTime? _lastPlayPauseHapticAt;

// Bumped by every new volume ramp so a superseded one stops writing volumes.
//
// WITHOUT THIS TWO FADES FIGHT. Each ramp is a loop of platform-channel
// writes, so a fade still running when the next one starts keeps interleaving its
// own values with the new one's — audible as a wobble on a fast skip.
//
// Top-level rather than a field because this file's members live in an extension,
// which cannot declare instance fields. Same pattern as the haptic timestamp
// above, and safe for the same reason: there is one player.
int _fadeGeneration = 0;

// Per-episode podcast resume positions (prefs key → JSON map of idHash → ms).
// Podcasts continue where the listener left off — pausing mid-episode, playing
// music, and coming back days later resumes at the same second.
/// Where the resume bookmarks live, for podcast episodes AND audiobook
/// chapters. The key still says podcast because renaming it would orphan every
/// bookmark already on a device; the ledger itself never cared which kind of
/// spoken word it was storing.
const String _podcastPositionsKey = 'auvy_podcast_positions';

extension PlayerPlaybackController on PlayerNotifier {

  /// [haptic] false for AUTOMATED play/pause (headphone unplug, interruptions,
  /// device-connect auto-resume, sleep timer) — the phone buzzing as if the
  /// user tapped was noticeable and wrong.
  void togglePlay({bool haptic = true}) {
    if (!mounted) return;
    _validateSyncState();

    final now = DateTime.now();
    if (haptic) {
      // `haptic` is only true for a DELIBERATE user tap — every automated call
      // in the app passes haptic: false. So it doubles as the signal that the
      // user has taken manual control of playback, which retires any pending
      // "resume when the headset comes back" licence: if you press pause
      // yourself, reconnecting your headphones must not start music again.
      // (See _pausedByDeviceLoss in _initAudioSession.)
      _pausedByDeviceLoss = null;
      if (_lastPlayPauseHapticAt == null ||
          now.difference(_lastPlayPauseHapticAt!) >
              const Duration(milliseconds: 300)) {
        _lastPlayPauseHapticAt = now;
        HapticService.medium();
      }
    }

    // COLD START: the session restore rebuilds `currentSong` + the mini-player
    // from prefs but never hands the track to the native engine, so there is no
    // media item to resume. Resuming anyway did nothing audible while Dart
    // optimistically flipped to "playing", and the next native state event
    // flipped it straight back — the "I have to press play three times" bug
    // (the third tap only worked because an error/recovery path had loaded the
    // track by then). Load it properly instead, continuing from the restored
    // position. Same guard covers any state where the engine was stopped.
    final cold = currentState.currentSong;
    if (!currentState.isPlaying &&
        cold != null &&
        _nativeLoadedSongId != cold.id) {
      _inactivityTimer?.cancel();
      _startCacheTimer(cold);
      unawaited(_loadAndPlay(cold, startFrom: currentState.position));
      // _loadAndPlay owns isLoading/isPlaying from here.
      currentState = currentState.copyWith(miniPlayerVisible: true);
      return;
    }

    final bool isHardwarePlaying = currentState.isPlaying;
    if (isHardwarePlaying) {
      _stopCacheTimer();
      NativeAudioEngine.pause();
      _resetInactivityTimer();
      // Snapshot the exact pause position so a later app kill restores here.
      _persistPositionOnly();
      // Podcasts: remember where the listener stopped (live engine position —
      // PlayerState.position can be up to a second stale).
      final cs = currentState.currentSong;
      if (cs != null && cs.isSpokenWord) {
        _savePodcastPosition(cs, currentPositionProvider.value);
      }
      // Live radio: start counting what the listener is missing.
      if (_isLiveRadio(cs)) radioPausedAtProvider.value = DateTime.now();
    } else {
      _inactivityTimer?.cancel();
      if (currentState.currentSong != null) {
        _startCacheTimer(currentState.currentSong!);
      }
      // Fold the paused span into the standing gap. It then stays put: from here
      // both the broadcast and the listener move at 1×.
      final pausedAt = radioPausedAtProvider.value;
      if (pausedAt != null && _isLiveRadio(currentState.currentSong)) {
        radioBehindLiveProvider.value =
            radioBehindLiveProvider.value + DateTime.now().difference(pausedAt);
      }
      radioPausedAtProvider.value = null;
      // (Re)take system audio focus BEFORE resuming so any other app playing
      // audio is paused by Android instead of Auvy playing over it.
      _activateAudioFocus();
      NativeAudioEngine.resume();
    }
    currentState = currentState.copyWith(
      isPlaying: !isHardwarePlaying,
      // Starting playback always brings the mini-player back. After a
      // swipe-down dismissal the same-song tap path resumes via togglePlay
      // (playSong early-returns), so without this the bar stayed hidden while
      // music was audibly playing — until the NEXT track change restored it.
      miniPlayerVisible:
          !isHardwarePlaying ? true : currentState.miniPlayerVisible,
    );
  }

  void seek(dynamic val) {
    Duration target;
    if (val is double) {
      // Percentage seek before the duration is known would compute 0 and snap
      // the track to the start — ignore until the engine reports a duration.
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
    if (dur > Duration.zero && target > dur) target = dur;

    // OPTIMISTIC: show the destination immediately and hold it there while the
    // engine completes the jump. The native clock keeps emitting a few pre-seek
    // positions (~2 ticks) before ExoPlayer lands — letting those through made
    // the slider snap back to the old spot and then leap forward. onPosition
    // (player_system.dart) drops stale ticks while _pendingSeekTarget is set.
    _pendingSeekTarget = target;
    _pendingSeekAt = DateTime.now();
    currentPositionProvider.value = target;
    currentState = currentState.copyWith(position: target);
    NativeAudioEngine.seek(target);
  }

  void setSpeed(double s) {
    if (!mounted) return;
    // Assuming you add setSpeed to NativeAudioEngine or handle natively
    try {
      NativeAudioEngine.setSpeed(s);
    } catch (_) {}
    // Podcasts remember their pace: choosing a speed while an episode plays
    // becomes the default for every future episode (until changed again).
    if (currentState.currentSong?.albumTitle == 'Podcast') {
      currentState = currentState.copyWith(speed: s, podcastSpeed: s);
      _saveSettingsDebounced();
    } else {
      currentState = currentState.copyWith(speed: s);
    }
  }

  // Nudge seeks are based on the LIVE clock (currentPositionProvider), not
  // PlayerState.position — the state copy is folded at most ~1×/sec, so using
  // it made double-tap seeks jump from a stale base (visible as a glitch when
  // nudging backward).
  void seekForward() {
    final newPos = currentPositionProvider.value + const Duration(seconds: 10);
    seek(newPos > currentState.duration ? currentState.duration : newPos);
  }

  void seekBackward() {
    final newPos = currentPositionProvider.value - const Duration(seconds: 10);
    seek(newPos < Duration.zero ? Duration.zero : newPos);
  }
  
  void setVolume(double v) {
    if (!mounted) return;
    NativeAudioEngine.setVolume(v);
    currentState = currentState.copyWith(volume: v);
    _saveSettings();
  }
  
  void toggleAudioNormalization() {
    if (!mounted) return;
    currentState = currentState.copyWith(
        audioNormalizationEnabled: !currentState.audioNormalizationEnabled);
    _applyAudioNormalization();
    _saveSettings();
  }

  Future<void> playPrevious() async {
    HapticService.light();

    if (currentState.position.inSeconds > 3 && _navIndex == 0) {
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
    // GAPLESS: the native ExoPlayer queue ALREADY transitioned to this track
    // (auto-advance from the pre-buffered upcoming item), so update all Dart
    // state/UI/queue but DON'T re-issue a native play (that would restart the
    // track with a gap). Default false = normal reload path (unchanged).
    bool alreadyPlayingNatively = false,
    // INTERNAL — the ids already visited by THIS conform chain.
    //
    // Set only by playSong's own recursion below. It belongs to the call rather
    // than to the notifier because plays can overlap (the transition debounce),
    // and a shared field would let one chain terminate another.
    Set<String>? conformChain,
  }) async {
    if (!mounted) return;
    // A user/queue-initiated track change clears any pending error-recovery
    // retry from a previous failure, so a backoff timer (or the connectivity
    // fast-path) can't later fire and reload/restart the now-current track.
    // (See _handlePlaybackError.)
    _recoveryTimer?.cancel();
    _pendingNetworkRetry = null;

    // AUDIO-ONLY: conform a music VIDEO to its studio-AUDIO equivalent
    // A music video (OMV/UGC) is a cinematic cut — intros, dialogue, interludes,
    // often longer than the song, which is not what an audio-only listener
    // asked for. Swap it for the searched audio-song version (or, if none
    // exists, fall through and play the video's own audio as a last resort).
    // Guarded on isMusicVideo, so ordinary audio plays do ZERO extra work.
    // A CONFIRMED music video (tagged OMV/UGC) always conforms. But deluxe /
    // compilation albums link video rows that arrive with an EMPTY
    // musicVideoType (YouTube doesn't tag them — verified live: "So Am I",
    // "we can't be friends" came through as OMV videos with mvType=""), so
    // isMusicVideo is false and the video slipped through. Treat an UNKNOWN type
    // inside an ALBUM/PLAYLIST as a possible untagged video too, but ONLY for a
    // fresh stream the user does NOT already have locally, and match STRICTLY
    // (exact title) so a genuine audio track is never mis-swapped.
    final bool confirmedVideo = inputSong.isMusicVideo;
    // PERMANENT video detection: a 16:9 `i.ytimg.com/vi/...` thumbnail reliably
    // marks a VIDEO even when YouTube leaves musicVideoType EMPTY (audio tracks
    // use SQUARE googleusercontent art). This conforms untagged videos played
    // from ANY source — search, home feed, autoplay/radio, mixes — not just
    // album/playlist context, which is why some videos still slipped through.
    // Song.looksLikeVideo, not a local copy: the previous inline test missed
    // `/vi_webp/` and `img.youtube.com/vi/`, which is one of the ways a video
    // reached the engine unconformed.
    final bool videoThumb = inputSong.looksLikeVideo;

    // The cache gate applied to the wrong signal
    //
    // THE BUG THIS FIXES, reported as "it captured the video version of
    // positions" with NEITHER of this method's two audio-only lines in the log —
    // so the swap was never even attempted, which means detection said "not a
    // video".
    //
    // `videoThumb` used to sit INSIDE `maybeUntaggedVideo`, and so inherited its
    // `!isCached` gate. That gate is there to protect the WEAK signal — "empty
    // musicVideoType inside an album or playlist" — from mis-swapping a genuine
    // audio track, and the strict title match is the other half of that
    // protection.
    //
    // A 16:9 ytimg still is not a weak signal; audio tracks carry SQUARE
    // googleusercontent art. Gating it on the cache meant that once a video had
    // been auto-cached, and this install holds 163 auto-cached items — it could
    // never be conformed again, for the life of that cache entry. "Some videos"
    // was exactly the videos already on disk.
    //
    // The thumbnail is now trusted like a tagged video: no cache gate, and no
    // strict-match requirement either.
    final bool untaggedInCollection = inputSong.musicVideoType.isEmpty &&
        (contextType == 'album' || contextType == 'playlist') &&
        !_cacheManager.isCached(inputSong.id);
    final bool isVideo = confirmedVideo || videoThumb || untaggedInCollection;
    if (!isVideo && !inputSong.id.startsWith('http')) {
      // SAID OUT LOUD, BECAUSE "NOTHING HAPPENED" WAS THE WHOLE PROBLEM.
      //
      // Both existing audio-only lines only print once a swap is ATTEMPTED, so a
      // video that failed DETECTION produced no line at all — indistinguishable
      // in a transcript from an ordinary audio track. These are the two inputs
      // the decision is made from, so a future miss names its own cause.
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
      // Cache-backed: if the list-display overlay (conform_provider) already
      // resolved this video while the user was scrolling, this returns instantly
      // with no second lookup.
      // strict only for the WEAK signal. A tagged video and a 16:9 ytimg still
      // are both reliable, and requiring an exact title match on those threw
      // away good matches that differ by a suffix ("(Official Audio)").
      final rawAudio = await _searchService.conformToAudioCached(
          inputSong, strict: !(confirmedVideo || videoThumb));
      if (!mounted) return;
      // Take the AUDIO, keep the EDITION. Substituting the conformed Song
      // wholesale handed over its cover and album id from a search result, which
      // could flip a deluxe track's artwork to the standard edition's mid-play.
      final audio = rawAudio == null
          ? null
          : SearchService.mergeConformedAudio(inputSong, rawAudio);
      // The swap that never settled, AND it froze the app
      //
      // THE BUG THIS FIXES, captured on device 2026-08-30 at 04:54:16 — every
      // one of these lines inside the SAME MILLISECOND:
      //
      //     Audio-only: swapped video "willow" → audio "willow" (mjsrrvbOeFo)
      //     Audio-only: swapped video "willow" → audio "willow" (qxrMpCMdYwk)
      //     Audio-only: swapped video "willow" → audio "willow" (mjsrrvbOeFo)
      //     …until Android offered "Auvy isn't responding" and the user closed it
      //
      // Two recordings of one song, each of which conforms to the OTHER. The
      // only guard was `audio.id != inputSong.id`, which stops A→A and says
      // nothing about A→B→A. And the loop is TIGHT rather than slow: after the
      // first two lookups both answers are in conformToAudioCached's memory
      // cache, so each turn costs no network and does five whole-queue copies
      //, which is what pins the isolate.
      //
      // It needs neither id to be a video. `untaggedInCollection` treats ANY
      // untagged track inside an album or playlist as a candidate, and both of
      // these are untagged, so each side sees the other as the audio it is
      // looking for.
      //
      // THE CHAIN IS THE FIX, NOT A DEPTH LIMIT ALONE. A cap would still let
      // the queue be rewritten several times for nothing; refusing an id already
      // visited stops at the first repeat, and the track we are holding is a
      // perfectly good answer — it IS the audio, by the same lookup that
      // nominated it.
      final chain = {...?conformChain, inputSong.id};
      if (audio != null && chain.contains(audio.id)) {
        print('WARN: conform loop refused: "${inputSong.title}" and ${audio.id} '
            'each conform to the other — playing this one as-is '
            '(chain: ${chain.length})');
      } else if (audio != null && audio.id != inputSong.id) {
        print('Audio-only: swapped video "${inputSong.title}" → audio "${audio.title}" (${audio.id})');
        // CRITICAL: swap the video → audio EVERYWHERE in the LIVE queue before
        // recursing. The conformed audio has a NEW id; without this swap it
        // wouldn't be found in any queue segment, so the recursive playSong
        // treated it as a brand-new play and DROPPED the album/playlist context
        // — then top-up refilled with recommendations. That was the "queue gets
        // cleared and a different one appears after every track" bug (fires on
        // every video track in audio-only mode). With the swap, the advance
        // logic matches by id and the context is preserved.
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

    // NOTE: the pending play debounce is cancelled further down, right before
    // the replacement timer is scheduled — NOT here. Cancelling before the
    // early-return guards meant a rapid duplicate tap could kill the pending
    // load and then bail (same-song guard below), leaving isLoading stuck
    // forever with nothing scheduled to load (audit #4).

    if (currentState.isLoading && _currentFetchId == song.id) return;

    if (effectiveBlacklist.contains(song.id)) {
      final isDisliked = currentState.blacklistedIds.contains(song.id) ||
          ref.read(intelligenceProvider).blacklistedIds.contains(song.id);
      // A transient failure block must never beat a DIRECT user tap: the block
      // exists to stop queue-advance from looping onto a dying stream, but the
      // track itself is usually fine — a fresh URL resolves and plays. Honoring
      // the block here made a manually tapped song silently skip to the next
      // one for up to 5 minutes ("this track is broken" feeling). Queue
      // advancement (auto OR the next-button) still honors the block.
      if (!isDisliked && !viaQueueAdvance && !isNextOrPrev) {
        _failureBlocks.remove(song.id);
        print('Manual play overrides temp failure block: ${song.title}');
      } else {
        if (!isDisliked) {
          final left = _failureBlocks[song.id]?.difference(DateTime.now()).inSeconds ?? 0;
          print('AUTO-SKIP "${song.title}" — temp failure block (${left}s left). '
              'If this track plays fine manually, the block was a false positive.');
        }
        // Strip the blocked track from every queue segment BEFORE skipping:
        // playNext() plays queue[1], which is this very track — without the strip
        // the skip recursed onto the same blocked song forever and playback died.
        List<Song> stripped(List<Song> l) => l.where((s) => s.id != song.id).toList();
        final su = stripped(currentState.userQueue);
        final sc = stripped(currentState.contextQueue);
        final sa = stripped(currentState.autoplayQueue);
        currentState = currentState.copyWith(
          userQueue: su,
          contextQueue: sc,
          autoplayQueue: sa,
          queue: [
            if (currentState.currentSong != null) currentState.currentSong!,
            ...su, ...sc, ...sa,
          ],
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

    // NOTE: the old code silently forced repeatMode to OFF whenever an autoplay
    // track played — that was the "Loop ON randomly turns itself off" quirk.
    // The user's repeat choice is now never touched behind their back.

    // Play crediting (playCounts / My Top 50 / taste model) moved OFF the
    // track START to a LISTEN THRESHOLD (see player_system's position handler):
    // a track counts as a "play" only once it's genuinely heard (~30s, or half
    // its length for short tracks). This stops tap-then-skip from inflating My
    // Top 50 and poisoning the taste model that re-ranks the YouTube-radio recs.
    // Reset the per-track flag as this new track loads.
    _currentPlayRecorded = false;

    // Music only: podcast "lyrics" are feed transcripts (handled in
    // lyricsProvider) and radio has none — an LRC search for either is wasted.
    //
    // AFTER A DWELL, NOT IMMEDIATELY. See _kLyricsDwell. A track skipped
    // past in a second does not need a multi-provider lyrics scan, and paying
    // for one per skip is what makes a skip run expensive enough to get the
    // whole app throttled. Superseding the timer means a run of skips costs one
    // scan, for the track the listener stops on.
    _lyricsDwellTimer?.cancel();
    if (!song.id.startsWith('http')) {
      _lyricsDwellTimer = Timer(_kLyricsDwell, () {
        // Still the same track? A late timer must not warm lyrics for something
        // that is no longer playing.
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
    // True when this play merely ADVANCES inside the queue we already have (no
    // new context). Used below to preserve `originalQueue` — the full-context
    // snapshot Repeat All loops over and un-shuffle restores from.
    bool advancedWithinQueue = isNextOrPrev;

    if (newQueue != null && newQueue.isNotEmpty) {
      final songIndex = index ?? newQueue.indexWhere((s) => s.id == song.id);
      if (songIndex != -1) {
        contextQueueSegment = newQueue.sublist(songIndex + 1);
      } else {
        contextQueueSegment = [...newQueue];
      }
    } else if (isNextOrPrev) {
      // HISTORY navigation (previous, or re-forward through history): the
      // upcoming queue must stay exactly as it is — stepping back to a track
      // should never destroy what's queued next.
      contextQueueSegment  = List.from(currentState.contextQueue);
      autoplayQueueSegment = List.from(currentState.autoplayQueue);
    } else {
      // No explicit new context. If the song is already in the upcoming queue
      // (auto-advance to queue[1], or a skip), ADVANCE WITHIN the existing
      // queue: consume entries up to and including the song, KEEP the rest.
      //
      // The old code wiped contextQueue/autoplayQueue here on EVERY track
      // change, which (a) destroyed a manually built queue and (b) made the
      // "queue is empty → top up" check fire after every single track — the
      // "queue refills itself with recommendations after each song" bug.
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
      // else: a brand-new standalone play — keep the user queue (unchanged
      // behavior), drop context/autoplay (they belonged to the old context).

      // Repeat All → the queue is CIRCULAR: re-append the track that just
      // finished to the END of the upcoming queue so the whole queue loops
      // forever instead of dying at the last track (the old code could only
      // ever loop the final track).
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

    // The now-playing track must NEVER also sit in the upcoming queue — not by
    // id, and not as a different-id TWIN (same title+artist), e.g. the VIDEO
    // version of the song when audio-only swapped the current to its audio
    // equivalent. That twin slipped past id-based dedup and showed up as "the
    // current track is also the next track".
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

    // A different station (or leaving radio entirely) starts at the live edge, so
    // the previous station's pause gap must not carry over onto it.
    if (!_isLiveRadio(song) || song.id != currentState.currentSong?.id) {
      radioPausedAtProvider.value = null;
      radioBehindLiveProvider.value = Duration.zero;
    }

    // "Recently played": every track that STARTS playing lands at the head of
    // history (deduped). Skipped for prev/next history-navigation so stepping
    // back doesn't reorder the trail being walked. (This replaces the old
    // _onSeamlessTransition, which credited the WRONG song and duplicated
    // history entries.)
    List<Song>? updatedHistory;
    if (!isNextOrPrev &&
        !song.id.startsWith('http') &&
        song.albumTitle != 'Podcast' &&
        song.albumTitle != 'RADIO') {
      updatedHistory =
          [song, ...currentState.history.where((s) => s.id != song.id)].take(_kHistoryCap).toList();
      // ABSOLUTE time, not "N minutes ago". History is backed up and restored
      // on another device, potentially days later — anything relative would be
      // computed against the wrong "now" and read as nonsense. See
      // [_historyPlayedAt].
      _historyPlayedAt[song.id] = DateTime.now().millisecondsSinceEpoch;
    }

    currentState = currentState.copyWith(
      currentSong: song,
      // Native gapless advance is already playing this track — not loading.
      isLoading: !alreadyPlayingNatively,
      miniPlayerVisible: true,
      queue: activeQueue,
      history: updatedHistory,
      // Preserve the pre-shuffle snapshot while shuffle is ON (mirrors
      // reorderQueue / jumpToQueueIndex). Clobbering it unconditionally meant
      // the first auto-advance while shuffled destroyed the order that
      // toggleShuffle() needs to restore, so turning shuffle OFF no longer
      // returned to the original order.
      // Also preserved on a mere ADVANCE inside the existing queue: the queue
      // SHRINKS as it plays, so re-snapshotting it here meant `originalQueue`
      // shrank with it — by the last track of an album it held one song. That
      // left Repeat All nothing to loop (it degenerated to Repeat One) and gave
      // un-shuffle less to restore. Only a genuinely NEW context replaces it.
      originalQueue: (currentState.isShuffle || advancedWithinQueue)
          ? currentState.originalQueue
          : List.from(activeQueue),
      currentIndex: 0,
      userQueue: userQueueSegment,
      contextQueue: contextQueueSegment,
      autoplayQueue: autoplayQueueSegment,
      playbackSource: advancedIntoAutoplay ? "Recommended" : source,
      // Two labels that claimed things that were NOT true
      //
      // 1. AUTOPLAY IS NOT RADIO. This read "${song.artist} Radio", and Auvy has
      //    an actual Radio feature — live stations, its own page, its own player
      //    treatment. So rolling off the end of a queue into recommendations
      //    announced a mode the listener had never started, and it was reported
      //    exactly that way: "it says Maroon 5 Radio, I didn't start radio mode".
      //    "Based on" says what is happening without borrowing the name of
      //    something else. ("Mix" is taken too — artist_page uses it for a
      //    deliberately-started artist mix.)
      //
      // 2. THE ALBUM IS NOT A PLACE YOU PLAY FROM. The fallback was
      //    `locationName ?? song.albumTitle`, so a track tapped on Home — which
      //    passes no locationName — rendered "PLAYING FROM HOME" above the
      //    track's ALBUM. Two lines that contradict each other, and the source of
      //    the reported bare "23": whatever happened to sit in albumTitle,
      //    presented as the place the music came from.
      //
      //    Null instead, and the player omits the second line. Saying nothing is
      //    correct here — there IS no collection, and every flow that has one
      //    (album, playlist, library, mood, audiobook) passes locationName
      //    explicitly, with queue advances carrying it forward.
      locationName: advancedIntoAutoplay
          ? "Based on ${song.artist}"
          : locationName,
      contextId: contextId,
      contextType: contextType,
      contextTitle: contextTitle,
      // A NEW play that named no collection has no collection — say so, rather
      // than letting the previous one persist. Restricted to a manual start:
      // advancing inside a queue, a next/prev, and a native gapless handover are
      // all continuations of the SAME context and must keep it.
      clearContext: contextType == null &&
          isManual &&
          !isNextOrPrev &&
          !viaQueueAdvance &&
          !alreadyPlayingNatively,
      position: Duration.zero,
      duration: Duration.zero,
    );

    // The three values the home mosaic makes its decision from
    //
    // A mosaic tile lights up when it believes its collection is what is playing,
    // and it decides that from playbackSource + contextType + contextTitle. That
    // rule has been rewritten twice — once for two tiles claiming to be playing at
    // the same time, once because a tile lit for a track it merely CONTAINED
    // rather than one played FROM it, and neither symptom could be traced,
    // because the values behind the decision were never written down anywhere.
    //
    // One line per track change, at the single point they are assigned. Reading a
    // mosaic complaint against a transcript now means comparing what the tile did
    // against what it was told, instead of guessing at one of them.
    //`loc=` IS THE VALUE ON SCREEN, AND IT WAS THE ONE THING MISSING.
    //
    // This line exists to answer "why does the player say that", and it named
    // source / ctxType / ctxTitle — none of which is what the second line
    // renders. The player shows `locationName`, so three separate reports about
    // that label ("23", "Maroon 5 Radio", a previous track's album) could not be
    // traced from a transcript at all: the printed fields were all correct while
    // the displayed one was wrong.
    //
    // It also prints whether the value was INHERITED. A queue advance carries
    // locationName forward on purpose — that is what keeps "from <playlist>"
    // across a track change, so a stale label and a correct one look identical
    // unless the line says which it is.
    // The marker must mean what the code does
    //
    // This printed "(cleared)" from a THREE-condition test while the assignment
    // above clears on FIVE. So every queue advance and every native hand-off —
    // the cases that carry a context forward on purpose — were reported as
    // having cleared it. A transcript then shows the collection being dropped on
    // a track change that in fact preserved it, which is worse than printing
    // nothing: it sends the reader after a bug that is not there. It sent ME
    // after one.
    //
    // Same expression as `clearContext`, deliberately. If that gains a condition,
    // this has to gain it too — a diagnostic that has drifted from its subject is
    // not a weaker diagnostic, it is a false one.
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
    // A track change supersedes any in-flight seek — never hold its stale
    // target against the NEW track's early position ticks.
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    currentPositionProvider.value = Duration.zero; // snap the progress bar to 0 for the new track

    // Music always starts at natural speed; podcasts start at the listener's
    // remembered pace.
    final startSpeed =
        // Audiobooks share the podcast speed memory: both are spoken word, and a
        // listener who prefers 1.25x means it for narration in general.
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

    // ADAPTIVE transition debounce. A lone tap or a natural track end starts
    // resolving IMMEDIATELY — the old fixed 700ms sat between EVERY pair of
    // tracks and was a big part of "the next song takes a moment to start".
    // Only a rapid skip-storm (another play within 600ms) coalesces behind a
    // short delay so mashing "next" fires one resolve, not one per tap.
    final requestAt = DateTime.now();
    final bool skipStorm = _lastPlayRequestAt != null &&
        requestAt.difference(_lastPlayRequestAt!) < const Duration(milliseconds: 600);
    _lastPlayRequestAt = requestAt;
    final debounce =
        skipStorm ? const Duration(milliseconds: 450) : Duration.zero;

    // Cancel the previous pending play ONLY now that this one is committed
    // and about to be scheduled (see the note at the top of this method).
    _playDebounceTimer?.cancel();
    _playDebounceTimer = Timer(debounce, () async {
      if (!mounted) return;

      if (_lastProcessedSongId == song.id) {
        try {
          if (alreadyPlayingNatively) {
            // GAPLESS: native already transitioned to this track — do NOT reload
            // it (a reload restarts it, defeating the zero-gap transition). The
            // queue/UI/state were updated above; just clear the loading flag.
            // Top-up / lyrics / next-preload below still run for both paths.
            // The engine holds THIS track now, so record it — otherwise the
            // next pause→play would needlessly reload instead of resuming.
            _nativeLoadedSongId = song.id;
            if (mounted && currentState.isLoading) {
              currentState = currentState.copyWith(isLoading: false);
            }
          } else {
          // Acquire audio focus up-front when this play will start audibly, so
          // other apps' audio is paused rather than overlapped.
          if (playImmediately) await _activateAudioFocus();

          // CACHE-FIRST: if the track is already on disk, play the local file
          // directly — instant start, no buffering stalls, instant seeking, no
          // network. Only for real tracks (not live radio http streams).
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
            // Radio / podcast — a direct playable URL; resolve it (as before).
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
            // YouTube track — hand the videoId to the native ResolvingDataSource
            // and let IT resolve the URL lazily (with native retry / re-resolve /
            // play-cache). This keeps the Dart resolve OFF the transition's
            // critical path — a network blip used to make the Dart resolve retry
            // for tens of seconds with playback sitting paused ("it just pauses").
            // The native resolveStream callback (player_system) does the actual
            // resolve on demand, hitting the warm resolver cache when preloaded.
            print('Native-resolving stream: ${song.title}');
            await NativeAudioEngine.playTrack(
              song.id, '',
              autoPlay: playImmediately,
            );
          }

          // The engine now holds a media item for this track — a later play tap
          // can resume() rather than reload (see togglePlay's cold-start guard).
          _nativeLoadedSongId = song.id;

          // Podcasts: continue where the listener left off. (Music always
          // starts from the top.)
          // A CHAPTER IS RESUMED, LIKE AN EPISODE — NOT RESTARTED.
          //
          // This read `albumTitle == 'Podcast'`, so an audiobook chapter was
          // never bookmarked and never resumed. A 40-minute chapter closed at
          // minute 35 began again at zero, which is the one thing a book cannot
          // do, and it is the same 'behave like an episode, not like radio'
          // mismatch that MediaKind exists to end.
          if (song.isSpokenWord) {
            final resume = await _getPodcastResumePosition(song);
            if (resume != null && resume > const Duration(seconds: 10)) {
              await NativeAudioEngine.seek(resume);
              currentPositionProvider.value = resume;
              print('Resuming ${song.mediaKind == MediaKind.audiobook ? "chapter" : "podcast"} '
                  'at ${resume.inMinutes}m${resume.inSeconds % 60}s');
            }
            // Sponsor breaks are a podcast thing; a public-domain reading has
            // none, and looking would be a wasted feed fetch.
            if (song.mediaKind == MediaKind.podcast) {
              // Costs a feed fetch, so playback must not wait on it.
              unawaited(_loadSponsorBreaks(song));
            }
          }

          if (playImmediately) {
            _fadeIn(currentState.volume);
          }
          } // end !alreadyPlayingNatively (gapless: skip the native reload)

          // Autoplay top-up ONLY when the queue is about to run dry — it never
          // refills over a queue the user built (Spotify-style: recommendations
          // kick in when YOUR queue ends). The refresh button in the queue
          // sheet (refreshAutoplay) remains the manual trigger. Threshold 2 (not
          // 1) so the refill has a full track of headroom to finish on slow
          // networks before the queue actually runs dry.
          final upcoming = userQueueSegment.length +
              contextQueueSegment.length +
              autoplayQueueSegment.length;
          // Only music gets a top-up. Radio's "artist" is "Live Radio •
          // <country>", so the top-up searched YouTube for that and filled the
          // queue with unrelated tracks — any stream hiccup then advanced into
          // them. A podcast episode and a book chapter want it no more than a
          // station does. (_topUpQueueInner refuses them all as well; this is
          // the early-out that saves the trip.)
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
          // Nothing usable is loaded — a later play tap must reload, not resume.
          _nativeLoadedSongId = null;
          // Carry the INTENT (this play was meant to be audible) into recovery:
          // deriving it from isPlaying there read `false` right after a track
          // ended, so the retried track loaded PAUSED — the "next song sits on
          // pause until I press play" bug.
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
    currentState = currentState.copyWith(miniPlayerVisible: false);
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

  /// How long a track START fades up over.
  ///
  /// 380ms, NOT TWO SECONDS. The old fade-in ran 20 steps of 100ms, so every
  /// non-gapless track swelled in over two full seconds, and it slept BEFORE the
  /// first write, adding 100ms of dead silence on top. That is the opposite of a
  /// seamless join: long enough to hear as an effect. This is the click-
  /// suppression window — enough to avoid a hard edge on the first sample, short
  /// enough that the track simply begins.
  static const Duration _kStartFade = Duration(milliseconds: 380);

  /// One volume ramp, shared by every fade in the player.
  ///
  /// EQUAL-POWER, NOT LINEAR IN AMPLITUDE. Hearing is roughly logarithmic, so
  /// a linear amplitude ramp does not sound linear — it hangs loud through the
  /// middle and then collapses at the end, which is exactly what makes a fade
  /// audible AS a fade. The gain follows sin(t·π/2) going up and cos(t·π/2)
  /// coming down, whose squares sum to 1: constant perceived loudness across the
  /// join, which is the "one continuous track" effect.
  ///
  /// TIME-DRIVEN, NOT STEP-COUNTED. The old loops did `steps` iterations of
  /// `delay(duration/steps)`, so the real duration was the intended one PLUS the
  /// accumulated cost of every channel write — a "6s" fade overran, and could
  /// still be ramping when the track ended. This reads a Stopwatch instead, so it
  /// lands on time no matter how slow the writes are, and simply takes coarser
  /// jumps on a loaded device rather than running long.
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
    // 50 Hz. Fast enough that the ramp is inaudible as steps, slow enough that a
    // multi-second fade is a few hundred channel writes rather than thousands.
    const tick = Duration(milliseconds: 20);
    final fadingIn = to >= from;
    final watch = Stopwatch()..start();
    NativeAudioEngine.setVolume(from);

    while (true) {
      await Future.delayed(tick);
      // A newer ramp owns the volume now, or the notifier is gone.
      if (!mounted || generation != _fadeGeneration) return;
      final t = (watch.elapsedMilliseconds / over.inMilliseconds).clamp(0.0, 1.0);
      // Normalised progress along `from`→`to`, shaped so the GAIN itself follows
      // the equal-power curve in both directions.
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
      currentState = currentState.copyWith(
        isLoading: true, 
        currentSong: song,
        locationName: song.albumTitle.isNotEmpty ? song.albumTitle : null,
      );

      _applyAudioNormalization();
      _updateMediaItem(song);

      // Playback that starts audibly must own the system audio focus.
      if (playImmediately) await _activateAudioFocus();

      // CACHE-FIRST: play the local file directly when the track is cached.
      final cachedPath =
          song.id.startsWith('http') ? null : _cacheManager.getCachedPath(song.id);
      if (cachedPath != null) {
        await NativeAudioEngine.playTrack(
          song.id, cachedPath,
          localPath: cachedPath,
          autoPlay: playImmediately,
        );
      } else if (song.id.startsWith('http')) {
        // Radio / podcast direct stream — resolve the playable URL.
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
        // YouTube — hand the videoId to the native ResolvingDataSource (lazy
        // resolve + native retry); keeps the Dart resolve off the critical path.
        await NativeAudioEngine.playTrack(song.id, '', autoPlay: playImmediately);
      }

      // The engine now holds a media item for this track, so a later togglePlay
      // can legitimately resume() instead of reloading.
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
      // The load failed, so the engine holds nothing usable for this track —
      // don't let a later play tap resume() into silence.
      _nativeLoadedSongId = null;
      if (mounted) currentState = currentState.copyWith(isLoading: false);
      _handlePlaybackError(e, intendedPlaying: playImmediately);
    }
  }

  /// Fade up after a resume. Was a second, separate 10×50ms linear ramp — two
  /// implementations of one idea, with different durations and different curves.
  /// Now the same ramp as everything else.
  Future<void> _fadeInAudio() =>
      _rampVolume(from: 0.0, to: currentState.volume, over: _kStartFade);

  // NOTE: the old _onSeamlessTransition was removed: playSong now rotates the
  // queue segments itself, history is written at play-start, and the completed
  // -listen credit happens in playNext(autoAdvance:true) — where the finished
  // track is still currentSong (the old code credited the WRONG song).

  void _validateSyncState() {
    // Hardware sync is natively managed by Kotlin now.
    // Dart is the source of truth for the queue!
  }

  void _startCacheTimer(Song song) {
    if (song.id.startsWith('http')) return; // live radio — never cached
    _cacheTimer?.cancel();

    if (_cacheManager.isCached(song.id)) return;
    // Already tried this song this session (success or fail) — never re-arm.
    // This is the loop breaker: a failed auto-cache no longer re-downloads on
    // every pause/resume.
    if (_autoCacheAttempted.contains(song.id)) return;

    // Auto-cache played tracks into the "Cached" folder, but ONLY on unmetered
    // Wi-Fi. On mobile data Auvy behaves like Spotify/Apple Music: it STREAMS
    // only (the native media3 play-cache already keeps the bytes you actually
    // listen to), so cellular data is never spent bulk-downloading in the
    // background. After a 10s grace so a track skipped within a couple seconds
    // isn't downloaded.
    _cacheTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || currentState.currentSong?.id != song.id) return;
      // Skip if it's already cached/downloaded.
      if (_cacheManager.isCached(song.id)) return;
      // 0-NETWORK PROMOTION: if the whole track is already in
      // the native media3 play-cache (a short track fully buffered by now), copy
      // those bytes into the visible Cached folder. NO HTTP re-download — that
      // second full download over HTTP (on top of the stream) was the mobile-
      // data drain we killed. The empty url means "promotion only": cacheTrack
      // no-ops if the play-cache doesn't yet hold the full track, and the
      // genuine-end handler (player_system.onTrackEnded) promotes it once the
      // track has streamed end-to-end. Works on any network (copies local bytes),
      // so no Wi-Fi/data-saver gate is needed here anymore.
      _autoCacheAttempted.add(song.id);
      try {
        await _cacheManager.cacheTrack(song, '', isExplicitDownload: false);
      } catch (_) {}
    });
  }

  void _stopCacheTimer() {
    _cacheTimer?.cancel();
  }

  // NOTE (2026-07-19): the disk-prefetch WINDOW was removed — pre-downloading
  // upcoming queue tracks re-downloaded on every queue edit (wasted data) and
  // the user rejected the disk approach. The real fix is the native
  // ResolvingDataSource + media3 SimpleCache play-cache:
  // URLs resolve lazily per-chunk inside the player and only bytes actually
  // played get cached. See NativePlayerManager.

  /// The native engine no longer holds a media item (it was stopped, or the
  /// process-level session was torn down). The next play tap must LOAD rather
  /// than resume. See the cold-start branch in [togglePlay].
  void markNativeUnloaded() => _nativeLoadedSongId = null;

  void stopAndDismiss() async {
    if (!mounted) return;
    if (currentState.crossfadeEnabled) {
      await _startCrossfade();
    }
    NativeAudioEngine.stop();
    _nativeLoadedSongId = null;

    currentState = currentState.copyWith(
      isPlaying: false,
      currentSong: null,
      position: Duration.zero,
    );

    // Tear the media session down too. Without this the notification stayed
    // up (and broadcastState kept re-posting it) after an idle-kill/dismiss —
    // a "playing nothing" zombie in the media controls.
    try {
      await _audioHandler?.stop();
    } catch (_) {}
  }

  void cycleRepeatMode() {
    if (!mounted) return;
    final modes = [RepeatMode.off, RepeatMode.all, RepeatMode.one];
    final currentIdx = modes.indexOf(currentState.repeatMode);
    final nextMode = modes[(currentIdx + 1) % modes.length];

    currentState = currentState.copyWith(repeatMode: nextMode);

    // GAPLESS × REPEAT — the fix for "Repeat One behaves like Repeat Off".
    // The NATIVE ExoPlayer, not Dart, is what actually plays at a track
    // boundary: `_preloadNextTrack` arms the next track as an upcoming media
    // item, and ExoPlayer rolls into it with no STATE_ENDED. So a repeat-mode
    // change MUST invalidate that armed item, or the boundary still honours the
    // OLD mode:
    //   • → Repeat One: an armed upcoming defeats the loop entirely — ExoPlayer
    //     advances to the next song and Dart's repeat-one branch then seeks 0 on
    //     the WRONG media item. Nothing must be armed in this mode.
    //   • → Off / All: the correct "next" can differ from what was armed.
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    _preloadedSongId = null;
    if (nextMode != RepeatMode.one && currentState.isPlaying) {
      Future.microtask(() => _preloadNextTrack());
    }

    //"Repeat All behaved like Repeat One" — with nothing upcoming, Repeat
    // All can only replay the CURRENT track (playNext's dry branch seeks to 0).
    // That is what happens when the user hits Loop late in a context (e.g. on
    // the LAST track of an album): the queue has already been consumed, so the
    // "loop" is one track long. Re-seed it from the full context snapshot.
    if (nextMode == RepeatMode.all) _reseedRepeatAllLoop();

    if (nextMode == RepeatMode.off && currentState.autoplayQueue.length < 5) {
      Future.microtask(() => _topUpQueue());
    }

    _saveSettings();
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
    // Actually arm ExoPlayer's silence trimmer. This call was missing, so the
    // setting only ever persisted a bool that nothing read.
    NativeAudioEngine.setSkipSilence(next);
  }

  void toggleEq() async {
    if (!mounted) return;
    final next = !currentState.eqEnabled;
    currentState = currentState.copyWith(eqEnabled: next);
    _saveSettingsDebounced();
    // Push to the native Equalizer (bound to the ExoPlayer audio session). When
    // OFF, the native side disables the effect — bands are kept so re-enabling
    // restores them.
    NativeAudioEngine.setEqualizer(next, currentState.eqBands);
  }

  void applyEqBands(List<double> bands, {bool persist = true}) {
    if (bands.length != 5) return;
    final clamped = bands.map((v) => v.clamp(-12.0, 12.0)).toList();

    if (persist && mounted) {
      currentState = currentState.copyWith(eqBands: clamped);
      _saveSettingsDebounced();
    }
    // Apply live to the native engine (real-time while dragging a band slider).
    NativeAudioEngine.setEqualizer(currentState.eqEnabled, clamped);
  }

  /// Push the current track's loudness correction to the native engine.
  ///
  /// Previously this scaled `player.volume` by a factor derived from
  /// `Song.loudness`, but `loudness` is only ever set for podcasts and radio
  /// (both hardcoded to the -14 target, i.e. a no-op), so for every YouTube
  /// track the condition was false and "Normalize volume" did nothing at all.
  /// Loudness now comes from YouTube's own `audioConfig.loudnessDb`, captured
  /// per videoId when the stream resolves (`player_system`'s stream resolver).
  ///
  /// A volume scale can only ever turn things DOWN, so a quiet master stayed
  /// quiet. The gain goes to the native side in millibels instead: positive =
  /// LoudnessEnhancer boost, negative = a player-volume trim. Falls back to
  /// `Song.loudness` so podcast/radio behaviour is unchanged.
  void _applyAudioNormalization() {
    if (!mounted) return;
    final song = currentState.currentSong;
    if (song == null) return;

    // GAIN FIRST, THEN VOLUME. The order used to be reversed, and it was the
    // whole bug: setVolume applies the CURRENT attenuation scale, so calling it
    // before the new gain arrived scaled this track by the previous track's
    // correction. Native now recomputes the trim inside setNormalizationGain
    // too, so neither call can leave the two out of step, but sending them in
    // the order they depend on keeps that a belt rather than the only brace.

    if (!currentState.audioNormalizationEnabled) {
      NativeAudioEngine.setNormalizationGain(false, 0);
      NativeAudioEngine.setVolume(currentState.volume);
      return;
    }

    final double? measured = _loudnessByVideoId[song.id] ?? song.loudness;
    if (measured == null) {
      // No loudness for this track (not resolved yet, or a local file) — clear
      // any correction left over from the PREVIOUS track rather than letting it
      // ride. Carrying it over is what made an unresolved track play at the
      // wrong level for no visible reason.
      NativeAudioEngine.setNormalizationGain(false, 0);
      NativeAudioEngine.setVolume(currentState.volume);
      return;
    }

    //`loudnessDb` IS THE CONTENT'S LEVEL, NOT A GAIN TO APPLY. I changed
    // this to `-measured` on the theory that YouTube already hands back a
    // correction, and the device disproved it within a minute: gains jumped to
    // +1716 and +982 mB — 17 dB and 10 dB of BOOST on ordinary tracks, which
    // would clip badly.
    //
    // The observed values settle it. Real sources cluster at -7.7 to -10.6 with
    // occasional outliers like -17.2. Read as content loudness those are
    // ordinary loud masters (-8 to -10 LUFS) plus one quiet track, and
    // correcting to the -14 streaming target gives ~-5.5 dB cuts and a +3 dB
    // lift respectively — exactly what normalization should do. Read as a
    // correction they would mean boosting nearly everything by 8-10 dB, which
    // no mastering reality produces.
    //
    // So the ~5 dB cut this applies is CORRECT, not the dampening bug. That was
    // the ordering fault above (each track got its neighbour's correction and a
    // loud master could pin the trim at 0.1 indefinitely). If normalized
    // playback still feels quiet next to other apps, that is normalization
    // working as designed — the switch to turn it off is in Settings.
    const double targetLoudness = -14.0;
    final double correctionDb = targetLoudness - measured;

    // Asymmetric limits, because the two directions carry different risk. A cut
    // is always safe; a large boost amplifies noise and clips. A pathological
    // source value (or a badly-tagged track) could otherwise ask for +20 dB.
    final int gainMb = (correctionDb * 100).round().clamp(-2000, 700);
    NativeAudioEngine.setNormalizationGain(true, gainMb);
    NativeAudioEngine.setVolume(currentState.volume);
  }

  // NOTE: `applyCrossfade(int remainingSeconds)` was removed. It was DEAD — no
  // caller anywhere in the app, and it could not have worked as written: driven
  // by whole remaining SECONDS, it would have stepped the volume once per second,
  // which is a staircase rather than a fade. A real per-track crossfade needs two
  // overlapping streams (see the note on _startCrossfade).

  /// Fade the CURRENT track down to silence.
  ///
  /// THIS IS A FADE-OUT, NOT A CROSSFADE, and the only caller is
  /// [stopAndDismiss]. Track-to-track continuity comes from native gapless
  /// (`NativeAudioEngine.setUpcoming` — ExoPlayer pre-buffers the next item and
  /// rolls into it with no gap at all), which is a better "single track" effect
  /// than any fade: a true crossfade needs TWO streams playing at once, and this
  /// engine exposes one volume. Fading one stream out and the next in leaves a dip
  /// through the middle, which is more audible than the seam it hides.
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
    // Restore, or the next playback starts silent.
    if (mounted) NativeAudioEngine.setVolume(currentState.volume);
  }

  // Podcast continuity
  // Episodes bookmark themselves: pause / switch away / app restart, and the
  // episode resumes at the same second. Finished episodes clear their bookmark.

  Future<void> _savePodcastPosition(Song episode, Duration position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_podcastPositionsKey);
      final Map<String, dynamic> map =
          raw != null ? Map<String, dynamic>.from(jsonDecode(raw)) : {};
      final key = episode.id.hashCode.toString();
      if (position.inSeconds > 5) {
        // Store the REAL episode length beside the position.
        //
        // The episode list used to compute "time left" purely from the feed's
        // <itunes:duration>, which is frequently absent (→ 0, and the row then
        // silently showed the POSITION instead of the remainder) and is only ever
        // approximate when present — ad insertion changes the actual file length.
        // The engine knows the true duration once the episode is playing, so
        // whatever we learn gets persisted and reused by the UI.
        //
        // Only trust currentState.duration when it belongs to THIS episode: this
        // is also called for the episode being LEFT, where the state may already
        // describe the incoming track. Any previously-learned duration is kept
        // rather than overwritten with 0.
        final int liveMs = (currentState.currentSong?.id == episode.id)
            ? currentState.duration.inMilliseconds
            : 0;
        final prev = map[key];
        final int prevMs = (prev is Map && prev['d'] is int) ? prev['d'] as int : 0;
        final int totalMs = liveMs > 0 ? liveMs : prevMs;
        map[key] = {
          'p': position.inMilliseconds,
          if (totalMs > 0) 'd': totalMs,
          // WHEN it was last listened to. Without this, "Continue listening" had
          // to guess, and guessed by feed order, so it offered the NEWEST
          // episode you had started rather than the one you were actually in the
          // middle of.
          't': DateTime.now().millisecondsSinceEpoch,
        };
        // Said once per item, NOT once per write.
        //
        // This heartbeat runs every 5s, so a line per write would bury a
        // transcript. One line the first time an episode or chapter is
        // bookmarked is enough to prove the path RAN, which is the open
        // question now that audiobook chapters use this ledger and nothing in
        // it ever said anything at all.
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
      // Cap the ledger so years of listening can't grow it unbounded.
      while (map.length > 200) {
        map.remove(map.keys.first);
      }
      await prefs.setString(_podcastPositionsKey, jsonEncode(map));
    } catch (e) {
      // Losing a bookmark is losing someone's place in a nine-hour book, so it
      // is worth a line. Swallowed before, which is why a failure here could
      // never have been told apart from the position never being saved at all.
      print('WARN: could not save the resume position for '
          '"${episode.title}": $e');
    }
  }

  /// The last item bookmarked, so the heartbeat says so once instead of every
  /// five seconds.
  static String? _lastBookmarkedId;

  // Live radio

  /// A live stream: the id is the stream URL itself, and it isn't a podcast
  /// enclosure (podcasts also carry a URL id. See PodcastEpisode.toSong).
  ///
  /// AN AUDIOBOOK CHAPTER IS NOT A RADIO STATION. This asked the question by
  /// elimination — an http id that is not a podcast, and an audiobook chapter
  /// is exactly that, so every listener of this predicate treated a book as a
  /// live broadcast: the pause/resume gap accounting started running against
  /// it, and 'go live' would have reconnected to the top of the chapter. Asking
  /// MediaKind instead means a new kind of media cannot silently inherit radio's
  /// behaviour by having a URL for an id.
  bool _isLiveRadio(Song? s) => s != null && s.mediaKind == MediaKind.liveStream;

  /// Rejoin the broadcast at the LIVE EDGE, discarding the accumulated gap.
  ///
  /// Reconnects rather than seeks: a live stream generally has no seekable window
  /// to jump forward within, and a fresh connection IS the live edge.
  Future<void> goLiveRadio() async {
    final s = currentState.currentSong;
    if (!_isLiveRadio(s)) return;
    HapticService.medium();
    radioPausedAtProvider.value = null;
    radioBehindLiveProvider.value = Duration.zero;
    // Force a real reload — the engine already holds this media item, so the
    // resume path would otherwise just continue from the stale buffer.
    _nativeLoadedSongId = null;
    await _loadAndPlay(s!);
  }

  // Sponsor breaks

  /// Work out the playing episode's ad ranges ONCE, when it starts.
  ///
  /// Only breaks the SHOW ITSELF timestamps are found — chapter JSON, or
  /// "(00:18:36) Sponsors: …" lines in the notes (see PodcastExtrasService).
  /// Dynamically-inserted ads shift per download and are genuinely undetectable
  /// from feed data, so those still play; this never guesses.
  Future<void> _loadSponsorBreaks(Song song) async {
    _adSkipRanges = const [];
    _adSkipsDone.clear();
    _adRangesForSongId = null;
    if (song.albumTitle != 'Podcast') return;
    try {
      final chapters = await ref.read(podcastChaptersProvider.future);
      // The listener can switch episodes while the feed request is in flight —
      // arming the previous episode's breaks against the new one would seek to
      // arbitrary places in it.
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
      // No chapter data, which is the common case. Nothing to skip.
    }
  }

  /// Jump past a sponsor break the moment playback reaches it.
  void _maybeSkipSponsorBreak(Duration position) {
    if (_adSkipRanges.isEmpty) return;
    final song = currentState.currentSong;
    if (song == null || _adRangesForSongId != song.id) return;
    final ms = position.inMilliseconds;
    for (final r in _adSkipRanges) {
      final start = r[0];
      final end = r[1];
      if (ms < start || ms >= end) continue;
      // Already jumped this one: the listener has since scrubbed back into it,
      // and must be allowed to stay.
      if (_adSkipsDone.contains(start)) return;
      // Only skip a break we ARRIVED at by playing into it. Landing in the middle
      // of one means it was sought deliberately, and yanking forward there would
      // make the break impossible to listen to on purpose.
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
      // Two shapes on purpose: a bare int is a bookmark written before durations
      // were stored, and must keep working across the upgrade rather than
      // silently losing every existing resume point.
      final ms = (entry is Map) ? entry['p'] : entry;
      if (ms is int && ms > 0) return Duration(milliseconds: ms);
      return null;
    } catch (_) {
      return null;
    }
  }
}