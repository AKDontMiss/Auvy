part of '../providers/player_provider.dart';

// When the playing position was last written to preferences (see the position
// ticker).
DateTime? _lastPositionPersist;

// The alarm-track preparation in flight, if any, and the pool of a call made
// meanwhile. See prepareAlarmTrack.
Future<void>? _alarmPrepInFlight;
List<Song>? _alarmPrepNext;

// Pending timer that reports a stall once it has lasted long enough.
// Top-level because this file is an extension (see _fadeGeneration in
// player_playback.dart).
Timer? _stallTimer;

/// Set while a manual skip's own native transition is in flight, so the
/// gapless handler knows the transition it is about to see was requested.
///
/// Top-level because it is written by playNext in player_queue.dart and read
/// here, and two extensions cannot share a static.
///
/// Also cleared by a timer: if the transition never arrives, a flag left set
/// would swallow the next real auto-advance.
bool _skipConsumesNextAdvance = false;

/// When each track in "Recently played" was last started (songId → epoch ms).
///
/// Absolute time on purpose: history is backed up and may be restored on
/// another device later, where a relative "3 hours ago" would be wrong.
///
/// Kept beside `PlayerState.history` rather than inside it, so the hot
/// `List<Song>` history and its saved format don't change. History is deduped
/// by id, so a map keyed by id is exact. Top-level because this file is an
/// extension.
Map<String, int> _historyPlayedAt = {};
Map<String, String> _historyPlayedDevice = {};

/// How many played tracks are kept, locally and in the backup. This is the
/// "Recently played" strip, not an archive (full listening data lives in the
/// intelligence layer), so it stays small enough to sync on every save.
const int _kHistoryCap = 50;

// How long playback must stay in BUFFERING before the UI says anything: long
// enough that a normal track start never trips it, short enough that a real
// stall is acknowledged quickly.
const Duration _kStallGrace = Duration(seconds: 3);


// Which InnerTube client the stream resolver tries first, per track. A
// persistent mid-track 403 on one format escalates to a different client (and
// format) instead of failing on the gated one forever.
//
// Sticky per track: a new video starts at 0 (the preferred client). Rapid
// repeat resolves (within 20 s, i.e. a 403 storm) move to the next client. A
// later resolve (resume, expired URL, replay) keeps the track's last client, so
// a track that needed a different client doesn't fall back to the gated one.
final Map<String, int> _streamClientRotation = {};
final Map<String, DateTime> _lastStreamResolveAt = {};
int _nextStreamClientRotation(String videoId) {
  final now = DateTime.now();
  final last = _lastStreamResolveAt[videoId];
  final prev = _streamClientRotation[videoId] ?? 0;
  final bool rapidRepeat =
      last != null && now.difference(last) < const Duration(seconds: 20);
  final int rot = rapidRepeat ? prev + 1 : prev; // escalate only on a live storm
  _streamClientRotation[videoId] = rot;
  _lastStreamResolveAt[videoId] = now;
  // Bound the maps so a long session can't grow them without limit.
  if (_streamClientRotation.length > 80) {
    final oldest = _lastStreamResolveAt.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (var i = 0; i < 20 && i < oldest.length; i++) {
      _streamClientRotation.remove(oldest[i].key);
      _lastStreamResolveAt.remove(oldest[i].key);
    }
  }
  return rot;
}

extension PlayerSystemController on PlayerNotifier {

  /// Every song playback should skip, the union of:
  ///  • the player-layer dislike set (`auvy_blacklist`),
  ///  • the intelligence-layer dislike set (`intel_blacklist`, cloud-synced),
  ///  • in-memory temporary failure blocks (tracks that failed to load). These
  ///    expire after a few minutes and are never saved: they are not dislikes.
  Set<String> get effectiveBlacklist {
    final now = DateTime.now();
    _failureBlocks.removeWhere((_, until) => now.isAfter(until));
    return {
      ...currentState.blacklistedIds,
      ...ref.read(intelligenceProvider).blacklistedIds,
      ..._failureBlocks.keys,
    };
  }

  /// Un-hides a disliked track everywhere: player layer, intelligence layer and
  /// any active failure block.
  Future<void> unhideSong(Song song) async {
    _failureBlocks.remove(song.id);
    final bl = Set<String>.from(currentState.blacklistedIds)..remove(song.id);
    currentState = currentState.copyWith(blacklistedIds: bl);
    ref.read(intelligenceProvider.notifier).removeFromNotInterested(song);
    await _saveSettings();
  }

  /// Un-hides everything at once (hidden-content page "Restore all").
  Future<void> unhideAll(List<Song> songs) async {
    _failureBlocks.clear();
    currentState = currentState.copyWith(blacklistedIds: {});
    // One state write and one save for the whole restore.
    ref.read(intelligenceProvider.notifier).removeManyFromNotInterested(songs);
    await _saveSettings();
  }

  // ==============================================================
  // MEDIA CONTROLS  (lock screen / notification)
  // ==============================================================
  Future<void> _initMediaControls() async {
    try {
      _audioHandler = await AudioService.init(
        builder: () => AuvyAudioHandler(this),
        // The app's image store, so artwork audio_service loads itself is shared
        // with what the app and MediaArtworkCache already fetched.
        cacheManager: CustomImageCacheManager(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.auvy.app.channel.audio',
          androidNotificationChannelName: 'Auvy Playback',
          androidNotificationChannelDescription: 'Auvy Music Player',
          androidNotificationOngoing: false,
          androidShowNotificationBadge: true,
          androidNotificationIcon: 'drawable/ic_notification',
          // Leave foreground state while paused (the audio_service default). Staying
          // foreground while idle made Android show a persistent "Auvy is running in
          // the background" notice with nothing playing. The notification and media
          // session stay fully interactive while the process lives.
          androidStopForegroundOnPause: true,
          androidNotificationClickStartsActivity: true,
        ),
      );
      print('OK: Media controls initialised (Native Bridge)');
      unawaited(MediaArtworkCache.dropLegacyStore());

      // Check again: in a headless engine the "native platform missing" verdict
      // usually arrives before the handler exists, so _onNativePlatformLost had
      // nothing to stop and an idle service kept holding memory.
      if (!NativeAudioEngine.platformAvailable) {
        print('STOP: handler came up in an engine with no native player — stopping');
        await _audioHandler?.stop();
        return;
      }

      // The launch restore can push the restored track's MediaItem before the
      // handler exists, and that push is lost. Push it again now.
      final restored = currentState.currentSong;
      if (restored != null) _updateMediaItem(restored);
    } catch (e) {
      print('WARN: Media controls setup failed: $e');
    }
  }

  // ==============================================================
  // CONNECTIVITY  (network changes and playback recovery)
  // ==============================================================
  Future<void> _initConnectivityListener() async {
    final notifier = ref.read(connectivityProvider.notifier);

    bool wasConnected = ref.read(connectivityProvider).isConnected;
    bool wasWifi = ref.read(connectivityProvider).isWifi;
    _connectivitySubscription = notifier.stream.listen((connState) {
      // Check isConnected first: isWifi is also false when there is no network at
      // all, which would log an outage as "Mobile".
      print('Network: ${!connState.isConnected ? "none (offline)" : connState.isWifi ? "WiFi" : "Mobile"}');

      // A reconnect after any offline gap: cached stream URLs are bound to the old
      // IP address and will fail with 403. Samsung phones often drop and reconnect
      // Wi-Fi under Doze (frequently with a new IP but the same "wifi" type), so a
      // reconnect must invalidate URLs just like a network type switch.
      final reconnected = !wasConnected && connState.isConnected;
      // A seamless Wi-Fi↔mobile switch keeps isConnected true throughout, so
      // `reconnected` is false, but the cached URLs are still bound to the old IP.
      // Treat a type change like a reconnect.
      final typeSwitched = connState.isConnected && connState.isWifi != wasWifi;
      if (typeSwitched || reconnected) {
        print('Network ${reconnected ? 'reconnected' : 'type switched'} — invalidating all cached stream URLs');
        _audioService.invalidateAllStreams();
        // Let the near-end warm-up run again on the new network.
        _preloadedSongId = null;
        // Fire any pending playback retry now, on a reconnect or a network switch,
        // instead of leaving the track paused until its backoff expires. Only set after
        // a real error, so healthy playback is never disturbed.
        final retry = _pendingNetworkRetry;
        if (retry != null) {
          _pendingNetworkRetry = null;
          _recoveryTimer?.cancel();
          print('Network changed — firing pending playback retry immediately');
          retry();
        }
      } else if (connState.isOffline) {
        if (_preloadedSongId != null && !_cacheManager.isCached(_preloadedSongId!)) {
          print('Network: offline — clearing non-cached preloaded stream ($_preloadedSongId)');
          try {
            NativeAudioEngine.clearUpcoming();
          } catch (_) {}
          _preloadedSongId = null;
        }
      }
      if (connState.isConnected) wasWifi = connState.isWifi;
      wasConnected = connState.isConnected;

      // Network type no longer changes audio quality here. "Mobile = lower, Wi-Fi =
      // restore" was often wrong (captive-portal Wi-Fi can be far worse than good
      // 5G). adaptive_bitrate.dart decides from measured throughput and stalls
      // instead; don't add a connection-type shortcut next to it.
      //
      // Connection type still matters for data saver, a spending choice the user
      // makes, read at resolve time via `shouldUseLowQualityAudio`.
    });
  }

  // ==============================================================
  // ADAPTIVE BITRATE
  // ==============================================================
  /// Reads recent network measurements and returns the bitrate ceiling to
  /// resolve at.
  ///
  /// Called right before each resolve, the only moment a different format can
  /// still be chosen. Never throws: on failure the ladder holds its current rung
  /// rather than dropping to the lowest.
  Future<int> _refreshBitrateCeiling() async {
    try {
      final stats = await NativeAudioEngine.getNetworkStats();
      int? qualityCeiling;
      if (currentState.audioQuality == AudioQuality.low) {
        qualityCeiling = 96000;
      } else if (currentState.audioQuality == AudioQuality.medium) {
        qualityCeiling = 128000;
      }
      final next = nextBitrateDecision(
        current: bitrateDecision,
        stalls: stats.stalls,
        estimateBps: stats.bitrateEstimate,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        dataSaver: ref.read(connectivityProvider).shouldUseLowQualityAudio ||
            currentState.audioQuality == AudioQuality.low,
        userQualityCeiling: qualityCeiling,
      );
      if (next.rung != bitrateDecision.rung) {
        print('adaptive bitrate: rung ${bitrateDecision.rung} → ${next.rung} '
            '(ceiling ${next.ceilingBps} bps, est ${stats.bitrateEstimate} bps, '
            'stalls ${stats.stalls})');
      } else if (stats.stalls > 0) {
        // Log a downgrade held off by the cooldown, so it doesn't look like an
        // unnoticed stall.
        print('adaptive bitrate: ${stats.stalls} stall(s) at rung '
            '${next.rung} — holding, last step was under '
            '${kDowngradeCooldownMs ~/ 1000}s ago');
      } else if (next.rung > 0) {
        // Log a rung that stays above 0 (degraded audio) with the estimate and how
        // far through its clean streak it is, so a ladder stuck low is visible.
        // `needs` is what the estimate must beat to climb. Rung 0 is the healthy
        // default and stays silent.
        final target = kBitrateLadder[next.rung - 1];
        final needs = ((target == 0 ? 160000 : target) * kHeadroom).round();
        print('adaptive bitrate: HELD at rung ${next.rung} '
            '(ceiling ${next.ceilingBps} bps) — est ${stats.bitrateEstimate} bps, '
            'clean ${next.cleanRuns}/$kRunsBeforeUpgrade, '
            'needs ≥$needs bps to climb');
      }
      bitrateDecision = next;
      return next.ceilingBps;
    } catch (e) {
      print('adaptive bitrate: holding rung ${bitrateDecision.rung} ($e)');
      return bitrateDecision.ceilingBps;
    }
  }

  // ==============================================================
  // AUDIO SESSION  (interruptions, headphone unplug / reconnect)
  // ==============================================================
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());
      // Audio focus is not requested here: taking it at launch would interrupt
      // whatever is already playing. The native player takes it when playback
      // starts (Android: requestAudioFocusIfNeeded; iOS: activatePlaybackSession).
      // Not through `setActive(true)` either: that registers a second focus request
      // from the same app, Android sends the loss to the first, and Auvy pauses
      // itself right after starting. Headphone events are broadcast-based and don't
      // need it; interruptionEventStream simply stays quiet.

      _subscriptions.add(session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // Brief dip (navigation prompt, notification): lower the volume.
              print('Audio interruption: ducking volume');
              NativeAudioEngine.setVolume(currentState.volume * 0.3);
              break;
            case AudioInterruptionType.pause:
              // Transient loss (call, voice assistant): pause and remember to resume when
              // the interruption ends.
              if (currentState.isPlaying) {
                _playInterrupted = true;
                print('Audio interruption began (pause): pausing and arming auto-resume');
                togglePlay(haptic: false);
              }
              break;
            case AudioInterruptionType.unknown:
              // Permanent loss on Android (another media app took focus). On iOS,
              // audio_session reports every interruption start as `unknown` and the end with
              // shouldResume as `pause`, so _playInterrupted is also set here so iOS can
              // resume when allowed.
              if (currentState.isPlaying) {
                _playInterrupted = Platform.isIOS;
                print('Audio interruption began (unknown, isIOS: ${Platform.isIOS}): pausing (armed: $_playInterrupted)');
                togglePlay(haptic: false);
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              print('Audio interruption ended: restoring volume');
              NativeAudioEngine.setVolume(currentState.volume);
              break;
            case AudioInterruptionType.pause:
              // Interruption over: resume only if we paused it above and the OS allows
              // resuming (shouldResume on iOS).
              if (_playInterrupted && !currentState.isPlaying) {
                print('Audio interruption ended with shouldResume — resuming playback');
                togglePlay(haptic: false);
              } else {
                print('Audio interruption ended (pause) but not resuming: interrupted=$_playInterrupted isPlaying=${currentState.isPlaying}');
              }
              _playInterrupted = false;
              break;
            case AudioInterruptionType.unknown:
              // Ended without permission to resume (or a permanent Android loss).
              print('Audio interruption ended without resume clearance — remaining paused');
              _playInterrupted = false;
              break;
          }
        }
      }));

      _subscriptions.add(session.becomingNoisyEventStream.listen((_) {
        // Headphones unplugged. Also cancel any pending interruption resume, so
        // unplugging during a call doesn't start the speaker when the call ends.
        print('Audio becoming noisy: headphones unplugged, pausing immediately');
        _playInterrupted = false;
        if (currentState.isPlaying) {
          _pausedByDeviceLoss = DateTime.now();
          togglePlay(haptic: false);
        }
      }));

      // Headphones connected (Bluetooth or wired): may resume playback. Android
      // delivers this even while Auvy is in the background, as long as the process
      // lives.
      //  • `armed` ignores the burst Android sends at registration listing devices
      //    that were already connected, so launching with a headset in doesn't
      //    autoplay.
      //  • Only headphone-type outputs count (not car docks, speakers or mid-song
      //    route changes), and only when a track is loaded and paused.
      bool armed = false;
      Future.delayed(const Duration(seconds: 2), () => armed = true);
      // AudioDeviceType is marked @experimental in audio_session but is stable in
      // practice; the lint is suppressed per line.
      // ignore: experimental_member_use
      const headphoneTypes = <AudioDeviceType>{
        // ignore: experimental_member_use
        AudioDeviceType.bluetoothA2dp,
        // ignore: experimental_member_use
        AudioDeviceType.bluetoothSco,
        // ignore: experimental_member_use
        AudioDeviceType.bluetoothLe,
        // ignore: experimental_member_use
        AudioDeviceType.wiredHeadset,
        // ignore: experimental_member_use
        AudioDeviceType.wiredHeadphones,
        // ignore: experimental_member_use
        AudioDeviceType.usbAudio,
      };
      _subscriptions.add(session.devicesChangedEventStream.listen((event) {
        if (!armed) return;
        // Don't act before saved settings have loaded, or the toggle below would read
        // its default instead of the user's choice.
        if (!_persistenceLoaded) return;

        // Disconnect → pause. A second path alongside `becomingNoisyEventStream`:
        // Android's "becoming noisy" broadcast is reliable for wired unplugs but not
        // for Bluetooth headsets that go out of range, run flat or switch off. The
        // device-removed callback fires on the Bluetooth teardown itself. Pausing twice
        // is harmless.
        final lostHeadphone = event.devicesRemoved
            .any((d) => d.isOutput && headphoneTypes.contains(d.type));
        if (lostHeadphone && currentState.isPlaying) {
          _playInterrupted = false;
          // A timestamp, not a bool: it allows the auto-resume below only for a device
          // coming back soon, not for an unrelated headset connected hours later.
          _pausedByDeviceLoss = DateTime.now();
          print('Output device disconnected — pausing');
          togglePlay(haptic: false);
          return;
        }
        // Log why nothing happened. Native's own becoming-noisy pause often wins the
        // race and sets isPlaying false before this runs; see the next block for how
        // that case is still recorded.
        if (lostHeadphone) {
          // Record the device loss anyway when native paused just before us. Two
          // callbacks react to one hardware event and the pause still happened because
          // the device went away; without the record, reconnecting could only resume
          // through the unconditional "play on connect" setting.
          //
          // Two conditions keep this honest: the player must have been playing within
          // [deviceLossPauseGrace] (a callback race lasts milliseconds), and a
          // deliberate pause disqualifies it, so pausing and then unplugging never
          // schedules a resume.
          final playingAt = _lastPlayingAt;
          final wasPlayingJustNow = playingAt != null &&
              DateTime.now().difference(playingAt) <
                  PlayerNotifier.deviceLossPauseGrace;
          final pausedOnPurpose = _deliberatePauseAt != null &&
              (playingAt == null || _deliberatePauseAt!.isAfter(playingAt));

          if (wasPlayingJustNow && !pausedOnPurpose) {
            _pausedByDeviceLoss = DateTime.now();
            print('Output device disconnected — native had already paused it, '
                'stamping _pausedByDeviceLoss anyway so a reconnect can resume '
                'on the continuity licence');
          } else {
            print('Output device disconnected but isPlaying was already false '
                'and this was not the becoming-noisy race '
                '(${pausedOnPurpose ? "the user paused on purpose" : "last playing too long ago"}) '
                '— not stamping, so a reconnect will not resume');
          }
        }

        // Reconnect → resume, but only when wanted.
        final connectedHeadphone = event.devicesAdded
            .any((d) => d.isOutput && headphoneTypes.contains(d.type));
        if (!connectedHeadphone) return;
        // Log declined reconnects too, so they're distinguishable from a listener that
        // never ran. Only reached when a headphone really connected.
        if (currentState.currentSong == null || currentState.isPlaying) {
          print('Output device connected but not resuming: '
              '${currentState.currentSong == null ? "nothing is loaded" : "already playing"}');
          return;
        }

        // Two separate reasons to resume:
        //
        //  1. We paused this playback because the device went away, recently.
        //     Resuming just continues what the user was listening to.
        //  2. The user turned on "Play on device connect".
        //
        // Without (1), only (2) was available, and it would start music on any
        // headset connection, even hours after a deliberate pause. With (1) the common
        // case works without the setting, and the setting keeps its meaning for people
        // who want it.
        final resumedFrom = _pausedByDeviceLoss;
        final reconnectedInTime = resumedFrom != null &&
            DateTime.now().difference(resumedFrom) <
                PlayerNotifier.deviceResumeWindow;
        if (!reconnectedInTime && !currentState.autoPlayOnConnect) {
          // Neither reason applies (setting off, no recent device loss), so there is
          // nothing to resume.
          print('Output device connected but not resuming: no continuity '
              'licence (stamp ${resumedFrom == null ? "absent" : "expired"}) '
              'and "Play on device connect" is off');
          return;
        }
        _pausedByDeviceLoss = null;

        // Let the new audio route settle before starting playback.
        Future.delayed(const Duration(milliseconds: 350), () async {
          if (!mounted ||
              currentState.currentSong == null ||
              currentState.isPlaying) {
            return;
          }

          // Only the setting (reason 2) needs a sanity check, since reason 1 fires only
          // moments after we paused. This path calls togglePlay() directly and bypasses
          // the audio handler's external-play guard, so check here that no other app is
          // playing. Done after the delay so isMusicActive() isn't confused by Auvy's own
          // fading output.
          if (!reconnectedInTime) {
            final handler = _audioHandler;
            if (handler is AuvyAudioHandler &&
                !await handler.unsolicitedResumeIsPlausible()) {
              return;
            }
            // The await above is a platform round trip; things may have changed.
            if (!mounted ||
                currentState.currentSong == null ||
                currentState.isPlaying) {
              return;
            }
          }

          print('Output device connected — resuming '
              '(${reconnectedInTime ? "was paused by disconnect" : "play-on-connect setting"})');
          togglePlay(haptic: false);
        });
      }));

      _audioSession = session;
      print('OK: Audio session configured with smart-resume');
    } catch (e) {
      print('WARN: Audio session setup failed: $e');
    }
  }


  Future<void> _bindEqualizerToSession() async {
    // Native binds the equalizer to the audio session; this pushes the saved
    // bands to it.
    try {
      
      applyEqBands(currentState.eqBands, persist: false);
      
      print('EQ bindings synced');
    } catch (e) {
      print('WARN: EQ session binding failed: $e');
    }
  }

  /// Saves only the live position (two ints). Runs every few seconds while
  /// playing and on every pause, so killing the app restores the exact spot, not
  /// just the track.
  /// Saves where playback is now (and a spoken-word bookmark). Called when the
  /// app leaves the screen: the periodic save is spaced out (see the position
  /// ticker), and the app may not come back.
  void persistPositionNow() {
    final song = currentState.currentSong;
    if (song == null || !song.hasSeekablePosition) return;
    _lastPositionPersist = DateTime.now();
    _persistPositionOnly();
    if (song.isSpokenWord) _savePodcastPosition(song, currentPositionProvider.value);
  }

  Future<void> _persistPositionOnly() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = currentPositionProvider.value.inMilliseconds;
      await prefs.setInt('auvy_position', ms);
      await prefs.setInt('player_resume_position_ms', ms);
    } catch (_) {}
  }

  // ==============================================================
  // PLAYER INIT  (native callbacks and state sync)
  // ==============================================================
  /// The native player is unreachable in this Flutter engine: shut the session
  /// down instead of retrying.
  ///
  /// audio_service starts a headless engine when the service launches without an
  /// Activity (Bluetooth connect, headset button, Android Auto, the system's
  /// resumption probe). That engine lacks the channels MainActivity registers by
  /// hand, so playback can never start. Retrying forever kept the service running,
  /// burning CPU and threads with nothing playing. Stopping lets the process die,
  /// and the next launch gets a real engine.
  void _onNativePlatformLost() {
    print('STOP: native player unreachable in this engine — stopping the session');

    // Stop repeating work first, so nothing restarts during teardown.
    _positionTicker?.cancel();
    _positionTicker = null;
    _queueSyncTimer?.cancel();
    _queueSyncTimer = null;
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = null;

    // No playback is possible, so state must not claim otherwise; a lingering
    // isPlaying/isLoading would keep the service alive through a swipe-away.
    if (mounted) {
      currentState = currentState.copyWith(isPlaying: false, isLoading: false);
    }

    // Drops the notification, leaves foreground state and lets the service finish.
    // Fire-and-forget: if the handler never came up there is nothing to stop.
    final handler = _audioHandler;
    if (handler != null) {
      handler.stop().catchError((_) {});
    }
  }

  /// Asks the native side one cheap question at startup, so a headless engine
  /// that can't play finds out immediately instead of after a full boot.
  void _probeNativePlatform() {
    // isMusicActive is read-only and safe before anything is loaded.
    NativeAudioEngine.isMusicActive();
  }

  void _initPlayer() {
    NativeAudioEngine.setVolume(currentState.volume);

    // A cross-device merge writes history straight to prefs, but history also
    // lives in memory and is saved on every track change, which would overwrite
    // the merge. Reload settings (including history) into live state after a
    // merge.
    CloudSyncService.onMergedIntoPrefs = () => reloadSettings();

    _initConnectivityListener();
    _bindEqualizerToSession();

    // Save the position every few seconds (see _persistPositionOnly). Skipped for
    // live radio, which has no position.
    _positionTicker?.cancel();
    _positionTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _checkForSilentPlayback();
      if (!currentState.isPlaying) return;
      final song = currentState.currentSong;
      if (song == null) return;
      // Only media with a seekable position (music, podcast episodes, audiobook
      // chapters) is saved; live radio is not.
      if (!song.hasSeekablePosition) return;
      // Not on every tick: each write rewrites the whole preferences file, which
      // holds the library and covers (10 MB measured on an iPhone). Every 15 s
      // for spoken word (where the exact spot matters), 30 s for music; pause,
      // a track change and leaving the app save at once, so little is lost.
      final now = DateTime.now();
      final every = song.isSpokenWord ? 15 : 30;
      final last = _lastPositionPersist;
      if (last != null && now.difference(last).inSeconds < every) return;
      _lastPositionPersist = now;
      _persistPositionOnly();
      if (song.isSpokenWord) {
        _savePodcastPosition(song, currentPositionProvider.value);
      }
    });

    // The native player reports real position, duration and play state about
    // twice a second; this drives the progress bar, time label and play button.
    // currentPositionProvider is a ValueListenable, so updating it moves the bar
    // without rebuilding the whole player page.
    //
    // Lazy resolver: the native player calls back here to resolve a video's stream
    // URL on demand. It is never handed a fixed URL, so expiry, 403s and IP
    // changes are fixed transparently instead of failing the track.
    NativeAudioEngine.setStreamResolver((videoId,
        {int expectContentLength = 0}) async {
      try {
        // Native only calls back when it needs a fresh URL (its own cache serves
        // replay, seek and re-buffer). Drop any Dart-side cached URL for this id first:
        // stream URLs are bound to the IP address, so after a network switch the old
        // one would keep failing for its whole TTL. Re-resolving signs the URL for the
        // current network, even if connectivity_plus missed the switch.
        _audioService.invalidateMemoryCache(videoId);
        // Don't rotate clients mid-track. A different client returns a different
        // format, which is a different file with its own length, while the player is
        // about to request the byte offset it reached in the old file. So a mid-track
        // re-resolve (expectContentLength > 0) must return a fresh URL for the same
        // format: the rotation counter is left alone.
        //
        // "Same format" means the track's sticky client index, read without bumping
        // it, not client 0. A track that escalated was pinned to client 1 or 2's
        // format, and asking client 0 would return a different format every time.
        //
        // The cooldown check for a refusing account (see _maxNoStreamStreak) comes
        // first, so a refusal costs one comparison instead of a sweep of every client.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (_resolveCooldownUntilMs > nowMs) {
          print('STOP: resolve suppressed for '
              '${((_resolveCooldownUntilMs - nowMs) / 1000).round()}s — every '
              'client refused $_noStreamStreak time(s) in a row; NOT hitting '
              'the network');
          return null;
        }
        final bool midTrack = expectContentLength > 0;
        // Checked before any network work: once a pin has been given up on (see
        // _maxPinRefusals), native keeps asking because it can't know anything
        // changed. Answering here costs one comparison instead of a metadata request.
        if (midTrack &&
            _pinFailId == videoId &&
            _pinFailClen == expectContentLength) {
          final waitMs =
              _pinCooldownUntilMs - DateTime.now().millisecondsSinceEpoch;
          if (waitMs > 0) {
            print('STOP: mid-track re-resolve suppressed (${waitMs}ms left) — '
                'clen $expectContentLength was refused $_pinFailCount time(s) '
                'and a clean restart is in flight; NOT hitting the network');
            return null;
          }
          // Reset the refusal count when a cooldown has lapsed, but only if a cooldown
          // was actually set (`_pinCooldownUntilMs` starts at 0). Without the `!= 0`
          // guard the count reset on every re-resolve and the give-up cap was
          // unreachable. The lapsed cooldown starts a fresh run with the same two
          // retries. [_pinGiveUps] is not cleared, so the backoff keeps growing.
          if (_pinCooldownUntilMs != 0) {
            _pinCooldownUntilMs = 0;
            _pinFailCount = 0;
          }
        }
        final rot = midTrack
            ? (_streamClientRotation[videoId] ?? 0)
            : _nextStreamClientRotation(videoId);
        // Log that the pin engaged; a lack of 403s alone doesn't prove it ran.
        // Release builds drop print().
        print(midTrack
            ? 'mid-track re-resolve — format PINNED to clen '
                '$expectContentLength (client rotation $rot)'
            : 'fresh resolve — client rotation $rot');
        String title = '';
        String artist = '';
        final cur = currentState.currentSong;
        if (cur != null && cur.id == videoId) {
          title = cur.title;
          artist = cur.artist;
        } else {
          for (final s in currentState.queue) {
            if (s.id == videoId) {
              title = s.title;
              artist = s.artist;
              break;
            }
          }
        }
        // The ceiling must not move during a mid-track re-resolve, which exists to
        // get a fresh URL for the same format. Stalls trigger re-resolves and also step
        // the ladder down, so a lower ceiling here would pick a different format that
        // the pin then rejects. Stalls are still counted and applied at the next fresh
        // resolve, at a track boundary where changing format is free.
        final ceiling = midTrack
            ? bitrateDecision.ceilingBps
            : await _refreshBitrateCeiling();
        // Freeze the data-saver flag for the track too. `shouldUseLowQualityAudio`
        // flips when the network changes, which is exactly when a re-resolve happens,
        // so the re-resolve would ask for a different bitrate (a different length) and
        // the pin would refuse it. Like the ceiling, both inputs hold for the life of
        // the track.
        final bool lowQuality;
        if (midTrack) {
          // Fall back to the live value only if this track has no recorded choice.
          lowQuality = _lowQualityPin[videoId] ??
              (ref.read(connectivityProvider).shouldUseLowQualityAudio ||
                  currentState.audioQuality == AudioQuality.low);
        } else {
          lowQuality = ref.read(connectivityProvider).shouldUseLowQualityAudio ||
              currentState.audioQuality == AudioQuality.low;
          _lowQualityPin[videoId] = lowQuality;
          if (_lowQualityPin.length > 300) {
            _lowQualityPin.remove(_lowQualityPin.keys.first);
          }
        }
        final stream = await _audioService.getStreamWithFallback(
          videoId, title, artist,
          // Data saver and manual Low quality are user-set caps on data use, so a fast
          // network doesn't override them. Everything else is decided by measurement.
          lowQuality: lowQuality,
          clientStartIndex: rot,
          maxBitrate: ceiling,
          // Stop resolving a track the user has already left. Trying every client can
          // take seconds; if the user skipped, a late "every client refused" would mark
          // the whole session as refused because of a track nobody is waiting for.
          //
          // "Wanted" means any track the player is legitimately holding: the current
          // song, or the preloaded next item, which native also asks to re-resolve when
          // a URL expires or the network switches. Refusing that one returned null
          // without counting as a refusal, so native retried in a loop that could
          // neither succeed nor fail.
          isStillWanted: () {
            final cur = currentState.currentSong?.id;
            if (cur == videoId) return true;
            // Only for a re-resolve. A first resolve of the next track goes through the
            // preload path, which has its own `stillNext` check.
            if (expectContentLength > 0 && _preloadedSongId == videoId) {
              return true;
            }
            return false;
          },
        );
        final url = stream?['url'];
        if (url == null || url.isEmpty) {
          // A skip is not a refusal. An abandoned resolve also returns null here, and
          // counting it would let quick skipping trip _maxNoStreamStreak and block every
          // resolve for a growing cooldown. If the track moved on, the null can't be
          // blamed on YouTube either way.
          if (currentState.currentSong?.id != videoId) {
            // Not counted, but logged with a repeat count, so a loop of abandoned resolves
            // for the same id is visible in an exported log.
            if (_abandonedResolveId == videoId) {
              _abandonedResolveCount++;
            } else {
              _abandonedResolveId = videoId;
              _abandonedResolveCount = 1;
            }
            final repeat = _abandonedResolveCount;
            logEvent('resolve for $videoId returned nothing, but the track had '
                'already changed — not counting it as a refusal'
                '${repeat > 2 ? " (abandoned $repeat times in a row — native "
                    "keeps asking about a track this predicate refuses)" : ""}');
            return null;
          }
          _abandonedResolveId = null;
          _abandonedResolveCount = 0;
          _noStreamStreak++;
          if (_noStreamStreak >= _maxNoStreamStreak) {
            final over = _noStreamStreak - _maxNoStreamStreak;
            final backoff = (_resolveCooldownBaseMs << over)
                .clamp(_resolveCooldownBaseMs, _resolveCooldownMaxMs);
            _resolveCooldownUntilMs =
                DateTime.now().millisecondsSinceEpoch + backoff;
            print('STOP: $_noStreamStreak resolves in a row found no playable '
                'stream — this is a refusal, not a network fault. Backing off '
                'for ${backoff ~/ 1000}s instead of re-asking every 5s');
          }
          return null;
        }
        // A successful resolve shows nothing is being refused any more.
        if (_noStreamStreak > 0) {
          print('OK: streams are resolving again after $_noStreamStreak '
              'refusal(s)');
          _noStreamStreak = 0;
          _resolveCooldownUntilMs = 0;
        }
        // YouTube reports the track's measured loudness in the player response. Cache
        // it per video and, if the track is playing now, apply normalization
        // immediately; this resolve is the only point the value is available.
        final ld = double.tryParse('${stream?['loudnessDb'] ?? ''}');
        if (ld != null) {
          _loudnessByVideoId[videoId] = ld;
          if (_loudnessByVideoId.length > 300) {
            _loudnessByVideoId.remove(_loudnessByVideoId.keys.first);
          }
          if (currentState.currentSong?.id == videoId) _applyAudioNormalization();
        }
        // A mid-track re-resolve that changed format is refused: a different length is
        // a different file, so continuing at the current byte offset can only fail.
        // Refusing lets Dart restart the track cleanly instead of burning retries.
        final int gotClen =
            int.tryParse(stream?['contentLength']?.toString() ?? '') ?? 0;
        if (midTrack && gotClen > 0 && gotClen != expectContentLength) {
          if (_pinFailId != videoId || _pinFailClen != expectContentLength) {
            _pinFailId = videoId;
            _pinFailClen = expectContentLength;
            _pinFailCount = 0;
            _pinGiveUps = 0;
          }
          _pinFailCount++;
          print('WARN: re-resolve returned a DIFFERENT format '
              '(clen $gotClen != $expectContentLength) — refusing it '
              '(refusal $_pinFailCount, give up at $_maxPinRefusals)');
          if (_pinFailCount >= _maxPinRefusals) {
            // Give up on the pin: restart the track so a fresh resolve pins a format that
            // exists, costing one re-buffer instead of silence.
            //
            // The cooldown doubles per give-up up to 5 minutes, so a pin that can never
            // resolve goes quiet after a few restarts instead of restarting every 30 s.
            _pinGiveUps++;
            final backoff = (_pinCooldownMs << (_pinGiveUps - 1))
                .clamp(_pinCooldownMs, _pinCooldownMaxMs);
            _pinCooldownUntilMs =
                DateTime.now().millisecondsSinceEpoch + backoff;
            print('STOP: the pinned format (clen $expectContentLength) is gone — '
                'giving up on it and restarting the track cleanly '
                '(give-up #$_pinGiveUps, quiet for ${backoff ~/ 1000}s)');
            // Not on this callback: native is blocked waiting for the reply, and the
            // restart calls back into native, so running it inline would deadlock.
            final restartId = videoId;
            Timer(Duration.zero, () {
              if (!mounted) return;
              if (currentState.currentSong?.id != restartId) return;
              handleStreamLeaseExpiration(
                // A stalled track reads isPlaying=false early, so take intent from either
                // flag, or the restart would land paused.
                intendedPlaying: currentState.isPlaying || currentState.isLoading,
                resumeFrom: currentPositionProvider.value,
              );
            });
          }
          return null;
        }
        // A format that resolved can be trusted again.
        if (_pinFailId == videoId) {
          _pinFailId = null;
          _pinFailClen = 0;
          _pinFailCount = 0;
          _pinCooldownUntilMs = 0;
        }
        return {
          'url': url,
          'userAgent': stream?['user_agent'] ?? '',
          'contentLength': stream?['contentLength'] ?? '0',
        };
      } catch (e) {
        print('resolveStream failed for $videoId: $e');
        return null;
      }
    });

    NativeAudioEngine.setListeners(
      // Recover from a fatal stream error (403/expired) by re-resolving and
      // resuming. playWhenReady carries the user's real play intent; isPlaying is
      // already false by now and would reload the track paused.
      onError: (playWhenReady) {
        if (!mounted) return;
        final livePos = currentPositionProvider.value;
        final pos = (livePos > Duration.zero)
            ? livePos
            : (currentState.position > Duration.zero ? currentState.position : Duration.zero);
        print('onError: native playback error (intendedPlaying=$playWhenReady, pos=${pos.inSeconds}s)');
        handleStreamLeaseExpiration(intendedPlaying: playWhenReady, resumeFrom: pos);
      },
      onPosition: (position, duration, isPlaying) {
        if (!mounted) return;
        // Record "we were playing a moment ago" for the disconnect handler, since
        // native's becoming-noisy pause often sets isPlaying false before it runs.
        if (isPlaying) _lastPlayingAt = DateTime.now();
        // Clear a stuck `isLoading` once native reports playback (playing, or the
        // clock moving); otherwise the mini-player and progress bar could stay frozen.
        if (currentState.isLoading && (isPlaying || position > Duration.zero)) {
          currentState = currentState.copyWith(isLoading: false);
        }
        // Audible progress means the network works again: clear the cross-track
        // failure streaks and any pending instant retry.
        if (isPlaying && position > Duration.zero) {
          _autoAdvanceFailStreak = 0;
          _gateFailStreak = 0;
          _pendingNetworkRetry = null;
        }
        if (currentState.isLoading) return;

        // A seek is settling: native still reports pre-seek positions for a tick or
        // two. Hold the target until the clock lands near it; a 2.5 s failsafe
        // releases the hold regardless.
        final pendingSeek = _pendingSeekTarget;
        if (pendingSeek != null) {
          final landed =
              (position - pendingSeek).abs() < const Duration(milliseconds: 1200);
          final expired = _pendingSeekAt == null ||
              DateTime.now().difference(_pendingSeekAt!) >
                  const Duration(milliseconds: 2500);
          if (landed || expired) {
            _pendingSeekTarget = null;
            _pendingSeekAt = null;
          } else {
            return; // stale pre-seek tick — keep showing the target
          }
        }

        // High frequency: the progress bar and time label listen to this directly
        // without touching PlayerState.
        currentPositionProvider.value = position;

        // A-B loop: when playback reaches loopEnd, jump back to loopStart.
        if (currentState.isLoopActive && isPlaying) {
          final loopEnd = currentState.loopEnd!;
          final loopStart = currentState.loopStart!;
          if (position >= loopEnd) {
            seek(loopStart);
            return;
          }
        }

        // Sponsor breaks are skipped here, on the player's own tick, so it works with
        // the player page closed and the screen off.
        _maybeSkipSponsorBreak(position);

        final knownDuration = duration > Duration.zero ? duration : currentState.duration;
        // Structural changes (duration known, play/pause) go into PlayerState
        // immediately. Position is folded in at most about once a second so every
        // playerProvider consumer isn't rebuilt on every tick.
        final structuralChange = currentState.duration != knownDuration ||
            currentState.isPlaying != isPlaying;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final positionDue = nowMs - _lastPosStateWriteMs >= 1000;
        if (structuralChange || (currentState.position != position && positionDue)) {
          _lastPosStateWriteMs = nowMs;
          currentState = currentState.copyWith(
            position: position,
            duration: knownDuration,
            isPlaying: isPlaying,
          );
        }
        // Credit a play once the track has really been heard: about 30 s, or half of a
        // short track (configurable in Settings → Listening data). Fires once per play
        // (_currentPlayRecorded, reset in playSong), so tap-then-skip credits nothing.
        // Live radio and podcast streams don't count toward music taste. With history
        // paused, nothing is credited.
        if (isPlaying &&
            !_currentPlayRecorded &&
            !ListeningPolicy.historyPaused) {
          final cs = currentState.currentSong;
          if (cs != null && !cs.id.startsWith('http')) {
            final thresholdMs =
                ListeningPolicy.thresholdMsFor(knownDuration.inMilliseconds);
            if (position.inMilliseconds >= thresholdMs) {
              _currentPlayRecorded = true;
              ref.read(intelligenceProvider.notifier).recordPlay(cs);
              // ListenBrainz uses the same threshold and the same pause-history switch, so
              // "heard" means one thing and pausing history also stops uploads. Does
              // nothing unless a token has been entered.
              //
              // `listened_at` is when the track started, not now, so listens aren't dated
              // ~30 s late or misordered.
              unawaited(ScrobbleService.instance.submitListen(
                cs,
                startedAt: DateTime.now().subtract(position),
              ));
            }
          }
        }
        // Warm the next track as this one nears its end. Cheap to call every tick; it
        // only acts inside the lead window.
        if (isPlaying) _preloadNextTrack();
      },
      // Track finished: advance the queue. If a new track is already loading (a
      // manual skip mid-song), the old track's end must not advance a second time.
      onTrackEnded: () {
        final cs = currentState.currentSong;
        final livePos = currentPositionProvider.value;
        final dur = currentState.duration;
        print('onTrackEnded: song="${cs?.title}" pos=${livePos.inSeconds}s '
            'dur=${dur.inSeconds}s isLoading=${currentState.isLoading} '
            'queueLen=${currentState.queue.length}');
        if (!mounted || currentState.isLoading) {
          print('onTrackEnded DROPPED (mounted=$mounted isLoading=${currentState.isLoading})');
          return;
        }
        // A live stream never really ends; "ended" means the connection dropped.
        // Reconnect the same station instead of advancing. isNextOrPrev bypasses the
        // same-song guard so the stream actually reloads.
        if (cs != null && cs.id.startsWith('http') && cs.albumTitle != 'Podcast') {
          playSong(cs,
              isManual: false,
              isNextOrPrev: true,
              source: currentState.playbackSource);
          return;
        }
        // A-B loop active: go back to loopStart instead of advancing.
        if (currentState.isLoopActive && currentState.loopStart != null) {
          seek(currentState.loopStart!);
          return;
        }

        // Premature end: the native player reports "ended" whenever the input stream
        // hits end-of-file, including when a throttled network cuts the connection
        // mid-track. If playback ended well short of a known duration, the track didn't
        // finish: heal it (local copy first, else a fresh stream) and resume where
        // audio stopped, instead of skipping.
        final catalogueDur = cs != null ? (_mediaItemDuration(cs, Duration.zero) ?? Duration.zero) : Duration.zero;
        // Use the catalogue duration, or the player's if it can't be parsed; if both
        // exist take the larger, so a short duration from a truncated stream can't hide
        // the cut-off.
        final knownDur = catalogueDur > Duration.zero
            ? (dur > catalogueDur ? dur : catalogueDur)
            : dur;
        final effectivePos = (livePos > Duration.zero)
            ? livePos
            : (currentState.position > Duration.zero ? currentState.position : Duration.zero);

        final endedEarly = cs != null &&
            !cs.id.startsWith('http') &&
            ((knownDur > const Duration(seconds: 15) &&
              effectivePos < knownDur - const Duration(seconds: 4)) ||
             (knownDur <= Duration.zero &&
              effectivePos > Duration.zero &&
              effectivePos < const Duration(minutes: 2)));
        if (endedEarly) {
          print('PREMATURE end — healing "${cs.title}" '
              '(${effectivePos.inSeconds}s/${knownDur.inSeconds}s) instead of skipping');
          handleStreamLeaseExpiration(intendedPlaying: true, resumeFrom: effectivePos);
          return;
        }
        // The track played to the end, so its audio is in the native play cache:
        // promote it into the Cached folder with no network use. Skips radio,
        // podcasts, non-video ids and tracks already cached. Fire-and-forget.
        if (cs != null &&
            !cs.id.startsWith('http') &&
            cs.albumTitle != 'Podcast' &&
            cs.id.length == 11 &&
            !_cacheManager.isCached(cs.id)) {
          _cacheManager.cacheTrack(cs, '', isExplicitDownload: false);
        }
        print('onTrackEnded → playNext (genuine end)');
        playNext(autoAdvance: true);
      },
      onIsPlayingChanged: (isPlaying, {playWhenReady}) {
        if (!mounted) return;
        // Buffering during a network hiccup while the user never paused
        // (playWhenReady true) must not flip isPlaying off, or the play button,
        // notification and equalizer flicker. Real pauses have playWhenReady false.
        final effectivePlaying = playWhenReady ?? isPlaying;
        if (currentState.isPlaying != effectivePlaying) {
          currentState = currentState.copyWith(isPlaying: effectivePlaying);
        }
      },
      // "Pause when muted": turning the volume to zero is a clear stop gesture, but
      // Android keeps playing into silence. Opt-in, and routed through
      // togglePlay(haptic: false) like other automatic pauses.
      onVolumeMuted: () {
        if (!mounted || !ListeningPolicy.pauseOnMute) return;
        if (!currentState.isPlaying) return;
        print('media volume hit zero — pausing');
        togglePlay(haptic: false);
      },
      // Stall detection. Every BUFFERING transition is reported, including normal
      // track starts, so a stall must last [_kStallGrace] before the UI shows it.
      // This catches playback that claims to play while no audio comes out, e.g.
      // when a stream URL dies because the network path changed.
      onBuffering: (buffering) {
        _stallTimer?.cancel();
        if (!buffering) {
          if (currentState.isStalled) {
            currentState = currentState.copyWith(isStalled: false);
          }
          return;
        }
        _stallTimer = Timer(_kStallGrace, () {
          if (!mounted) return;
          currentState = currentState.copyWith(isStalled: true);
          print('playback stalled — buffering for '
              '${_kStallGrace.inSeconds}s with no audio');

          // A stall arms recovery, not just a message. Losing the network mid-track
          // raises no error; the player just buffers. Arming the same retry an error
          // would lets the reconnect handler resume playback. It checks the song id, so a
          // late fire after the user moved on does nothing.
          final stalledSong = currentState.currentSong;
          if (stalledSong == null) return;
          final wasPlaying = currentState.isPlaying;

          // A track already on disk doesn't need to wait for the network: heal from the
          // local copy right away.
          if (!stalledSong.id.startsWith('http') &&
              _cacheManager.getCachedPath(stalledSong.id) != null) {
            print('stall recovery — "${stalledSong.title}" is already cached; '
                'healing from disk now instead of waiting out the '
                '12s network floor');
            handleStreamLeaseExpiration(
              intendedPlaying: wasPlaying,
              resumeFrom: currentState.position,
            );
            return;
          }
          void resumeAfterStall() {
            if (!mounted) return;
            if (currentState.currentSong?.id != stalledSong.id) return;
            if (_isProcessingTransition) return;
            print('stall recovery — reloading "${stalledSong.title}" '
                'at ${currentState.position.inSeconds}s');
            // Resolve fresh: the stalled URL belongs to the network path that went away,
            // and the reconnect handler has already dropped it.
            _loadAndPlay(stalledSong,
                playImmediately: wasPlaying, startFrom: currentState.position);
          }

          _pendingNetworkRetry = resumeAfterStall;
          // Also a timer, because a stall isn't always a disconnect. connectivity_plus
          // reports the link, not whether packets flow; a captive portal or a dead CDN
          // edge stalls playback while the OS still says "connected", so no event fires.
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 12), () {
            if (!mounted) return;
            if (_pendingNetworkRetry != resumeAfterStall) return;
            _pendingNetworkRetry = null;
            resumeAfterStall();
          });
        });
      },
      onNativeAutoAdvance: (videoId) {
        // Gapless: the native player moved into the pre-buffered next item (no
        // "ended" event mid-playlist). Credit and cache the finished track, then sync
        // Dart's queue without reloading, which would restart the audio.
        if (!mounted || !currentState.gaplessPlayback) return;
        // A manual skip also lands here and must not count as a finished track: it
        // would advance the queue a second time and credit the skipped song a full
        // play. The skip does its own bookkeeping, so consume this one and ignore it.
        if (_skipConsumesNextAdvance) {
          _skipConsumesNextAdvance = false;
          print('transition for $videoId is our own skip — not a finish');
          return;
        }
        // Repeat One wins over a stale gapless item. Nothing should be prepared in
        // this mode, but if something slipped through, the player has already moved
        // into the next song; reload the current track so Repeat One actually repeats.
        if (currentState.repeatMode == RepeatMode.one) {
          final repeatSong = currentState.currentSong;
          print('Repeat One: dropping a stale gapless advance to $videoId');
          try {
            NativeAudioEngine.clearUpcoming();
          } catch (_) {}
          _preloadedSongId = null;
          if (repeatSong != null) {
            _loadAndPlay(repeatSong, playImmediately: true);
          }
          return;
        }
        if (currentState.isLoopActive && currentState.loopStart != null) {
          final loopStart = currentState.loopStart!;
          print('A-B loop: dropping gapless advance to $videoId and looping to $loopStart');
          try {
            NativeAudioEngine.clearUpcoming();
          } catch (_) {}
          _preloadedSongId = null;
          seek(loopStart);
          return;
        }
        final finished = currentState.currentSong;
        // The track played to the end, so its bytes are in the play cache: promote it
        // for free (as in onTrackEnded).
        if (finished != null &&
            !finished.id.startsWith('http') &&
            finished.albumTitle != 'Podcast' &&
            finished.id.length == 11 &&
            !_cacheManager.isCached(finished.id)) {
          _cacheManager.cacheTrack(finished, '', isExplicitDownload: false);
        }
        // The prepared item should be queue[1]. If the queue changed after it was
        // queued, fall back to a normal load of the correct next track (brief gap,
        // rare).
        final matches = currentState.queue.length > 1 &&
            currentState.queue[1].id == videoId;
        print('gapless auto-advance → $videoId (matches=$matches)');
        // Did the previous track actually finish? This path handles most transitions,
        // so log it when a track ended noticeably early. The last reported position
        // still belongs to the old track, since this fires on the transition itself.
        //
        // Both thresholds must be exceeded: ten seconds is nothing in an hour-long
        // podcast and five percent is nothing in a short interlude, and gapless joins
        // normally land a moment early.
        final catalogueDur = finished != null ? (_mediaItemDuration(finished, Duration.zero) ?? Duration.zero) : Duration.zero;
        final expected = catalogueDur > Duration.zero
            ? (currentState.duration > catalogueDur ? currentState.duration : catalogueDur)
            : currentState.duration;
        final livePos = currentPositionProvider.value;
        final effectivePos = (livePos > Duration.zero)
            ? livePos
            : (currentState.position > Duration.zero ? currentState.position : Duration.zero);
        final shortBy = expected - effectivePos;
        if (expected > const Duration(seconds: 15) &&
            shortBy > const Duration(seconds: 10) &&
            shortBy.inMilliseconds > expected.inMilliseconds * 0.05) {
          // logEvent, not print, so it reaches the activity log.
          logEvent('PREVIOUS TRACK DID NOT FINISH — "${finished?.title}" '
              'stopped ${shortBy.inSeconds}s short of ${expected.inSeconds}s '
              'and the queue advanced');
        }
        playNext(autoAdvance: true, alreadyPlayingNatively: matches);
      },
      onIcyMetadata: (streamTitle, stationName, genre, bitrate) {
        if (!mounted) return;
        final cs = currentState.currentSong;
        if (cs != null && cs.mediaKind == MediaKind.liveStream) {
          IcyMetadataService.updateLiveMetadata(
            cs.id,
            streamTitle: streamTitle,
            stationName: stationName,
            genre: genre,
            bitrate: bitrate,
          );
          RadioScheduleService.onNativeIcyMetadata(cs, null);
          _updateLiveRadioNotification(cs, streamTitle);
        }
      },
    );
  }
  

  // After 3 hours without playback, stop the player and release its resources.

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 3), () async {
      if (!currentState.isPlaying) {
        print('3h inactivity — releasing background resources');
        await NativeAudioEngine.stop();
        _nativeLoadedSongId = null;
        currentState = currentState.copyWith(
          currentSong: null,
          queue: [],
          miniPlayerVisible: false,
        );
      }
    });
  }

  // ==============================================================
  // PERSISTENCE  (save / load queue & settings)
  // ==============================================================
  Future<void> _initPersistence() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final blacklistJson    = prefs.getStringList('auvy_blacklist') ?? [];
    final userQueueJson    = prefs.getString('auvy_user_queue');
    final contextQueueJson = prefs.getString('auvy_context_queue');
    final autoplayQueueJson= prefs.getString('auvy_autoplay_queue');
    final userQueueEnd     = prefs.getInt('auvy_user_queue_end') ?? 0;
    final cacheLimit       = prefs.getInt('auvy_max_cache_size') ?? 500;
    // Apply the saved cache limit to the cache manager now, not only when the
    // slider is touched.
    _cacheManager.maxCacheSizeMB = cacheLimit;

    final queueJson        = prefs.getString('auvy_queue');       
    final originalQueueJson= prefs.getString('auvy_original_queue');
    final currentSongJson  = prefs.getString('auvy_current_song');
    final savedPositionMs  = prefs.getInt('auvy_position') ?? 0;
    final shuffle          = prefs.getBool('auvy_shuffle') ?? false;
    final repeatIdx        = prefs.getInt('auvy_loop') ?? 0;
    final vol              = prefs.getDouble('auvy_volume') ?? 1.0;
    final ctxId            = prefs.getString('auvy_ctx_id');
    final ctxType          = prefs.getString('auvy_ctx_type');
    final ctxTitle         = prefs.getString('auvy_ctx_title');
    final crossfade        = prefs.getBool('auvy_crossfade') ?? false;
    final crossfadeSec     = prefs.getInt('auvy_crossfade_duration') ?? 5;
    final normalization    = prefs.getBool('auvy_normalization') ?? true;
    final qualityIdx       = prefs.getInt('auvy_audio_quality') ?? AudioQuality.auto.index;
    final gapless          = prefs.getBool('auvy_gapless') ?? true;
    // 'auvy_explicit_preferred' is not read: explicit/original versions are always
    // preferred, and an old saved `false` must not disable that.
    final autoPlayConnect  = prefs.getBool('auvy_autoplay_on_connect') ?? false;
    // Audio-only is permanent; any stored value is ignored. There is no longer a
    // video mode or a setting for it.
    const processVideos = false;
    // Hides YouTube Shorts where videos are allowed. On by default: a Short is a
    // snippet, not a song.
    SearchService.hideShorts = prefs.getBool('auvy_hide_shorts') ?? true;
    // Apply to the search layer up front so the first search respects it.
    SearchService.processVideos = processVideos;
    // Load the learned video→audio map so videos seen before need no lookup.
    // Unawaited; a swap that runs first just misses the cache once.
    unawaited(SearchService.loadConformCache());

    final silenceSkip = prefs.getBool('auvy_silence_skipping') ?? false;
    final pitch       = prefs.getDouble('auvy_pitch') ?? 1.0;
    final podcastSpd  = prefs.getDouble('auvy_podcast_speed') ?? 1.0;
    final seekJumpSec = prefs.getInt('auvy_seek_jump_seconds') ?? 10;
    final pauseOnMute = prefs.getBool('auvy_pause_on_zero_volume') ?? false;
    final eqEnabled   = prefs.getBool('auvy_eq_enabled') ?? false;
    final eqBandsRaw  = prefs.getStringList('auvy_eq_bands');
    final eqBands     = eqBandsRaw != null
        ? eqBandsRaw.map((s) => double.tryParse(s) ?? 0.0).toList()
        : List<double>.filled(5, 0.0);

    List<Song> userQueue = userQueueJson != null
        ? (jsonDecode(userQueueJson) as List).map((s) => Song.fromMap(s)).toList()
        : [];
    List<Song> contextQueue = contextQueueJson != null
        ? (jsonDecode(contextQueueJson) as List).map((s) => Song.fromMap(s)).toList()
        : [];
    List<Song> autoplayQueue = autoplayQueueJson != null
        ? (jsonDecode(autoplayQueueJson) as List).map((s) => Song.fromMap(s)).toList()
        : [];
    final List<Song> history = _readHistory(prefs);
    List<Song> legacyQueue = queueJson != null
        ? (jsonDecode(queueJson) as List).map((s) => Song.fromMap(s)).toList()
        : [];

    List<Song> originalQueue = originalQueueJson != null
        ? (jsonDecode(originalQueueJson) as List).map((s) => Song.fromMap(s)).toList()
        : legacyQueue;

    Song? current = currentSongJson != null
        ? Song.fromMap(jsonDecode(currentSongJson))
        : null;

    List<Song> fullQueue;
    int currentIndex = 0;

    if (userQueue.isNotEmpty || contextQueue.isNotEmpty || autoplayQueue.isNotEmpty) {
      fullQueue = [ if (current != null) current, ...userQueue, ...contextQueue, ...autoplayQueue ];
    } else if (legacyQueue.isNotEmpty) {
      fullQueue = legacyQueue;
      if (current != null) {
        currentIndex = legacyQueue.indexWhere((s) => s.id == current.id);
        if (currentIndex == -1) currentIndex = 0;
      }
    } else {
      fullQueue = current != null ? [current] : [];
    }

    if (!mounted) return;
    currentState = currentState.copyWith(
      history:                 history,
      historyPlayedAt:         Map<String, int>.from(_historyPlayedAt),
      historyPlayedDevice:     Map<String, String>.from(_historyPlayedDevice),
      queue:                   fullQueue,
      userQueue:               userQueue,
      contextQueue:            contextQueue,
      autoplayQueue:           autoplayQueue,
      maxCacheSizeMB:          cacheLimit,
      userQueueEndIndex:       userQueueEnd,
      blacklistedIds:          blacklistJson.toSet(),
      originalQueue:           originalQueue.isNotEmpty ? originalQueue : fullQueue,
      currentSong:             current,
      currentIndex:            currentIndex,
      position:                Duration(milliseconds: savedPositionMs),
      miniPlayerVisible:       current != null, 
      isShuffle:               shuffle,
      // Clamped: an out-of-range saved value would throw during restore.
      repeatMode:              RepeatMode.values[
                                 repeatIdx.clamp(0, RepeatMode.values.length - 1)],
      volume:                  vol,
      contextId:               ctxId,
      pitch: pitch,
      podcastSpeed: podcastSpd,
      eqEnabled: eqEnabled,
      eqBands: eqBands,
      silenceSkippingEnabled: silenceSkip,
      crossfadeEnabled: crossfade,
      crossfadeDuration: Duration(seconds: crossfadeSec),
      audioNormalizationEnabled: normalization,
      audioQuality: AudioQuality.values[qualityIdx],
      gaplessPlayback: gapless,
      autoPlayOnConnect: autoPlayConnect,
      processVideosEnabled: processVideos,
      contextType: ctxType,
      contextTitle: ctxTitle,
      seekJumpSeconds: seekJumpSec,
      pauseOnZeroVolume: pauseOnMute,
    );

    if (current != null && current.image.isNotEmpty) {
      ref.read(playerColorProvider.notifier).updateFromImage(current.image);
      _updateMediaItem(current);
    }

    final resumeSource = prefs.getString('player_resume_source') ?? 'Library';
    final resumeContextTitle = prefs.getString('player_resume_context_title') ?? '';
    // Restore the location name with the source. The player header has two lines,
    // the kind ("PLAYING FROM PLAYLIST") and the name, so saving only the source
    // lost the name on restart.
    final resumeLocation = prefs.getString('player_resume_location') ?? '';
    final accurateResumePosMs = prefs.getInt('player_resume_position_ms') ?? savedPositionMs;

    if (!mounted) return;
    currentState = currentState.copyWith(
      playbackSource: resumeSource,
      locationName: resumeLocation.isNotEmpty ? resumeLocation : null,
      contextTitle: resumeContextTitle.isNotEmpty ? resumeContextTitle : ctxTitle,
      miniPlayerVisible: current != null,
    );

    // Push the loaded EQ and pitch settings to the native player. The equalizer
    // applies them once the audio session starts; pitch applies immediately.
    NativeAudioEngine.setEqualizer(currentState.eqEnabled, currentState.eqBands);
    NativeAudioEngine.setPitch(currentState.pitch);
    // Push the restored silence-skipping flag, or Settings shows "on" while the
    // player has it off.
    NativeAudioEngine.setSkipSilence(currentState.silenceSkippingEnabled);

    // One-time cleanup: older builds wrote temporary stream failures into this
    // saved blocklist, hiding tracks the user never disliked. Real dislikes are
    // always also in the intelligence blocklist, so any player-layer id missing
    // there is a stale failure and is dropped. Delayed until intelligence state
    // has loaded.
    Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      final intel = ref.read(intelligenceProvider);
      final intelLoaded = intel.blacklistedIds.isNotEmpty ||
          intel.playCounts.isNotEmpty ||
          intel.trackMetadata.isNotEmpty;
      if (!intelLoaded) return;
      final cleaned = currentState.blacklistedIds
          .where((id) => intel.blacklistedIds.contains(id))
          .toSet();
      if (cleaned.length != currentState.blacklistedIds.length) {
        print('Purged ${currentState.blacklistedIds.length - cleaned.length} stale failure-blocks from the dislike list');
        currentState = currentState.copyWith(blacklistedIds: cleaned);
        _saveSettingsDebounced();
      }
    });

    _persistenceLoaded = true;
    // A handoff that arrived during the load is taken after the restored
    // session's own delayed seek below, so that seek can't land on it.
    final pendingHandoff = _pendingHandoff;
    if (pendingHandoff != null) {
      _pendingHandoff = null;
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) unawaited(_adoptHandoff(pendingHandoff));
      });
    }

    if (current != null && fullQueue.isNotEmpty) {
      try {
        await _loadAndPlay(current, playImmediately: false);
        
        if (accurateResumePosMs > 0) {
          Future.delayed(const Duration(milliseconds: 300), () async {
            await NativeAudioEngine.seek(Duration(milliseconds: accurateResumePosMs));
            final restored = Duration(milliseconds: accurateResumePosMs);
            currentState = currentState.copyWith(position: restored);
            // The progress bar reads this directly; without it the restored track shows
            // 0:00 until playback starts.
            currentPositionProvider.value = restored;
          });
        }
      } catch (e) {
        print('WARN: Hardware queue restore failed: $e');
      }
    }
  }

  // ==============================================================
  // HANDOFF  (pick up where another device left off)
  // ==============================================================
  /// What this device is playing, for the next push (see playback_handoff.dart).
  /// Null with nothing loaded, or for live radio, which has no place to resume.
  Future<Map<String, dynamic>?> _handoffSnapshot() async {
    if (!mounted) return null;
    final song = currentState.currentSong;
    if (song == null || !song.hasSeekablePosition) return null;
    // Stamped with when this device last actually played, not with the push:
    // a device merely open on yesterday's song must not look newer than one
    // paused ten minutes ago. Never played here: 0, which no device takes.
    final prefs = await SharedPreferences.getInstance();
    final atMs = currentState.isPlaying
        ? DateTime.now().millisecondsSinceEpoch
        : (prefs.getInt('auvy_last_playback_at') ?? 0);
    final next = [
      for (final s in [
        ...currentState.userQueue,
        ...currentState.contextQueue,
        ...currentState.autoplayQueue,
      ])
        if (s.id != song.id) s,
    ];
    return PlaybackHandoff(
      device: '', // filled in by the sync, which knows this device's id
      deviceName: '',
      atMs: atMs,
      playing: currentState.isPlaying,
      positionMs: currentPositionProvider.value.inMilliseconds,
      durationMs: currentState.duration.inMilliseconds,
      song: song.toMap(),
      next: [for (final s in next.take(PlaybackHandoff.maxNext)) s.toMap()],
      source: currentState.playbackSource,
      location: currentState.locationName ?? '',
      contextTitle: currentState.contextTitle ?? '',
      contextId: currentState.contextId,
      contextType: currentState.contextType,
    ).toJson();
  }

  void _receiveHandoff(Map<String, dynamic> raw) {
    // Before the saved queue has loaded, it would be overwritten by it.
    if (!_persistenceLoaded) {
      _pendingHandoff = raw;
      return;
    }
    unawaited(_adoptHandoff(raw));
  }

  /// Takes another device's playing state when this one is idle: loaded paused,
  /// like a restored session, so one tap carries on.
  Future<void> _adoptHandoff(Map<String, dynamic> raw) async {
    final h = PlaybackHandoff.fromJson(raw);
    if (h == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final me = await CloudSyncService.instance.deviceId();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var inRoom = false;
    try {
      inRoom = ref.read(listenTogetherProvider).active;
    } catch (_) {}
    if (!mounted ||
        !shouldAdoptHandoff(h,
            thisDevice: me,
            localPlaying: currentState.isPlaying,
            inListenTogether: inRoom,
            localLastPlaybackMs: prefs.getInt('auvy_last_playback_at'),
            nowMs: nowMs)) {
      return;
    }
    final songs = [
      for (final m in [h.song, ...h.next])
        if (Song.fromMap(m).id.isNotEmpty) Song.fromMap(m),
    ];
    if (songs.isEmpty) return;
    final target = handoffTarget(h, nowMs);
    final i = target.index.clamp(0, songs.length - 1);
    final current = songs[i];
    final rest = songs.sublist(i + 1);
    final position = Duration(milliseconds: target.positionMs);
    currentState = currentState.copyWith(
      currentSong: current,
      queue: [current, ...rest],
      originalQueue: [current, ...rest],
      currentIndex: 0,
      userQueue: const [],
      contextQueue: rest,
      autoplayQueue: const [],
      userQueueEndIndex: 0,
      position: position,
      isPlaying: false,
      miniPlayerVisible: true,
      playbackSource: h.source.isNotEmpty ? h.source : currentState.playbackSource,
      locationName: h.location.isNotEmpty ? h.location : null,
      contextTitle: h.contextTitle.isNotEmpty ? h.contextTitle : null,
      contextId: h.contextId,
      contextType: h.contextType,
    );
    currentPositionProvider.value = position;
    if (current.image.isNotEmpty) {
      ref.read(playerColorProvider.notifier).updateFromImage(current.image);
    }
    _updateMediaItem(current);
    await _saveSettings();
    final from = h.deviceName.isNotEmpty ? h.deviceName : 'your other device';
    print('handoff: picked up "${current.title}" at '
        '${position.inSeconds}s from $from '
        '(${h.playing ? "it was playing, caught up ${i > 0 ? "$i song(s) on" : "within the song"}" : "it was paused"})');
    // Loaded like a restored session: prepared and paused at the position.
    try {
      await _loadAndPlay(current, playImmediately: false);
      if (position > Duration.zero && mounted) {
        await NativeAudioEngine.seek(position);
      }
    } catch (e) {
      print('WARN: handoff: could not prepare "${current.title}" ($e)');
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
        'auvy_blacklist', currentState.blacklistedIds.toList());
    await prefs.setString('auvy_user_queue',
        jsonEncode(currentState.userQueue.map((s) => s.toMap()).toList()));
    await prefs.setString('auvy_context_queue',
        jsonEncode(currentState.contextQueue.map((s) => s.toMap()).toList()));
    await prefs.setString('auvy_autoplay_queue',
        jsonEncode(currentState.autoplayQueue.map((s) => s.toMap()).toList()));
    await prefs.setInt('auvy_user_queue_end', currentState.userQueueEndIndex);
    await prefs.setInt('auvy_max_cache_size', currentState.maxCacheSizeMB);

    // Recently played, with absolute play times. v2 stores `{s: song, t: epochMs}`
    // per entry and is the key that goes to the cloud (see
    // CloudSyncService._stringKeys). v1 (songs only) is still written so
    // downgrading to an older build keeps the list.
    final trimmedHistory = currentState.history.take(_kHistoryCap).toList();
    // Drop times for tracks that fell off the end, so the map stays bounded.
    final liveIds = trimmedHistory.map((s) => s.id).toSet();
    _historyPlayedAt.removeWhere((id, _) => !liveIds.contains(id));
    _historyPlayedDevice.removeWhere((id, _) => !liveIds.contains(id));
    await prefs.setString(
        'auvy_history_v2',
        jsonEncode(trimmedHistory
            .map((s) => {
                  's': s.toMap(),
                  // 0 means "played, time unknown" (restored from a v1 backup). Never `now`,
                  // which would invent a play that didn't happen.
                  't': _historyPlayedAt[s.id] ?? 0,
                  'd': _historyPlayedDevice[s.id] ?? '',
                })
            .toList()));
    await prefs.setString('auvy_history', jsonEncode(
        trimmedHistory.map((s) => s.toMap()).toList()));
    // Schedule a backup, so history reaches the cloud even for someone who only
    // listens and never edits anything. Low urgency: history regenerates itself,
    // and going to the background forces a push anyway. See [BackupUrgency].
    CloudSyncService.instance
        .scheduleBackup(urgency: BackupUrgency.listening);
    await prefs.setString('auvy_queue',
        jsonEncode(currentState.queue.map((s) => s.toMap()).toList()));
    await prefs.setString('auvy_original_queue',
        jsonEncode(currentState.originalQueue.map((s) => s.toMap()).toList()));

    if (currentState.currentSong != null) {
      await prefs.setString('auvy_current_song',
          jsonEncode(currentState.currentSong!.toMap()));
    }

    await prefs.setInt(
        'auvy_position', currentState.position.inMilliseconds);
    await prefs.setBool('auvy_shuffle', currentState.isShuffle);
    await prefs.setInt('auvy_loop', currentState.repeatMode.index);
    await prefs.setDouble('auvy_volume', currentState.volume);

    if (currentState.contextId != null) {
      await prefs.setString('auvy_ctx_id', currentState.contextId!);
    }
    if (currentState.contextType != null) {
      await prefs.setString('auvy_ctx_type', currentState.contextType!);
    }
    if (currentState.contextTitle != null) {
      await prefs.setString('auvy_ctx_title', currentState.contextTitle!);
    }

    await prefs.setBool('auvy_crossfade', currentState.crossfadeEnabled);
    await prefs.setInt('auvy_crossfade_duration',
        currentState.crossfadeDuration.inSeconds);
    await prefs.setBool(
        'auvy_normalization', currentState.audioNormalizationEnabled);
    await prefs.setInt(
        'auvy_audio_quality', currentState.audioQuality.index);
    await prefs.setBool('auvy_gapless', currentState.gaplessPlayback);
    await prefs.setBool(
        'auvy_autoplay_on_connect', currentState.autoPlayOnConnect);
    await prefs.setBool(
        'auvy_process_videos', currentState.processVideosEnabled);
    await prefs.setBool(
        'auvy_silence_skipping', currentState.silenceSkippingEnabled);
    await prefs.setDouble('auvy_pitch', currentState.pitch);
    await prefs.setDouble('auvy_podcast_speed', currentState.podcastSpeed);
    await prefs.setBool('auvy_eq_enabled', currentState.eqEnabled);
    await prefs.setStringList('auvy_eq_bands',
        currentState.eqBands.map((v) => v.toString()).toList());
    await prefs.setInt('auvy_seek_jump_seconds', currentState.seekJumpSeconds);
    await prefs.setBool('auvy_pause_on_zero_volume', currentState.pauseOnZeroVolume);
    
    try {
      if (currentState.currentSong != null) {
        await prefs.setString('player_resume_song', jsonEncode(currentState.currentSong!.toMap()));
        await prefs.setInt('player_resume_position_ms', currentState.position.inMilliseconds);
        await prefs.setString('player_resume_source', currentState.playbackSource);
        // The location name that pairs with the source above (see
        // _restoreResumeState).
        await prefs.setString('player_resume_location', currentState.locationName ?? '');
        await prefs.setString('player_resume_context_title', currentState.contextTitle ?? '');
      }
      // Keep the podcast bookmark fresh too, so an app kill mid-episode still
      // resumes correctly next time.
      final cs = currentState.currentSong;
      if (cs != null && cs.isSpokenWord) {
        unawaited(_savePodcastPosition(cs, currentState.position));
      }
    } catch (e) {
      print('WARN: Failed to persist resume state: $e');
    }
  }

  Set<String> get _activePlaybackProtectedIds => {
    if (currentState.currentSong != null) currentState.currentSong!.id,
    if (_upNextId() != null) _upNextId()!,
    if (_preloadedSongId != null) _preloadedSongId!,
  };

  void _syncCacheProtectedTracks() {
    _cacheManager.protectedPlaybackIds = _activePlaybackProtectedIds;
  }

  void setCacheLimit(int mb) {
    currentState = currentState.copyWith(maxCacheSizeMB: mb);
    AudioCacheManager().maxCacheSizeMB = mb;
    // Apply a lowered limit now rather than at the next cache write or sweep.
    AudioCacheManager().enforceCacheLimit(
        currentPlayingId: currentState.currentSong?.id,
        protectedIds: _activePlaybackProtectedIds);
    _saveSettingsDebounced();
  }

  void _saveSettingsDebounced() {
    _persistenceTimer?.cancel();
    _persistenceTimer =
        Timer(const Duration(seconds: 2), () => _saveSettings());
  }

  // ==============================================================
  // CACHE MAINTENANCE  (top tracks, alarm track, 5-minute cleanup)
  // ==============================================================
  /// Keeps the user's most-played tracks ("My Top 50") pinned so they are never
  /// auto-evicted, and on Wi-Fi caches them ahead of time. [download] enables the
  /// network-heavy caching (skipped at launch, on mobile data and with data saver
  /// set to always); pins are always refreshed.
  Future<void> _refreshTopTrackCaching({required bool download}) async {
    try {
      final intel = ref.read(intelligenceProvider);
      final top = computeTop50(
        intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
      _cacheManager.pinnedSongIds = top.map((s) => s.id).toSet();
      _syncCacheProtectedTracks();
      if (download && top.isNotEmpty) {
        final conn = ref.read(connectivityProvider);
        if (conn.isWifi && !conn.isOffline &&
            conn.dataSaverMode != DataSaverMode.always) {
          // Fire-and-forget; internally capped and spaced so it can't burst data use.
          _cacheManager.ensureTopTracksCached(top);
        }
      }
    } catch (e) {
      print('WARN: Top-track pin/cache refresh failed: $e');
    }
  }

  /// Puts one playable file on disk ahead of the wake-up alarm.
  ///
  /// The alarm plays natively (AlarmAudioService) at the set minute without
  /// Flutter running, so it can't resolve a stream, and it may ring offline. The
  /// audio is fetched while the app is alive so the alarm only opens a file.
  ///
  /// [pool] is the caller's taste-ordered candidate list; an explicit pick
  /// (source == 'song') overrides it. Cheap to call on every resume: returns
  /// immediately unless the file is missing, stale or for the wrong track.
  Future<void> prepareAlarmTrack(List<Song> pool) {
    // One at a time. Every resume calls this, and two downloads into the same
    // .part file broke each other ("File closed"), so on a phone switching apps
    // the track was never ready. A call made meanwhile (a new pick, say) runs
    // once afterwards with its pool; it costs nothing if that track is ready.
    final running = _alarmPrepInFlight;
    if (running != null) {
      _alarmPrepNext = pool;
      return running;
    }
    return _alarmPrepInFlight = _prepareAlarmTrack(pool).whenComplete(() {
      _alarmPrepInFlight = null;
      final next = _alarmPrepNext;
      _alarmPrepNext = null;
      if (next != null && mounted) prepareAlarmTrack(next);
    });
  }

  Future<void> _prepareAlarmTrack(List<Song> pool) async {
    if (!AlarmService.enabled) {
      await AlarmService.clearPreparedTrack();
      return;
    }
    try {
      // An explicit choice decides the track. For a collection that is its first
      // track, so waking to an album starts at track one.
      final Song? want = AlarmService.source == 'song'
          ? AlarmService.pickedSong
          : (AlarmService.source == 'collection' && pool.isNotEmpty
              ? pool.first
              : null);
      final candidates = want != null ? <Song>[want] : pool;
      // Log the decision; every branch below returns silently.
      final needs = await AlarmService.needsPreparation(wantId: want?.id);
      print('alarm prepare: source=${AlarmService.source} '
          'want="${want?.title ?? '(any)'}" have="${await AlarmService.preparedTitle()}" '
          'candidates=${candidates.length} needsPrep=$needs');
      if (candidates.isEmpty) return;
      if (!needs) return;

      final song = want ?? (List<Song>.of(candidates)..shuffle()).first;

      // Already downloaded or cached? Copy the file; no network needed.
      final local = _cacheManager.getCachedPath(song.id);
      if (local != null && File(local).existsSync()) {
        if (await AlarmService.storeFromFile(song, local)) return;
      }

      final stream = await _audioService
          .getStreamWithFallback(song.id, song.title, song.artist)
          .timeout(const Duration(seconds: 25));
      final url = stream?['url'];
      if (url == null || url.isEmpty) return;
      await AlarmService.storeFromUrl(song, url, stream?['user_agent']);
    } catch (e) {
      // Never let this break a resume. With no prepared track the alarm still rings
      // with the system tone.
      print('WARN: alarm track prepare failed: $e');
    }
  }

  void _startCacheCleanup() {
    // Pin top tracks early (without downloading at launch) so eviction respects
    // them from the first cleanup.
    _refreshTopTrackCaching(download: false);
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      // Refresh pins and top up the top-track cache before pruning.
      await _refreshTopTrackCaching(download: true);
      try {
        // Re-measure file sizes, then trim the auto-cache by measured bytes (least
        // recently used first) until it fits the limit. Downloads are not counted
        // against the cache limit.
        await _cacheManager.reconcileCacheSizes();
        await _cacheManager.enforceCacheLimit(
            currentPlayingId: currentState.currentSong?.id,
            protectedIds: _activePlaybackProtectedIds);
      } catch (e) {
        print('WARN: Cache cleanup error: $e');
      }

      final historySize = currentState.history.length;
      if (historySize > 100) {
        final trimmed = currentState.history.take(50).toList();
        currentState = currentState.copyWith(history: trimmed);
        _saveSettings();
        print('History trimmed: $historySize → ${trimmed.length}');
      }
    });
  }

  // ==============================================================
  // ERROR HANDLING
  // ==============================================================
  void _handlePlaybackError(Object error, {bool? intendedPlaying}) {
    final message = _errorHandler.handleError(error, currentState.currentSong?.id ?? '');
    print('ERROR: $message');

    // Should the retried track play or stay paused? Callers that know pass
    // [intendedPlaying]. Reading isPlaying instead gave `false` right after a track
    // ended, so the next track loaded paused. The launch restore stays paused
    // because it passes false explicitly.
    final bool wasPlaying = intendedPlaying ?? currentState.isPlaying;
    // Tie recovery to the song that failed, so a pending retry never restarts a
    // different track the user has switched to.
    final String? failedId = currentState.currentSong?.id;

    _consecutiveErrors++;

    final err             = error.toString().toLowerCase();
    final isNetworkError  = err.contains('socketexception')
        || err.contains('failed host lookup')
        || err.contains('timeoutexception')
        || err.contains('connection closed')
        || err.contains('no address associated')
        || err.contains('clientexception');
    final isFormatError   = err.contains('formatexception')
        || err.contains('invalid')
        || err.contains('unsupported');
    // "No playable stream" usually means a network blackout (Doze or Wi-Fi power
    // saving blocks DNS in the background), not a dead track; the same track
    // resolves fine once the network wakes. So never block the track for 5
    // minutes, and treat repeats across tracks as "wait for the network", not
    // "skip the queue".
    final isResolveFailure = err.contains('no playable stream');

    // Retries check failedId, so a late fire after the user moved on does nothing.
    // Also set as _pendingNetworkRetry so a restored network fires it immediately.
    void scheduleRetry(Duration delay) {
      void retry() {
        if (mounted && currentState.currentSong != null && currentState.currentSong?.id == failedId && !_isProcessingTransition) {
          print('Retrying "${currentState.currentSong?.title}" (attempt $_consecutiveErrors)');
          // Resume only if playback was running when the error hit (keeps a paused
          // launch paused, resumes after a mid-song drop).
          _loadAndPlay(currentState.currentSong!, playImmediately: wasPlaying);
        }
      }
      _pendingNetworkRetry = retry;
      _recoveryTimer?.cancel();
      _recoveryTimer = Timer(delay, retry);
    }

    if (isNetworkError ||
        (isResolveFailure && !ref.read(connectivityProvider).hasInternet)) {
      NativeAudioEngine.pause();
      currentState = currentState.copyWith(isLoading: true);
      scheduleRetry(Duration(seconds: min(5 * pow(2, _consecutiveErrors - 1).toInt(), 30)));
      return;
    }

    if (isFormatError) {
      // A format error is a real per-track failure: block the track and advance.
      print('Unrecoverable format error – skipping track');
      final failing = currentState.currentSong;
      if (failing != null) _handlePersistentFailure(failing);
      _consecutiveErrors = 0;
      playNext(autoAdvance: true);
      return;
    }

    if (_consecutiveErrors >= 3) {
      if (isResolveFailure) {
        _autoAdvanceFailStreak++;
        if (_autoAdvanceFailStreak >= 3) {
          // Third track in a row that won't resolve: an outage the OS hasn't reported
          // yet. Hold this track (paused, spinner) and retry slowly and on reconnect,
          // instead of skipping through the queue.
          print('STOP: $_autoAdvanceFailStreak consecutive tracks failed to resolve — treating as network outage, holding "${currentState.currentSong?.title}"');
          NativeAudioEngine.pause();
          currentState = currentState.copyWith(isLoading: true);
          _consecutiveErrors = 0;
          scheduleRetry(const Duration(seconds: 30));
          return;
        }
        // Resolve failures don't prove the track is bad: advance without the 5-minute
        // block, so it plays normally next time.
        print('Resolve failed ${_consecutiveErrors}× for "${currentState.currentSong?.title}" — skipping (no block)');
        _consecutiveErrors = 0;
        playNext(autoAdvance: true);
        return;
      }
      print('Unrecoverable error – skipping track');
      final failing = currentState.currentSong;
      if (failing != null) _handlePersistentFailure(failing);
      _consecutiveErrors = 0;
      playNext(autoAdvance: true);
      return;
    }

    scheduleRetry(_errorHandler.getRetryDelay(_consecutiveErrors));
  }

  Future<void> _handlePersistentFailure(Song song) async {
    print('ALERT: Persistent failure: ${song.title} — blocking for 5 min (in-memory)');

    // In-memory and self-expiring, not the saved dislike list, so a single flaky
    // failure can never hide a track permanently.
    _failureBlocks[song.id] = DateTime.now().add(const Duration(minutes: 5));
    // The caller (_handlePlaybackError / handleStreamLeaseExpiration) calls
    // playNext(), to avoid advancing twice.
  }

  // ==============================================================
  // SYSTEM MEDIA SESSION  (notification / lock screen metadata)
  // ==============================================================
  /// The duration to publish to the system media session: the player's value if
  /// it has one, otherwise the catalogue's.
  ///
  /// playSong resets PlayerState.duration to zero and native reports the real one
  /// about two seconds later. A MediaItem without a duration makes Android drop
  /// the seek bar and timestamps from the media notification, and it doesn't
  /// bring them back when the duration arrives. Song.duration (the catalogue's
  /// `m:ss` label) is known for every queued track, so a skip from the
  /// notification can publish a real duration immediately.
  ///
  /// Returns null, not Duration.zero, for anything unparseable (e.g. live radio);
  /// setCurrentMediaItem substitutes its own value for that case.
  Duration? _mediaItemDuration(Song song, Duration fromEngine) {
    if (song.mediaKind == MediaKind.liveStream) return null;
    if (fromEngine > Duration.zero) return fromEngine;
    final parts = song.duration.split(':');
    // "m:ss" or "h:mm:ss". Anything else is a label, not a time.
    if (parts.length < 2 || parts.length > 3) return null;
    var seconds = 0;
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || v < 0) return null;
      seconds = seconds * 60 + v;
    }
    return seconds > 0 ? Duration(seconds: seconds) : null;
  }

  void _updateMediaItem(Song song) {
    if (_audioHandler == null || currentState.currentSong == null) return;
  
    // Prefer a local cover file for the notification and lock screen: a file://
    // URI loads instantly and reliably, while a slow network image sometimes never
    // appears (Samsung's Now Bar caches the artless first publish).
    // getDisplayImage only has a local file for downloaded tracks;
    // MediaArtworkCache fills the gap by reusing the file cached_network_image
    // already wrote when the app showed this cover.
    var artPath = _cacheManager.getDisplayImage(song.id, _mediaArtUrl(song));
    if (artPath.startsWith('http')) {
      final local = MediaArtworkCache.localPath(artPath);
      if (local != null) {
        artPath = local;
      } else {
        // The cover has never been drawn (e.g. an autoplay pick). Publish now with the
        // network URI so the notification isn't held up, then switch to a file URI once
        // the bytes arrive, if the song is still current. That upgrade touches only the
        // current item (_upgradeCurrentArtwork); calling _updateMediaItem again would
        // rebuild the whole system queue for one changed cover.
        final cold = artPath;
        MediaArtworkCache.warm(cold).then((path) {
          if (path == null || !mounted) return;
          if (currentState.currentSong?.id != song.id) return;
          _upgradeCurrentArtwork(song, path);
        });
      }
    }
    final isRadio = song.mediaKind == MediaKind.liveStream;
    String displayTitle = song.title;
    String displayArtist = song.artist;
    if (isRadio) {
      final cachedIcy = IcyMetadataService.getCached(song.id);
      if (cachedIcy != null && cachedIcy.streamTitle != null && cachedIcy.streamTitle!.trim().isNotEmpty) {
        final st = cachedIcy.streamTitle!.trim();
        if (st.contains(' - ')) {
          final parts = st.split(' - ');
          final artist = parts.first.trim();
          final title = parts.sublist(1).join(' - ').trim();
          if (title.isNotEmpty) displayTitle = title;
          if (artist.isNotEmpty) displayArtist = '$artist • ${song.title}';
        } else {
          displayTitle = st;
          displayArtist = song.title;
        }
      }
    }

    final mediaItem = MediaItem(
      id:       song.id,
      album:    isRadio ? song.title : (song.albumTitle.isNotEmpty ? song.albumTitle : 'Single'),
      title:    displayTitle,
      artist:   displayArtist,
      duration: _mediaItemDuration(song, currentState.duration),
      artUri: artPath.isNotEmpty
          ? (artPath.startsWith('http') ? Uri.tryParse(artPath) : Uri.file(artPath))
          : null,
    );

    final handler = _audioHandler as AuvyAudioHandler;
    handler.setCurrentMediaItem(mediaItem);

    final systemQueue = currentState.queue.map((s) => MediaItem(
        id:     s.id,
        album:  s.albumTitle,
        title:  s.title,
        artist: s.artist,
        artUri: s.image.isNotEmpty 
            ? (s.image.startsWith('http') ? Uri.tryParse(s.image) : Uri.file(s.image))
            : null,
      )).toList();

    handler.updateQueue(systemQueue);
    if (currentState.currentIndex >= 0) {
      handler.setQueueIndex(currentState.currentIndex);
    }

    // Prefetch the next few covers to disk, so their first publish already has
    // the image. Fire-and-forget and bounded inside warmAll; cache hits cost no
    // network, and the notification never waits for it.
    final idx = currentState.currentIndex;
    if (idx >= 0 && idx + 1 < currentState.queue.length) {
      MediaArtworkCache.warmAll(currentState.queue
          .skip(idx + 1)
          .map(_mediaArtUrl)
          .where((u) => u.startsWith('http')));
    }
  }

  /// The cover URL for the notification and lock screen. On Android it is the
  /// player page's own URL: the system shows media art at 320 dp at most, and the
  /// player and the next-track preload have usually fetched exactly that file
  /// already, so the notification costs nothing extra rather than a second, 1200 px
  /// download per track. iOS can show lock-screen art full width, so it keeps the
  /// full-size cover.
  String _mediaArtUrl(Song song) {
    if (!Platform.isAndroid) return song.image;
    final url = AuvyImage.playerArtUrl(song.image,
        allowHighRes: ref.read(connectivityProvider).shouldLoadHighResImages);
    return url.isNotEmpty ? url : song.image;
  }

  /// Re-publishes only the current media item with its cover now on disk: same
  /// fields with a `file://` artUri, and no queue update, since only one track's
  /// artwork changed.
  void _upgradeCurrentArtwork(Song song, String localPath) {
    if (_audioHandler == null) return;
    // The track may have changed while the download ran.
    if (currentState.currentSong?.id != song.id) return;
    (_audioHandler as AuvyAudioHandler).setCurrentMediaItem(MediaItem(
      id: song.id,
      album: song.albumTitle.isNotEmpty ? song.albumTitle : 'Single',
      title: song.title,
      artist: song.artist,
      // Same fallback as _updateMediaItem: this can land before the player's first
      // tick, and a null duration would remove a seek bar already showing.
      duration: _mediaItemDuration(song, currentState.duration),
      artUri: Uri.file(localPath),
    ));
  }

  /// Updates the notification and lock screen title/artist when a live station's
  /// on-air song changes.
  void _updateLiveRadioNotification(Song song, String? streamTitle) {
    if (_audioHandler == null || streamTitle == null || streamTitle.trim().isEmpty) return;
    if (currentState.currentSong?.id != song.id) return;
    final clean = streamTitle.trim();
    String displayTitle = song.title;
    String displayArtist = song.artist;
    if (clean.contains(' - ')) {
      final parts = clean.split(' - ');
      final artist = parts.first.trim();
      final title = parts.sublist(1).join(' - ').trim();
      if (title.isNotEmpty) displayTitle = title;
      if (artist.isNotEmpty) displayArtist = '$artist • ${song.title}';
    } else {
      displayTitle = clean;
      displayArtist = song.title;
    }

    final currentItem = (_audioHandler as AuvyAudioHandler).mediaItem.value;
    if (currentItem != null && currentItem.title == displayTitle && currentItem.artist == displayArtist) {
      return; // Already up to date
    }

    final artPath = _cacheManager.getDisplayImage(song.id, _mediaArtUrl(song));
    final localArt = artPath.startsWith('http') ? MediaArtworkCache.localPath(artPath) : artPath;
    final resolvedArt = (localArt != null && localArt.isNotEmpty) ? localArt : artPath;

    final updated = MediaItem(
      id: song.id,
      album: song.title,
      title: displayTitle,
      artist: displayArtist,
      duration: null,
      artUri: resolvedArt.isNotEmpty
          ? (resolvedArt.startsWith('http') ? Uri.tryParse(resolvedArt) : Uri.file(resolvedArt))
          : null,
    );

    (_audioHandler as AuvyAudioHandler).setCurrentMediaItem(updated);
  }

  // ==============================================================
  // LIBRARY / INTELLIGENCE  (likes and dislikes)
  // ==============================================================
  void toggleLike() {
    if (currentState.currentSong == null) return;
    final library  = ref.read(libraryProvider.notifier);
    final wasLiked = library.isSongLiked(currentState.currentSong!.id);

    library.toggleSongLike(currentState.currentSong!);
    ref.read(intelligenceProvider.notifier).trackLike(
      currentState.currentSong!,
      isLiked: !wasLiked,
    );

    // Auto-download on like (opt-in). Wi-Fi only and never for radio or podcast
    // streams, like auto-cache.
    if (!wasLiked && ListeningPolicy.autoDownloadOnLike) {
      final song = currentState.currentSong!;
      final conn = ref.read(connectivityProvider);
      if (!song.id.startsWith('http') &&
          song.albumTitle != 'Podcast' &&
          conn.isWifi &&
          !conn.isOffline &&
          !_cacheManager.isExplicitlyDownloaded(song.id)) {
        unawaited(Future(() async {
          try {
            await _cacheManager.cacheTrack(song, '', isExplicitDownload: true);
            print('Auto-downloaded on like: ${song.title}');
          } catch (e) {
            print('WARN: Auto-download on like failed: $e');
          }
        }));
      }
    }

    if (_audioHandler != null) {
      (_audioHandler as AuvyAudioHandler).broadcastState();
    }
  }

  void dontRecommend(Song song) async {
    final isCurrent  = currentState.currentSong?.id == song.id;
    final newBl      = Set<String>.from(currentState.blacklistedIds)..add(song.id);

    ref.read(intelligenceProvider.notifier).markAsNotInterested(song);
    
    if (isCurrent) await NativeAudioEngine.pause();

    final filter = (List<Song> l) => l.where((s) => s.id != song.id).toList();

    final newUser = filter(currentState.userQueue);
    final newCtx  = filter(currentState.contextQueue);
    final newAuto = filter(currentState.autoplayQueue);

    currentState = currentState.copyWith(
      blacklistedIds: newBl,
      userQueue:      newUser,
      contextQueue:   newCtx,
      autoplayQueue:  newAuto,
      queue:          [
        // Keep the current track at index 0 in both cases: when disliking the current
        // track, playNext() below advances to queue[1], so leaving it out would skip
        // the first upcoming song as well. The disliked track is still removed from
        // every lane and blocked.
        if (currentState.currentSong != null) currentState.currentSong!,
        ...newUser, ...newCtx, ...newAuto,
      ],
    );

    if (isCurrent) playNext();
    _saveSettings();
  }

  // ==============================================================
  // SETTINGS
  // ==============================================================
  /// "Recently played" from disk, newest first, with [_historyPlayedAt] filled.
  ///
  /// Reads v2 (with play times) first and falls back to the v1 song list, for
  /// installs from before v2 and for restores of backups written by older builds.
  ///
  /// Shared by the cold-start load and [reloadSettings], so a restore brings
  /// history back immediately.
  List<Song> _readHistory(SharedPreferences prefs) {
    _historyPlayedAt = {};
    _historyPlayedDevice = {};
    final v2 = prefs.getString('auvy_history_v2');
    if (v2 != null) {
      final out = <Song>[];
      try {
        for (final r in jsonDecode(v2) as List) {
          if (r is! Map) continue;
          final songMap = r['s'];
          if (songMap == null) continue;
          final song = Song.fromMap(songMap);
          if (song.id.isEmpty) continue;
          out.add(song);
          final t = (r['t'] as num?)?.toInt() ?? 0;
          // 0 means "played, time unknown"; kept out of the map rather than dated 1970.
          if (t > 0) _historyPlayedAt[song.id] = t;
          final d = (r['d'] as String?)?.trim() ?? '';
          if (d.isNotEmpty) _historyPlayedDevice[song.id] = d;
        }
        return out.take(_kHistoryCap).toList();
      } catch (_) {
        // Corrupt v2: fall back to v1 rather than lose the list.
      }
    }
    final v1 = prefs.getString('auvy_history');
    if (v1 == null) return const [];
    try {
      return (jsonDecode(v1) as List)
          .map((s) => Song.fromMap(s))
          .take(_kHistoryCap)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Re-reads saved settings (and history) into state after a cloud restore.
  /// Settings are normally read once at startup, before the login-gate restore
  /// runs, so without this a restored setting would only apply after a restart.
  /// Never touches the queue, current song or session state.
  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    // History too: this runs after a cloud restore, which writes the backed-up
    // prefs to disk first.
    final restoredHistory = _readHistory(prefs);
    final crossfade     = prefs.getBool('auvy_crossfade') ?? false;
    final crossfadeSec  = prefs.getInt('auvy_crossfade_duration') ?? 5;
    final normalization = prefs.getBool('auvy_normalization') ?? true;
    final qualityIdx    = (prefs.getInt('auvy_audio_quality') ?? AudioQuality.auto.index)
        .clamp(0, AudioQuality.values.length - 1);
    final gapless       = prefs.getBool('auvy_gapless') ?? true;
    final autoPlayConn  = prefs.getBool('auvy_autoplay_on_connect') ?? false;
    // Audio-only is permanent; any stored value is ignored (see the cold-start
    // load).
    const processVideos = false;
    final silenceSkip   = prefs.getBool('auvy_silence_skipping') ?? false;
    final pitch         = prefs.getDouble('auvy_pitch') ?? 1.0;
    final podcastSpd    = prefs.getDouble('auvy_podcast_speed') ?? 1.0;
    final eqEnabled     = prefs.getBool('auvy_eq_enabled') ?? false;
    final eqBandsRaw    = prefs.getStringList('auvy_eq_bands');
    final eqBands       = eqBandsRaw != null
        ? eqBandsRaw.map((s) => double.tryParse(s) ?? 0.0).toList()
        : List<double>.filled(5, 0.0);
    final cacheLimit    = prefs.getInt('auvy_max_cache_size') ?? currentState.maxCacheSizeMB;

    currentState = currentState.copyWith(
      crossfadeEnabled: crossfade,
      crossfadeDuration: Duration(seconds: crossfadeSec),
      audioNormalizationEnabled: normalization,
      audioQuality: AudioQuality.values[qualityIdx],
      gaplessPlayback: gapless,
      autoPlayOnConnect: autoPlayConn,
      processVideosEnabled: processVideos,
      // Only replace the live history when disk has one: this also runs for plain
      // settings changes, and an empty list would erase what was just played.
      history: restoredHistory.isNotEmpty ? restoredHistory : currentState.history,
      historyPlayedAt: Map<String, int>.from(_historyPlayedAt),
      historyPlayedDevice: Map<String, String>.from(_historyPlayedDevice),
      silenceSkippingEnabled: silenceSkip,
      pitch: pitch,
      podcastSpeed: podcastSpd,
      eqEnabled: eqEnabled,
      eqBands: eqBands,
      maxCacheSizeMB: cacheLimit,
    );
    SearchService.processVideos = processVideos;
    // Mirrors the cold-start load, so toggling Shorts applies without a restart.
    SearchService.hideShorts = prefs.getBool('auvy_hide_shorts') ?? true;
    NativeAudioEngine.setEqualizer(eqEnabled, eqBands);
    NativeAudioEngine.setPitch(pitch);
  }

  void toggleCrossfade() {
    currentState = currentState.copyWith(crossfadeEnabled: !currentState.crossfadeEnabled);
    _saveSettings();
  }

  void setCrossfadeDuration(Duration duration) {
    currentState = currentState.copyWith(crossfadeDuration: duration);
    _saveSettings();
  }


  /// Whether connecting headphones or a Bluetooth device resumes playback. Off by
  /// default (see [PlayerState.autoPlayOnConnect]).
  void setAutoPlayOnConnect(bool enabled) {
    currentState = currentState.copyWith(autoPlayOnConnect: enabled);
    _saveSettings();
  }


  // Sleep timer. The timer field lives on PlayerNotifier because extensions can't
  // hold state; part files share the library, so `_sleepTimer` is visible here.

  /// Starts (or, with null, cancels) the sleep timer: playback pauses after
  /// [duration]. Not saved, so a killed app never comes back with a stale timer.
  /// Starting a timer cancels "sleep at end of track"; the two are exclusive.
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _restoreVolumeAfterSleepFade(); // cancelling mid-fade must not leave it quiet
    if (duration == null) {
      print('Sleep timer cancelled');
      currentState = currentState.copyWith(clearSleepTimer: true);
      return;
    }
    final endsAt = DateTime.now().add(duration);
    print('Sleep timer armed for ${duration.inMinutes}m (ends at $endsAt)');
    currentState = currentState.copyWith(
      clearSleepTimer: true, // wipes endsAt/minutes/endOfTrack in one shot…
    );
    currentState = currentState.copyWith(
      sleepTimerEndsAt: endsAt, // …then arm fresh
      sleepTimerMinutes: duration.inMinutes,
    );
    _sleepTimer = Timer(duration, () {
      if (!mounted) return;
      print('Sleep timer expired — pausing playback');
      if (currentState.isPlaying) togglePlay(haptic: false);
      currentState = currentState.copyWith(clearSleepTimer: true);
      _restoreVolumeAfterSleepFade();
    });
    // Fade out into the pause over the last _sleepFadeSeconds instead of stopping
    // abruptly. The volume is restored afterwards so the next play isn't silent.
    if (duration > const Duration(seconds: _sleepFadeSeconds + 2)) {
      _sleepFadeTimer?.cancel();
      _sleepFadeTimer = Timer(
        duration - const Duration(seconds: _sleepFadeSeconds),
        _startSleepFadeOut,
      );
    }
  }

  // Resolve back-off state. Two kinds of repeated failure are answered locally
  // instead of with more network requests:
  //
  //  • Pin refusals: a mid-track re-resolve that returns a different content
  //    length is refused (a different file can't continue at the old offset),
  //    but native re-asks every few seconds. After [_maxPinRefusals] the pin
  //    itself is treated as stale and the track restarts, and a cooldown answers
  //    further requests for free while that happens.
  //  • Whole-chain refusals: see below.

  // Consecutive resolves where every InnerTube client refused. After a burst of
  // skipping YouTube sometimes refuses everything for a while, even though the
  // network and cookies are fine. Retrying every few seconds only spends data, so
  // after [_maxNoStreamStreak] refusals resolves pause for a growing cooldown.
  //
  // Global rather than per track: the refusal applies to the account or IP, not
  // to one video.
  static int _noStreamStreak = 0;

  /// Consecutive resolves abandoned because the id wasn't wanted, per id.
  /// Diagnostic only; it makes a retry loop visible in the log (see the abandon
  /// site).
  static String? _abandonedResolveId;
  static int _abandonedResolveCount = 0;
  static int _resolveCooldownUntilMs = 0;

  /// Consecutive whole-chain refusals before backing off. Three, because a single
  /// track can genuinely be unavailable (region-locked, removed, age-gated) and
  /// should just be skipped.
  static const int _maxNoStreamStreak = 3;

  /// Doubling from 30 s to 5 minutes: a short first wait keeps a brief throttle
  /// from feeling like an outage, and the cap bounds a long one.
  static const int _resolveCooldownBaseMs = 30000;
  static const int _resolveCooldownMaxMs = 300000;

  static String? _pinFailId;
  static int _pinFailClen = 0;
  static int _pinFailCount = 0;

  /// How many times this pin has been given up on; drives the escalating
  /// cooldown. Reset only when the pin changes or a resolve succeeds, never by a
  /// lapsed cooldown, so the backoff keeps growing across rounds.
  static int _pinGiveUps = 0;
  static int _pinCooldownUntilMs = 0;

  /// Refusals before the pin itself is treated as stale. Three, because a one-off
  /// mismatch should still be retried: a restart costs the listener a re-buffer.
  static const int _maxPinRefusals = 3;

  /// How long to answer "no" for free after giving up on a pin: long enough for
  /// the restart to re-pin, short enough not to block a real recovery. Doubles per
  /// give-up up to [_pinCooldownMaxMs].
  static const int _pinCooldownMs = 30000;
  static const int _pinCooldownMaxMs = 300000;


  // Detects "the app says it's playing but no sound is coming out".
  //
  // Other detectors watch specific mechanisms (buffering events, errors, heal
  // counters) and can all miss a failure where the data source keeps failing
  // quietly. This watches the outcome: state says playing, time passes, and the
  // playhead doesn't move. That catches every cause, including new ones.
  void _checkForSilentPlayback() {
    final song = currentState.currentSong;
    // isLoading counts too: a load that never finishes is exactly this failure.
    final shouldBeMoving =
        song != null && (currentState.isPlaying || currentState.isLoading);
    if (!shouldBeMoving) {
      _silentTicks = 0;
      _silentSongId = null;
      return;
    }
    final posMs = currentPositionProvider.value.inMilliseconds;
    if (_silentSongId != song.id) {
      _silentSongId = song.id;
      _silentPosMs = posMs;
      _silentTicks = 0;
      return;
    }
    // Live radio has no playhead to judge.
    if (song.mediaKind == MediaKind.liveStream) {
      _silentTicks = 0;
      return;
    }
    // Less than a second of movement over a 5 s tick is not progress; the margin
    // absorbs rounding at a track boundary.
    if ((posMs - _silentPosMs).abs() > 1000) {
      _silentPosMs = posMs;
      _silentTicks = 0;
      return;
    }
    _silentTicks++;
    if (_silentTicks < _silentTicksToReport) return;

    final seconds = _silentTicks * 5;
    print('SILENT PLAYBACK — "${song.title}" has been '
        '${currentState.isLoading ? "loading" : "playing"} for ${seconds}s with '
        'the playhead stuck at ${(posMs / 1000).toStringAsFixed(1)}s '
        '(stalled=${currentState.isStalled}, '
        'cached=${AudioCacheManager().isCached(song.id)}, '
        'online=${ref.read(connectivityProvider).hasInternet})');

    // Report every level but act only once, so recovery can't turn into a loop of
    // its own.
    if (_silentTicks != _silentTicksToReport) return;
    if (!ref.read(connectivityProvider).hasInternet) {
      print('…offline, so the existing hold-for-reconnect owns this one');
      return;
    }
    print('…forcing a clean reload, since nothing else has claimed it');
    handleStreamLeaseExpiration(
      intendedPlaying: true,
      resumeFrom: currentPositionProvider.value,
    );
  }

  /// Ticks without playhead movement before reporting: six, i.e. 30 seconds.
  /// Long enough to ignore slow loads and poor-signal buffering.
  static const int _silentTicksToReport = 6;

  static String? _silentSongId;
  static int _silentPosMs = 0;
  static int _silentTicks = 0;

  /// Seconds of gentle volume ramp before a sleep timer pauses playback.
  static const int _sleepFadeSeconds = 20;

  /// Ramps the volume down over the final [_sleepFadeSeconds].
  ///
  /// Each tick recomputes the target from `sleepTimerEndsAt`, so the fade stops
  /// when the timer is cancelled or re-armed, finishes on time regardless of main
  /// thread load, and re-asserts the volume if a track change's start-fade tries
  /// to reset it. Uses an equal-power curve so the fade sounds even.
  void _startSleepFadeOut() {
    _sleepFadeRamp?.cancel();
    if (!mounted) return;
    final endsAt = currentState.sleepTimerEndsAt;
    if (endsAt == null) return;
    // The level to fade from. currentState.volume is the user's setting and the
    // fade never writes it, so it stays a stable baseline.
    final baseline = currentState.volume;
    const totalMs = _sleepFadeSeconds * 1000;

    _sleepFadeRamp = Timer.periodic(const Duration(milliseconds: 250), (t) {
      // The timer was cancelled or re-armed, or the notifier is gone: stop and
      // restore the volume so the next play isn't silent.
      if (!mounted || currentState.sleepTimerEndsAt != endsAt) {
        t.cancel();
        _sleepFadeRamp = null;
        if (mounted) NativeAudioEngine.setVolume(currentState.volume);
        return;
      }
      final remainMs = endsAt.difference(DateTime.now()).inMilliseconds;
      final progress = (1 - remainMs / totalMs).clamp(0.0, 1.0);
      // Equal-power fade-out, matching _rampVolume in player_playback.
      NativeAudioEngine.setVolume(baseline * cos(progress * pi / 2));
      if (progress >= 1.0) {
        t.cancel();
        _sleepFadeRamp = null;
      }
    });
  }

  void _restoreVolumeAfterSleepFade() {
    _sleepFadeTimer?.cancel();
    _sleepFadeTimer = null;
    _sleepFadeRamp?.cancel();
    _sleepFadeRamp = null;
    if (mounted) NativeAudioEngine.setVolume(currentState.volume);
  }

  /// "Sleep at end of track": playback pauses when the current track finishes
  /// instead of advancing (see playNext). Cancels any running duration timer.
  void setSleepAtEndOfTrack(bool enabled) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _restoreVolumeAfterSleepFade();
    currentState = currentState.copyWith(clearSleepTimer: true);
    if (enabled) {
      currentState = currentState.copyWith(sleepAtEndOfTrack: true);
      // Drop the prepared gapless item now, not at the boundary. It was usually
      // prepared seconds into the track, and the native player would roll into it
      // before Dart hears the track ended. Synchronous, like resyncUpcomingIfChanged.
      try {
        NativeAudioEngine.clearUpcoming();
      } catch (_) {}
      _preloadedSongId = null;
    }
  }

  /// Clears all in-memory playback data for a "Delete account" reset: stops the
  /// player and clears queues, current song, history and blocklist so the saved
  /// state is empty (matching the cleared prefs) and nothing shows as playing.
  Future<void> clearAllForAccountReset() async {
    try {
      await NativeAudioEngine.stop();
    } catch (_) {}
    _nativeLoadedSongId = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _playDebounceTimer?.cancel();
    _recoveryTimer?.cancel();
    _preloadTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _sleepFadeRamp?.cancel();
    _historyPlayedAt.clear();
    _historyPlayedDevice.clear();
    MediaArtworkCache.clear();
    currentPositionProvider.value = Duration.zero;
    currentState = PlayerState();
    await _saveSettings();
  }

  // ==============================================================
  // DOWNLOAD SONG
  // ==============================================================
  Future<void> downloadSong(Song song) async {
    print('Downloading: ${song.title}');
    try {
      await DownloadHelper.downloadCollection([song]);
      print('OK: Download queued/completed successfully');
    } catch (e) {
      print('ERROR: Download failed: $e');
    }
  }
}