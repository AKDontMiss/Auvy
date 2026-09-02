part of '../providers/player_provider.dart';

// Pending "this stall has lasted long enough to admit to" timer. Library-level
// because this file is an extension; see _fadeGeneration in player_playback.dart
// for the same constraint.
Timer? _stallTimer;

/// Set while a manual skip's own native transition is in flight, so the gapless
/// handler knows the transition it is about to see is one we asked for.
///
/// Library-level for the same reason as [_stallTimer]: it is written by
/// playNext in player_queue.dart and read here, and two extensions on the same
/// class cannot share a static between them.
///
/// CLEARED BY A TIMER AS WELL AS BY USE. If the transition never arrives —
/// the seek was refused, the item went away — a flag left standing would swallow
/// the next GENUINE auto-advance, turning one lost event into a queue that
/// silently stops following the music.
bool _skipConsumesNextAdvance = false;

/// When each track in "Recently played" was last started — songId → epoch ms.
///
/// ABSOLUTE MILLISECONDS, DELIBERATELY. History is now part of the cloud
/// backup, so it gets restored on a different device at a different time. A
/// relative value ("3 hours ago") would be re-anchored to whatever "now" happened
/// to be at restore and would read as nonsense; an epoch stamp means the same
/// instant everywhere.
///
/// Companion to `PlayerState.history` rather than folded into it: the history list
/// is `List<Song>` and read on hot playback paths, and changing its type to carry
/// a timestamp would ripple through the queue sheet, the player and the persisted
/// format for no gain. A map keyed by id is exact, because history is deduped by
/// id — a track appears at most once.
///
/// Library-level for the same reason as [_stallTimer]: this file is an extension.
Map<String, int> _historyPlayedAt = {};

/// How many played tracks are kept — locally AND in the backup.
///
/// CAPPED ON PURPOSE. This is the "Recently played" strip, not an archive: the
/// analytical listening history lives in the intelligence layer (`intel_history`,
/// `intel_play_counts`, `intel_timestamps`), which is separately backed up. Fifty
/// entries with timestamps is roughly 25–30KB of JSON — cheap enough to sync on
/// every library save, and it never grows.
const int _kHistoryCap = 50;

// How long playback must sit in BUFFERING before the UI says anything. Long
// enough that a normal track start never trips it, short enough that a real stall
// is acknowledged before the user concludes the app is broken.
const Duration _kStallGrace = Duration(seconds: 3);


// Rotates which InnerTube client the stream resolver tries FIRST, so a persistent
// mid-track 403 (a format/PO-token-gated googlevideo stream that re-fetching the
// SAME format can't cure) escalates to a DIFFERENT format instead of 403-storming
// on the gated one forever.
//
// The index is STICKY per track: a brand-new videoId starts at 0 (the preferred
// client). Each RAPID repeat resolve (within 20 s — i.e. a live 403 storm) bumps
// the index to the next client. A non-rapid resolve (a resume, an expired URL
// re-fetch minutes later, or a replay) KEEPS the track's last index, so a stream
// that needed a different client doesn't fall back to the gated one and re-stall —
// making replays and later sections of that track effectively uninterrupted.
// (True "predict the 403 before it happens" is impossible — you only learn a
// chunk is gated by requesting it, but sticky rotation + the cached working URL
// mean it's paid at most once per track, then seamless.)
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
  // Bound the maps so a long listening session can't grow them without limit.
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

  /// Every song playback should skip — the UNION of:
  ///  • the player-layer USER dislike set (`auvy_blacklist`),
  ///  • the intelligence-layer dislike set (`intel_blacklist`, cloud-synced),
  ///  • the IN-MEMORY transient failure blocks (tracks that failed to load;
  ///    auto-expire after a few minutes and are NEVER persisted — they are not
  ///    dislikes and must not survive a restart or reach the cloud).
  Set<String> get effectiveBlacklist {
    final now = DateTime.now();
    _failureBlocks.removeWhere((_, until) => now.isAfter(until));
    return {
      ...currentState.blacklistedIds,
      ...ref.read(intelligenceProvider).blacklistedIds,
      ..._failureBlocks.keys,
    };
  }

  /// Un-hide a disliked track EVERYWHERE: player layer, intelligence layer and
  /// any live failure block. The hidden-content page's Restore used to clear
  /// only the intelligence layer, so the player-layer entry kept blocking the
  /// track — "restore" looked like it did nothing.
  Future<void> unhideSong(Song song) async {
    _failureBlocks.remove(song.id);
    final bl = Set<String>.from(currentState.blacklistedIds)..remove(song.id);
    currentState = currentState.copyWith(blacklistedIds: bl);
    ref.read(intelligenceProvider.notifier).removeFromNotInterested(song);
    await _saveSettings();
  }

  /// Un-hide everything at once (hidden-content page "Restore all").
  Future<void> unhideAll(List<Song> songs) async {
    _failureBlocks.clear();
    currentState = currentState.copyWith(blacklistedIds: {});
    // One state write and one save for the whole restore — see
    // removeManyFromNotInterested for what the per-song loop was costing.
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
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.auvy.app.channel.audio',
          androidNotificationChannelName: 'Auvy Playback',
          androidNotificationChannelDescription: 'Auvy Music Player',
          androidNotificationOngoing: false,
          androidShowNotificationBadge: true,
          androidNotificationIcon: 'drawable/ic_notification',
          // Demote the service out of FOREGROUND state while paused (the
          // audio_service default). Holding foreground while idle is what made
          // Android/One UI pin a persistent "Auvy is running in the background"
          // notice with nothing playing — for up to an hour after a pause, or
          // indefinitely when a session was merely restored and never played
          // (the idle-kill only arms on pause). The old reason for `false`
          // ("notification PLAY did nothing after pausing") had two REAL causes
          // that are both fixed since: broadcastState reported `idle` while
          // paused (controllers treated the session as dead and dropped it) and
          // media-button click storms flipped play/pause (now debounced). With
          // `true`, pausing detaches foreground but keeps the notification +
          // media session fully interactive while the process lives.
          androidStopForegroundOnPause: true,
          androidNotificationClickStartsActivity: true,
        ),
      );
      print('OK: Media controls initialised (Native Bridge)');

      // The platform-lost verdict can arrive BEFORE this line.
      //
      // _probeNativePlatform fires in the constructor and AudioService.init is
      // awaited here, so in a headless engine the latch is usually already set
      // by the time the handler exists, and _onNativePlatformLost had nothing
      // to stop, which left an idle service holding ~208MB of RAM for a player
      // that can never play. Re-check now that there IS something to stop.
      if (!NativeAudioEngine.platformAvailable) {
        print('STOP: handler came up in an engine with no native player — stopping');
        await _audioHandler?.stop();
        return;
      }

      // The launch-restore races this init: _initPersistence pushes the
      // restored track's MediaItem while _audioHandler may still be null —
      // that push is silently dropped and the system notification shows a
      // bare "Auvy is running" (no title/cover) until the NEXT track change.
      // Re-push now that the handler exists.
      final restored = currentState.currentSong;
      if (restored != null) _updateMediaItem(restored);
    } catch (e) {
      print('WARN: Media controls setup failed: $e');
    }
  }

  // ==============================================================
  // CONNECTIVITY LISTENER  (auto quality adjustment)
  // ==============================================================
  Future<void> _initConnectivityListener() async {
    final notifier = ref.read(connectivityProvider.notifier);

    bool wasConnected = ref.read(connectivityProvider).isConnected;
    bool wasWifi = ref.read(connectivityProvider).isWifi;
    _connectivitySubscription = notifier.stream.listen((connState) {
      // CHECK isConnected FIRST. isWifi is false when there is NO network at
      // all, so the old two-way label printed "Mobile" for an outage, and it
      // printed it on the same event as connectivity_provider's "Gone offline",
      // which read as a contradiction in the logs:
      //
      //   18:47:34 Gone offline
      //   18:47:34 Network: Mobile
      //
      // Cosmetic, but a log that lies costs more than one that says nothing.
      print('Network: ${!connState.isConnected ? "none (offline)" : connState.isWifi ? "WiFi" : "Mobile"}');

      // Network TYPE changed (WiFi <-> mobile) OR a RECONNECT after any offline
      // gap: every cached googlevideo URL is bound to the OLD egress IP and will
      // 403 the moment ExoPlayer touches it. This is the #1 screen-off failure —
      // Samsung drops+reconnects Wi-Fi under Doze (often a NEW IP, same "wifi"
      // type), so the pre-warmed URL and even freshly-resolved ones 403 in a
      // storm. A reconnect must invalidate too (the old code only caught a
      // type SWITCH), so the next resolve/heal starts from genuinely fresh URLs.
      final reconnected = !wasConnected && connState.isConnected;
      // A SEAMLESS wifi<->mobile switch (mobile data already on when wifi drops)
      // keeps isConnected==true the whole time, so `reconnected` is false — but
      // every cached googlevideo URL is still bound to the OLD egress IP and will
      // 403 on the new network. Treat a type change the same as a reconnect.
      final typeSwitched = connState.isConnected && connState.isWifi != wasWifi;
      if (typeSwitched || reconnected) {
        print('Network ${reconnected ? 'reconnected' : 'type switched'} — invalidating all cached stream URLs');
        _audioService.invalidateAllStreams();
        // Let the near-track-end warm-up rerun against the new network.
        _preloadedSongId = null;
        // Fire any pending playback retry NOW — on a reconnect OR a wifi<->mobile
        // switch — instead of letting a mid-backoff track sit paused for up to 30
        // more seconds on a network that changed under it. (_pendingNetworkRetry
        // is only set after a real error, so this never disturbs healthy playback.)
        final retry = _pendingNetworkRetry;
        if (retry != null) {
          _pendingNetworkRetry = null;
          _recoveryTimer?.cancel();
          print('Network changed — firing pending playback retry immediately');
          retry();
        }
      }
      if (connState.isConnected) wasWifi = connState.isWifi;
      wasConnected = connState.isConnected;

      // THE WI-FI/MOBILE QUALITY FLIP USED TO LIVE HERE. IT IS GONE ON PURPOSE.
      //
      // It read "mobile data" as "reduce quality" and "Wi-Fi" as "restore it",
      // which is wrong in both directions often enough to matter: café Wi-Fi
      // behind a captive portal is far worse than good 5G, and neither branch
      // was evidence of anything — it fired on the transition, not on the
      // network failing to keep up. A track stalling right now kept stalling.
      //
      // adaptivebitrateDecision.dart replaces it with the measurement itself:
      // throughput from media3's bandwidth meter plus mid-track stall counts.
      // Do not reintroduce a connectivity-type shortcut alongside it — the two
      // would fight, and the guess would sometimes win.
      //
      // The connection TYPE still matters for data-saver, which is a
      // user-set spending decision rather than a quality one; that is read at
      // resolve time via `shouldUseLowQualityAudio`.
    });
  }

  // ==============================================================
  // AUDIO SESSION  (focus, ducking, headphone unplug)
  // ==============================================================
  // Adaptive bitrate
  /// Read what the network has been doing and return the ceiling to resolve at.
  ///
  /// Called immediately before each resolve — the only moment a different format
  /// can still be chosen. Never throws: on any failure the ladder HOLDS its
  /// position, so a broken measurement degrades to the previous decision rather
  /// than to the floor (dropping to the floor on an error would make a transient
  /// channel hiccup audible for the rest of the session).
  Future<int> _refreshBitrateCeiling() async {
    try {
      final stats = await NativeAudioEngine.getNetworkStats();
      final next = nextBitrateDecision(
        current: bitrateDecision,
        stalls: stats.stalls,
        estimateBps: stats.bitrateEstimate,
        dataSaver: ref.read(connectivityProvider).shouldUseLowQualityAudio,
      );
      if (next.rung != bitrateDecision.rung) {
        print('adaptive bitrate: rung ${bitrateDecision.rung} → ${next.rung} '
            '(ceiling ${next.ceilingBps} bps, est ${stats.bitrateEstimate} bps, '
            'stalls ${stats.stalls})');
      } else if (next.rung > 0) {
        // A ladder that cannot climb was completely silent
        //
        // This only ever logged a CHANGE, so a rung sitting at the bottom and
        // failing to recover produced no line at all, and that is exactly the
        // failure nextBitrateDecision's own comment warns about: "over-correcting
        // is why quality ratchets down and never recovers".
        //
        // Found while trying to answer "why is my audio 70kbps": two stalls
        // stepped the rung 0 → 1 → 2, and then five resolves went by in silence.
        // There was no way to tell a ladder that had climbed back from one stuck
        // at the floor.
        //
        // Rung 0 stays silent because it is the healthy default and would be a
        // line per track for nothing. A NON-ZERO rung is degraded audio, which is
        // rare, worth knowing about, and carries the two numbers that decide
        // whether it can recover: the estimate, and how far through the clean
        // streak it is. `needs` is what the estimate has to beat to climb.
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

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());
      // NOTE: focus is NOT acquired here. Requesting it at init stole audio
      // focus from whatever app was playing the moment Auvy launched, and it
      // was never re-requested afterwards, so once focus was lost, pressing
      // play made Auvy play ON TOP of the other app (the "two audios
      // overlapping" bug). Focus is now (re)acquired via _activateAudioFocus()
      // every time playback actually starts. See togglePlay / playSong /
      // _loadAndPlay. Android then tells the other app to pause, and the
      // interruption stream below stays wired to a live focus request.

      _subscriptions.add(session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // Transient dip (navigation prompt, notification) — lower volume.
              NativeAudioEngine.setVolume(currentState.volume * 0.3);
              break;
            case AudioInterruptionType.pause:
              // TRANSIENT loss (call, voice assistant): pause and remember to
              // auto-resume when the interruption ends.
              if (currentState.isPlaying) {
                _playInterrupted = true;
                togglePlay(haptic: false);
              }
              break;
            case AudioInterruptionType.unknown:
              // PERMANENT loss (another media app started playing): pause and
              // do NOT auto-resume — Android never sends an "end" for this,
              // and the user has moved to the other app.
              if (currentState.isPlaying) {
                _playInterrupted = false;
                togglePlay(haptic: false);
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              NativeAudioEngine.setVolume(currentState.volume);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Interruption over → resume ONLY if we auto-paused above.
              if (_playInterrupted && !currentState.isPlaying) togglePlay(haptic: false);
              _playInterrupted = false;
              break;
          }
        }
      }));

      _subscriptions.add(session.becomingNoisyEventStream.listen((_) {
        // Headphones unplugged. Also drop any pending interruption auto-resume:
        // unplugging DURING a call/assistant interruption must not blast the
        // speaker when that interruption later ends.
        _playInterrupted = false;
        if (currentState.isPlaying) {
          _pausedByDeviceLoss = DateTime.now();
          togglePlay(haptic: false);
        }
      }));

      // Bluetooth / wired headphones CONNECTED → auto-resume, as if the user
      // tapped play. Android delivers this via AudioManager's device-added
      // callback, which fires even while Auvy is backgrounded (as long as the
      // process is alive). Guards:
      //  • `armed` skips the burst Android emits at registration reporting the
      //    ALREADY-connected devices — otherwise Auvy would autoplay on launch
      //    whenever a headset happened to be plugged in.
      //  • only headphone-type OUTPUTS (not a car dock, speaker or a mid-song
      //    route change) trigger it, and only when a track is loaded & paused.
      bool armed = false;
      Future.delayed(const Duration(seconds: 2), () => armed = true);
      // AudioDeviceType is annotated @experimental in audio_session; the values
      // are stable in practice. Suppress the (only-a-warning) lint on this line.
      // ignore: experimental_member_use
      const headphoneTypes = <AudioDeviceType>{ AudioDeviceType.bluetoothA2dp, AudioDeviceType.bluetoothSco, AudioDeviceType.wiredHeadset, AudioDeviceType.wiredHeadphones };
      _subscriptions.add(session.devicesChangedEventStream.listen((event) {
        if (!armed) return;
        // Never act before the persisted settings finished loading — the
        // toggle read below would evaluate its cold default instead of what
        // the user actually chose (init-order race on slow cold starts).
        if (!_persistenceLoaded) return;

        // Disconnect → pause
        // A SECOND, independent path to the same outcome as
        // `becomingNoisyEventStream`, and the reason "sometimes it doesn't
        // pause" was reported: pausing used to depend solely on Android
        // broadcasting ACTION_AUDIO_BECOMING_NOISY, which is reliable for a
        // wired unplug but NOT for Bluetooth. A headset that drops out of range,
        // runs out of battery, or is switched off often disconnects without that
        // broadcast (or with it delayed past the point where audio has already
        // moved to the phone speaker). The device-removed callback fires on the
        // A2DP teardown itself, so it catches those cases.
        //
        // Double-pausing is harmless — `togglePlay` is guarded on isPlaying and
        // the native `setHandleAudioBecomingNoisy(true)` pause is idempotent —
        // so having both paths is strictly safer than picking one.
        final lostHeadphone = event.devicesRemoved
            .any((d) => d.isOutput && headphoneTypes.contains(d.type));
        if (lostHeadphone && currentState.isPlaying) {
          _playInterrupted = false;
          // Stamped, not a bare bool: it is what licenses the auto-resume below,
          // and a resume is only ever wanted for a device coming BACK, not for
          // an unrelated headset connected hours later.
          _pausedByDeviceLoss = DateTime.now();
          print('Output device disconnected — pausing');
          togglePlay(haptic: false);
          return;
        }

        // RECONNECT → RESUME, but only when it is genuinely wanted
        final connectedHeadphone = event.devicesAdded
            .any((d) => d.isOutput && headphoneTypes.contains(d.type));
        if (!connectedHeadphone) return;
        if (currentState.currentSong == null || currentState.isPlaying) return;

        // TWO separate licences to resume, and the distinction is the whole
        // point of this block:
        //
        //  1. We paused THIS playback because the device went away, recently.
        //     Resuming restores what the user was already listening to — that is
        //     continuity, not an interruption, and it is what the platform
        //     behaviour people expect from "my headphones reconnected".
        //
        //  2. The user explicitly opted into "Play on device connect".
        //
        // Without (1) the only option was (2), which is unconditional: it would
        // start music on ANY headset connection — including hours after the user
        // deliberately pressed pause, or when they connected a headset to make a
        // call. That is the interruptive behaviour worth avoiding. With (1) the
        // common case works without the setting, and the setting keeps its
        // original meaning for people who do want play-on-connect always.
        final resumedFrom = _pausedByDeviceLoss;
        final reconnectedInTime = resumedFrom != null &&
            DateTime.now().difference(resumedFrom) <
                PlayerNotifier.deviceResumeWindow;
        if (!reconnectedInTime && !currentState.autoPlayOnConnect) return;
        _pausedByDeviceLoss = null;

        // Let the new audio route settle before starting playback.
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted &&
              currentState.currentSong != null &&
              !currentState.isPlaying) {
            print('Output device connected — resuming '
                '(${reconnectedInTime ? "was paused by disconnect" : "play-on-connect setting"})');
            togglePlay(haptic: false);
          }
        });
      }));

      _audioSession = session;
      print('OK: Audio session configured with smart-resume');
    } catch (e) {
      print('WARN: Audio session setup failed: $e');
    }
  }

  /// Audio focus is owned ENTIRELY by the native layer now — see
  /// `NativePlayerManager.setupAudioFocus()` / `requestAudioFocusIfNeeded()`,
  /// which requests GAIN on `onPlayWhenReadyChanged(true)`, handles
  /// LOSS / LOSS_TRANSIENT / CAN_DUCK, and keeps the play-during-a-phone-call
  /// exception. This method is deliberately a NO-OP.
  ///
  /// Why: it used to call `_audioSession.setActive(true)`, which registers a
  /// SECOND AudioFocusRequest — from the same app — alongside the native one.
  /// Android grants the newest request and sends AUDIOFOCUS_LOSS to the
  /// previous holder, so Auvy evicted ITSELF: togglePlay requested focus via
  /// the plugin, `NativeAudioEngine.resume()` then made the native layer request
  /// it, the plugin's request received LOSS(-1), and the interruption handler
  /// above treated that as "another app started playing" and paused ~150ms
  /// after playback began. That is the "I have to press play three times on a
  /// cold start" bug — each tap traded focus back and forth until the two
  /// requests happened to settle. Verified on-device in logcat:
  ///   requestAudioFocus → granted=true / isPlaying=true
  ///   onAudioFocusChange(-1) → com.ryanheise.audio_session…
  ///   isPlaying=false
  ///
  /// Nothing is lost by dropping the plugin request: the native GAIN request is
  /// what makes other media apps pause, and `becomingNoisyEventStream` /
  /// `devicesChangedEventStream` (headphone unplug + connect-autoresume) are
  /// broadcast-based and keep working without an active focus request. With no
  /// plugin request registered, `interruptionEventStream` simply stays quiet —
  /// its handler is kept as-is so focus handling is correct if it ever returns.
  Future<void> _activateAudioFocus() async {}

  Future<void> _bindEqualizerToSession() async {
    // Native ExoPlayer binding handles EQ routing now. 
    // This method acts as a UI settings sync.
    try {
      
      // If you are using a Flutter EQ package, apply the bands.
      // Or pass it natively via MethodChannel.
      applyEqBands(currentState.eqBands, persist: false);
      
      print('EQ bindings synced');
    } catch (e) {
      print('WARN: EQ session binding failed: $e');
    }
  }

  /// Persist ONLY the live position (cheap, two ints). Runs every few seconds
  /// while playing and on every pause, so killing the app from recents restores
  /// not just the track but the exact timestamp. The full _saveSettings only
  /// runs on discrete events, which meant the saved position was usually the
  /// track START — "remembers the song but not where I was".
  Future<void> _persistPositionOnly() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = currentPositionProvider.value.inMilliseconds;
      await prefs.setInt('auvy_position', ms);
      await prefs.setInt('player_resume_position_ms', ms);
    } catch (_) {}
  }

  // ==============================================================
  // PLAYER INIT  (Start the UI Ticker and sync native state)
  // ==============================================================
  /// The native player is unreachable in this Flutter engine — shut the
  /// session down instead of retrying into a void.
  ///
  /// THE RUNAWAY THIS EXISTS TO STOP. audio_service starts a HEADLESS engine
  /// whenever the service is launched with no Activity — Bluetooth connect,
  /// headset button, Android Auto, SystemUI's resumption probe. That engine gets
  /// only pub plugins from GeneratedPluginRegistrant, so the channels
  /// MainActivity registers by hand are absent and playback can never start.
  ///
  /// Before this, the player did not know that. It ran the full track-start
  /// sequence, got nothing, and tried again every few seconds — forever. A
  /// session found on device had restarted the foreground service 875 times,
  /// burned 9m33s of CPU, leaked ~2400 executor threads and was still climbing,
  /// all with the app dismissed and nothing playing.
  ///
  /// Stopping is the honest response: this engine cannot play audio, so holding
  /// a media session open only advertises a player that will never work. Once
  /// the service stops, the process is free to die and the next launch from the
  /// launcher gets a real engine with real channels.
  void _onNativePlatformLost() {
    print('STOP: native player unreachable in this engine — stopping the session');

    // Kill the repeating work first, so nothing re-arms during teardown.
    _positionTicker?.cancel();
    _positionTicker = null;
    _queueSyncTimer?.cancel();
    _queueSyncTimer = null;
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = null;

    // No playback is possible, so the state must not claim otherwise — a
    // lingering isPlaying/isLoading is exactly what convinced onTaskRemoved to
    // keep the service alive through a swipe.
    if (mounted) {
      currentState = currentState.copyWith(isPlaying: false, isLoading: false);
    }

    // Drops the notification, releases foreground state and lets the service
    // finish. Fire-and-forget: if the handler never came up there is nothing
    // to stop and nothing to report.
    final handler = _audioHandler;
    if (handler != null) {
      handler.stop().catchError((_) {});
    }
  }

  /// Ask the native side one cheap question at startup.
  ///
  /// Without this the answer arrives whenever the first real command happens to
  /// run, which is somewhere inside the session restore, so a doomed engine
  /// still did a full boot before finding out. Probing up front means the
  /// teardown above runs in the first moment of life instead of after the app
  /// has loaded a feed it will never show.
  void _probeNativePlatform() {
    // isMusicActive is read-only and safe to call before anything is loaded.
    NativeAudioEngine.isMusicActive();
  }

  void _initPlayer() {
    NativeAudioEngine.setVolume(currentState.volume);

    _initConnectivityListener();
    _bindEqualizerToSession();

    // Heartbeat position persistence. See _persistPositionOnly. Live radio has
    // no meaningful position, so it's skipped, but podcast episode ids are ALSO
    // http stream URLs, and they DO have a position (their per-episode bookmark
    // used to only update on pause/switch, so an OS kill mid-episode lost hours).
    _positionTicker?.cancel();
    _positionTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _checkForSilentPlayback();
      if (!currentState.isPlaying) return;
      final song = currentState.currentSong;
      if (song == null) return;
      // A book chapter has a position worth keeping, AND this dropped it.
      //
      // The old test was 'http id and not a podcast → live radio, nothing to
      // save', which is true of a station and false of an audiobook chapter. So
      // the heartbeat skipped books entirely: an OS kill mid-chapter lost the
      // place, which for a nine-hour book is the whole point of it.
      if (!song.hasSeekablePosition) return;
      _persistPositionOnly();
      if (song.isSpokenWord) {
        _savePodcastPosition(song, currentPositionProvider.value);
      }
    });

    // The native ExoPlayer engine streams REAL position / duration / play-state
    // back to us (~2x/sec). This is what drives the progress bar, time label and
    // play button — replacing the old fake "+1s" guessed clock that never tracked
    // actual playback. currentPositionProvider is a ValueListenable, so updating
    // it moves the bar without rebuilding the whole player page.
    // LAZY resolver: the native ResolvingDataSource calls this to (re)resolve a
    // videoId's stream URL on demand — the player is never handed a fixed URL, so
    // expiry / 403 / IP-change (Doze Wi-Fi flap) is fixed transparently at the
    // data layer instead of dying and cascade-skipping.
    NativeAudioEngine.setStreamResolver((videoId,
        {int expectContentLength = 0}) async {
      try {
        // The native ResolvingDataSource only calls back here when it needs a
        // FRESH url — its own songUrlCache already serves replay/seek/re-buffer,
        // so a Dart resolve request means "cache-miss or I just dropped a 403'd
        // url". Drop any Dart-side cached url for this id FIRST: googlevideo urls
        // are IP-bound, so after a WiFi<->mobile switch StreamResolver would keep
        // returning the same (now-403'ing) url for its whole 5h TTL and native
        // would 403-storm forever ("plays like it's offline"). Re-resolving here
        // re-signs the url for the CURRENT network, and this recovers even when
        // connectivity_plus misses the switch (verified: it can). Cheap: native
        // caches the result, so this runs ~once per (re)resolve, not per chunk.
        _audioService.invalidateMemoryCache(videoId);
        // Do NOT rotate mid-track.
        //
        // Rotation exists to escape a gated stream, and it escalates whenever
        // resolves repeat inside 20s, which is exactly what a mid-track 403 storm
        // looks like. So it fired precisely when it must not: a different client
        // returns a different FORMAT, a different format is a different FILE with
        // its own length and byte layout, and the player is about to ask for the
        // byte offset it had reached in the OLD file. Observed on one track across
        // consecutive attempts — itag=140 clen=3406710, then itag=251
        // clen=2708020 — after 1 MiB of the first had already been consumed. Every
        // "fresh URL" was refused because every one was a different file, so the
        // recovery kept feeding the loop it was trying to break.
        //
        // expectContentLength is non-zero only for a mid-track re-resolve. There
        // the right answer is a FRESH URL FOR THE SAME FORMAT, so ESCALATION is
        // suppressed — the rotation counter is left untouched, since bumping it
        // would escalate a storm that is no longer choosing a client.
        //
        // Suppressing escalation is NOT the same as asking client 0, AND the
        // Difference was a track that could never recover.
        //
        // This passed a literal 0 mid-track. Rotation is STICKY per track, so a
        // track that had escalated — the only kind that ever gets here, since
        // escalation is what a 403 storm does — was originally resolved by client
        // 1 or 2 and PINNED to that client's format. Asking client 0 for the
        // "same format" then returned a different one by construction, the pin
        // refused it, and the refusal was deterministic: same question, same
        // wrong answer, forever. Visible in the 2026-08-30 transcript as a count
        // that kept climbing past its own cap — 4/3, 5/3, 6/3 — one resolve every
        // 30s, because the clean restart re-pinned the same unreachable format.
        //
        // The sticky index, read WITHOUT bumping it, is what "the same format"
        // actually means.
        // The free "no" for a gated account. See _maxNoStreamStreak. Checked
        // before anything else so a refusal costs one comparison, not a sweep of
        // the whole client chain.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (_resolveCooldownUntilMs > nowMs) {
          print('STOP: resolve suppressed for '
              '${((_resolveCooldownUntilMs - nowMs) / 1000).round()}s — every '
              'client refused $_noStreamStreak time(s) in a row; NOT hitting '
              'the network');
          return null;
        }
        final bool midTrack = expectContentLength > 0;
        // THE FREE "NO" — CHECKED BEFORE ANY NETWORK WORK HAPPENS.
        //
        // This is the half that stops the drain. Once a pin has been given up on
        // (see _maxPinRefusals), native does not stop asking — it cannot know
        // anything changed, so the answer has to be cheap. Returning here costs
        // one comparison instead of a metadata resolve, which is the difference
        // between the 1,800 requests that were measured and none.
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
          // The reset needs a guard, NOT removal
          //
          // Zeroing the count here UNCONDITIONALLY is what broke the give-up:
          // `_pinCooldownUntilMs` starts at zero, so `waitMs` was negative before
          // any give-up had ever happened and the reset ran on every matching
          // re-resolve, putting the cap out of reach. The 2026-08-31 transcript
          // is unambiguous — seven refusals in 24s, every one of them "(1/3)",
          // then a resolve that gave out entirely.
          //
          // The `!= 0` test is the whole fix. Only a cooldown that was really set
          // and has really lapsed is a fresh run, and that run deserves the same
          // two transient retries as the first. [_pinGiveUps] is deliberately NOT
          // cleared, so the backoff keeps escalating across rounds.
          if (_pinCooldownUntilMs != 0) {
            _pinCooldownUntilMs = 0;
            _pinFailCount = 0;
          }
        }
        final rot = midTrack
            ? (_streamClientRotation[videoId] ?? 0)
            : _nextStreamClientRotation(videoId);
        // POSITIVE evidence that the pin engaged. Absence of 403s is NOT proof the
        // fix works — it is equally consistent with the pin never running, which is
        // exactly how the first attempt at this looked fixed while being inert on
        // the ordinary streaming path. Release swallows print(), so this costs
        // nothing shipped.
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
        // The ladder must NOT move during a mid-track re-resolve.
        //
        // A mid-track re-resolve exists to get a FRESH URL FOR THE SAME FORMAT
        // (see the pin below). Consulting the ladder here defeats that in the
        // worst possible way, because the two triggers coincide: a re-resolve
        // happens BECAUSE playback stalled, and a stall is exactly what steps the
        // ladder down. A lower ceiling picks a different format, a different
        // format has a different length, and the pin then rejects every single
        // attempt — turning recoverable stutter into "4 fresh-url attempts all
        // refused, FATAL" every time.
        //
        // So the ceiling is frozen for the life of a track. Stalls still COUNT —
        // they stay on the native counter, unread, and are consumed by the next
        // fresh resolve, so the downgrade still happens, just at the track
        // boundary where changing format is free.
        final ceiling = midTrack
            ? bitrateDecision.ceilingBps
            : await _refreshBitrateCeiling();
        // Freeze the data-saver flag too, NOT just the ceiling
        //
        // TWO inputs choose the format, and freezing one of them is the same as
        // freezing neither. `shouldUseLowQualityAudio` is
        // `dataSaverMode == wifi && !isWifi`, so it flips the moment the phone
        // changes network, and a network change is precisely when a re-resolve
        // happens, because switching invalidates every cached stream URL.
        //
        // Caught in the 2026-09-01 log, and the ordering is unambiguous:
        //
        //   10:51:00  Back online: WiFi / Network type switched
        //   10:51:57  re-resolve returned a DIFFERENT format
        //             (clen 3770579 != 3505097) — refusing it (1/3)
        //   10:52:02  giving up on it and restarting the track cleanly
        //   10:52:46  ... and the whole cycle again, give-up #2
        //
        // The track had been resolved on mobile with data-saver on (131kbps,
        // clen 3505097). WiFi returned, the flag went false, and the mid-track
        // re-resolve asked for the unrestricted format (154kbps, clen 3770579) —
        // which the pin then correctly refused, three times, twice over, costing
        // six wasted resolves and two clean restarts of a track that was playing
        // perfectly well.
        //
        // The pin was doing its job. The resolver was being asked the wrong
        // question. Same reasoning as the ceiling immediately above: changing
        // format is free at a track boundary and never free mid-track, so both
        // inputs hold for the life of the track.
        final bool lowQuality;
        if (midTrack) {
          // Fall back to the live value only if this track has no recorded one,
          // which means the pin was set by a path that did not go through a
          // fresh resolve — better to behave as before than to guess.
          lowQuality = _lowQualityPin[videoId] ??
              ref.read(connectivityProvider).shouldUseLowQualityAudio;
        } else {
          lowQuality = ref.read(connectivityProvider).shouldUseLowQualityAudio;
          _lowQualityPin[videoId] = lowQuality;
          if (_lowQualityPin.length > 300) {
            _lowQualityPin.remove(_lowQualityPin.keys.first);
          }
        }
        final stream = await _audioService.getStreamWithFallback(
          videoId, title, artist,
          // Data-saver is still an explicit, user-set cap — it protects a data
          // allowance rather than playback, so a fast network is not a reason to
          // ignore it. Everything else is now decided by measurement.
          lowQuality: lowQuality,
          clientStartIndex: rot,
          maxBitrate: ceiling,
          // STOP RESOLVING A TRACK THE USER HAS ALREADY LEFT.
          //
          // The chain tries five clients and then a signed-in retry, which can
          // run for seconds. On 2026-09-02 a gated track was skipped at
          // 21:56:16.8; its resolve carried on until :19.3, well after the next
          // track was playing, and then declared "every client refused" and
          // marked the visitor id stale — a session-wide verdict drawn from a
          // track nobody was waiting for, which then applies to the track the
          // user DID move to. A mid-track re-resolve is unaffected: there the
          // videoId being asked about IS the current song.
          isStillWanted: () => currentState.currentSong?.id == videoId,
        );
        final url = stream?['url'];
        if (url == null || url.isEmpty) {
          // A SKIP IS NOT A REFUSAL, AND THIS STREAK HAS TEETH.
          //
          // An abandoned resolve (isStillWanted above) also returns null here,
          // and counting it would let the user's own skipping trip
          // _maxNoStreamStreak — which sets _resolveCooldownUntilMs and then
          // suppresses EVERY resolve for an exponentially growing window. Three
          // fast skips would have stopped playback from resolving anything,
          // which is a far worse symptom than the one being guarded against.
          //
          // Re-checking the same condition the predicate used is what separates
          // the two cases: the track moving on is why the resolve returned
          // nothing. If it genuinely failed AND the user has since skipped, not
          // counting it is still right — the failure cannot be attributed and
          // the track is gone either way.
          if (currentState.currentSong?.id != videoId) {
            print('resolve for $videoId returned nothing, but the track had '
                'already changed — not counting it as a refusal');
            return null;
          }
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
        // A stream that resolved proves nothing is being refused any more.
        if (_noStreamStreak > 0) {
          print('OK: streams are resolving again after $_noStreamStreak '
              'refusal(s)');
          _noStreamStreak = 0;
          _resolveCooldownUntilMs = 0;
        }
        // YouTube reports the track's measured loudness on the player response.
        // Cache it per videoId and, if this is the track playing right now,
        // apply normalization immediately — this resolve is the ONLY point the
        // value is available, and it lands after playSong has already run.
        final ld = double.tryParse('${stream?['loudnessDb'] ?? ''}');
        if (ld != null) {
          _loudnessByVideoId[videoId] = ld;
          if (_loudnessByVideoId.length > 300) {
            _loudnessByVideoId.remove(_loudnessByVideoId.keys.first);
          }
          if (currentState.currentSong?.id == videoId) _applyAudioNormalization();
        }
        // A mid-track re-resolve that changed format is worse than nothing.
        //
        // A different length means a different file, so continuing at the
        // player's current byte offset can only 403. Refusing it surfaces the
        // failure immediately — Dart then restarts the track cleanly — instead of
        // burning the whole retry budget on ranges that cannot exist.
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
            // The pin, not the stream, is the stale thing. Stop defending it: a
            // fresh resolve re-pins to a format that actually exists, and the
            // listener pays one re-buffer instead of silence.
            //
            // ESCALATING, SO A PIN THAT WILL NEVER RESOLVE CANNOT THRASH. The
            // refusal count restarts once the cooldown lapses, so a dead pin
            // reaches this branch again every round; a fixed cooldown would mean
            // a restart every 30 seconds forever. Doubling to a 5-minute ceiling
            // costs a genuinely dead pin a few restarts before it goes quiet,
            // while a recoverable one still gets its first retry promptly.
            _pinGiveUps++;
            final backoff = (_pinCooldownMs << (_pinGiveUps - 1))
                .clamp(_pinCooldownMs, _pinCooldownMaxMs);
            _pinCooldownUntilMs =
                DateTime.now().millisecondsSinceEpoch + backoff;
            print('STOP: the pinned format (clen $expectContentLength) is gone — '
                'giving up on it and restarting the track cleanly '
                '(give-up #$_pinGiveUps, quiet for ${backoff ~/ 1000}s)');
            // OFF THIS CALLBACK. Native is blocked waiting for this reply, and
            // the restart path calls back into native — running it inline would
            // have each side waiting on the other.
            final restartId = videoId;
            Timer(Duration.zero, () {
              if (!mounted) return;
              if (currentState.currentSong?.id != restartId) return;
              handleStreamLeaseExpiration(
                // A stalled track reads isPlaying=false long before anyone
                // notices, so intent has to come from either flag or the restart
                // lands paused — the "playback just stopped" shape again.
                intendedPlaying: currentState.isPlaying || currentState.isLoading,
                resumeFrom: currentPositionProvider.value,
              );
            });
          }
          return null;
        }
        // A format that resolved is a pin worth trusting again.
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
      // Self-heal on a fatal stream error (403/expired): re-resolve + resume.
      // playWhenReady carries the user's true play intent across the error —
      // isPlaying is already false by now (the buffer underran long before the
      // error surfaced), so healing from isPlaying reloaded the track PAUSED:
      // the "playback just stops mid-track" bug.
      onError: (playWhenReady) {
        if (mounted) handleStreamLeaseExpiration(intendedPlaying: playWhenReady);
      },
      onPosition: (position, duration, isPlaying) {
        if (!mounted) return;
        // Self-heal a stuck `isLoading`: once the native engine actually reports
        // playback (playing, or the clock advancing), we are NOT loading anymore.
        // Without this, a stale isLoading=true (e.g. after cache-first play or a
        // recovery) silently froze the mini-player/progress bar forever.
        if (currentState.isLoading && (isPlaying || position > Duration.zero)) {
          currentState = currentState.copyWith(isLoading: false);
        }
        // Real audible progress = the network path works again: clear the
        // cross-track resolve-failure streaks and any armed instant retry.
        if (isPlaying && position > Duration.zero) {
          _autoAdvanceFailStreak = 0;
          _gateFailStreak = 0;
          _pendingNetworkRetry = null;
        }
        if (currentState.isLoading) return;

        // A manual seek is settling: the engine still reports pre-seek
        // positions for a tick or two, which snapped the bar back to the old
        // spot and then forward again. Hold the optimistic target until the
        // clock lands near it; a 2.5s failsafe releases the hold no matter
        // what (e.g. a seek the engine quietly ignored).
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

        // High-frequency: the progress bar / time label listen to this directly,
        // so it stays perfectly live without touching PlayerState.
        currentPositionProvider.value = position;

        // Sponsor breaks jump themselves. Done HERE, on the engine's own tick,
        // rather than in the player page — the page is usually closed and the
        // screen usually off while a two-hour episode plays, and a skip that only
        // works when you're watching it isn't a skip.
        _maybeSkipSponsorBreak(position);

        final knownDuration = duration > Duration.zero ? duration : currentState.duration;
        // Structural changes (duration resolved, play/pause) must reflect in
        // PlayerState immediately — they're rare and lots of widgets depend on
        // them. The position, however, is throttled: fold it in at most ~1×/sec
        // so we don't rebuild every playerProvider consumer on every tick
        // (~2×/sec) just to advance a value nothing reads via ref.watch.
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
        // LISTEN-THRESHOLD play crediting (Last.fm-scrobble style). A track
        // counts as a real "play" — feeding playCounts / My Top 50 / the taste
        // model — only once it's been genuinely heard: ~30s, or half its length
        // for short tracks. Fires ONCE per play (guarded by _currentPlayRecorded,
        // reset as each track loads in playSong), so tap-then-skip credits
        // nothing. Excludes live radio / podcast streams (http ids) from music
        // taste. This is what stops sampled-and-skipped tracks from inflating
        // Top 50 and poisoning the recommendations.
        // The threshold is user-configurable (Settings → Listening data);
        // ListeningPolicy's defaults are the old hardcoded 30s / 50% values.
        // With history paused, nothing is credited at all.
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
              // ListenBrainz rides the SAME threshold rather than defining its
              // own: "genuinely heard" should mean one thing in Auvy, and the
              // user already tuned it in Settings → Listening data. It also
              // inherits the pauseListeningHistory guard above, so pausing
              // history stops the scrobble too — a privacy switch that only
              // covered local records while still uploading listens would be a
              // lie. No-ops unless a token has been entered.
              //
              // `listened_at` is the moment the track STARTED, not now: filing it
              // at the crossing point would date every listen ~30s late and
              // misorder back-to-back tracks.
              unawaited(ScrobbleService.instance.submitListen(
                cs,
                startedAt: DateTime.now().subtract(position),
              ));
            }
          }
        }
        // Spotify-style preloading: as the track nears its end, warm the next
        // one's stream URL / cache / lyrics so the switch is seamless. Cheap to
        // call every tick — it self-guards and only acts inside the lead window.
        if (isPlaying) _preloadNextTrack();
      },
      // Track finished naturally — advance the queue (don't re-prepare the same URL).
      // isLoading guard: while a NEW track is already being resolved (manual
      // skip mid-song), the ending of the OLD track must not advance the queue
      // a second time — that double-skip jumped past tracks seemingly at random.
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
        // A live radio stream never legitimately "ends" — ended means the
        // connection dropped. Reconnect the same station instead of advancing
        // into whatever happens to sit in the queue. isNextOrPrev bypasses the
        // same-id togglePlay guard so the stream actually reloads.
        if (cs != null && cs.id.startsWith('http') && cs.albumTitle != 'Podcast') {
          playSong(cs,
              isManual: false,
              isNextOrPrev: true,
              source: currentState.playbackSource);
          return;
        }
        // PREMATURE-END GUARD (the "kept ending & skipping" bug)
        // ExoPlayer fires STATE_ENDED not only at a true end but whenever the
        // input stream hits EOF — including when a Doze-throttled network cuts
        // the googlevideo connection mid-track (the stream is served truncated,
        // ExoPlayer plays what arrived, then "ends"). Blindly advancing here is
        // the false-negative the user sees: the track "skips" itself yet plays
        // perfectly when tapped manually (a fresh, un-truncated stream).
        //
        // If we ended well short of a KNOWN duration, the track did NOT finish —
        // heal it (cache-first, else re-resolve a fresh stream) and resume from
        // where audio actually stopped, instead of skipping to the next song.
        final endedEarly = cs != null &&
            !cs.id.startsWith('http') &&
            dur > const Duration(seconds: 30) &&
            livePos > Duration.zero &&
            livePos < dur - const Duration(seconds: 12);
        if (endedEarly) {
          print('PREMATURE end — healing "${cs.title}" '
              '(${livePos.inSeconds}s/${dur.inSeconds}s) instead of skipping');
          handleStreamLeaseExpiration(intendedPlaying: true, resumeFrom: livePos);
          return;
        }
        // "Cache what you finished":
        // the track played end-to-end, so its full audio is now in the native
        // play-cache — promote it into the visible Cached folder with ZERO
        // network (any network), replacing the old 10s HTTP re-download. Guarded
        // (skips radio/podcast/non-videoId/already-cached); '' url = promote-only
        // (no HTTP fallback). Fire-and-forget.
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
      onIsPlayingChanged: (isPlaying) {
        if (mounted && currentState.isPlaying != isPlaying) {
          currentState = currentState.copyWith(isPlaying: isPlaying);
        }
      },
      // "Pause when muted": turning the volume to zero is an unambiguous stop
      // gesture, but Android keeps playing into silence — burning data and
      // battery. Opt-in, and routed through togglePlay(haptic:false) like every
      // other automated pause so state/media-session/notification stay in sync.
      onVolumeMuted: () {
        if (!mounted || !ListeningPolicy.pauseOnMute) return;
        if (!currentState.isPlaying) return;
        print('media volume hit zero — pausing');
        togglePlay(haptic: false);
      },
      // Sustained-stall detection
      //
      // Native reports every BUFFERING transition, and a normal track start is
      // one of them — surfacing those would put a "reconnecting" flicker on every
      // song. So a stall has to LAST before it is admitted to.
      //
      // What this catches: playback that reports PLAYING while no audio comes
      // out, which happens when a googlevideo URL dies because the network path
      // moved (Samsung Wi-Fi flap: dual-stack Wi-Fi ↔ IPv6-only LTE). Measured
      // live at twelve seconds of silence, with the UI showing a playing track
      // the whole time, which reads as a broken app and provokes skipping, and
      // skipping restarts the load and makes it worse.
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

          // A stall must arm the recovery, NOT just report itself
          //
          // Losing the network mid-track raises NO ExoPlayer error: the buffer
          // drains and the player simply buffers forever. So `isStalled` went
          // true, the UI said "Connecting…", and `_pendingNetworkRetry` stayed
          // null, which is what the connectivity listener fires on reconnect.
          // Nothing was armed, so when the network came back it invalidated the
          // cached URLs and then had nothing to run: the track sat there dead
          // while the rest of the app worked. Reported as "even if i reconnect
          // internet the app won't continue play and buffer as it should".
          //
          // Arming the same closure an error would arm makes reconnect resume it.
          // It self-guards on the song id, so a stale fire after the user has
          // moved on is a no-op, and it is only ever armed while a stall is
          // actually in progress.
          final stalledSong = currentState.currentSong;
          if (stalledSong == null) return;
          final wasPlaying = currentState.isPlaying;

          // A track that is already on disk has nothing to wait for
          //
          // Both recovery routes below wait for the NETWORK: one for a
          // connectivity event, the other for a 12-second floor under it. Neither
          // reason applies to a complete local copy, so waiting is pure silence.
          //
          // Measured on 2026-08-31: "Starboy" stalled at 21:15:50, recovered at
          // 21:16:02 and healed from its local copy 163ms later. Fifteen seconds
          // of nothing — the 3s stall grace plus the 12s floor — for audio the
          // device already held in full.
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
            // Resolved fresh: the URL this stalled on is bound to the network
            // path that went away, and the reconnect handler has already dropped
            // it from the cache.
            _loadAndPlay(stalledSong,
                playImmediately: wasPlaying, startFrom: currentState.position);
          }

          _pendingNetworkRetry = resumeAfterStall;
          // And a timer too, because a stall is NOT always a disconnect.
          //
          // connectivity_plus reports the LINK, not whether packets flow. A
          // captive portal, an IPv6-only cell handover, or a dead CDN edge all
          // stall playback while the OS still calls the network "connected" — so
          // no connectivity EVENT ever fires and a reconnect-only recovery waits
          // for something that already happened. This is the floor under that.
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
        // GAPLESS: ExoPlayer auto-advanced to the pre-buffered upcoming item
        // (a mid-playlist transition fires NO STATE_ENDED). Credit + cache the
        // finished track, then sync Dart's queue WITHOUT a native reload (the
        // audio is already playing gaplessly — reloading would restart it).
        if (!mounted || !currentState.gaplessPlayback) return;
        // A skip also lands here, AND must NOT be treated as a finish
        //
        // playNext's fast path asks native to jump to the buffered item, which
        // raises the same transition this handler listens for. Left alone it
        // would advance the queue a SECOND time — two tracks for one tap — and,
        // worse, credit the skipped song a full play at percent 1.0, teaching
        // the taste model that a track the user rejected was listened to whole.
        //
        // The skip does its own bookkeeping and its own state sync, so this
        // occurrence is consumed and ignored.
        if (_skipConsumesNextAdvance) {
          _skipConsumesNextAdvance = false;
          print('transition for $videoId is our own skip — not a finish');
          return;
        }
        // REPEAT ONE must win over a stale gapless arm. Nothing should be armed
        // in this mode (cycleRepeatMode clears it), but if an upcoming item
        // slipped through, ExoPlayer has already rolled into the NEXT song —
        // seeking to 0 from here would restart that wrong track and leave the UI
        // showing the old one. Reload the current track instead so Repeat One
        // actually repeats. (This was "Repeat One behaves like Repeat Off".)
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
        final finished = currentState.currentSong;
        // Cache-what-you-finished (mirrors onTrackEnded): the track played
        // end-to-end, so its bytes are in the play-cache — promote for free.
        if (finished != null &&
            !finished.id.startsWith('http') &&
            finished.albumTitle != 'Podcast' &&
            finished.id.length == 11 &&
            !_cacheManager.isCached(finished.id)) {
          _cacheManager.cacheTrack(finished, '', isExplicitDownload: false);
        }
        // The pre-queued upcoming should be queue[1]. If the queue changed after
        // it was enqueued (queue[1].id != the track native rolled into), fall
        // back to a normal reload of the correct next (brief gap, rare).
        final matches = currentState.queue.length > 1 &&
            currentState.queue[1].id == videoId;
        print('gapless auto-advance → $videoId (matches=$matches)');
        playNext(autoAdvance: true, alreadyPlayingNatively: matches);
      },
    );
  }
  

  // NOTE: the old _startPositionTicker (a fake "+1s" clock that could ALSO
  // call playNext at its guessed boundary) was removed — it was dead code, and
  // if ever re-wired it would fight the native engine's real position stream
  // and double-advance the queue at track end.

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

    final blacklistJson    = prefs.getStringList('auvy_blacklist') ?? [];
    final userQueueJson    = prefs.getString('auvy_user_queue');
    final contextQueueJson = prefs.getString('auvy_context_queue');
    final autoplayQueueJson= prefs.getString('auvy_autoplay_queue');
    final userQueueEnd     = prefs.getInt('auvy_user_queue_end') ?? 0;
    final cacheLimit       = prefs.getInt('auvy_max_cache_size') ?? 500;
    // Sync the saved cache limit into the cache manager NOW. Without this it
    // stayed at its hardcoded default until the user touched the slider, so
    // eviction used the wrong threshold for the whole session.
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
    // 'auvy_explicit_preferred' is deliberately NOT read: explicit/original
    // versions are ALWAYS preferred (field default true) — a stale saved
    // `false` from when the toggle existed must not disable it.
    final autoPlayConnect  = prefs.getBool('auvy_autoplay_on_connect') ?? false;
    // AUDIO-ONLY IS NOW PERMANENT — the stored value is deliberately IGNORED.
    //
    // Music-video versions are no longer offered at all: there is one kind of
    // result, the audio one, so there is nothing to configure and no toggle to
    // find. Reading the old pref back would strand anyone who had switched
    // videos on in a mode the app no longer has a control for.
    const processVideos = false;
    // Hides YouTube Shorts on the videos-allowed path. Default TRUE: a Short is
    // a snippet, not a song, so surfacing it is virtually never what was wanted.
    SearchService.hideShorts = prefs.getBool('auvy_hide_shorts') ?? true;
    // Apply to the search layer up-front so the very first search respects it.
    SearchService.processVideos = processVideos;
    // The learned video→audio map, so videos met in a previous session cost no
    // lookup this one. Unawaited: nothing blocks on it, and a conform that
    // happens to run first simply misses the cache once.
    unawaited(SearchService.loadConformCache());

    final silenceSkip = prefs.getBool('auvy_silence_skipping') ?? false;
    final pitch       = prefs.getDouble('auvy_pitch') ?? 1.0;
    final podcastSpd  = prefs.getDouble('auvy_podcast_speed') ?? 1.0;
    final eqEnabled   = prefs.getBool('auvy_eq_enabled') ?? false;
    final eqBandsRaw  = prefs.getStringList('auvy_eq_bands');
    final eqBands     = eqBandsRaw != null
        ? eqBandsRaw.map(double.parse).toList()
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

    currentState = currentState.copyWith(
      history:                 history,
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
      // Clamped: an out-of-range persisted value (older build / corrupt prefs)
      // used to throw RangeError right in the middle of state restore.
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
    );

    if (current != null && current.image.isNotEmpty) {
      ref.read(playerColorProvider.notifier).updateFromImage(current.image);
      _updateMediaItem(current);
    }

    final resumeSource = prefs.getString('player_resume_source') ?? 'Library';
    final resumeContextTitle = prefs.getString('player_resume_context_title') ?? '';
    // Restored alongside the source: the player header is TWO lines — the kind
    // ("PLAYING FROM PLAYLIST") and the NAME of that place. Persisting only the
    // source meant a resumed session kept the right kind but lost the name, and
    // the name line silently fell back to the track's own albumTitle — so
    // reopening the app on a playlist read "PLAYING FROM PLAYLIST" over an
    // unrelated album title.
    final resumeLocation = prefs.getString('player_resume_location') ?? '';
    final accurateResumePosMs = prefs.getInt('player_resume_position_ms') ?? savedPositionMs;

    currentState = currentState.copyWith(
      playbackSource: resumeSource,
      locationName: resumeLocation.isNotEmpty ? resumeLocation : null,
      contextTitle: resumeContextTitle.isNotEmpty ? resumeContextTitle : ctxTitle,
      miniPlayerVisible: current != null,
    );

    // Push the LOADED DSP settings to the native engine so EQ + pitch actually
    // take effect (before this they only lived in Dart state). The native
    // Equalizer buffers this and (re)applies when the audio session initialises
    // on the first track; pitch goes into PlaybackParameters immediately.
    NativeAudioEngine.setEqualizer(currentState.eqEnabled, currentState.eqBands);
    NativeAudioEngine.setPitch(currentState.pitch);
    // Silence skipping is a pure engine flag — push the restored value or the
    // setting reads "on" in Settings while the engine has it off.
    NativeAudioEngine.setSkipSilence(currentState.silenceSkippingEnabled);

    // ONE-TIME CLEANUP of the old failure-block bug: transient stream failures
    // used to be written into this persisted blacklist, permanently hiding
    // tracks the user never disliked (silent auto-skips). Real dislikes are
    // always ALSO in the intelligence blacklist (dontRecommend writes both),
    // so any player-layer id missing there is a stale failure block → drop it.
    // Runs delayed and only once the intelligence state has actually loaded.
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

    if (current != null && fullQueue.isNotEmpty) {
      try {
        await _loadAndPlay(current, playImmediately: false);
        
        if (accurateResumePosMs > 0) {
          Future.delayed(const Duration(milliseconds: 300), () async {
            await NativeAudioEngine.seek(Duration(milliseconds: accurateResumePosMs));
            final restored = Duration(milliseconds: accurateResumePosMs);
            currentState = currentState.copyWith(position: restored);
            // The progress bar reads this ValueNotifier directly; without it the
            // restored track showed 0:00 until playback started ticking.
            currentPositionProvider.value = restored;
          });
        }
      } catch (e) {
        print('WARN: Hardware queue restore failed: $e');
      }
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

    // Recently played, WITH absolute play times
    //
    // v2 stores `{s: song, t: epochMs}` per entry. v1 (a bare song list, no
    // times) is still written so that DOWNGRADING to an older build does not
    // silently lose the trail — it costs a few KB and removes a one-way door.
    //
    // v2 is the key that goes to the cloud; see CloudSyncService._stringKeys.
    final trimmedHistory = currentState.history.take(_kHistoryCap).toList();
    // Drop stamps for tracks that have fallen off the end, so the map cannot
    // grow without bound across a long session.
    final liveIds = trimmedHistory.map((s) => s.id).toSet();
    _historyPlayedAt.removeWhere((id, _) => !liveIds.contains(id));
    await prefs.setString(
        'auvy_history_v2',
        jsonEncode(trimmedHistory
            .map((s) => {
                  's': s.toMap(),
                  // 0 = "played, time unknown" (restored from a v1 backup).
                  // Never `now`: stamping an old play with the current time would
                  // invent history that did not happen.
                  't': _historyPlayedAt[s.id] ?? 0,
                })
            .toList()));
    await prefs.setString('auvy_history', jsonEncode(
        trimmedHistory.map((s) => s.toMap()).toList()));
    // AND PUSH IT. Nothing in this file scheduled a backup, so history only
    // reached the cloud when something ELSE happened to trigger one (a library
    // edit, an intelligence save). Someone who only listens edits nothing, so
    // their trail could lag indefinitely. scheduleBackup is debounced 30s and
    // rate-limited to one push per 5 minutes, so calling it per save is exactly
    // what it is for — the same thing LibraryProvider._saveToDisk does.
    CloudSyncService.instance.scheduleBackup();
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
    
    try {
      if (currentState.currentSong != null) {
        await prefs.setString('player_resume_song', jsonEncode(currentState.currentSong!.toMap()));
        await prefs.setInt('player_resume_position_ms', currentState.position.inMilliseconds);
        await prefs.setString('player_resume_source', currentState.playbackSource);
        // The NAME that pairs with the source above. See the restore side in
        // _restoreResumeState for why saving one without the other showed a
        // resumed session the wrong location.
        await prefs.setString('player_resume_location', currentState.locationName ?? '');
        await prefs.setString('player_resume_context_title', currentState.contextTitle ?? '');
      }
      // Keep the podcast bookmark fresh too, so an app kill mid-episode still
      // resumes correctly the NEXT time this episode is opened.
      final cs = currentState.currentSong;
      if (cs != null && cs.isSpokenWord) {
        unawaited(_savePodcastPosition(cs, currentState.position));
      }
    } catch (e) {
      print('WARN: Failed to persist resume state: $e');
    }
  }

  void setCacheLimit(int mb) {
    currentState = currentState.copyWith(maxCacheSizeMB: mb);
    AudioCacheManager().maxCacheSizeMB = mb;
    // A lowered limit takes effect NOW rather than at the next cache write or
    // the next five-minute sweep, so the number on screen describes the cache
    // the user actually has. The slider cannot go below what is already cached,
    // so in practice this only ever trims the last megabyte of rounding.
    AudioCacheManager().enforceCacheLimit(
        currentPlayingId: currentState.currentSong?.id);
    _saveSettingsDebounced();
  }

  void _saveSettingsDebounced() {
    _persistenceTimer?.cancel();
    _persistenceTimer =
        Timer(const Duration(seconds: 2), () => _saveSettings());
  }

  // ==============================================================
  // CACHE CLEANUP TIMER  (every 5 min)
  // ==============================================================
  /// Keep the user's most-played tracks ("My Top 50") pinned (never auto-evicted)
  /// and — on Wi-Fi — proactively cached, so the cached-track count reliably
  /// meets or exceeds My Top 50 (the behaviour the user expects). [download]
  /// gates the network-heavy proactive caching (skipped at launch / on mobile
  /// data / data-saver-always) while pinning is always refreshed.
  Future<void> _refreshTopTrackCaching({required bool download}) async {
    try {
      final intel = ref.read(intelligenceProvider);
      final top = computeTop50(
        intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
      _cacheManager.pinnedSongIds = top.map((s) => s.id).toSet();
      if (download && top.isNotEmpty) {
        final conn = ref.read(connectivityProvider);
        if (conn.isWifi && !conn.isOffline &&
            conn.dataSaverMode != DataSaverMode.always) {
          // Fire-and-forget; internally capped + spaced so it can't storm data.
          _cacheManager.ensureTopTracksCached(top);
        }
      }
    } catch (e) {
      print('WARN: Top-track pin/cache refresh failed: $e');
    }
  }

  /// Put ONE playable file on disk ahead of the wake-up alarm.
  ///
  /// THIS IS WHAT MAKES THE ALARM AN ALARM. The music is played natively by
  /// AlarmAudioService at the exact minute, with Flutter not running, so it
  /// cannot resolve a stream, and it must not need to. A signed googlevideo url
  /// is bound to the egress IP and expires in hours, the phone may be in
  /// airplane mode, and YouTube may simply be unreachable at 07:00. So the audio
  /// is fetched while the app is alive and awake, and the alarm only has to open
  /// a file.
  ///
  /// [pool] is the caller's taste-ordered candidate list; an explicit pick
  /// (source == 'song') overrides it. Cheap to call on every resume: it returns
  /// immediately unless the file is missing, stale, or for the wrong track.
  Future<void> prepareAlarmTrack(List<Song> pool) async {
    if (!AlarmService.enabled) {
      await AlarmService.clearPreparedTrack();
      return;
    }
    try {
      // An explicit choice pins exactly which track is prepared. For a collection
      // that is its FIRST track, so waking to an album starts at track one —
      // preparing a random track of it would start the album in the middle.
      final Song? want = AlarmService.source == 'song'
          ? AlarmService.pickedSong
          : (AlarmService.source == 'collection' && pool.isNotEmpty
              ? pool.first
              : null);
      final candidates = want != null ? <Song>[want] : pool;
      // States this decision out loud. Every branch below is a silent early
      // return, so without it "the alarm has no audio" and "the audio was
      // already there" look identical from the outside.
      final needs = await AlarmService.needsPreparation(wantId: want?.id);
      print('alarm prepare: source=${AlarmService.source} '
          'want="${want?.title ?? '(any)'}" have="${await AlarmService.preparedTitle()}" '
          'candidates=${candidates.length} needsPrep=$needs');
      if (candidates.isEmpty) return;
      if (!needs) return;

      final song = want ?? (List<Song>.of(candidates)..shuffle()).first;

      // Already downloaded or cached? Copy the bytes — no network at all, and
      // it means a chosen song from their library is ready instantly.
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
      // Never let this break a resume. The alarm still rings — on the system
      // alarm tone — if no track was ever prepared.
      print('WARN: alarm track prepare failed: $e');
    }
  }

  void _startCacheCleanup() {
    // Pin top tracks early (don't download at launch) so eviction respects them
    // from the first cleanup onward.
    _refreshTopTrackCaching(download: false);
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      // Refresh pins + top up the top-track cache before pruning below.
      await _refreshTopTrackCaching(download: true);
      try {
        // Re-measure against disk first, then trim by MEASURED BYTES.
        //
        // This used to prune by a guess, AND against the wrong total.
        //
        // It compared getCacheSize(), which counts DOWNLOADS too — against the
        // cache limit, then kept `limit ÷ 5` tracks on a "~5 MB per track"
        // assumption. Two failures compounded: downloads the limit does not
        // govern could put the cache permanently "over", and the fix was a track
        // COUNT that has no fixed relationship to megabytes, so it either left
        // the cache over the limit or threw away tracks that fitted.
        //
        // enforceCacheLimit measures the auto-cache alone and evicts
        // least-recently-used until it genuinely fits.
        await _cacheManager.reconcileCacheSizes();
        await _cacheManager.enforceCacheLimit(
            currentPlayingId: currentState.currentSong?.id);
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

    // What should the retried track do — play or stay paused? Callers that KNOW
    // the intent pass it ([intendedPlaying] = the playImmediately of the failed
    // play). Deriving it from isPlaying here read `false` in the auto-advance
    // case (the previous track had just ENDED), so the recovered next track
    // loaded paused — the "next song sits on pause until I press play" bug.
    // The launch-restore case still stays paused: it passes intendedPlaying
    // false explicitly via _loadAndPlay(playImmediately: false).
    final bool wasPlaying = intendedPlaying ?? currentState.isPlaying;
    // Bind recovery to the song that actually failed. If the user switches to a
    // different track during the backoff window, the pending retry must NOT
    // re-resolve and restart the NEW track from 0:00 (or pause it because
    // wasPlaying was captured from the old failure) — that was the random
    // "song restarted itself" glitch.
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
    // "No playable stream" is the resolver giving up — usually NOT a dead
    // track but a network blackout (Doze/Wi-Fi power-save kills DNS while
    // backgrounded; every client fallback SocketExceptions inside the audio
    // service and the loader wraps them all into this one generic message).
    // Verified live on-device: the same track resolved fine seconds later once
    // the radio woke. So it must never 5-min-block the track, and repeats
    // ACROSS tracks mean "hold and wait for network", not "skip the queue".
    final isResolveFailure = err.contains('no playable stream');

    // Retries self-guard on failedId, so a stale fire after the user moved on
    // is a no-op. Also armed as _pendingNetworkRetry: the connectivity
    // listener fires it INSTANTLY on network-restore instead of letting a
    // mid-backoff track sit paused for up to 30 extra seconds.
    void scheduleRetry(Duration delay) {
      void retry() {
        if (mounted && currentState.currentSong != null && currentState.currentSong?.id == failedId && !_isProcessingTransition) {
          print('Retrying "${currentState.currentSong?.title}" (attempt $_consecutiveErrors)');
          // Resume only if playback was actually running when the error hit
          // (preserves paused-on-launch; still resumes after a mid-song drop).
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
      // A format error is a REAL per-track failure — block + advance.
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
          // Third track in a row that won't RESOLVE: an outage the OS hasn't
          // reported yet. Hold this track (paused, spinner) and retry on a
          // slow cadence + instantly on connectivity restore — instead of
          // silently auto-skipping through the rest of the queue.
          print('STOP: $_autoAdvanceFailStreak consecutive tracks failed to resolve — treating as network outage, holding "${currentState.currentSong?.title}"');
          NativeAudioEngine.pause();
          currentState = currentState.copyWith(isLoading: true);
          _consecutiveErrors = 0;
          scheduleRetry(const Duration(seconds: 30));
          return;
        }
        // Resolve failures don't prove the track is bad — advance WITHOUT the
        // 5-minute block, so the same track plays normally when tried again.
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

    // In-memory, auto-expiring block — NOT the persisted dislike blacklist.
    // Writing failures into the persisted set meant a track that failed once
    // (flaky network moment) could stay blacklisted FOREVER if the app closed
    // before the old 5-minute un-block timer ran, silently skipping it on
    // every future play — the "auto-skips out of nowhere" bug.
    _failureBlocks[song.id] = DateTime.now().add(const Duration(minutes: 5));
    playNext();
  }

  // ==============================================================
  // Os media item sync
  // ==============================================================
  /// Duration to publish to the system media session: the engine's value when
  /// it has one, otherwise the catalogue's.
  ///
  /// WHY THE FALLBACK EXISTS — A SKIP FROM THE NOTIFICATION LOST THE SEEK BAR.
  ///
  /// playSong resets PlayerState.duration to zero, and the native engine only
  /// reports the real one on its first position tick, roughly two seconds later.
  /// Until then this published `null`, and a MediaItem carrying no duration is
  /// exactly what makes Android drop the seek bar and the timestamps from the
  /// media notification. broadcastState() does patch the duration in once the
  /// tick lands, but the panel does not re-lay-out a seek bar it has already
  /// drawn without one, so the controls stayed bare for the whole track.
  ///
  /// Reproduced with `adb shell input keyevent 87`: the session went
  /// `metadata: size=9` (no duration) and then `size=10` two seconds later,
  /// while the notification showed neither bar nor clock the entire time. An
  /// in-app skip looked fine only because the player page draws its own bar from
  /// PlayerState and never consults the session.
  ///
  /// Song.duration is the catalogue's own `m:ss` label and is already known for
  /// every queued track, so a skip can publish a real duration in the SAME
  /// frame instead of waiting for audio to start.
  ///
  /// Returns null rather than Duration.zero for anything unparseable — live
  /// radio has no duration, and setCurrentMediaItem substitutes its own value
  /// for that case.
  Duration? _mediaItemDuration(Song song, Duration fromEngine) {
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
  
    // Prefer the LOCAL cached cover file for the system notification/lock-screen:
    // a file:// URI loads instantly and reliably, whereas a large/slow network
    // thumbnail sometimes never renders in the media notification ("cover art
    // isn't rendered like in the player page"). Falls back to the network URL.
    //
    // getDisplayImage ONLY HAS A LOCAL FILE FOR DOWNLOADED TRACKS. For an
    // ordinary streamed track it returns the network URL, so the intent above was
    // silently not achieved in the common case, and a network artUri is exactly
    // what produces the artless first publish that Samsung's Now Bar caches
    // ("album art = null" while the player page shows the cover perfectly).
    //
    // MediaArtworkCache closes that gap by reusing the file cached_network_image
    // already wrote when the app displayed this cover. See that class for why the
    // two caches are separate and why only a file:// URI fixes it.
    var artPath = _cacheManager.getDisplayImage(song.id, song.image);
    if (artPath.startsWith('http')) {
      final local = MediaArtworkCache.localPath(artPath);
      if (local != null) {
        artPath = local;
      } else {
        // Genuinely cold cover (an autoplay pick whose art has never been drawn).
        // Publish now with the network URI so the notification is not held up,
        // then upgrade to a file URI as soon as the bytes land. Guarded on the
        // song still being current, so a fast skip cannot republish stale art.
        // UPGRADES THE CURRENT ITEM ONLY — DO NOT CALL _updateMediaItem HERE.
        //
        // The first version of this re-entered _updateMediaItem, which also
        // rebuilds the ENTIRE system queue: one MediaItem allocated per queued
        // track plus a platform-channel push, and with autoplay that queue is
        // 15-50 entries. So every track change did that work TWICE — once
        // immediately and once when the cover landed — for a change that only
        // ever affects the artUri of the track playing right now. That second
        // pass is a plausible source of the one-frame flicker reported around a
        // track transition, and it is pure waste either way.
        final cold = artPath;
        MediaArtworkCache.warm(cold).then((path) {
          if (path == null || !mounted) return;
          if (currentState.currentSong?.id != song.id) return;
          _upgradeCurrentArtwork(song, path);
        });
      }
    }
    final mediaItem = MediaItem(
      id:       song.id,
      album:    song.albumTitle.isNotEmpty ? song.albumTitle : 'Single',
      title:    song.title,
      artist:   song.artist,
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

    // Pre-fetch the NEXT few covers to disk.
    //
    // Without this, the upgrade path above still leaves every track's first
    // publish artless the first time it plays — most visibly for autoplay/radio
    // picks, whose covers the UI has never drawn, so nothing has put them in the
    // shared cache yet. Warming ahead means the file is already there when the
    // track becomes current and the very first publish carries the bitmap.
    //
    // Fire-and-forget, bounded inside warmAll, and a cache hit costs no network —
    // so this is cheap on the common path and only downloads what is genuinely
    // new. Deliberately NOT awaited: the notification must not wait on it.
    final idx = currentState.currentIndex;
    if (idx >= 0 && idx + 1 < currentState.queue.length) {
      MediaArtworkCache.warmAll(currentState.queue
          .skip(idx + 1)
          .map((s) => s.image)
          .where((u) => u.startsWith('http')));
    }
  }

  /// Re-publish ONLY the current media item, with its cover now on disk.
  ///
  /// The cheap half of [_updateMediaItem]: identical fields, but a `file://`
  /// artUri and deliberately NO updateQueue / setQueueIndex. The queue's own
  /// entries did not change — one track's artwork did, and rebuilding 15-50
  /// MediaItems plus a second platform-channel push to alter a single artUri is
  /// work nobody asked for. Doing it the expensive way meant every track change
  /// ran the full sync twice, which is the likely source of the one-frame flicker
  /// seen at a transition.
  void _upgradeCurrentArtwork(Song song, String localPath) {
    if (_audioHandler == null) return;
    // The track may have moved on between the download starting and finishing.
    if (currentState.currentSong?.id != song.id) return;
    (_audioHandler as AuvyAudioHandler).setCurrentMediaItem(MediaItem(
      id: song.id,
      album: song.albumTitle.isNotEmpty ? song.albumTitle : 'Single',
      title: song.title,
      artist: song.artist,
      // Same fallback as _updateMediaItem: this re-publish can land before the
      // engine's first tick, and republishing with a null duration would undo a
      // seek bar that was already showing.
      duration: _mediaItemDuration(song, currentState.duration),
      artUri: Uri.file(localPath),
    ));
  }

  // ==============================================================
  // Library / intelligence integration
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

    // Auto-download on like (opt-in): liking a track is the strongest signal
    // the user wants it available offline. Wi-Fi only and never for radio /
    // podcast streams, matching the auto-cache policy — liking on mobile data
    // must not start a background download.
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
        // Keep the current at index 0 in BOTH cases. When disliking the CURRENT
        // track, playNext() below treats queue[0] as "now playing" and advances
        // to queue[1], so if the current were omitted here, queue[1] would be
        // the SECOND upcoming and the first upcoming got silently skipped (the
        // "dislike current → skips an extra song" bug). The disliked track is
        // still removed from every segment + blacklisted, so it never returns.
        if (currentState.currentSong != null) currentState.currentSong!,
        ...newUser, ...newCtx, ...newAuto,
      ],
    );

    if (isCurrent) playNext();
    _saveSettings();
  }

  // ==============================================================
  // SETTINGS TOGGLES
  // ==============================================================
  /// Re-read persisted SETTINGS into state after a cloud RESTORE. Settings are
  /// normally read once at startup (before the login-gate restore runs), so
  /// without this a restored setting wouldn't apply until an app restart. Only
  /// touches SETTINGS — never the queue / current-song / session state.
  /// "Recently played" from disk, newest first, with [_historyPlayedAt] filled.
  ///
  /// v2 first (absolute play times), falling back to the v1 song-only list. The
  /// fallback matters on two paths: an install predating v2, and a restore from a
  /// cloud backup written by an older build. Order survives either way, so the
  /// strip looks right even when the times are unknown.
  ///
  /// Shared by the cold-start load and by [reloadSettings] — the restore path.
  /// Duplicating it was how the restore ended up NOT bringing history back until
  /// the next app launch.
  List<Song> _readHistory(SharedPreferences prefs) {
    _historyPlayedAt = {};
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
          // 0 = "played, time unknown". Kept OUT of the map rather than recorded
          // as an epoch-zero play, which would date the track to 1970.
          if (t > 0) _historyPlayedAt[song.id] = t;
        }
        return out.take(_kHistoryCap).toList();
      } catch (_) {
        // Corrupt v2 → fall through to v1 rather than losing the strip entirely.
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

  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    // HISTORY TOO — this runs after a cloud RESTORE.
    //
    // A restore writes the backed-up prefs and then calls this to pull them into
    // live state. History was not read here, so a restored "Recently played"
    // stayed invisible until the next cold start — the data was on disk and the
    // app simply never looked.
    final restoredHistory = _readHistory(prefs);
    final crossfade     = prefs.getBool('auvy_crossfade') ?? false;
    final crossfadeSec  = prefs.getInt('auvy_crossfade_duration') ?? 5;
    final normalization = prefs.getBool('auvy_normalization') ?? true;
    final qualityIdx    = (prefs.getInt('auvy_audio_quality') ?? AudioQuality.auto.index)
        .clamp(0, AudioQuality.values.length - 1);
    final gapless       = prefs.getBool('auvy_gapless') ?? true;
    final autoPlayConn  = prefs.getBool('auvy_autoplay_on_connect') ?? false;
    // AUDIO-ONLY IS NOW PERMANENT — the stored value is deliberately IGNORED.
    //
    // Music-video versions are no longer offered at all: there is one kind of
    // result, the audio one, so there is nothing to configure and no toggle to
    // find. Reading the old pref back would strand anyone who had switched
    // videos on in a mode the app no longer has a control for.
    const processVideos = false;
    final silenceSkip   = prefs.getBool('auvy_silence_skipping') ?? false;
    final pitch         = prefs.getDouble('auvy_pitch') ?? 1.0;
    final podcastSpd    = prefs.getDouble('auvy_podcast_speed') ?? 1.0;
    final eqEnabled     = prefs.getBool('auvy_eq_enabled') ?? false;
    final eqBandsRaw    = prefs.getStringList('auvy_eq_bands');
    final eqBands       = eqBandsRaw != null
        ? eqBandsRaw.map(double.parse).toList()
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
      // Only replace the live trail when disk actually has one: reloadSettings
      // also runs for plain settings changes, and clobbering a session-built
      // history with an empty list would erase what the user just played.
      history: restoredHistory.isNotEmpty ? restoredHistory : currentState.history,
      silenceSkippingEnabled: silenceSkip,
      pitch: pitch,
      podcastSpeed: podcastSpd,
      eqEnabled: eqEnabled,
      eqBands: eqBands,
      maxCacheSizeMB: cacheLimit,
    );
    SearchService.processVideos = processVideos;
    // The settings-revision reload path has to mirror the cold-load path above,
    // or toggling Shorts in Settings would not take effect until a restart.
    SearchService.hideShorts = prefs.getBool('auvy_hide_shorts') ?? true;
    NativeAudioEngine.setEqualizer(eqEnabled, eqBands);
    NativeAudioEngine.setPitch(pitch);
  }

  void setAudioQuality(AudioQuality quality) {
    if (currentState.audioQuality == quality) return; // no actual change
    currentState = currentState.copyWith(audioQuality: quality);
    _saveSettings();
    // Drop cached stream URLs (Dart + native) so the NEXT resolve re-picks the
    // format for the new quality. Cached googlevideo URLs are quality-agnostic
    // and would otherwise keep serving the old bitrate until they expire (~6h).
    // The current track keeps playing from its buffer; the change lands on the
    // next (re)resolve — mirrors the network-switch invalidation.
    _audioService.invalidateAllStreams();
  }

  void toggleCrossfade() {
    currentState = currentState.copyWith(crossfadeEnabled: !currentState.crossfadeEnabled);
    _saveSettings();
  }

  void setCrossfadeDuration(Duration duration) {
    currentState = currentState.copyWith(crossfadeDuration: duration);
    _saveSettings();
  }

  // NOTE: toggleExplicitPreference() was removed — explicit/original versions
  // are ALWAYS preferred (explicitContentPreferred is permanently true and no
  // longer persisted, so a stale saved `false` can't disable it either).

  /// Whether connecting headphones / a Bluetooth device auto-resumes playback.
  /// Off by default (see [PlayerState.autoPlayOnConnect]).
  void setAutoPlayOnConnect(bool enabled) {
    currentState = currentState.copyWith(autoPlayOnConnect: enabled);
    _saveSettings();
  }

  // NOTE: toggleProcessVideos() was removed along with its Settings row.
  // Audio-only is not a mode any more, it is how the app works — every result is
  // the audio version. processVideosEnabled stays in state (always false) because
  // the conform logic reads it; it simply has no way to become true.

  // ── Sleep timer (field lives on PlayerNotifier — extensions can't hold
  // instance state; part files share the library so `_sleepTimer` is visible).

  /// Arm (or with null, cancel) the sleep timer: playback pauses after
  /// [duration]. Session-only — deliberately not persisted, so a killed app
  /// never wakes up with a stale timer. Arming a duration clears any armed
  /// end-of-track sleep (the two modes are mutually exclusive).
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _restoreVolumeAfterSleepFade(); // cancelling mid-fade must not leave it quiet
    if (duration == null) {
      currentState = currentState.copyWith(clearSleepTimer: true);
      return;
    }
    currentState = currentState.copyWith(
      clearSleepTimer: true, // wipes endsAt/minutes/endOfTrack in one shot…
    );
    currentState = currentState.copyWith(
      sleepTimerEndsAt: DateTime.now().add(duration), // …then arm fresh
      sleepTimerMinutes: duration.inMinutes,
    );
    _sleepTimer = Timer(duration, () {
      if (!mounted) return;
      if (currentState.isPlaying) togglePlay(haptic: false);
      currentState = currentState.copyWith(clearSleepTimer: true);
      _restoreVolumeAfterSleepFade();
    });
    // FADE OUT into the pause instead of cutting the music dead — you're falling
    // asleep, a hard stop is exactly what wakes you up. Ramps over the final
    // _sleepFadeSeconds, and the volume is always restored afterwards so the
    // next play isn't silent.
    if (duration > const Duration(seconds: _sleepFadeSeconds + 2)) {
      _sleepFadeTimer?.cancel();
      _sleepFadeTimer = Timer(
        duration - const Duration(seconds: _sleepFadeSeconds),
        _startSleepFadeOut,
      );
    }
  }

  // A pinned format that is gone must NOT be asked for forever
  //
  // Refusing a re-resolve that returns a different content length is correct — a
  // different length is a different file, and continuing at the old byte offset
  // can only 403. But refusing is not RECOVERING: native re-asks every ~5s, and
  // the wrong answer was deterministic, so no number of retries could succeed.
  // Measured 2026-08-28: 53 minutes, 1,800 metadata requests, 27.2 MB, and
  // audio_stream at 0.00 MB the whole time. The pin outlived its format.
  //
  // Two bounds, fixing different halves: the COUNT decides when to stop
  // believing the pin and restart the track so a fresh resolve can pin a format
  // that exists; the COOLDOWN answers later attempts without a network call
  // while that restart is in flight, which is what actually stops the traffic.

  // A refusal is NOT a network fault
  //
  // After a burst of rapid skipping (2026-08-30), every InnerTube client refused
  // at once — UNPLAYABLE, LOGIN_REQUIRED, then error 400 on the signed-in
  // retry — while verifyAccess kept returning 200 on the same cookie and the
  // network was fine. YouTube had simply decided to say no for a while.
  //
  // Native then re-asked every five seconds, each attempt sweeping the whole
  // client chain: youtube_metadata reached 8.76 MB in one short session, almost
  // all of it refusals. The only useful response to "no" is to stop asking, so
  // this is the same shape as _pinCooldownMs — answer for free, no network.
  //
  // GLOBAL rather than per track: gating applies to the account or the egress
  // IP, and the transcript shows five different videos refused inside a minute.
  // A per-track counter would need five runs to learn what one already proves.
  static int _noStreamStreak = 0;
  static int _resolveCooldownUntilMs = 0;

  /// Consecutive whole-chain refusals before backing off.
  ///
  /// Three, not one: a single track really can be unavailable (region-locked,
  /// pulled, age-gated) while everything else plays, and that must stay a fast
  /// skip to the next track rather than a silence. Three in a row is no longer
  /// about one track.
  static const int _maxNoStreamStreak = 3;

  /// Doubling from 30s to 5 minutes. Gating lifts on the order of minutes, so a
  /// short first wait keeps a brief throttle from feeling like an outage, while
  /// the cap stops a long one from costing anything at all.
  static const int _resolveCooldownBaseMs = 30000;
  static const int _resolveCooldownMaxMs = 300000;

  static String? _pinFailId;
  static int _pinFailClen = 0;
  static int _pinFailCount = 0;

  /// How many times this pin has been given up on.
  ///
  /// Drives the escalating cooldown. Reset only when the pin changes or a resolve
  /// succeeds. Deliberately NOT reset by a lapsed cooldown, unlike
  /// [_pinFailCount] — that is what keeps the backoff growing across rounds
  /// instead of restarting a dead pin every 30 seconds forever.
  static int _pinGiveUps = 0;
  static int _pinCooldownUntilMs = 0;

  /// Refusals before the pin itself is treated as the stale thing.
  ///
  /// Three, not one: a genuinely transient mismatch (a CDN serving a neighbouring
  /// format for one request) should still be refused and retried, because a
  /// restart costs the listener a re-buffer. Three identical answers is no longer
  /// transient.
  static const int _maxPinRefusals = 3;

  /// How long to answer "no" for free after giving up on a pin. Long enough for
  /// the restart to prepare and re-pin, short enough that a real recovery is not
  /// blocked, and if the restart fails, the next window costs 1 request, not 600.
  ///
  /// Doubles per give-up up to [_pinCooldownMaxMs]: the refusal count is no
  /// longer reset when a cooldown lapses, so every later mismatch reaches the
  /// give-up. Without escalation that would restart the track every 30 seconds
  /// for as long as the pin stays dead.
  static const int _pinCooldownMs = 30000;
  static const int _pinCooldownMaxMs = 300000;


  // The app says it is playing; no sound is coming out
  //
  // WHY THIS EXISTS, and it is the most expensive gap the transcript exposed.
  // On 2026-08-28 playback was dead from 17:05 to 18:00 — 53 minutes — while the
  // app re-resolved a stream 615 times and moved 27.2 MB of metadata. The one
  // number that mattered, audio_stream, stayed at 0.00 MB the whole time.
  //
  // Every existing detector missed it, and each for a defensible reason:
  //   • onBuffering fires on BUFFERING transitions, and native never entered
  //     BUFFERING — the data source was failing before it got that far. That
  //     detector logged ONCE in nineteen hours, and not here.
  //   • onError never fired, because nothing errored; the resolver politely
  //     returned null and native politely asked again.
  //   • the heal counters never advanced, because no heal was ever attempted.
  //
  // Each of those watches a MECHANISM. This watches the OUTCOME: the state says
  // playing, the wall clock is moving, the playhead is not. That is true for
  // every cause — including causes not yet met, which is the point.
  void _checkForSilentPlayback() {
    final song = currentState.currentSong;
    // isLoading counts: a load that never finishes is exactly this failure, and
    // it is where the 53 minutes were actually spent.
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
    // Live radio has no playhead to advance, so it can never be judged this way.
    if (song.mediaKind == MediaKind.liveStream) {
      _silentTicks = 0;
      return;
    }
    // A 5s tick that moved the playhead less than a second is not progress —
    // the small allowance absorbs a rounding wobble at a track boundary.
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

    // Report every level, act once. A recovery that re-armed every 30s would be
    // its own loop, and this is the code path that has already demonstrated it
    // can spin, so the arming is deliberately narrow.
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

  /// Ticks of no playhead movement before it is worth saying out loud.
  ///
  /// Six, i.e. 30 seconds. Long enough that an ordinary slow load, a long
  /// buffering spell on poor signal, or a cold cache read is never reported;
  /// short enough that 53 minutes of silence becomes 30 seconds of silence.
  static const int _silentTicksToReport = 6;

  static String? _silentSongId;
  static int _silentPosMs = 0;
  static int _silentTicks = 0;

  /// Seconds of gentle volume ramp before a sleep timer pauses playback.
  static const int _sleepFadeSeconds = 20;

  /// Ramp the volume down over the final [_sleepFadeSeconds].
  ///
  /// DRIVEN BY THE CLOCK, NOT BY A STEP COUNT. Three things were wrong with
  /// the twenty-timer version this replaces:
  ///
  ///  • Nothing could cancel it. The timers were never stored, so cancelling the
  ///    sleep timer and arming a longer one left the old ramp running, and its
  ///    only bail-out test was "is a sleep timer armed?", which the NEW timer
  ///    satisfied. A fresh two-hour timer faded to near-silence in 20 seconds.
  ///  • A step counter drifts. Twenty chained delays on a busy main thread take
  ///    longer than twenty ticks, so the fade finished after the pause.
  ///  • A LINEAR gain ramp is not a linear fade. Perceived loudness follows
  ///    roughly the square root of amplitude, so `1 - i/steps` drops fast and
  ///    then crawls — audible as a lurch, which is the one thing a sleep fade
  ///    must not be.
  ///
  /// Recomputing the target from `sleepTimerEndsAt` every tick fixes all three,
  /// and has a fourth benefit: it re-asserts the volume continuously, so if a
  /// track change fires its own start-fade inside the window (which would
  /// otherwise reset the volume to full and strand the sleep fade) the next tick
  /// simply puts it back on curve.
  void _startSleepFadeOut() {
    _sleepFadeRamp?.cancel();
    if (!mounted) return;
    final endsAt = currentState.sleepTimerEndsAt;
    if (endsAt == null) return;
    // The level to fade FROM. Read once: currentState.volume is the user's
    // setting and is never written by the fade, so it stays a stable baseline.
    final baseline = currentState.volume;
    const totalMs = _sleepFadeSeconds * 1000;

    _sleepFadeRamp = Timer.periodic(const Duration(milliseconds: 250), (t) {
      // The timer was cancelled, re-armed, or the notifier is gone: stop and put
      // the volume back, or the next play would start silent.
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

  /// Sleep at END OF TRACK (Spotify-style): playback pauses when the current
  /// track finishes instead of advancing (see playNext). Arms exclusively —
  /// any running duration timer is cancelled.
  void setSleepAtEndOfTrack(bool enabled) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _restoreVolumeAfterSleepFade();
    currentState = currentState.copyWith(clearSleepTimer: true);
    if (enabled) {
      currentState = currentState.copyWith(sleepAtEndOfTrack: true);
    }
  }

  /// Wipe ALL in-memory playback data for a "Delete Account" reset: stops the
  /// engine and clears the queues, current song, history and blacklist so the
  /// debounced persistence writes an empty state (matching the cleared prefs)
  /// and the UI shows nothing playing — a true new-user state.
  Future<void> clearAllForAccountReset() async {
    try {
      await NativeAudioEngine.stop();
    } catch (_) {}
    _nativeLoadedSongId = null;
    _recoveryTimer?.cancel();
    _preloadTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepFadeTimer?.cancel();
    _sleepFadeRamp?.cancel();
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