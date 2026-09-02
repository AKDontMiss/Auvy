part of '../providers/player_provider.dart';

/// The queue is three lanes, NOT one list
///
/// Everything in this file makes sense once that is clear, and almost nothing
/// does before it. `state.queue` is a DERIVED view, rebuilt after every mutation
/// as exactly:
///
///     queue = [ currentSong, ...userQueue, ...contextQueue, ...autoplayQueue ]
///
///   • userQueue     — what the listener explicitly asked for ("add to queue").
///                     Plays first, because an explicit request outranks
///                     anything the app decided on its own.
///   • contextQueue  — the rest of the album / playlist / radio being played.
///   • autoplayQueue — algorithm-generated continuation, so playback never ends.
///
/// Two rules follow, and breaking either causes bugs that look unrelated:
///
/// 1. **Index 0 is the PLAYING track, not a pending one.** Every scan for "is
///    this already queued" starts at 1, and [removeFromQueue] maps a `queue`
///    index back to its lane with `rel = index - 1`. An off-by-one here removes
///    the wrong song.
/// 2. **Never mutate `queue` directly.** Write the lane, then let the rebuild
///    produce `queue`. A direct write disagrees with the lanes on the next
///    mutation, and the lanes are what persist.
///
/// `originalQueue` is the pre-shuffle snapshot, so turning shuffle off restores
/// an order rather than re-sorting. `userQueueEndIndex` marks where the user's
/// own entries stop, for the "Up next" divider.
///
/// Mutations are serialised through `_lockMutation` and end by calling
/// [resyncUpcomingIfChanged]: the native player is told the NEXT track in advance
/// for gapless playback, so a queue edit that changes what is next has to correct
/// that, or the old next track plays for a moment first.
extension PlayerQueueController on PlayerNotifier {

  /// The id of the track currently in the "up next" slot (`queue[1]`), or null
  /// if nothing is queued after the current track. Captured BEFORE a mutation
  /// so [resyncUpcomingIfChanged] can tell whether the gapless native upcoming
  /// went stale (see the fix for the "wrong next song plays for ~500ms" bug).
  String? _upNextId() =>
      currentState.queue.length > 1 ? currentState.queue[1].id : null;

  /// Where [song] already sits as a PENDING entry, or -1.
  ///
  /// Matches by id AND by title+artist SIGNATURE — id-only let the video/audio
  /// TWIN of a queued track (different id, same song) slip back in, which showed
  /// up as "the same song twice in the queue".
  ///
  /// THE SCAN STARTS AT 1, AND THAT IS THE WHOLE POINT. `queue[0]` is the
  /// track PLAYING, not something waiting to be played, so it is not a duplicate
  /// of anything — queueing the song you are listening to means "play it again
  /// after this", which is a perfectly ordinary thing to ask for.
  ///
  /// One predicate for both callers, because two of them disagreed AND the UI
  /// LIED ABOUT IT. [toggleQueue] skipped index 0; [addToQueue]'s own check did
  /// not. So queueing the current track made toggleQueue report "added" — the
  /// toast appeared, the artwork flew to the mini-player, the haptic fired — and
  /// then addToQueue found the playing track in its scan and returned without
  /// adding anything. Every attempt looked like it worked and none of them did,
  /// so the swipe could be repeated forever with no effect.
  ///
  /// The twin case was the same lie from the other direction: toggleQueue matched
  /// on id only, so a queued twin was invisible to it and it reported "added"
  /// while addToQueue's signature check dropped the song. Sharing this one
  /// predicate makes the two answers agree by construction.
  int _pendingQueueIndexOf(Song song) {
    String sig(Song s) =>
        '${s.title.toLowerCase().trim()}_${s.artist.toLowerCase().trim()}';
    final target = sig(song);
    for (var i = 1; i < currentState.queue.length; i++) {
      final s = currentState.queue[i];
      if (s.id == song.id || sig(s) == target) return i;
    }
    return -1;
  }

  /// Whether [song] is already waiting in the queue. For callers that reach
  /// [addToQueue] directly and need to word their own feedback honestly — read it
  /// BEFORE the add, since the add changes the answer.
  bool isPendingInQueue(Song song) => _pendingQueueIndexOf(song) != -1;

  // ==============================================================
  // ADD SINGLE SONG
  // ==============================================================
  Future<void> addToQueue(Song song, {bool skipDuplicateCheck = false}) async {
    HapticService.selection();
    if (currentState.queue.isEmpty) {
      playSong(song, source: 'Queue');
      return;
    }

    if (!skipDuplicateCheck && _pendingQueueIndexOf(song) != -1) {
      print('Already in queue: ${song.title}');
      return;
    }

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final updatedUser = [...currentState.userQueue, song];
        final currentSong = currentState.currentSong;

        final newQueue = [
          if (currentSong != null) currentSong,
          ...updatedUser,
          ...currentState.contextQueue,
          ...currentState.autoplayQueue,
        ];

        currentState = currentState.copyWith(
          userQueue:     updatedUser,
          queue:         newQueue,
          originalQueue: [...currentState.originalQueue, song],
        );

        print(' Queued "${song.title}" manually');
      } catch (e) {
        print('ERROR: addToQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // ==============================================================
  // Add album to queue
  // ==============================================================
  Future<void> addAlbumToQueue(List<Song> albumTracks, {String? albumId}) async {
    HapticService.selection();

    if (currentState.queue.isEmpty) {
      playSong(albumTracks.first, newQueue: albumTracks, source: 'Album');
      return;
    }

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final existingIds = currentState.queue.map((s) => s.id).toSet();
        final isPlayingFromAlbum = currentState.contextId == albumId;

        List<Song> tracksToAdd;

        if (isPlayingFromAlbum) {
          print('Playing from this album – replacing upcoming tracks');
          final currentIdx = albumTracks.indexWhere((s) => s.id == currentState.currentSong?.id);

          tracksToAdd = (currentIdx != -1 && currentIdx < albumTracks.length - 1)
              ? albumTracks.sublist(currentIdx + 1)
              : albumTracks;

          final newQueue = [
            if (currentState.currentSong != null) currentState.currentSong!,
            ...currentState.userQueue,
            ...tracksToAdd,
            ...currentState.autoplayQueue,
          ];

          currentState = currentState.copyWith(
            contextQueue:  tracksToAdd,
            queue:         newQueue,
            originalQueue: List.from(newQueue),
            contextId:     albumId,
            contextType:   'album',
          );
        } else {
          tracksToAdd = albumTracks.where((s) => !existingIds.contains(s.id)).toList();

          if (tracksToAdd.isEmpty) {
            print('All album tracks already in queue');
            return;
          }

          final updatedUser = [...currentState.userQueue, ...tracksToAdd];
          final newQueue = [
            if (currentState.currentSong != null) currentState.currentSong!,
            ...updatedUser,
            ...currentState.contextQueue,
            ...currentState.autoplayQueue,
          ];

          currentState = currentState.copyWith(
            userQueue:     updatedUser,
            queue:         newQueue,
            originalQueue: List.from(newQueue),
          );
        }

        print(' Added ${tracksToAdd.length} album tracks to queue');
      } catch (e) {
        print('ERROR: addAlbumToQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // ==============================================================
  // REMOVE FROM QUEUE
  // ==============================================================
  Future<void> removeFromQueue(int index) async {
    if (index <= 0 || index >= currentState.queue.length) return;

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final songToRemove = currentState.queue[index];

        ref.read(lastRemovedItemProvider.notifier).state = RemovedQueueItem(
          song:          songToRemove,
          index:         index,
          timestamp:     DateTime.now(),
          userQueue:     List.from(currentState.userQueue),
          contextQueue:  List.from(currentState.contextQueue),
          autoplayQueue: List.from(currentState.autoplayQueue),
        );

        final rel      = index - 1;
        final uBound   = currentState.userQueue.length;
        final cBound   = uBound + currentState.contextQueue.length;

        List<Song> newUser  = List.from(currentState.userQueue);
        List<Song> newCtx   = List.from(currentState.contextQueue);
        List<Song> newAuto  = List.from(currentState.autoplayQueue);

        if (rel < uBound) {
          newUser.removeAt(rel);
        } else if (rel < cBound) {
          newCtx.removeAt(rel - uBound);
        } else {
          final autoRel = rel - cBound;
          if (autoRel < newAuto.length) newAuto.removeAt(autoRel);
        }

        final newQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...newUser, ...newCtx, ...newAuto,
        ];

        currentState = currentState.copyWith(
          userQueue:     newUser,
          contextQueue:  newCtx,
          autoplayQueue: newAuto,
          queue:         newQueue,
          originalQueue: List.from(newQueue),
        );

      } catch (e) {
        print('ERROR: removeFromQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        Future.delayed(const Duration(milliseconds: 300), () {
        });
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  Future<void> undoRemoveFromQueue() async {
    final lastRemoved = ref.read(lastRemovedItemProvider);
    if (lastRemoved == null) return;

    if (DateTime.now().difference(lastRemoved.timestamp).inSeconds > 10) {
      ref.read(lastRemovedItemProvider.notifier).state = null;
      return;
    }

    final prevNext = _upNextId();
    final newQueue = [
      if (currentState.currentSong != null) currentState.currentSong!,
      ...lastRemoved.userQueue,
      ...lastRemoved.contextQueue,
      ...lastRemoved.autoplayQueue,
    ];

    currentState = currentState.copyWith(
      userQueue:     lastRemoved.userQueue,
      contextQueue:  lastRemoved.contextQueue,
      autoplayQueue: lastRemoved.autoplayQueue,
      queue:         newQueue,
      originalQueue: List.from(newQueue),
    );

    resyncUpcomingIfChanged(prevNext);
    ref.read(lastRemovedItemProvider.notifier).state = null;
    _saveSettingsDebounced();
  }

  // ==============================================================
  // REORDER QUEUE
  // ==============================================================
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == 0 || newIndex == 0 || oldIndex == newIndex) return;

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        if (oldIndex < newIndex) newIndex -= 1;

        final upcomingOld = oldIndex - 1;
        final upcomingNew = newIndex - 1;

        final fullList = [
          ...currentState.userQueue,
          ...currentState.contextQueue,
          ...currentState.autoplayQueue,
        ];

        if (upcomingOld < 0 || upcomingOld >= fullList.length ||
            upcomingNew < 0 || upcomingNew >= fullList.length) return;

        final reordered = List<Song>.from(fullList);
        final moved     = reordered.removeAt(upcomingOld);
        reordered.insert(upcomingNew, moved);

        final uBound = currentState.userQueue.length;
        final cBound = uBound + currentState.contextQueue.length;

        int getZone(int idx) => idx < uBound ? 0 : (idx < cBound ? 1 : 2);
        final sZone = getZone(upcomingOld);
        final tZone = getZone(upcomingNew);

        int newULen = currentState.userQueue.length;
        int newCLen = currentState.contextQueue.length;

        if (sZone != tZone) {
          if (sZone == 0) newULen--;
          else if (sZone == 1) newCLen--;
          if (tZone == 0) newULen++;
          else if (tZone == 1) newCLen++;
        }

        final newUser  = reordered.sublist(0, newULen);
        final newCtx   = reordered.sublist(newULen, newULen + newCLen);
        final newAuto  = reordered.sublist(newULen + newCLen);

        final newQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...newUser, ...newCtx, ...newAuto,
        ];

        currentState = currentState.copyWith(
          queue:         newQueue,
          userQueue:     newUser,
          contextQueue:  newCtx,
          autoplayQueue: newAuto,
          originalQueue: currentState.isShuffle
              ? currentState.originalQueue
              : List.from(newQueue),
        );

      } catch (e) {
        print('ERROR: reorderQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        Future.delayed(const Duration(milliseconds: 300), () {
        });
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // ==============================================================
  // CLEAR USER QUEUE
  // ==============================================================
  Future<void> clearUserQueue() async {
    if (currentState.userQueue.isEmpty) return;

    final newQueue  = [
      if (currentState.currentSong != null) currentState.currentSong!,
      ...currentState.contextQueue,
      ...currentState.autoplayQueue,
    ];

    currentState = currentState.copyWith(
      userQueue:         [],
      queue:             newQueue,
      originalQueue:     List.from(newQueue),
      userQueueEndIndex: 0,
    );

    _saveSettings();
  }

  // ==============================================================
  // Jump to queue index
  // ==============================================================
  void jumpToQueueIndex(int index) {
    if (index < 0 || index >= currentState.queue.length) return;

    if (index == 0) {
      NativeAudioEngine.seek(Duration.zero);
      return;
    }

    final jumpedSong = currentState.queue[index];
    final uBound     = currentState.userQueue.length;
    final cBound     = uBound + currentState.contextQueue.length;

    List<Song> newUser  = [];
    List<Song> newCtx   = [];
    List<Song> newAuto  = [];

    for (int i = index + 1; i < currentState.queue.length; i++) {
      final rel = i - 1; 
      if (rel < uBound)       newUser.add(currentState.queue[i]);
      else if (rel < cBound)  newCtx.add(currentState.queue[i]);
      else                    newAuto.add(currentState.queue[i]);
    }

    final isUserJump  = index <= uBound;
    final isAutoJump  = index >  cBound;
    final newSource   = isAutoJump ? 'Discovery' : (isUserJump ? 'Your Queue' : currentState.playbackSource);
    final newLocation = isAutoJump ? jumpedSong.albumTitle : (isUserJump ? 'Manually Added' : (currentState.contextTitle ?? currentState.locationName));

    final newQueue = [jumpedSong, ...newUser, ...newCtx, ...newAuto];

    currentState = currentState.copyWith(
      currentSong:    jumpedSong,
      currentIndex:   0,
      queue:          newQueue,
      userQueue:      newUser,
      contextQueue:   newCtx,
      autoplayQueue:  newAuto,
      playbackSource: newSource,
      locationName:   newLocation,
      originalQueue:  currentState.isShuffle ? currentState.originalQueue : newQueue,
    );

    _loadAndPlay(jumpedSong, playImmediately: true);
  }

  // ==============================================================
  // PLAY NEXT (The Native Engine Way)
  // ==============================================================
  Future<void> playNext({bool autoAdvance = false, bool alreadyPlayingNatively = false}) async {
    if (!autoAdvance && _navIndex > 0) {
      HapticService.light();
      _navIndex--;
      if (_navIndex > 0) {
        final target = currentState.history[_navIndex];
        await playSong(target, source: currentState.playbackSource, locationName: currentState.locationName, isNextOrPrev: true);
        return;
      }
      if (currentState.history.isNotEmpty) {
        final nowSong = currentState.history[0];
        await playSong(nowSong, source: currentState.playbackSource, locationName: currentState.locationName, isNextOrPrev: true);
        return;
      }
    }

    if (!autoAdvance) {
      _navIndex = 0;
      HapticService.light();
      final double total   = currentState.duration.inSeconds.toDouble();
      final double current = currentState.position.inSeconds.toDouble();
      final double percent = total > 0 ? (current / total) : 0.0;
      
      // Guard the force-unwrap: a manual "next" with nothing loaded (stray
      // media-button skip, or next after the queue was cleared) used to throw a
      // null-check exception here instead of no-opping.
      final skipSong = currentState.currentSong;
      if (skipSong != null) {
        await handleSmartSkipDetection(skipSong, percent);
        ref.read(intelligenceProvider.notifier).trackInteraction(
          skipSong,
          percent: percent,
          genreContext: currentState.contextType == 'genre' ? currentState.contextTitle : null,
        );
      }

      if (currentState.currentSong != null) {
        final song = currentState.currentSong!;
        final durationSec = currentState.duration.inSeconds;
        final listenedSec = currentState.position.inSeconds;
        
        final qualifies = listenedSec >= 30 || (durationSec > 0 && (listenedSec / durationSec) >= 0.5);
          
        if (qualifies && !song.id.startsWith('http') && song.albumTitle != 'Podcast' && song.albumTitle != 'RADIO') {
          final updatedHistory = [song, ...currentState.history.where((s) => s.id != song.id)].take(50).toList();
          currentState = currentState.copyWith(history: updatedHistory);
        }
      }
    }

    if (autoAdvance && currentState.sleepAtEndOfTrack) {
      // Sleep at end of track: stop HERE instead of advancing. One-shot —
      // pressing play later resumes normal queue behavior.
      print('End-of-track sleep — pausing instead of advancing');
      currentState = currentState.copyWith(
        clearSleepTimer: true, // also resets sleepAtEndOfTrack
        isPlaying: false,
      );
      NativeAudioEngine.pause();
      await NativeAudioEngine.seek(Duration.zero);
      return;
    }

    if (autoAdvance) {
      // Spoken word that played to the end starts fresh next time — an episode
      // and a book chapter alike, or the bookmark would send the listener back
      // to the last few seconds of something they already finished.
      final finishedPod = currentState.currentSong;
      if (finishedPod != null && finishedPod.isSpokenWord) {
        _savePodcastPosition(finishedPod, Duration.zero);
      }
      // The track finished NATURALLY — credit the full listen while it is
      // still currentSong. (The old _onSeamlessTransition did this 700ms after
      // the switch and credited the NEW track instead.)
      final finished = currentState.currentSong;
      if (finished != null &&
          !finished.id.startsWith('http') &&
          finished.albumTitle != 'Podcast' &&
          finished.albumTitle != 'RADIO') {
        ref.read(intelligenceProvider.notifier).bumpLastPlayTimestamp(finished.id);
        ref.read(intelligenceProvider.notifier).trackInteraction(
          finished, percent: 1.0,
          genreContext: currentState.contextType == 'genre' ? currentState.contextTitle : null,
        );
        // Keep My Top 50 current (ranked by real listen counts).
        final intel = ref.read(intelligenceProvider);
        ref.read(libraryProvider.notifier).refreshTop50(
            intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
        final updatedHistory =
            [finished, ...currentState.history.where((s) => s.id != finished.id)]
                .take(50)
                .toList();
        currentState = currentState.copyWith(history: updatedHistory);
      }
    }

    if (currentState.repeatMode == RepeatMode.one && autoAdvance) {
      await NativeAudioEngine.seek(Duration.zero);
      await NativeAudioEngine.resume();
      return;
    }

    if (currentState.queue.isEmpty) return;

    // Check if we have more songs in the queue
    if (currentState.queue.length > 1) {
       // Since index 0 is playing now, song at index 1 is next!
       final nextSong = currentState.queue[1];

       // The skip that does NOT wait for the network
       //
       // THE BUG THIS FIXES: "sometimes there is a delay when skipping".
       //
       // A track that ENDS naturally is instant, because _preloadNextTrack has
       // already armed the next one as a pre-buffered ExoPlayer item and the
       // engine simply rolls into it. Tapping next threw that away: playSong
       // prepared the track from scratch, which means resolving a stream URL
       // over the network before a single sample can play — for a song the
       // device had already downloaded and buffered.
       //
       // So ask the engine to move to what it is holding. It refuses unless the
       // armed item really is this one (the id is matched natively, where the
       // truth is), and a refusal costs one channel call before falling through
       // to exactly the path that ran before, so the worst case is today's
       // behaviour, and the common case is no wait at all.
       //
       // Only for a DELIBERATE skip while playing: an auto-advance is already
       // handled by the transition itself, and a paused player should stay
       // paused rather than being told to play.
       //
       // AND NOT ONTO A BLOCKED TRACK. playSong auto-skips a disliked or
       // temp-failed queue[1] instead of playing it, so making it audible first
       // and retracting it afterwards would be exactly the wrong order. Cheap
       // to ask, and it keeps the fast path agreeing with the slow one.
       var nativelyAdvanced = alreadyPlayingNatively;
       if (!autoAdvance &&
           !alreadyPlayingNatively &&
           currentState.isPlaying &&
           currentState.gaplessPlayback &&
           !effectiveBlacklist.contains(nextSong.id)) {
         // Armed BEFORE the call: the transition can be delivered while the
         // await is still settling, and a flag set afterwards would arrive too
         // late to suppress the duplicate advance.
         _skipConsumesNextAdvance = true;
         nativelyAdvanced = await NativeAudioEngine.advanceToUpcoming(nextSong.id);
         if (!nativelyAdvanced) {
           _skipConsumesNextAdvance = false;
         } else {
           print('instant skip → "${nextSong.title}" (already buffered, no resolve)');
           // A transition that never lands must not leave the flag standing —
           // it would swallow the next real gapless advance.
           Timer(const Duration(milliseconds: 1500), () {
             if (!_skipConsumesNextAdvance) return;
             _skipConsumesNextAdvance = false;
             // Worth a line: the engine said it had moved and then no
             // transition arrived. Playback is fine either way, but it means
             // the two sides briefly disagreed about which track is playing.
             print('no transition followed the instant skip — flag released');
           });
         }
       }

       // playSong advances WITHIN the existing queue (segments are preserved
       // and rotated there). Carry the source/location so the "playing from"
       // label doesn't reset to "Library" on every auto-advance.
       await playSong(
         nextSong,
         playImmediately: true,
         source: currentState.playbackSource,
         locationName: currentState.locationName,
         // Queue advancement honors temp failure blocks (a direct user tap
         // overrides them. See playSong's blacklist branch).
         viaQueueAdvance: true,
         // GAPLESS: native already transitioned to nextSong — update state but
         // don't reload (which would restart it and defeat the zero-gap hand-off).
         // Also true when the fast path above moved the engine, for the same
         // reason: the audio is already the new track.
         alreadyPlayingNatively: nativelyAdvanced,
       );

    } else {
      if (currentState.repeatMode == RepeatMode.all) {
        // Last track of the loop. Restart the WHOLE context if we still have
        // its snapshot (the normal case now) — only fall back to replaying this
        // single track when there genuinely is no context to loop.
        if (_reseedRepeatAllLoop() && currentState.queue.length > 1) {
          print('Repeat All: restarting the context from the top');
          await playSong(
            currentState.queue[1],
            playImmediately: true,
            source: currentState.playbackSource,
            locationName: currentState.locationName,
            viaQueueAdvance: true,
          );
        } else {
          print('Repeat All: single-track loop (no context to restart)');
          await NativeAudioEngine.seek(Duration.zero);
          await NativeAudioEngine.resume();
        }
      } else {
        // Queue fully dry at track end. force:true — continuing playback is not
        // a background prefetch, so data-saver must not silence the player; and
        // _topUpQueue now AWAITS a refill already in flight instead of no-oping
        // against it (the old flag check burned all retries in ~1.5s and gave
        // up while the refill was still working — playback just stopped).
        print('Queue ended – emergency refill');
        for (int attempt = 0; attempt < 3 && currentState.queue.length <= 1; attempt++) {
          await _topUpQueue(force: true);
          if (currentState.queue.length > 1) break;
          await Future.delayed(const Duration(milliseconds: 400));
        }

        if (currentState.queue.length > 1) {
          await playSong(
            currentState.queue[1],
            playImmediately: true,
            source: currentState.playbackSource,
            locationName: currentState.locationName,
            // WITHOUT THIS THE CONTEXT IS WIPED. playSong treats a call with no
            // contextType as a MANUAL start and clears the stored collection —
            // correct when someone taps a loose track, wrong here, where this is
            // the same playlist continuing after a refill. The label survived
            // (locationName is carried above) while the context did not, so the
            // home mosaic stopped showing the collection as playing while the
            // player still named it. Every other advance in this file passes it.
            viaQueueAdvance: true,
          );
        } else {
          // Nothing arrived (flaky network / recommender empty). Don't die
          // silently: if tracks land shortly after (e.g. the shared refill
          // resolves late), auto-advance instead of sitting stopped forever.
          print('ALERT: Refill found nothing — arming late-arrival rescue');
          // The finished track's clock was left at its end — drop the progress
          // bar to 0 so it doesn't sit pinned at the end while we wait.
          currentPositionProvider.value = Duration.zero;
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 4), () {
            if (mounted && !currentState.isPlaying && currentState.queue.length > 1) {
              print('Late refill landed — resuming playback');
              // Carry the source/location forward: a rescue is still playback
              // from wherever the listener started, and omitting these reset
              // the header to source's "Library" default.
              playSong(currentState.queue[1],
                  playImmediately: true,
                  source: currentState.playbackSource,
                  locationName: currentState.locationName,
                  // Same reason as the refill advance above: without it this
                  // counts as a manual start and clears the collection the
                  // comment right here says it is carrying forward.
                  viaQueueAdvance: true);
            }
          });
        }
      }
    }
  }

  /// Repeat All needs something to loop. Normally it self-sustains: `playSong`
  /// re-appends each finished track, so the queue is CIRCULAR. But when the user
  /// engages Loop late — classically while the LAST track of an album is playing
  /// — the upcoming queue has already been consumed, so the "loop" is one track
  /// long and Repeat All is indistinguishable from Repeat One.
  ///
  /// This restores the loop from `originalQueue` (the full-context snapshot),
  /// rotated so the CURRENT track stays where it is and the rest of the context
  /// follows it. Returns true when a multi-track loop is now in place.
  bool _reseedRepeatAllLoop() {
    if (!mounted) return false;
    // Already have a real loop (the circular case) — leave it alone.
    if (currentState.queue.length > 1) return true;

    final current = currentState.currentSong;
    final pool = currentState.originalQueue;
    if (current == null || pool.length < 2) return false;
    // Live radio has no meaningful "context" to loop.
    if (current.id.startsWith('http')) return false;

    final idx = pool.indexWhere((s) => s.id == current.id);
    // Everything after the current track, then everything before it — i.e. the
    // context continues from here and wraps around, exactly like Spotify.
    final rest = idx == -1
        ? pool.where((s) => s.id != current.id).toList()
        : [...pool.sublist(idx + 1), ...pool.sublist(0, idx)];
    if (rest.isEmpty) return false;

    // Re-seeded tracks are CONTEXT (they came from the album/playlist the user
    // started), never "up next" the user hand-picked and never autoplay recs.
    currentState = currentState.copyWith(
      queue: [current, ...rest],
      contextQueue: rest,
      userQueue: const [],
      autoplayQueue: const [],
      currentIndex: 0,
    );
    print('Repeat All: re-seeded the loop with ${rest.length} track(s)');
    // The native engine may hold a now-wrong upcoming item — re-arm it.
    _preloadedSongId = null;
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    if (currentState.isPlaying) Future.microtask(() => _preloadNextTrack());
    _saveSettingsDebounced();
    return true;
  }

  // ==============================================================
  // SHUFFLE
  // ==============================================================
  /// Put shuffle into a KNOWN state, idempotently.
  ///
  /// [toggleShuffle] flips, so its result depends on what it was before — which
  /// is wrong for any caller that needs shuffle specifically ON. The playlist
  /// page's shuffle button guarded with `if (!isShuffleOn) toggleShuffle()`,
  /// which is this method written badly at the call site, and it read the flag
  /// from a rebuilt widget rather than from the notifier.
  void setShuffle(bool on) {
    if (currentState.isShuffle == on) return;
    toggleShuffle();
  }

  void toggleShuffle() {
    // A trivial queue (≤1 track — e.g. after the user clears the queue) has
    // nothing to REORDER, but the shuffle FLAG must still flip. The old bare
    // `return` left isShuffle unchanged, so cycleShuffleMode's SMART→OFF branch
    // (which calls toggleShuffle to turn off) no-op'd and the shuffle button got
    // stuck oscillating between "shuffle on" and "smart shuffle", never off.
    if (currentState.queue.length <= 1) {
      currentState = currentState.copyWith(isShuffle: !currentState.isShuffle);
      _saveSettings();
      return;
    }

    final isTurningOn = !currentState.isShuffle;

    if (isTurningOn) {
      print('Enabling shuffle…');
      final currentSong = currentState.currentSong;
      if (currentSong == null) {
        currentState = currentState.copyWith(isShuffle: true);
        _saveSettings();
        return;
      }

      final origUser = List<Song>.from(currentState.userQueue);
      final origCtx  = List<Song>.from(currentState.contextQueue);
      final origAuto = List<Song>.from(currentState.autoplayQueue);

      final shuffledUser = _smartShuffle(List.from(currentState.userQueue));
      final shuffledCtx  = _smartShuffle(List.from(currentState.contextQueue));
      final shuffledAuto = _smartShuffle(List.from(currentState.autoplayQueue));

      final newQueue     = [currentSong, ...shuffledUser, ...shuffledCtx, ...shuffledAuto];
      final origSnapshot = [currentSong, ...origUser, ...origCtx, ...origAuto];

      currentState = currentState.copyWith(
        isShuffle:     true,
        queue:         newQueue,
        userQueue:     shuffledUser,
        contextQueue:  shuffledCtx,
        autoplayQueue: shuffledAuto,
        originalQueue: origSnapshot, 
        currentIndex:  0,
      );

    } else {
      print('Disabling shuffle…');
      final currentId = currentState.currentSong?.id;

      if (currentState.originalQueue.isEmpty || currentId == null) {
        currentState = currentState.copyWith(isShuffle: false);
        _saveSettings();
        return;
      }

      final origIdx = currentState.originalQueue.indexWhere((s) => s.id == currentId);

      if (origIdx == -1) {
        currentState = currentState.copyWith(isShuffle: false);
        _saveSettings();
        return;
      }

      final remaining = origIdx < currentState.originalQueue.length - 1
              ? currentState.originalQueue.sublist(origIdx + 1)
              : <Song>[];

      final userIds = currentState.userQueue.map((s) => s.id).toSet();
      final ctxIds  = currentState.contextQueue.map((s) => s.id).toSet();
      final autoIds = currentState.autoplayQueue.map((s) => s.id).toSet();

      final allCurrent = {...userIds, ...ctxIds, ...autoIds};
      final valid = remaining.where((s) => allCurrent.contains(s.id));

      final restoredUser  = <Song>[];
      final restoredCtx   = <Song>[];
      final restoredAuto  = <Song>[];

      for (final song in valid) {
        if (userIds.contains(song.id))       restoredUser.add(song);
        else if (ctxIds.contains(song.id))   restoredCtx.add(song);
        else if (autoIds.contains(song.id))  restoredAuto.add(song);
      }

      final restoredQueue = [
        currentState.currentSong!,
        ...restoredUser, ...restoredCtx, ...restoredAuto,
      ];

      currentState = currentState.copyWith(
        isShuffle:     false,
        queue:         restoredQueue,
        userQueue:     restoredUser,
        contextQueue:  restoredCtx,
        autoplayQueue: restoredAuto,
        currentIndex:  0,
      );
    }

    _saveSettings();
  }

  void clearPlaybackHistory() {
    currentState = currentState.copyWith(history: []);
  }

  bool toggleQueue(Song song) {
    // Shared with addToQueue. See [_pendingQueueIndexOf] for why they must not
    // each have their own idea of what counts as already-queued.
    final existingIdx = _pendingQueueIndexOf(song);

    if (existingIdx != -1) {
      removeFromQueue(existingIdx);
      return false;
    } else {
      addToQueue(song);
      return true;
    }
  }

  /// Queue [songs] that are not already queued. Returns how many were added.
  ///
  /// IT USED TO BE `void ... async`, AND CALLERS LIED BECAUSE OF IT
  ///
  /// That signature is unawaitable AND unreadable: a caller could neither wait
  /// for it nor learn what happened. So the playlist page said "Added to Queue"
  /// unconditionally — including when every track was already queued and this
  /// method had returned without adding anything.
  ///
  /// The count is the honest answer, and it is not the same as `songs.length`:
  /// entries already present are dropped by id AND by title+artist signature.
  /// Pairs with [removeListFromQueue], which reports the same way.
  Future<int> addListToQueue(List<Song> songs) async {
    if (songs.isEmpty) return 0;

    if (currentState.queue.isEmpty) {
      playSong(songs.first, newQueue: songs, source: 'Queue');
      return songs.length;
    }
    var added = 0;

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        // De-dupe against everything already in the queue — by id AND by
        // title+artist SIGNATURE. Signature matters because "queue this album"
        // while a track from it plays can re-add a DIFFERENT-id twin of the
        // current song (e.g. the VIDEO version when audio-only swapped the
        // current to its audio equivalent), which id-only dedup misses and
        // which then showed up as "the current track is also the next track".
        String sig(Song s) =>
            '${s.title.toLowerCase().trim()}_${s.artist.toLowerCase().trim()}';
        final existingIds = currentState.queue.map((s) => s.id).toSet();
        final existingSigs = currentState.queue.map(sig).toSet();
        final seenSigs = <String>{};
        final toAdd = songs.where((s) {
          if (existingIds.contains(s.id) || existingSigs.contains(sig(s))) return false;
          return seenSigs.add(sig(s)); // also drop dups WITHIN the added list
        }).toList();

        if (toAdd.isEmpty) {
          print('addListToQueue: all ${songs.length} track(s) were already queued');
          return;
        }
        added = toAdd.length;

        final updatedUser = [...currentState.userQueue, ...toAdd];
        final newQueue    = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...updatedUser,
          ...currentState.contextQueue,
          ...currentState.autoplayQueue,
        ];

        currentState = currentState.copyWith(
          userQueue:         updatedUser,
          queue:             newQueue,
          originalQueue:     [...currentState.originalQueue, ...toAdd],
          userQueueEndIndex: updatedUser.length,
        );

      } catch (e) {
        print('ERROR: addListToQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
    return added;
  }

  /// Take [songs] back out of the queue. Returns how many were actually removed.
  ///
  /// Written because a button was lying
  ///
  /// The playlist page's queue toggle called [addListToQueue] on the way in and,
  /// on the way out, showed a "Removed from Queue" toast and nothing else — there
  /// was no bulk remove to call, so the branch was left empty. The tracks stayed
  /// queued while the UI said they had gone.
  ///
  /// Matches by id AND by title+artist signature, the same rule
  /// [_pendingQueueIndexOf] and [addListToQueue] use: the copy sitting in the
  /// queue can be a different-id twin of the one on screen (the audio-only swap
  /// of a video), and an id-only removal misses exactly the entry the user is
  /// looking at.
  ///
  /// The CURRENT track is never removed — it is not pending, it is playing, and
  /// dropping it from under the player is a different operation entirely.
  Future<int> removeListFromQueue(List<Song> songs) async {
    if (songs.isEmpty || currentState.queue.length <= 1) return 0;

    String sig(Song s) =>
        '${s.title.toLowerCase().trim()}_${s.artist.toLowerCase().trim()}';
    final ids = songs.map((s) => s.id).toSet();
    final sigs = songs.map(sig).toSet();
    bool targeted(Song s) => ids.contains(s.id) || sigs.contains(sig(s));

    var removed = 0;
    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final newUser = currentState.userQueue.where((s) => !targeted(s)).toList();
        final newCtx = currentState.contextQueue.where((s) => !targeted(s)).toList();
        final newAuto =
            currentState.autoplayQueue.where((s) => !targeted(s)).toList();

        removed = (currentState.userQueue.length - newUser.length) +
            (currentState.contextQueue.length - newCtx.length) +
            (currentState.autoplayQueue.length - newAuto.length);
        if (removed == 0) {
          print('removeListFromQueue: none of ${songs.length} track(s) were queued');
          return;
        }

        final newQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...newUser, ...newCtx, ...newAuto,
        ];
        currentState = currentState.copyWith(
          userQueue: newUser,
          contextQueue: newCtx,
          autoplayQueue: newAuto,
          queue: newQueue,
          originalQueue: List.from(newQueue),
          userQueueEndIndex: newUser.length,
        );
        print('removeListFromQueue: removed $removed of ${songs.length} '
            'track(s) — queue now ${newQueue.length}');
      } catch (e) {
        print('ERROR: removeListFromQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
    return removed;
  }

  Future<void> clearAllQueue() async {
    if (currentState.queue.length <= 1) return;
    final prevNext = _upNextId();

    final newQueue = [if (currentState.currentSong != null) currentState.currentSong!];

    currentState = currentState.copyWith(
      userQueue:         [],
      contextQueue:      [],
      autoplayQueue:     [],
      queue:             newQueue,
      originalQueue:     List.from(newQueue),
      userQueueEndIndex: 0,
    );

    resyncUpcomingIfChanged(prevNext);
    _saveSettings();
  }

  List<Song> _smartShuffle(List<Song> songs) {
    if (songs.length <= 2) {
      return List<Song>.from(songs)..shuffle();
    }

    final Map<String, List<Song>> groups = {};
    for (final song in songs) {
      groups.putIfAbsent(song.artist, () => []).add(song);
    }

    groups.forEach((_, tracks) => tracks.shuffle());

    final artists = groups.keys.toList()..shuffle();
    final result  = <Song>[];

    while (result.length < songs.length) {
      for (final artist in artists) {
        final group = groups[artist];
        if (group != null && group.isNotEmpty) {
          result.add(group.removeAt(0));
          if (result.length >= songs.length) break;
        }
      }
    }
    return result;
  }

  // ==============================================================
  // QUEUE HEALTH CHECK  (runs every 7 s via timer)
  // ==============================================================

  void _performQueueHealthCheck() {
    bool needsSync = false;

    final blacklisted = effectiveBlacklist;
    final cleanUser = currentState.userQueue.where((s) => !blacklisted.contains(s.id)).toList();
    final cleanCtx  = currentState.contextQueue.where((s) => !blacklisted.contains(s.id)).toList();

    final seenIds  = <String>{};
    final cleanAuto = currentState.autoplayQueue.where((s) {
      if (blacklisted.contains(s.id) || seenIds.contains(s.id)) return false;
      seenIds.add(s.id);
      return true;
    }).toList();

    if (cleanUser.length != currentState.userQueue.length ||
        cleanCtx.length  != currentState.contextQueue.length ||
        cleanAuto.length != currentState.autoplayQueue.length) {
      needsSync = true;
    }

    if (needsSync) {
      final finalQueue = [
        if (currentState.currentSong != null) currentState.currentSong!,
        ...cleanUser, ...cleanCtx, ...cleanAuto,
      ];

      currentState = currentState.copyWith(
        userQueue:     cleanUser,
        contextQueue:  cleanCtx,
        autoplayQueue: cleanAuto,
        queue:         finalQueue,
      );
      _saveSettings();
    }
  }

  void _startQueueSyncVerification() {
    _queueSyncTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      // Only verify while actually playing. The queue can't drift while paused
      // or backgrounded, so running this every 7s 24/7 just burned CPU/battery.
      if (!mounted || !currentState.isPlaying) return;
      _performQueueHealthCheck();
    });
  }

  void addToQueueNext(Song song) {
    final prevNext = _upNextId();
    final newUserQueue = [
      song,
      ...currentState.userQueue.where((s) => s.id != song.id),
    ];
    final newQueue = [
      if (currentState.currentSong != null) currentState.currentSong!,
      ...newUserQueue,
      ...currentState.contextQueue,
      ...currentState.autoplayQueue,
    ];

    currentState = currentState.copyWith(userQueue: newUserQueue, queue: newQueue);
    resyncUpcomingIfChanged(prevNext);
    _saveSettingsDebounced();
  }

  Future<void> _updateAudioPlayerQueue(
    List<Song> newQueue,
    int currentIndex, {
    bool updateCurrentTrack = false,
  }) async {
    if (newQueue.isEmpty) return;
    currentState = currentState.copyWith(queue: newQueue);
    _saveSettingsDebounced();
  }

}