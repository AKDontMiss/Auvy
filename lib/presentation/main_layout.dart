import 'dart:async';
import 'dart:io' show Platform;
import 'package:auvy/providers/download_provider.dart'; 
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/presentation/pages/login_gate_page.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/providers/data_usage_provider.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:auvy/services/audio_capture_service.dart';
import 'package:auvy/services/song_recognition_service.dart';
import 'package:auvy/presentation/widgets/song_recognition_sheet.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/widgets/connection_banner.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/listen_together_provider.dart'
    show listenTogetherProvider, LtRole;
import 'package:auvy/services/performance_monitor.dart';
import 'package:auvy/core/native_audio_engine.dart'
    show NativeAudioEngine; 
import 'package:auvy/presentation/pages/home_page.dart';
import 'package:auvy/presentation/pages/library_page.dart';
import 'package:auvy/presentation/pages/search_page.dart';
import 'package:auvy/presentation/widgets/auvy_nav_bar.dart';
import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:auvy/presentation/tutorial_tour.dart';
import 'package:auvy/presentation/widgets/mini_player.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/scroll_control_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/signing_reminder_provider.dart';
import 'package:auvy/providers/whats_new_provider.dart';
import 'package:auvy/providers/audiobook_provider.dart';
import 'package:auvy/presentation/pages/whats_new_page.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/presentation/pages/alarm_ringing_page.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/core/app_colors.dart';

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  static GlobalKey<NavigatorState>? activeTabNavigator;

  // Page transition: HYDRV's motion (see [HydrvTransition]) on the horizontal axis.
  // The incoming page arrives from 8% to the right while fading in; the covered page
  // drifts left to −4% while fading out. Everything moves one way, and the exit is
  // quicker than the entrance.
  //
  // Horizontal because this is a push (you went deeper; back returns you), matching
  // the platform back gesture. Arrivals in place keep the vertical rise: tab switches
  // (see [HydrvIndexedSwitch]) and the now-playing sheet.
  //
  // The covered page fades fully to 0, so two pages are never both painted over the
  // shared DynamicBackground.
  static Route<T> smoothRoute<T>(Widget page, {String? name, bool opaque = false}) {
    return PageRouteBuilder<T>(
      settings: name != null ? RouteSettings(name: name) : null,
      // Tab detail pages are non-opaque, compositing over the shared DynamicBackground so
      // the backdrop stays continuous. A page pushed on the root navigator (e.g.
      // Settings) has only MainLayout beneath, so it must be opaque, or the page below
      // shows through once the transition settles.
      opaque: opaque,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      // HYDRV's durations, verbatim: 180ms in, 160ms out. The reverse of a push
      // is a pop, so `reverseTransitionDuration` gets the exit timing.
      transitionDuration: HydrvMotion.enterDuration,
      reverseTransitionDuration: HydrvMotion.exitDuration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          HydrvTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        axis: Axis.horizontal,
        child: child,
      ),
    );
  }

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with WidgetsBindingObserver {
  // Which tab the app opens on.
  //
  // This initializer is a BEST GUESS, not the truth: `_initBackgroundServices()`
  // (which calls `ListeningPolicy.reloadFrom`) runs AFTER `runApp`, so on a fast
  // boot this can be read before prefs have loaded and fall back to Home. The
  // authoritative apply happens in initState. See `_applyDefaultTab`.
  int _selectedIndex = ListeningPolicy.defaultOpenTab;

  /// Set once the user taps a tab themselves, so a late-arriving preference can
  /// never yank them off the tab they just chose.
  bool _userChoseTab = false;
  DateTime? _lastPressedAt;
  StreamSubscription? _notificationSubscription;

  // One navigator key per tab, so each tab keeps its own history.
  final Map<int, GlobalKey<NavigatorState>> _navigatorKeys = {
    0: GlobalKey<NavigatorState>(),
    1: GlobalKey<NavigatorState>(),
    2: GlobalKey<NavigatorState>(),
  };

  /// Starts the walkthrough if something has armed it. Called only from
  /// [CoachTour.armedSignal] (Settings → "Play tutorial"); it never starts by itself.
  void _maybeStartTour() {
    if (!mounted || !CoachTour.armed || CoachTour.isRunning) return;
    CoachTour.armed = false;
    startAuvyTour(
      context,
      accent: ref.read(themeProvider),
      // Which tab is showing is this widget's own state to change.
      onTab: (i) {
        if (mounted) setState(() => _selectedIndex = i);
      },
      // Whether the player lessons can run, decided here: with nothing playing there's
      // no mini-player or player page, so those steps are left out.
      canOpenPlayer: ref.read(playerProvider).currentSong != null,
      openPlayer: () async {
        if (!mounted) return;
        if (ref.read(playerProvider).currentSong == null) return;
        _navigateToPlayer();
      },
      // The counterpart of openPlayer: `onEnter` runs in both directions, so steps that
      // need the player closed call this (otherwise stepping back out of the player
      // steps would spotlight a mini-player hidden behind the player page). A no-op when
      // the player isn't open, so every pre-player step can declare it.
      closePlayer: () async {
        if (!mounted || !AppNavigation.isPlayerOpen) return;
        Navigator.of(context).pop();
        // One frame for the route to actually leave, or the step measures the
        // mini player while the player page is still on top of it.
        await Future<void>.delayed(const Duration(milliseconds: 260));
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CoachTour.armedSignal.addListener(_maybeStartTour);
    accessRevokedProvider.addListener(_onRevokedSignal);
    // Tells the performance sampler what the app was doing: without it, screen-off
    // streaming and genuine idle look the same (no frames) but differ hugely in CPU.
    // See PerformanceMonitor.contextProbe. Registered here because this shell outlives
    // every page; cheap (three in-memory reads every 30 s, only when sampling is on).
    PerformanceMonitor.instance.contextProbe = _describeForPerf;
    _applyDefaultTab();
    _notificationSubscription = AudioService.notificationClicked.listen((clicked) {
      if (clicked) {
        final playerState = ref.read(playerProvider);
        if (playerState.currentSong != null) {
          _navigateToPlayer();
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // No tutorial on the first frame; _maybeStartTour is only wired to
      // CoachTour.armedSignal.

      final dataTracker = ref.read(dataUsageProvider.notifier);
      HttpPool().attachDataTracker(dataTracker);
      // Library's reload hook lives here rather than in library_page (which has
      // no initState). Home registers its own. Search is deliberately absent —
      // "reload" is meaningless for results that depend on a typed query.
      ref.read(tabReloadControlProvider.notifier).update((m) => {
            ...m,
            2: () async {
              final lib = ref.read(libraryProvider.notifier);
              await lib.reloadFromStorage();
              lib.forceRefreshAllFolders();
            },
          });
      // Was this launch an ALARM firing? Checked here rather than in main()
      // because starting playback needs the providers, which only exist once the
      // widget tree is up.
      _maybeStartAlarmPlayback();
      _refreshAlarmTrack();
      // Answer tile captures the moment they land, rather than when the user next
      // opens the app. See _handlePendingCapture.
      AudioCaptureService.listenForPendingCaptures();
      // The same serialised entry point as mount and resume, so the three callers can't
      // race.
      AudioCaptureService.onPendingReady = _maybeIdentifyPendingCapture;
      // At mount as well as on resume: a cold start delivers no "resumed" event (Flutter
      // reports changes, not the initial state), and tapping a "found" notification is
      // now always a cold start. `consumeFoundTap` is read-and-clear natively, so mount
      // and resume can't both navigate.
      _maybeOpenFoundAlbum();
      _maybeIdentifyPendingCapture();
      // The access check at mount too, for the same reason: a blocked account restarting
      // the app would otherwise never be checked. Forced past the throttle, which exists
      // to limit mid-session checks, not the launch check.
      _maybeEjectIfRevoked(force: true);
      // iOS: when the sideload signature runs out, and the reminders before it.
      ref.read(signingReminderProvider.notifier).refresh();
      // What's New: a notification tap opens the page; checks start a little
      // after launch so they never compete with the first screen.
      CloudSyncService.onHeld = _onBackupHeld;
      WhatsNewNotifier.attachChannel();
      WhatsNewNotifier.onOpenRequested = _maybeOpenWhatsNew;
      _maybeOpenWhatsNew();
      final whatsNew = ref.read(whatsNewProvider.notifier)..start();
      // Created now so it follows the player from the start: a chapter resumed
      // from the queue moves its book's bookmark without the page being opened.
      ref.read(audiobookLibraryProvider.notifier);
      Future.delayed(const Duration(seconds: 45), () {
        if (mounted) whatsNew.maybeCheck();
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Static callbacks, so they must not outlive this State.
    if (WhatsNewNotifier.onOpenRequested == _maybeOpenWhatsNew) {
      WhatsNewNotifier.onOpenRequested = null;
    }
    if (CloudSyncService.onHeld == _onBackupHeld) CloudSyncService.onHeld = null;
    CoachTour.armedSignal.removeListener(_maybeStartTour);
    accessRevokedProvider.removeListener(_onRevokedSignal);
    _notificationSubscription?.cancel();
    // The monitor is a singleton and outlives this State, so a probe left
    // behind would `ref.read` a disposed container on its next tick.
    PerformanceMonitor.instance.contextProbe = null;
    super.dispose();
  }

  /// Last value of the paused-position counter, so the perf line can report a
  /// RATE. A cumulative total only says something happened at some point; a
  /// per-sample delta says whether it is still happening.
  int _lastPausedPosCount = 0;

  /// One line of "what was running", for the perf sampler.
  ///
  /// Deliberately terse and deliberately SILENT about anything inactive: a
  /// Listen Together field that says "none" on every line for two days is the
  /// same fault as a warning that fires on a normal event — it trains the
  /// reader to skip the column. What is absent is not happening.
  String _describeForPerf() {
    final p = ref.read(playerProvider);
    final parts = <String>[];

    // The field the probe exists for. Checked most-specific first: a stalled track is
    // also `isPlaying`, and a loading one is more interesting than paused.
    if (p.currentSong == null) {
      parts.add('no track');
    } else if (p.isStalled) {
      parts.add('audio STALLED');
    } else if (p.isLoading) {
      parts.add('audio loading');
    } else if (p.isPlaying) {
      parts.add('audio PLAYING');
    } else {
      parts.add('audio paused');
    }

    // Queue depth, because an autoplay top-up that keeps re-running is a cost
    // that shows up as CPU with nothing else in the log to explain it.
    if (p.queue.isNotEmpty) parts.add('q${p.queue.length}');

    // Only while a session is live.
    final lt = ref.read(listenTogetherProvider);
    if (lt.role != LtRole.none) parts.add('lt ${lt.role.name}');

    // Only while a timer is set — it changes what "still playing at 3am" means.
    if (p.sleepTimerEndsAt != null) parts.add('sleep-timer set');
    if (p.sleepAtEndOfTrack) parts.add('sleep-at-track-end');

    // The position feed's drain detector, reported as a delta since the last sample.
    // A handful per interval is normal (a seek while paused, a duration resolving); a
    // steady ~60 per 30 s means the feed failed to stop.
    final pos = NativeAudioEngine.positionUpdatesWhilePaused;
    final delta = pos - _lastPausedPosCount;
    _lastPausedPosCount = pos;
    if (delta > 0) parts.add('pos-while-paused $delta');

    return parts.join(' · ');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check for a pending alarm on every resume: `onNewIntent` sets the native flag
    // when an alarm arrives while Auvy is already running in the background.
    // `consumePendingAlarm` is read-and-clear natively, so it can't fire twice.
    if (state == AppLifecycleState.resumed) {
      _maybeStartAlarmPlayback();
      // Keep tomorrow's alarm audio on disk. Every resume, because there is no
      // background job to rely on and the alarm has to work on a morning the
      // user never opened the app the night before.
      _refreshAlarmTrack();
      _maybeIdentifyPendingCapture();
      _maybeOpenFoundAlbum();
      _maybeEjectIfRevoked();
      // A SideStore refresh re-signs the app with a new expiry.
      ref.read(signingReminderProvider.notifier).refresh();
      _maybeOpenWhatsNew();
      ref.read(whatsNewProvider.notifier)
        ..refreshPermission()
        ..maybeCheck();
      _catchUpWithOtherDevices();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // The position is saved every 15-30 s while playing; leaving the app saves
      // it exactly, in case the system ends the process.
      ref.read(playerProvider.notifier).persistPositionNow();
    }
  }


  /// Revocation mid-session: the approval check also runs on every resume
  /// (throttled), so an account blocked or put back in the queue doesn't keep using an
  /// open app for days. An account verdict (pending / blocked / closed) ends the
  /// session and returns to the sign-in page, which explains what happened.
  /// `unavailable` never ejects anyone: a Worker outage or dead network must not cost
  /// people their music.
  DateTime? _lastRevokeCheck;

  /// Fires the instant ANY code path sees a verdict, not only on resume —
  /// blocking someone mid-listen has to take effect while they are listening.
  void _onRevokedSignal() {
    final v = accessRevokedProvider.value;
    if (v == null || !mounted) return;
    // Consume it, or returning to the gate re-triggers this on every rebuild.
    accessRevokedProvider.value = null;
    _ejectTo(v.status, v.identity);
  }

  /// [force] skips the throttle. Used at launch, where the answer decides whether
  /// the app should be open at all — a recent check from the previous session is
  /// not evidence about this one.
  Future<void> _maybeEjectIfRevoked({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastRevokeCheck != null &&
        now.difference(_lastRevokeCheck!) < const Duration(minutes: 10)) {
      return;
    }
    _lastRevokeCheck = now;

    final notifier = ref.read(accountProvider.notifier);
    final access = await notifier.verifyAccess();
    if (!mounted) return;

    final revoked = access.status == 'pending' ||
        access.status == 'blocked' ||
        access.status == 'closed' ||
        access.status == 'device_revoked';
    if (!revoked) return;

    _ejectTo(access.status, access.identity);
  }

  /// Stop playback, drop the session, and replace the whole stack with the
  /// sign-in page carrying the verdict.
  Future<void> _ejectTo(String status, String? identity) async {
    // Stop the audio first, so the login page isn't shown with music still playing.
    try {
      ref.read(playerProvider.notifier).stopAndDismiss();
    } catch (_) {}
    // Drop the session so the sign-in page offers the account chooser again
    // rather than silently re-signing the account that was just refused.
    try {
      await SessionCookieManager().clearCookies();
    } catch (_) {}
    if (status == 'device_revoked') {
      try {
        await ref.read(accountProvider.notifier).resetDeviceSession();
      } catch (_) {}
    }
    if (!mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginGatePage(
          hasOnboarded: true,
          initialStatus: status,
          initialIdentity: identity,
        ),
      ),
      (route) => false,
    );
  }

  /// Opened by tapping a "song found" notification: go to that album and play it. The
  /// notification only carries title and artist, so the album is looked up here; if
  /// the lookup misses, the user still lands in Auvy. Playback is started by AlbumPage
  /// once its track list resolves (see [AlbumPage.autoplayTrack]), so the rest of the
  /// album queues behind it.
  DateTime? _lastCatchUp;
  bool _catchingUp = false;

  /// On returning to the app: if another device on the account has pushed since,
  /// pull it in (library, settings, and where it left off; see
  /// playback_handoff.dart). One document read to ask, at most once a minute.
  ///
  /// [held]: a push was just held because the other device pushed, which is
  /// already known, so no question and no wait.
  Future<void> _catchUpWithOtherDevices({bool held = false}) async {
    if (_catchingUp) return;
    final now = DateTime.now();
    if (!held &&
        _lastCatchUp != null &&
        now.difference(_lastCatchUp!) < const Duration(minutes: 1)) {
      return;
    }
    _lastCatchUp = now;
    _catchingUp = true;
    try {
      if (!held && !await CloudSyncService.instance.hasNewerBackup()) return;
      if (!mounted) return;
      print(held
          ? 'cloud: a push was held for another device\'s newer backup — merging it in'
          : 'cloud: another device backed up while this one was away — catching up');
      await ref.read(accountProvider.notifier).restoreCloudBackup();
    } finally {
      _catchingUp = false;
    }
  }

  void _onBackupHeld() => _catchUpWithOtherDevices(held: true);

  /// Opened by tapping a What's New notification (read-and-clear natively, so
  /// it opens once).
  Future<void> _maybeOpenWhatsNew() async {
    if (!await WhatsNewNotifier.consumeOpenRequest() || !mounted) return;
    AppNavigation.pushOnActiveTab(const WhatsNewPage(), name: 'whats-new');
  }

  Future<void> _maybeOpenFoundAlbum() async {
    final query = await AudioCaptureService.consumeFoundTap();
    if (query == null || query.trim().isEmpty || !mounted) return;
    try {
      final songs = await ref.read(searchServiceProvider).search(query, 'track');
      if (!mounted || songs.isEmpty) return;
      final song = songs.first;
      final album = ContentMenus.buildAlbumForSong(song);
      AppNavigation.pushOnActiveTab(
        AlbumPage(
          album: album,
          artistName: song.artist,
          fallbackTrack: song,
          // Tapping an answer is a request to HEAR it. Landing on the album and
          // waiting for a second tap made the notification feel like a bookmark
          // rather than a result.
          autoplayTrack: song,
        ),
        name: AppNavigation.albumTag(album),
      );
    } catch (_) {
      // Network hiccup — the user is in the app, which is the important part.
    }
  }

  /// The capture being identified right now, so the three triggers (mount, resume,
  /// native handoff) can't race. `takePendingCapture` is read-and-clear, so the first
  /// caller owns the capture through to a posted result and the others join its
  /// future.
  Future<void>? _captureWork;

  /// Identifies audio the quick-settings tile captured. The tile doesn't open the
  /// app (that would pause whatever was playing), so it saves raw PCM to disk and
  /// recognition happens here, when Auvy is next in front of the user.
  /// `takePendingCapture` clears the marker as it reads, so a capture is never
  /// identified twice.
  Future<void> _maybeIdentifyPendingCapture() {
    final inFlight = _captureWork;
    if (inFlight != null) return inFlight;
    final work = _handlePendingCapture();
    _captureWork = work;
    return work.whenComplete(() {
      if (identical(_captureWork, work)) _captureWork = null;
    });
  }

  Future<void> _handlePendingCapture() async {
    final pcm = await AudioCaptureService.takePendingCapture();
    if (pcm == null) {
      print('identify: nothing pending');
      return;
    }
    print('identify: took ${pcm.length} bytes of pending capture');

    // `mounted` and `isCurrent` don't mean "on screen" (both hold while backgrounded);
    // only the lifecycle state says whether a sheet can be seen.
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

    // One lookup per question: the sheet runs its own recognition (with progress and
    // artwork) and posts the tile notification itself.
    if (resumed && mounted) {
      print('identify: on screen — handing to the result sheet');
      showPendingCaptureResult(context, pcm);
      return;
    }

    // Never discard a capture already taken (the take is destructive): off screen,
    // identify here so the notification can carry the answer.
    print('identify: not on screen — recognising here for the notification');
    try {
      final outcome = await SongRecognitionService().recognizeFromPcm(pcm);
      final r = outcome.result;
      if (r != null) {
        await AudioCaptureService.notifyFound(r.title, r.artist);
      } else {
        // Say what happened. A silent failure looks identical to a tile that does
        // not work, which is how a feature gets abandoned.
        await AudioCaptureService.notifyFound(
            'No match', outcome.message ?? 'Could not identify that audio.');
      }
    } catch (e) {
      print('WARN: tile capture identify failed: $e');
      await AudioCaptureService.notifyFound(
          'Could not identify', 'Something went wrong listening.');
    }
  }

  /// Applies the "Open on" preference, reading prefs directly because
  /// `ListeningPolicy.reloadFrom` runs after `runApp`, so MainLayout can be built
  /// first. Skipped once the user has picked a tab.
  Future<void> _applyDefaultTab() async {
    await ListeningPolicy.load();
    if (!mounted || _userChoseTab) return;
    final want = ListeningPolicy.defaultOpenTab;
    if (want != _selectedIndex) setState(() => _selectedIndex = want);
  }

  /// True while the ringing screen is on top; guards re-entrancy (see
  /// [_maybeStartAlarmPlayback]).
  bool _alarmScreenUp = false;

  /// Takes over the wake-up music if this launch came from the alarm. The native
  /// side answers true once per firing (read-and-clear), so a later resume can't
  /// restart it. Picks a source in taste order, each falling back to the next,
  /// and finally to autoplay, so the alarm never stays silent.
  Future<void> _maybeStartAlarmPlayback() async {
    // The alarm is usually already playing: AlarmAudioService starts it natively at
    // the set minute, before Flutter runs. Dart takes over: find out what's ringing and
    // how far in, stop the native player, and continue the same track in the normal
    // pipeline (queue, artwork, controls).
    //
    // Re-entrancy: this runs on every resume and awaits a Navigator.push that stays
    // pending while the alarm screen is up, so without the guard backgrounding and
    // returning would push a second ringing screen.
    if (_alarmScreenUp) return;

    final state = await AlarmService.audioState();
    final ringing = state['active'] == true;
    // Read-and-clear, so a later resume can't restart the alarm music.
    final fired = await AlarmService.consumePendingAlarm();
    if (!mounted) return;

    // Only show the screen while the alarm is actually ringing: the `fired` flag
    // outlives the audio (stopped from the notification, or by the 15-minute cap), and
    // a silent full-screen alarm on the next launch would just be confusing. Clean up
    // the lock-screen flags and say nothing.
    if (!ringing) {
      if (fired) await AlarmService.exitAlarmScreen();
      return;
    }

    // The screen doesn't depend on the library: it needs one song for artwork at most,
    // and renders without it.
    final ringingId = state['videoId'] as String?;
    Song? ringingSong;
    if (ringingId != null && ringingId.isNotEmpty) {
      ringingSong = AlarmService.pickedSong?.id == ringingId
          ? AlarmService.pickedSong
          : _alarmPool().where((s) => s.id == ringingId).firstOrNull;
    }

    // A hardware key can stop the alarm underneath us (volume rocker — see
    // MainActivity.dispatchKeyEvent). Without this the audio stopped and the
    // ringing screen stayed on a silent phone.
    final nav = Navigator.of(context, rootNavigator: true);
    AlarmService.listenForExternalStop();
    AlarmService.onStoppedExternally = () {
      if (nav.canPop()) nav.pop(AlarmAction.stop);
    };

    _alarmScreenUp = true;
    final action = await nav
        .push<AlarmAction>(
      PageRouteBuilder(
        opaque: true,
        // No slide-in. An alarm appears; it does not arrive from the right.
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => AlarmRingingPage(
          song: ringingSong,
          accent: ref.read(themeProvider),
        ),
      ),
    );

    // Both outcomes end in silence, AND neither starts the player.
    // An alarm that turns itself into a listening session keeps playing while you
    // are in the shower. Stop means stop; snooze means stop and come back.
    _alarmScreenUp = false;
    AlarmService.onStoppedExternally = null;
    if (action == AlarmAction.snooze) {
      await AlarmService.snooze();
    } else {
      await AlarmService.stopAudio();
    }

    // Leave nothing behind: booting Flutter for the alarm screen also brings up the
    // media session, so tear the player down afterwards (only if nothing was playing
    // before the alarm).
    if (ref.read(playerProvider).currentSong == null) {
      try {
        ref.read(playerProvider.notifier).stopAndDismiss();
      } catch (_) {}
    }

    // Then get out of the way, like a clock app. Native only backs out when the alarm
    // launched the app; if Auvy was already open, it stays.
    await AlarmService.exitAlarmScreen();
  }

  /// Candidate tracks for the alarm, in taste order, each falling back to the
  /// next — an alarm that stays silent because one list happened to be empty is
  /// the failure mode that actually matters here.
  List<Song> _alarmPool() {
    final lib = ref.read(libraryProvider);
    final intel = ref.read(intelligenceProvider);

    List<Song> pool = const [];
    switch (AlarmService.source) {
      case 'song':
        final picked = AlarmService.pickedSong;
        if (picked != null) return <Song>[picked, ...lib.likedSongs];
        pool = lib.likedSongs;
        break;
      // A saved album or playlist, in its own order. The alarm plays its FIRST
      // track (that is what gets pre-cached), and the rest becomes the queue — so
      // waking to an album starts where the album starts, not somewhere in it.
      case 'collection':
        final name = AlarmService.pickedCollection;
        final tracks = name == null ? const <Song>[] : (lib.playlistSongs[name] ?? const <Song>[]);
        if (tracks.isNotEmpty) return tracks;
        pool = lib.likedSongs;
        break;
      case 'top':
        final ranked = intel.playCounts.entries
            .where((e) => intel.trackMetadata.containsKey(e.key))
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        pool = ranked.take(40).map((e) => intel.trackMetadata[e.key]!).toList();
        break;
      case 'recent':
        pool = ref.read(playerProvider).history;
        break;
      case 'liked':
      default:
        pool = lib.likedSongs;
    }
    if (pool.isEmpty) pool = lib.likedSongs;
    if (pool.isEmpty) pool = ref.read(playerProvider).history;
    return pool;
  }

  /// Keep a playable file on disk for the next alarm. Cheap on most resumes —
  /// it returns immediately unless the file is missing, stale or for the wrong
  /// track, so calling it on every resume is what keeps the alarm dependable
  /// without a background job.
  Future<void> _refreshAlarmTrack() async {
    // Load the alarm prefs rather than trusting the static: AlarmService.reloadFrom
    // runs after runApp, so on a cold start this can run first (same reason as
    // _applyDefaultTab).
    await AlarmService.load();
    if (!mounted || !AlarmService.enabled) return;
    // iOS before 26 can't ring it, so there's nothing to download for; and a
    // one-off alarm that already rang is switched off rather than re-set.
    if (!await AlarmService.isSupported()) return;
    await AlarmService.syncRungOnce();
    if (!mounted || !AlarmService.enabled) return;
    final pool = _alarmPool();
    // Fire and forget: a download must never hold up a resume.
    ref.read(playerProvider.notifier).prepareAlarmTrack(pool);
  }

  void _navigateToPlayer() {
    if (!mounted) return;
    // A PlayerPage is already showing (opened via mini-player OR a previous
    // notification tap) — bring nothing new; just keep the existing one. This is
    // what stops the player from stacking on every notification tap.
    if (AppNavigation.isPlayerOpen) return;

    final nav = Navigator.of(context, rootNavigator: true);
    // Belt-and-suspenders: pop any stray /player route before pushing one.
    nav.popUntil((route) => route.settings.name != AppNavigation.playerRouteName);
    nav.push(AppNavigation.playerRoute());
  }

  // When the active tab was last re-tapped, for "tap again to reload".

  /// When the active tab was last re-tapped, so a SECOND tap can mean "reload"
  /// (see [_onItemTapped]).
  DateTime? _lastTabRetapAt;
  int? _lastRetapIndex;

  /// How long after a scroll-to-top another tap still counts as "…and reload".
  static const Duration _retapReloadWindow = Duration(seconds: 2);

  void _onItemTapped(int index) {
    if (index == _selectedIndex) {
      // Tapping the ALREADY-SELECTED tab, in escalating order:
      //   1. inside a sub-page  → pop back to the tab's root
      //   2. at the root        → scroll to the top
      //   3. tap again quickly  → RELOAD the tab's content
      final navigator = _navigatorKeys[index]?.currentState;
      if (navigator != null && navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
        _lastTabRetapAt = null;
        return;
      }

      final now = DateTime.now();
      final isSecondTap = _lastRetapIndex == index &&
          _lastTabRetapAt != null &&
          now.difference(_lastTabRetapAt!) <= _retapReloadWindow;

      if (isSecondTap) {
        final reload = ref.read(tabReloadControlProvider)[index];
        if (reload != null) {
          HapticService.medium();
          _lastTabRetapAt = null; // consume it — don't reload twice in a row
          reload();
          return;
        }
      }

      _lastTabRetapAt = now;
      _lastRetapIndex = index;
      if (index == 0) {
        final scrollCallback = ref.read(homeScrollControlProvider);
        if (scrollCallback != null) scrollCallback();
      }
      return;
    }
    _lastTabRetapAt = null;
    _userChoseTab = true; // a late "Open on" apply must not override this
    setState(() => _selectedIndex = index);
  }

  // Helper to wrap each page in a tab-specific Navigator
  Widget _buildTabNavigator(int index, Widget rootPage) {
    return Navigator(
      key: _navigatorKeys[index],
      onGenerateRoute: (settings) => MainLayout.smoothRoute(rootPage,
      ),
    );
  }


  /// Left-edge swipe to go back, iOS only: iOS has no system back button, and screens
  /// pushed with PageRouteBuilder have no Cupertino back gesture. A narrow translucent
  /// strip (taps still pass through), rightward flicks only, so it doesn't take the
  /// player page's horizontal drags. Android keeps its own back.
  Widget _withIosBackGesture(Widget child) {
    if (kIsWeb || !Platform.isIOS) return child;
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 22,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 150) _handleBack();
            },
          ),
        ),
      ],
    );
  }

  /// The one back implementation, shared by Android's system back and iOS's edge
  /// swipe, so there's a single tested traversal.
  void _handleBack() {

        // 1) Inside the current tab: step back one page, retracing the path within this
        //    tab.
        final currentNavigator = _navigatorKeys[_selectedIndex]?.currentState;
        if (currentNavigator != null && currentNavigator.canPop()) {
          currentNavigator.pop();
          return;
        }

        // 2) At the root of a NON-Home tab → return to Home. Reset the Home tab
        //    to its root first so the user always lands on a CLEAN home screen
        //    (never a leftover Album/Artist page) — that's the single, defined
        //    "exit point", and it makes the double-press-to-exit predictable.
        if (_selectedIndex != 0) {
          final home = _navigatorKeys[0]?.currentState;
          if (home != null && home.canPop()) {
            home.popUntil((route) => route.isFirst);
          }
          setState(() => _selectedIndex = 0);
          _lastPressedAt = null; // fresh two-press sequence once Home is reached
          return;
        }

        // 3) On the Home tab root: the first back shows "Press back again to exit"; a
        //    second within 2 s exits.
        // Android only: an iOS app doesn't close itself, so on iOS a swipe at the Home root
        // does nothing.
        if (!Platform.isAndroid) return;

        final now = DateTime.now();
        if (_lastPressedAt == null || now.difference(_lastPressedAt!) > const Duration(seconds: 2)) {
          _lastPressedAt = now;
          AnimatedToast.show(context,
              text: 'Press back again to exit',
              icon: Icons.exit_to_app,
              color: ref.read(themeProvider));
          return;
        }

        SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    MainLayout.activeTabNavigator = _navigatorKeys[_selectedIndex];
    
    final themeColor = ref.watch(themeProvider); 
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bool isKeyboardOpen = keyboardHeight > 0;
    final navBarHeight = 70.0 + MediaQuery.of(context).padding.bottom;
    final totalBottomHeight = navBarHeight;
    final hasSong = ref.watch(playerProvider.select((p) => p.currentSong != null));
    final miniPlayerVisible = ref.watch(playerProvider.select((p) => p.miniPlayerVisible));
    
    return PopScope(
      canPop: false,
      // Use onPopInvokedWithResult: the deprecated onPopInvoked doesn't fire reliably
      // under Android 13+ predictive back, which let the OS exit the app directly from a
      // tab root.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },      child: _withIosBackGesture(DynamicBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false, 
          body: Stack(
            children: [
              // 1. Content / Pages (Bottom Layer)
              Positioned.fill(
                bottom: isKeyboardOpen ? keyboardHeight : totalBottomHeight,
                // Swallow the tab navigators' NavigationNotifications so they never reach the
                // framework's system-back dispatcher. Each inner Navigator reports "can't handle
                // pop" at its root, which under Android 13+ predictive back would tell the OS the
                // app can't handle back, so the next back from a Search/Library root would exit
                // the app. The root PopScope (canPop: false) handles back and forwards pops to the
                // active tab.
                child: NotificationListener<NavigationNotification>(
                  onNotification: (_) => true,
                  // Tab switches use HYDRV's fragment transition (its original use: moving between
                  // bottom-nav destinations). The IndexedStack underneath keeps every tab's
                  // navigator stack and scroll position.
                  child: HydrvIndexedSwitch(
                    index: _selectedIndex,
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: [
                        _buildTabNavigator(0, const HomePage()),
                        _buildTabNavigator(1, const SearchPage()),
                        _buildTabNavigator(2, const LibraryPage()),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. Download progress banner
              Consumer(
                builder: (context, ref, child) {
                  final downloadState = ref.watch(downloadProvider);
                  final bottomPadding = totalBottomHeight + (hasSong ? 85 : 15);
                  
                  return AnimatedPositioned(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutExpo,
                    bottom: downloadState.isDownloading ? bottomPadding : -100,
                    left: 16,
                    right: 16,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      // A solid banner, since it floats over scrolling pages while a download runs (a
                      // BackdropFilter would re-blur every scroll frame).
                      child: Container(
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFF121212).withOpacity(0.96),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withOpacity(0.08)),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 10)),
                            ],
                          ),
                          child: Stack(
                            children: [
                              // Text & Icon Content
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
                                      child: const Icon(Icons.download_rounded, color: Colors.white, size: 16),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            downloadState.collectionKind.isEmpty
                                                ? 'Downloading ${downloadState.currentItemName}'
                                                : 'Downloading ${downloadState.collectionKind.toLowerCase()} · ${downloadState.currentItemName}',
                                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          // The preparing stage needs its own sentence.
                                          //
                                          // Stream resolution happens before anything is
                                          // saved, and it is the slow part. Saying "0 of 20
                                          // tracks saved" throughout it is why this looked
                                          // broken rather than busy.
                                          Text(
                                            downloadState.phase == DownloadPhase.preparing
                                                ? (downloadState.totalTracks > 0
                                                    ? 'Preparing ${downloadState.downloadedTracks} of ${downloadState.totalTracks}…'
                                                    : 'Preparing…')
                                                : '${downloadState.downloadedTracks} of ${downloadState.totalTracks} tracks saved',
                                            style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 11, fontWeight: FontWeight.w500),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Progress Bar
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    // While preparing there is no honest
                                    // fraction of SAVED tracks to draw, so the
                                    // bar tracks resolve progress instead of
                                    // sitting at zero. DownloadState.fraction
                                    // returns null in that stage; this uses the
                                    // resolve ratio so the bar always moves.
                                    final progress = downloadState.totalTracks > 0
                                        ? (downloadState.downloadedTracks / downloadState.totalTracks).clamp(0.0, 1.0)
                                        : 0.0;
                                    return Container(
                                      height: 3, width: constraints.maxWidth, color: Colors.white.withOpacity(0.05), alignment: Alignment.centerLeft,
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 300), height: 3, width: constraints.maxWidth * progress,
                                        decoration: BoxDecoration(
                                          color: themeColor,
                                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                                          boxShadow: [BoxShadow(color: themeColor.withOpacity(0.5), blurRadius: 8)],
                                        ),
                                      ),
                                    );
                                  }
                                ),
                              ),
                            ],
                          ),
                        ),
                    ),
                  );
                },
              ),

              // 3. NavBar with gradient
              if (!isKeyboardOpen)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Stack(
                    children: [
                      // Gradient Shadow
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [AppColors.matteBlack.withOpacity(0.0), AppColors.matteBlack],
                                stops: const [0.0, 0.4],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Tappable Nav Bar
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 24.0),
                          child: AuvyNavBar(
                            currentIndex: _selectedIndex,
                            onTap: _onItemTapped,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // 4. MiniPlayer — TOPMOST (moved down here so it renders above sub-page Scaffolds)
              if (hasSong)
                Positioned(
                  left: 0, 
                  right: 0, 
                  bottom: totalBottomHeight + 10, 
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (Widget child, Animation<double> animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    // No CoachAnchor here: the key lives on the container that draws the bar (see
                    // mini_player.dart), and adding it here too would register the same GlobalKey
                    // twice (a crash).
                    child: (hasSong && !isKeyboardOpen && miniPlayerVisible)
                      ? const MiniPlayer(key: ValueKey('active_miniplayer'))
                      : const SizedBox.shrink(),
                  ),
                ),

              // The connection banner sits ABOVE the mini player: it is a
              // transient announcement, and the one moment it matters most is
              // when playback has just stalled, which is exactly when the user
              // is looking at the player controls.
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: ConnectionBanner(),
              ),

            ],
          ),
        ),
      )
    ));
  }
}