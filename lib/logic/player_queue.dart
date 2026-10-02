part of '../providers/player_provider.dart';

/// Queue editing and track-to-track navigation.
///
/// The queue is three lanes, not one list. `state.queue` is a derived view,
/// rebuilt after every change as:
///
///     queue = [ currentSong, ...userQueue, ...contextQueue, ...autoplayQueue ]
///
///   • userQueue     — tracks the listener added ("add to queue"). Plays first.
///   • contextQueue  — the rest of the album / playlist / radio being played.
///   • autoplayQueue — generated continuation so playback never simply ends.
///
/// Two rules:
///
/// 1. **Index 0 is the playing track**, not a pending one. Scans for "already
///    queued" start at 1, and [removeFromQueue] maps a `queue` index to its lane
///    with `rel = index - 1`.
/// 2. **Never write `queue` directly.** Change a lane and rebuild `queue` from
///    the lanes; the lanes are what get saved.
///
/// `originalQueue` is the pre-shuffle order, so turning shuffle off restores it.
/// `userQueueEndIndex` marks where the user's own entries end, for the "Up next"
/// divider.
///
/// Changes are serialised through `_lockMutation` and finish with
/// [resyncUpcomingIfChanged]: the native player is told the next track in advance
/// for gapless playback, so an edit that changes what is next must update it.
extension PlayerQueueController on PlayerNotifier {

  /// The id of the track in the "up next" slot (`queue[1]`), or null if nothing
  /// follows the current track. Captured before a change so
  /// [resyncUpcomingIfChanged] can tell whether the native player's pre-buffered
  /// next track is now wrong.
  String? _upNextId() =>
      currentState.queue.length > 1 ? currentState.queue[1].id : null;

  /// Where [song] already waits in the queue, or -1.
  ///
  /// Matches by id and by title+artist, so the video/audio twin of a queued track
  /// (different id, same song) is not queued twice.
  ///
  /// The scan starts at 1: `queue[0]` is playing, not waiting, so queueing the song
  /// you are listening to simply means "play it again after this".
  ///
  /// [toggleQueue] and [addToQueue] both use this check, so the "added" feedback
  /// the UI shows always matches what actually happened.
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

  /// Whether [song] is already waiting in the queue. Callers that go to
  /// [addToQueue] directly use it to word their feedback; read it before the add.
  bool isPendingInQueue(Song song) => _pendingQueueIndexOf(song) != -1;

  // Adds one song to the user's lane, after anything they queued earlier.
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
          userQueue:         updatedUser,
          queue:             newQueue,
          originalQueue:     [...currentState.originalQueue, song],
          userQueueEndIndex: updatedUser.length,
        );

        print('Queued "${song.title}" manually');
      } catch (e) {
        print('ERROR: addToQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // Adds an album. If the album is already the playing context, its remaining
  // tracks replace the upcoming ones instead of being added twice.
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
            userQueue:         updatedUser,
            queue:             newQueue,
            originalQueue: currentState.isShuffle
                ? [...currentState.originalQueue, ...tracksToAdd]
                : List.from(newQueue),
            userQueueEndIndex: updatedUser.length,
          );
        }

        print('Added ${tracksToAdd.length} album tracks to queue');
      } catch (e) {
        print('ERROR: addAlbumToQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // Removes the entry at [index] from whichever lane holds it, keeping enough to
  // undo the removal.
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
          userQueue:         newUser,
          contextQueue:      newCtx,
          autoplayQueue:     newAuto,
          queue:             newQueue,
          originalQueue: currentState.isShuffle
              ? currentState.originalQueue.where((s) => s.id != songToRemove.id).toList()
              : List.from(newQueue),
          userQueueEndIndex: newUser.length,
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

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
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
          originalQueue: currentState.isShuffle
              ? currentState.originalQueue
              : List.from(newQueue),
          userQueueEndIndex: lastRemoved.userQueue.length,
        );
        print('Queue: undo remove restored "${lastRemoved.song.title}"');
      } catch (e) {
        print('ERROR: undoRemoveFromQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        ref.read(lastRemovedItemProvider.notifier).state = null;
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // Moves an upcoming entry. Index 0, the playing track, cannot be moved.
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

        final safeULen = newULen.clamp(0, reordered.length);
        final safeCLen = newCLen.clamp(0, reordered.length - safeULen);
        final newUser  = reordered.sublist(0, safeULen);
        final newCtx   = reordered.sublist(safeULen, safeULen + safeCLen);
        final newAuto  = reordered.sublist(safeULen + safeCLen);

        final newQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...newUser, ...newCtx, ...newAuto,
        ];

        currentState = currentState.copyWith(
          queue:             newQueue,
          userQueue:         newUser,
          contextQueue:      newCtx,
          autoplayQueue:     newAuto,
          originalQueue: currentState.isShuffle
              ? currentState.originalQueue
              : List.from(newQueue),
          userQueueEndIndex: newUser.length,
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

  // Empties the user's lane; context and autoplay tracks stay.
  Future<void> clearUserQueue() async {
    if (currentState.userQueue.isEmpty) return;

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final newQueue = [
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
        print('Queue: cleared user queue (prevUpNext=$prevNext, newUpNext=${_upNextId()})');
      } catch (e) {
        print('ERROR: clearUserQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
  }

  // Plays the entry at [index] now and drops everything before it.
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
    final newLocation = isAutoJump
        ? "Based on ${jumpedSong.artist}"
        : (isUserJump ? 'Manually Added' : (currentState.contextTitle ?? currentState.locationName));

    final newQueue = [jumpedSong, ...newUser, ...newCtx, ...newAuto];

    currentState = currentState.copyWith(
      currentSong:       jumpedSong,
      currentIndex:      0,
      queue:             newQueue,
      userQueue:         newUser,
      contextQueue:      newCtx,
      autoplayQueue:     newAuto,
      playbackSource:    newSource,
      locationName:      newLocation,
      originalQueue:     currentState.isShuffle ? currentState.originalQueue : newQueue,
      userQueueEndIndex: newUser.length,
    );

    _loadAndPlay(jumpedSong, playImmediately: true);
  }

  /// The genre this play should be credited to.
  ///
  /// `contextType` is only ever 'album', 'playlist', 'artist' or 'radio', so the
  /// 'genre' branch rarely applies. The song's primary genre from genresFor is
  /// used instead, the same source player_smart uses for scoring, so learning and
  /// scoring agree about what a track is.
  ///
  /// A primary genre credited here at full weight plus half weight from tag
  /// extraction earns 1.5x a secondary genre, which is intended: the genre a
  /// track leads with should outweigh its incidental tags.
  String? _genreContextFor(Song song) {
    if (currentState.contextType == 'genre') return currentState.contextTitle;
    return ref.read(intelligenceProvider.notifier).genresFor(song).firstOrNull;
  }

  Future<void> playNext({bool autoAdvance = false, bool alreadyPlayingNatively = false}) async {
    if (_navIndex > 0) {
      if (!autoAdvance) {
        HapticService.light();
      } else {
        final finished = currentState.currentSong;
        if (finished != null) {
          if (finished.isSpokenWord) {
            _savePodcastPosition(finished, Duration.zero);
          }
          if (!finished.id.startsWith('http') &&
              finished.albumTitle != 'Podcast' &&
              finished.albumTitle != 'RADIO') {
            ref.read(intelligenceProvider.notifier).bumpLastPlayTimestamp(finished.id);
            ref.read(intelligenceProvider.notifier).trackInteraction(
              finished,
              percent: 1.0,
              genreContext: _genreContextFor(finished),
            );
          }
        }
      }
      _navIndex--;
      if (_navIndex > 0 && _navIndex < currentState.history.length) {
        final target = currentState.history[_navIndex];
        await playSong(target, source: currentState.playbackSource, locationName: currentState.locationName, isNextOrPrev: true);
        return;
      }
      if (currentState.history.isNotEmpty) {
        final nowSong = currentState.history[0];
        await playSong(nowSong, source: currentState.playbackSource, locationName: currentState.locationName, isNextOrPrev: true);
        return;
      }
      _navIndex = 0;
    }

    if (!autoAdvance) {
      _navIndex = 0;
      HapticService.light();
      final double total   = currentState.duration.inSeconds.toDouble();
      final double current = currentState.position.inSeconds.toDouble();
      final double percent = total > 0 ? (current / total) : 0.0;
      
      // A manual "next" with nothing loaded (a stray media-button press, or after
      // the queue was cleared) does nothing.
      final skipSong = currentState.currentSong;
      if (skipSong != null) {
        if (!ListeningPolicy.historyPaused) {
          await handleSmartSkipDetection(skipSong, percent);
          ref.read(intelligenceProvider.notifier).trackInteraction(
            skipSong,
            percent: percent,
            genreContext: _genreContextFor(skipSong),
          );
        }
      }

      if (currentState.currentSong != null) {
        final song = currentState.currentSong!;
        final durationMs = currentState.duration.inMilliseconds;
        final listenedMs = currentState.position.inMilliseconds;
        
        final qualifies = listenedMs >= ListeningPolicy.thresholdMsFor(durationMs);
          
        if (qualifies &&
            !ListeningPolicy.historyPaused &&
            !song.id.startsWith('http') &&
            song.albumTitle != 'Podcast' &&
            song.albumTitle != 'RADIO') {
          final updatedHistory = [song, ...currentState.history.where((s) => s.id != song.id)].take(_kHistoryCap).toList();
          _historyPlayedAt[song.id] = DateTime.now().millisecondsSinceEpoch;
          final curDevice = DeviceInfoService.currentDeviceName;
          if (curDevice.isNotEmpty) _historyPlayedDevice[song.id] = curDevice;
          currentState = currentState.copyWith(
            history: updatedHistory,
            historyPlayedAt: Map<String, int>.from(_historyPlayedAt),
            historyPlayedDevice: Map<String, String>.from(_historyPlayedDevice),
          );
        }
      }
    }

    if (autoAdvance) {
      // A finished episode or audiobook chapter starts from the beginning next time,
      // instead of resuming at its last few seconds.
      final finishedPod = currentState.currentSong;
      if (finishedPod != null && finishedPod.isSpokenWord) {
        _savePodcastPosition(finishedPod, Duration.zero);
        if (finishedPod.mediaKind == MediaKind.audiobook) {
          SpokenWordHooks.chapterFinished?.call(finishedPod);
        }
      }
      // The track finished on its own: credit the full listen while it is still
      // currentSong.
      final finished = currentState.currentSong;
      if (finished != null &&
          !finished.id.startsWith('http') &&
          finished.albumTitle != 'Podcast' &&
          finished.albumTitle != 'RADIO') {
        if (!ListeningPolicy.historyPaused) {
          ref.read(intelligenceProvider.notifier).bumpLastPlayTimestamp(finished.id);
          ref.read(intelligenceProvider.notifier).trackInteraction(
            finished, percent: 1.0,
            genreContext: _genreContextFor(finished),
          );
          // Keep My Top 50 current (ranked by real listen counts).
          final intel = ref.read(intelligenceProvider);
          ref.read(libraryProvider.notifier).refreshTop50(
              intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
          final updatedHistory =
              [finished, ...currentState.history.where((s) => s.id != finished.id)]
                  .take(_kHistoryCap)
                  .toList();
          _historyPlayedAt[finished.id] = DateTime.now().millisecondsSinceEpoch;
          final curDevice = DeviceInfoService.currentDeviceName;
          if (curDevice.isNotEmpty) _historyPlayedDevice[finished.id] = curDevice;
          currentState = currentState.copyWith(
            history: updatedHistory,
            historyPlayedAt: Map<String, int>.from(_historyPlayedAt),
            historyPlayedDevice: Map<String, String>.from(_historyPlayedDevice),
          );
        }
      }
    }

    if (autoAdvance && currentState.sleepAtEndOfTrack) {
      // "Sleep at end of track": stop here instead of advancing. One-shot; pressing
      // play later resumes normal queue behaviour.
      final finishedSong = currentState.currentSong;
      print('End-of-track sleep — pausing instead of advancing'
          '${alreadyPlayingNatively ? ' (undoing a gapless roll-over)' : ''}');
      currentState = currentState.copyWith(
        clearSleepTimer: true, // also resets sleepAtEndOfTrack
        isPlaying: false,
      );
      NativeAudioEngine.pause();
      if (alreadyPlayingNatively) {
        // With gapless on, the native player has already rolled into the next track by
        // the time Dart hears the old one ended. Just not advancing would pause and
        // rewind the wrong track, so undo the roll-over: drop the upcoming item and put
        // the finished track back, paused at its start, so the player and the screen
        // agree about what is loaded. The Repeat One and A-B loop guards do the same.
        try {
          NativeAudioEngine.clearUpcoming();
        } catch (_) {}
        _preloadedSongId = null;
        if (finishedSong != null) {
          await _loadAndPlay(finishedSong, playImmediately: false);
        }
      } else {
        await NativeAudioEngine.seek(Duration.zero);
      }
      return;
    }

    if (currentState.repeatMode == RepeatMode.one && autoAdvance) {
      _currentPlayRecorded = false;
      _pendingSeekTarget = null;
      _pendingSeekAt = null;
      currentPositionProvider.value = Duration.zero;
      await NativeAudioEngine.seek(Duration.zero);
      await NativeAudioEngine.resume();
      return;
    }

    if (currentState.queue.isEmpty) return;

    // More songs queued?
    if (currentState.queue.length > 1) {
       // Index 0 is playing, so index 1 is next.
       final nextSong = currentState.queue[1];

       // Instant skip: move to the track the native player already has buffered.
       //
       // A track that ends on its own changes instantly because _preloadNextTrack has
       // already prepared the next one; a manual "next" would otherwise prepare it
       // from scratch, including a network lookup, even when it is downloaded and
       // buffered. So the native player is asked to move to its prepared item; it
       // refuses unless that item really is this track, and a refusal falls through
       // to the normal path below.
       //
       // Only for a deliberate skip while playing (auto-advance is handled by the
       // transition itself, and a paused player should stay paused), and never onto
       // a disliked or temporarily failing track, which playSong would skip anyway.
       var nativelyAdvanced = alreadyPlayingNatively;
       if (!autoAdvance &&
           !alreadyPlayingNatively &&
           currentState.isPlaying &&
           currentState.gaplessPlayback &&
           !effectiveBlacklist.contains(nextSong.id)) {
         // Set before the call: the transition can arrive before the await returns, and
         // a flag set afterwards would be too late to suppress the duplicate advance.
         _skipConsumesNextAdvance = true;
         nativelyAdvanced = await NativeAudioEngine.advanceToUpcoming(nextSong.id);
         if (!nativelyAdvanced) {
           _skipConsumesNextAdvance = false;
         } else {
           print('instant skip → "${nextSong.title}" (already buffered, no resolve)');
           // Release the flag if no transition arrives, or it would swallow the next real
           // gapless advance.
           Timer(const Duration(milliseconds: 1500), () {
             if (!_skipConsumesNextAdvance) return;
             _skipConsumesNextAdvance = false;
             // Log it: playback is fine, but the two sides briefly disagreed about which
             // track is playing.
             print('no transition followed the instant skip — flag released');
           });
         }
       }

       // playSong advances within the existing queue. Carry source and location so
       // the "playing from" label doesn't reset to "Library" on every advance.
       await playSong(
         nextSong,
         playImmediately: true,
         source: currentState.playbackSource,
         locationName: currentState.locationName,
         // Queue advances respect temporary failure blocks (a direct tap overrides
         // them; see playSong).
         viaQueueAdvance: true,
         // Native already switched to nextSong (gapless, or the instant skip above):
         // update state without reloading, which would restart the track.
         alreadyPlayingNatively: nativelyAdvanced,
       );

    } else {
      if (currentState.repeatMode == RepeatMode.all) {
        // Last track of a Repeat All loop: restart the whole context if we still have
        // it, and only replay this single track when there is no context to loop.
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
          _currentPlayRecorded = false;
          _pendingSeekTarget = null;
          _pendingSeekAt = null;
          currentPositionProvider.value = Duration.zero;
          await NativeAudioEngine.seek(Duration.zero);
          await NativeAudioEngine.resume();
        }
      } else {
        // Queue is empty at the end of a track. force:true because continuing playback
        // is not a background prefetch, so data-saver must not stop it; _topUpQueue
        // waits for a refill already in progress.
        print('Queue ended – emergency refill');
        for (int attempt = 0; attempt < 3 && currentState.queue.length <= 1; attempt++) {
          await _topUpQueue(force: true);
          if (!mounted) return;
          if (currentState.queue.length > 1) break;
          await Future.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
        }

        if (currentState.queue.length > 1) {
          await playSong(
            currentState.queue[1],
            playImmediately: true,
            source: currentState.playbackSource,
            locationName: currentState.locationName,
            // Pass the context through: playSong treats a call without contextType as a
            // manual start and clears the stored collection, which is wrong when the same
            // playlist is simply continuing after a refill.
            viaQueueAdvance: true,
          );
        } else {
          // Nothing arrived (flaky network or empty recommendations). If tracks land
          // shortly after, auto-advance instead of staying stopped.
          print('ALERT: Refill found nothing — arming late-arrival rescue');
          // Reset the progress bar to 0 instead of leaving it at the end of the finished
          // track while we wait.
          currentPositionProvider.value = Duration.zero;
          final expectedSongId = currentState.currentSong?.id;
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 4), () {
            if (mounted &&
                !currentState.isPlaying &&
                !currentState.isLoading &&
                currentState.currentSong?.id == expectedSongId &&
                currentState.queue.length > 1) {
              print('Late refill landed — resuming playback');
              // Carry source and location forward; this is still playback from wherever the
              // listener started.
              playSong(currentState.queue[1],
                  playImmediately: true,
                  source: currentState.playbackSource,
                  locationName: currentState.locationName,
                  // Same as the refill advance above: without it this counts as a manual start
                  // and clears the collection.
                  viaQueueAdvance: true);
            }
          });
        }
      }
    }
  }

  /// Makes sure Repeat All has something to loop.
  ///
  /// Normally the loop sustains itself: `playSong` re-appends each finished track.
  /// But if Repeat All is turned on late (say during the last track of an album),
  /// the upcoming tracks are already used up and the "loop" is one track long.
  ///
  /// This rebuilds it from `originalQueue`, rotated so the current track stays
  /// current and the rest of the context follows. Returns true when a multi-track
  /// loop is in place.
  bool _reseedRepeatAllLoop() {
    if (!mounted) return false;
    // Already looping over several tracks; leave it alone.
    if (currentState.queue.length > 1) return true;

    final current = currentState.currentSong;
    final pool = currentState.originalQueue;
    if (current == null || pool.length < 2) return false;
    // Live radio has no context to loop.
    if (current.id.startsWith('http')) return false;

    final idx = pool.indexWhere((s) => s.id == current.id);
    // Everything after the current track, then everything before it, so the
    // context continues from here and wraps around.
    final rest = idx == -1
        ? pool.where((s) => s.id != current.id).toList()
        : [...pool.sublist(idx + 1), ...pool.sublist(0, idx)];
    if (rest.isEmpty) return false;

    // Re-added tracks belong to the context lane, not the user's lane or autoplay.
    currentState = currentState.copyWith(
      queue:             [current, ...rest],
      contextQueue:      rest,
      userQueue:         const [],
      autoplayQueue:     const [],
      userQueueEndIndex: 0,
      currentIndex:      0,
    );
    print('Repeat All: re-seeded the loop with ${rest.length} track(s)');
    // The native player may hold a now-wrong upcoming item; prepare it again.
    _preloadedSongId = null;
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    if (currentState.isPlaying) Future.microtask(() => _preloadNextTrack());
    _saveSettingsDebounced();
    return true;
  }

  // Shuffle on/off.
  /// Sets shuffle to a known state. Unlike [toggleShuffle], the result does not
  /// depend on the previous state, which is what callers that need shuffle on
  /// (the playlist page's shuffle button) want.
  void setShuffle(bool on) {
    if (currentState.isShuffle == on) return;
    toggleShuffle();
  }

  void toggleShuffle() {
    // With one track or none there is nothing to reorder, but the flag must still
    // change, or the shuffle button's smart→off step would never turn it off.
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

      final origIndices = {
        for (int i = 0; i < currentState.originalQueue.length; i++)
          currentState.originalQueue[i].id: i
      };
      final origIdx = origIndices[currentId] ?? -1;

      // 1. User lane: keep every user-queued song. Songs that were in originalQueue
      // go back to their original relative order; newly added ones stay as they are.
      final restoredUser = List<Song>.from(currentState.userQueue);
      restoredUser.sort((a, b) {
        final aIdx = origIndices[a.id];
        final bIdx = origIndices[b.id];
        if (aIdx != null && bIdx != null) return aIdx.compareTo(bIdx);
        if (aIdx != null) return -1;
        if (bIdx != null) return 1;
        return 0;
      });

      // 2. Context lane: keep every remaining album/playlist track, in album order:
      // tracks after the current one first, then unplayed ones from before it.
      final restoredCtx = List<Song>.from(currentState.contextQueue);
      if (origIdx != -1) {
        restoredCtx.sort((a, b) {
          final aOrig = origIndices[a.id] ?? 999999;
          final bOrig = origIndices[b.id] ?? 999999;
          final aOrder = aOrig > origIdx ? (aOrig - origIdx) : (aOrig + 100000);
          final bOrder = bOrig > origIdx ? (bOrig - origIdx) : (bOrig + 100000);
          return aOrder.compareTo(bOrder);
        });
      }

      // 3. Autoplay lane: keep the remaining discovery tracks.
      final restoredAuto = List<Song>.from(currentState.autoplayQueue);

      final restoredQueue = [
        currentState.currentSong!,
        ...restoredUser,
        ...restoredCtx,
        ...restoredAuto,
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
    _navIndex = 0;
    _historyPlayedAt.clear();
    _historyPlayedDevice.clear();
    currentState = currentState.copyWith(
      history: [],
      historyPlayedAt: {},
      historyPlayedDevice: {},
    );
    _saveSettings();
  }

  bool toggleQueue(Song song) {
    // Same check as addToQueue (see [_pendingQueueIndexOf]).
    final existingIdx = _pendingQueueIndexOf(song);

    if (existingIdx != -1) {
      removeFromQueue(existingIdx);
      return false;
    } else {
      addToQueue(song);
      return true;
    }
  }

  /// Queues the [songs] that are not already queued and returns how many were
  /// added. Entries already present are skipped by id and by title+artist, so the
  /// count can be lower than `songs.length`; callers use it to word their
  /// confirmation. Pairs with [removeListFromQueue].
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
        // Skip anything already queued, by id and by title+artist. The signature check
        // catches a different-id twin of the current song (for example the video
        // version when audio-only mode swapped in the audio one).
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

  /// Removes [songs] from the queue and returns how many were removed.
  ///
  /// Matches by id and by title+artist, like [_pendingQueueIndexOf] and
  /// [addListToQueue], because the queued copy can be a different-id twin of the
  /// one on screen.
  ///
  /// The current track is never removed; it is playing, not pending.
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
          originalQueue: currentState.isShuffle
              ? currentState.originalQueue.where((s) => !targeted(s)).toList()
              : List.from(newQueue),
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

    await _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final newQueue = [if (currentState.currentSong != null) currentState.currentSong!];

        currentState = currentState.copyWith(
          userQueue:         [],
          contextQueue:      [],
          autoplayQueue:     [],
          queue:             newQueue,
          originalQueue:     List.from(newQueue),
          userQueueEndIndex: 0,
        );
        print('Queue: cleared all queue items except current track');
      } catch (e) {
        print('ERROR: clearAllQueue error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
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

  // Queue health check, run every 7 s while playing: drops blocked tracks from
  // every lane and duplicates from autoplay, then rebuilds the queue if anything
  // changed.

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
      final prevNext = _upNextId();
      final finalQueue = [
        if (currentState.currentSong != null) currentState.currentSong!,
        ...cleanUser, ...cleanCtx, ...cleanAuto,
      ];

      currentState = currentState.copyWith(
        userQueue:         cleanUser,
        contextQueue:      cleanCtx,
        autoplayQueue:     cleanAuto,
        queue:             finalQueue,
        userQueueEndIndex: cleanUser.length,
      );
      print('Queue: health check purged blacklisted/duplicate items (prevUpNext=$prevNext, newUpNext=${_upNextId()})');
      resyncUpcomingIfChanged(prevNext);
      _saveSettingsDebounced();
    }
  }

  void _startQueueSyncVerification() {
    _queueSyncTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      // Only check while playing; nothing changes the queue while paused, and running
      // every 7 s around the clock wasted battery.
      if (!mounted || !currentState.isPlaying) return;
      _performQueueHealthCheck();
    });
  }

  void addToQueueNext(Song song) {
    HapticService.selection();
    if (currentState.queue.isEmpty) {
      playSong(song, source: 'Queue');
      return;
    }

    _lockMutation(() async {
      final prevNext = _upNextId();
      try {
        final newContextQueue =
            currentState.contextQueue.where((s) => s.id != song.id).toList();
        final newAutoplayQueue =
            currentState.autoplayQueue.where((s) => s.id != song.id).toList();
        final newUserQueue = [
          song,
          ...currentState.userQueue.where((s) => s.id != song.id),
        ];
        final newQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          ...newUserQueue,
          ...newContextQueue,
          ...newAutoplayQueue,
        ];
        final newOriginalQueue = [
          if (currentState.currentSong != null) currentState.currentSong!,
          song,
          ...currentState.originalQueue.where(
              (s) => s.id != song.id && s.id != currentState.currentSong?.id),
        ];

        currentState = currentState.copyWith(
          userQueue:         newUserQueue,
          contextQueue:      newContextQueue,
          autoplayQueue:     newAutoplayQueue,
          queue:             newQueue,
          originalQueue:     newOriginalQueue,
          userQueueEndIndex: newUserQueue.length,
        );
        print('Queue: added "${song.title}" as play next (newUpNext: ${song.id})');
      } catch (e) {
        print('ERROR: addToQueueNext error: $e');
      } finally {
        resyncUpcomingIfChanged(prevNext);
        _saveSettingsDebounced();
        _processNextMutation();
      }
    });
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