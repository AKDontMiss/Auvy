import 'dart:async'; 
import 'package:auvy/providers/download_provider.dart'; 
import 'package:flutter/material.dart';
import 'package:auvy/providers/account_provider.dart';
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

  // Page transition — HYDRV's motion (see [HydrvTransition]), on the HORIZONTAL
  // axis: the incoming page arrives from 8% to the right while fading in, the
  // covered page keeps drifting left to −4% while fading out. Everything moves in
  // ONE direction, and the exit is quicker than the entrance, which is what reads
  // as "clean".
  //
  // Horizontal, not vertical, because this is a PUSH — you went somewhere deeper
  // and back returns you, which is exactly what sideways travel says and what the
  // platform back gesture already implies. Arrivals in place keep the vertical
  // rise: tab switches (see [HydrvIndexedSwitch] — nothing was pushed, so nothing
  // should look pushed) and the now-playing sheet, which rises because it is a
  // sheet.
  //
  // This replaced a scale-based pop (0.92 → 1.0 in, 1.0 → 1.05 out). The zoom
  // drew attention to the transition itself; a flat slide gets out of the way and
  // lets the content land.
  //
  // The transparent-scaffold constraint is unchanged and still respected: the
  // covered page fades fully to 0, so two pages are never both painted over the
  // shared DynamicBackground (the old "ghost/residue" bug).
  static Route<T> smoothRoute<T>(Widget page, {String? name, bool opaque = false}) {
    return PageRouteBuilder<T>(
      settings: name != null ? RouteSettings(name: name) : null,
      // Tab detail pages are NON-opaque: they composite over the shared
      // DynamicBackground so the backdrop stays continuous while contents
      // cross-fade. A page pushed on the ROOT navigator (e.g. Settings) has no
      // shared backdrop beneath it — only MainLayout, so it must be OPAQUE
      // (opaque:true) or the page underneath shows through its transparent
      // gaps. The transition still shows the page below DURING the animation
      // (the pop-in/out), then occludes it once settled.
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

  //  1. ADDED: Unique Navigator Keys for each tab to track their history independently
  final Map<int, GlobalKey<NavigatorState>> _navigatorKeys = {
    0: GlobalKey<NavigatorState>(),
    1: GlobalKey<NavigatorState>(),
    2: GlobalKey<NavigatorState>(),
  };

  /// Start the interactive walkthrough if something has armed it.
  ///
  /// Called both from the first frame (onboarding armed it before this widget
  /// existed) and from [CoachTour.armedSignal] (Settings → Replay tutorial arms it
  /// much later). Guarded so the two paths can't stack two tours.
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
      // The player-gesture steps need the real player on screen to point at. No
      // song playing → it can't open, its anchors never mount, and the engine
      // skips those steps instead of pointing at nothing.
      openPlayer: () async {
        if (!mounted) return;
        if (ref.read(playerProvider).currentSong == null) return;
        _navigateToPlayer();
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CoachTour.armedSignal.addListener(_maybeStartTour);
    accessRevokedProvider.addListener(_onRevokedSignal);
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
      // The interactive walkthrough runs HERE, not in onboarding: it points at
      // the real tabs and the real mini-player, so it needs the actual app on
      // screen to point AT. Onboarding just arms it and hands over.
      _maybeStartTour();

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
      // THE SAME SERIALISED ENTRY POINT AS MOUNT AND RESUME. Pointing this at
      // its own method is what let three callers race one read-and-clear.
      AudioCaptureService.onPendingReady = _maybeIdentifyPendingCapture;
      // AT MOUNT AS WELL AS ON RESUME. A COLD START HAS NO "RESUMED" EVENT.
      //
      // This used to run only from didChangeAppLifecycleState, which never fires
      // for a launch: the widget mounts already resumed, and Flutter delivers
      // lifecycle CHANGES, not the initial state. That was survivable while the
      // app was usually alive in the background, but the headless path now
      // retires its process, so tapping a "found" notification is ALWAYS a cold
      // start, and the album navigation silently never ran. The user got the app
      // and nothing else.
      //
      // Exactly the alarm bug noted below, mirrored: that one polled only at
      // mount and missed resumes; this one polled only on resume and missed
      // mount. Both need both. `consumeFoundTap` is read-and-clear natively, so
      // the pair cannot double-navigate.
      _maybeOpenFoundAlbum();
      _maybeIdentifyPendingCapture();
      // And the access check, for the same reason as the two above.
      //
      // This ran ONLY from the resumed branch of didChangeAppLifecycleState, and a
      // cold start never delivers "resumed" — the widget mounts already resumed and
      // Flutter reports CHANGES. So a blocked account that RESTARTED the app was
      // never checked: it was only caught if the user happened to background Auvy
      // and come back. Restarting is the obvious way to try again after being
      // kicked out, which made it the one path that let them in.
      //
      // Forced past the throttle: a launch is exactly when a definitive answer is
      // wanted, and the ten-minute window exists to stop mid-session polling, not
      // to skip the check that decides whether this session should exist.
      _maybeEjectIfRevoked(force: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CoachTour.armedSignal.removeListener(_maybeStartTour);
    accessRevokedProvider.removeListener(_onRevokedSignal);
    _notificationSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // THE SECOND ALARM BUG. `onNewIntent` sets the native flag when an alarm
    // arrives while Auvy is already alive, but nothing asked Dart to re-check —
    // the only poll was MainLayout's one-shot postFrameCallback at mount. So an
    // alarm that fired with the app merely BACKGROUNDED set a flag nobody read,
    // and no music played. Re-poll on every resume; `consumePendingAlarm` is
    // read-and-clear natively, so this can't double-fire.
    if (state == AppLifecycleState.resumed) {
      _maybeStartAlarmPlayback();
      // Keep tomorrow's alarm audio on disk. Every resume, because there is no
      // background job to rely on and the alarm has to work on a morning the
      // user never opened the app the night before.
      _refreshAlarmTrack();
      _maybeIdentifyPendingCapture();
      _maybeOpenFoundAlbum();
      _maybeEjectIfRevoked();
    }
  }


  /// Revocation mid-session
  ///
  /// The approval gate only ran at app START. Someone approved for weeks who is
  /// then blocked or put back in the queue kept the app open indefinitely — the
  /// owner's decision did nothing until that person happened to relaunch. On a
  /// music app that can be days.
  ///
  /// Re-checked on every RESUME, throttled so a quick app-switch does not fire a
  /// verify each time. An account verdict (pending / blocked / closed) ends the
  /// session and returns them to the sign-in page, which names the account and
  /// says what happened.
  ///
  /// Deliberately silent on `unavailable`. A Worker outage or a dead network
  /// must NEVER eject someone — that would turn a server hiccup into everyone
  /// losing their music. Only an explicit verdict about the ACCOUNT acts.
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
        access.status == 'closed';
    if (!revoked) return;

    _ejectTo(access.status, access.identity);
  }

  /// Stop playback, drop the session, and replace the whole stack with the
  /// sign-in page carrying the verdict.
  Future<void> _ejectTo(String status, String? identity) async {
    // STOP THE AUDIO FIRST. Being returned to the login page while the
    // track keeps playing is not a revocation, it is a confusing screen.
    try {
      ref.read(playerProvider.notifier).stopAndDismiss();
    } catch (_) {}
    // Drop the session so the sign-in page offers the account chooser again
    // rather than silently re-signing the account that was just refused.
    try {
      await SessionCookieManager().clearCookies();
    } catch (_) {}
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

  /// Opened by tapping a "song found" notification → go to that album AND play it.
  ///
  /// The notification only carries the title and artist (it was posted from a
  /// string, not a resolved track), so the album has to be looked up here. Failing
  /// silently is correct if the lookup misses: the user still lands in Auvy, which
  /// is where they were heading.
  ///
  /// Playback is started by AlbumPage once its track list resolves, not here —
  /// see [AlbumPage.autoplayTrack] for why waiting is what gets the rest of the
  /// album into the queue behind it.
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

  /// Identify audio the quick-settings tile captured while Auvy was closed.
  ///
  /// The tile deliberately does NOT open the app — doing so would background
  /// whatever was playing and pause it, which is the whole failure the tile exists
  /// to avoid. So it drops raw PCM on disk and recognition happens here, the moment
  /// Auvy is next in front of the user, which is also where the result can be shown.
  ///
  /// `takePendingCapture` clears the marker as it reads, so a capture can never be
  /// identified twice, and a resume with nothing waiting costs one pref read.
  /// In-flight capture handling, so the three triggers below cannot race.
  ///
  /// THREE CALLERS, ONE DESTRUCTIVE READ. This is the "stuck on Identifying…"
  /// bug. `takePendingCapture` is read-AND-CLEAR, and it was called from mount,
  /// from resume, and from the native handoff — all of which fire together when
  /// the tile is tapped with Auvy on screen. Caught in the log to the millisecond:
  ///
  /// handoff accepted — identifying the tile capture
  /// identify: nothing pending (already consumed)
  ///
  /// The loser returned silently, and that was fatal rather than merely wasteful:
  /// the handoff had already answered `true`, so the native service cleared
  /// `headlessPending` and stopped, trusting Dart to finish. Nobody then replaced
  /// "Identifying…", and the notification stood for ever.
  ///
  /// Serialising fixes it at the source: whoever arrives first owns the capture
  /// through to a posted result, and the others join that same future instead of
  /// racing it for bytes that are already gone.
  Future<void>? _captureWork;

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

    //`mounted` AND `isCurrent` DO NOT MEAN "ON SCREEN".
    //
    // A backgrounded MainLayout is still mounted and its route is still current,
    // so the old test passed while Auvy was behind another app, and the result
    // was rendered into a sheet nobody could see, leaving the notification on
    // "Identifying…". The lifecycle state is the only thing that answers it.
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

    // ONE LOOKUP PER QUESTION. The sheet runs its OWN recognition (with
    // progress and artwork) and posts the tile notification itself — so
    // recognising here as well would mean two fingerprints and two network calls
    // for one tap, with the possibility of the two disagreeing.
    if (resumed && mounted) {
      print('identify: on screen — handing to the result sheet');
      showPendingCaptureResult(context, pcm);
      return;
    }

    // NEVER DISCARD A CAPTURE WE HAVE ALREADY TAKEN. The take is destructive,
    // and this path used to `return` on `!mounted` AFTER it — throwing the audio
    // away with the promise still outstanding. Off screen, the notification is
    // the only thing that can reach the user, so identify here and let it carry
    // the answer.
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

  /// Authoritatively apply the "Open on" preference.
  ///
  /// Re-reads prefs directly instead of trusting the static, because
  /// `ListeningPolicy.reloadFrom` runs from `_initBackgroundServices()` AFTER
  /// `runApp`, so on a fast boot MainLayout can be built first and land on Home
  /// regardless of the setting. Skipped once the user has picked a tab, so a
  /// late-arriving preference can't move them mid-interaction.
  Future<void> _applyDefaultTab() async {
    await ListeningPolicy.load();
    if (!mounted || _userChoseTab) return;
    final want = ListeningPolicy.defaultOpenTab;
    if (want != _selectedIndex) setState(() => _selectedIndex = want);
  }

  /// Start the wake-up music if this launch came from the alarm.
  ///
  /// The native side answers true exactly ONCE per firing (read-and-clear), so a
  /// later resume can't restart the alarm music. Picks a source in taste order,
  /// each falling back to the next, and finally to autoplay — an alarm that
  /// stays silent because a list happened to be empty is the one failure mode
  /// that actually matters here.
  /// True while the ringing screen is on top. Guards re-entrancy. See the note
  /// at the top of [_maybeStartAlarmPlayback].
  bool _alarmScreenUp = false;

  Future<void> _maybeStartAlarmPlayback() async {
    // THE ALARM IS ALREADY PLAYING BY NOW — adopt it, don't race it.
    //
    // AlarmAudioService starts the music natively at the exact minute, with
    // Flutter not even running. So by the time this method exists to be called,
    // there is usually sound coming out of the phone already. Dart's job is no
    // longer "start the alarm" but "take the wheel": find out what is ringing
    // and how far in, stop the native player, and continue the SAME track in the
    // normal pipeline so the user gets a real queue, artwork and controls.
    // RE-ENTRANCY. This runs on EVERY resume, and it awaits a Navigator.push
    // that stays pending for as long as the alarm screen is up. Backgrounding and
    // returning while it showed called this again, saw the alarm still ringing,
    // and pushed a SECOND ringing screen on top of the first, so stopping the
    // alarm dismissed one and left the other, on a silent phone.
    if (_alarmScreenUp) return;

    final state = await AlarmService.audioState();
    final ringing = state['active'] == true;
    // Read-and-clear, so a later resume can't restart the alarm music.
    final fired = await AlarmService.consumePendingAlarm();
    if (!mounted) return;

    // Only show the screen while it is actually ringing.
    //
    // `fired` outlives the audio: stop the alarm from the notification action (or
    // let the 15-minute cap end it) without opening Auvy, and the flag is still
    // set the next time the app starts. Showing a full-screen alarm then is a
    // jump-scare over whatever the user actually opened the app to do, with no
    // sound to explain it. Clean up the lockscreen flags and say nothing.
    if (!ringing) {
      if (fired) await AlarmService.exitAlarmScreen();
      return;
    }

    // THE SCREEN NO LONGER DEPENDS ON THE LIBRARY. A `pool.isEmpty` check used
    // to sit here and return BEFORE the screen was shown, so on an empty library
    // the alarm rang with no way to stop it but the notification. The screen needs
    // one song for its artwork at most, and renders fine without it.
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

    // Leave nothing behind in the panels.
    //
    // Showing the alarm screen means booting Flutter, and booting Flutter brings
    // up the media session, so after the alarm was stopped Auvy was still sitting
    // in the notification shade AND in the media-output panel, with nothing
    // playing. That is residue from a UI that only existed to hold two buttons.
    //
    // Only when there was no session to begin with: if music was already playing
    // when the alarm fired, tearing down the player would be destroying something
    // the user is using.
    if (ref.read(playerProvider).currentSong == null) {
      try {
        ref.read(playerProvider.notifier).stopAndDismiss();
      } catch (_) {}
    }

    // And then get out of the way
    //
    // A clock app does not leave itself open after you turn the alarm off — you
    // dismiss it and you are back at the lockscreen, as though nothing happened.
    // Auvy sitting on Home afterwards is a second thing to deal with before
    // you are even properly awake.
    //
    // Native decides whether to actually leave: it only backs out when the ALARM
    // is what launched the app. If Auvy was already open when the alarm fired,
    // the user was using it and closing it would be the rude surprise instead.
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
    // LOAD THE PREFS, DON'T TRUST THE STATIC. AlarmService.reloadFrom runs
    // from _initBackgroundServices AFTER runApp, so on a cold start MainLayout's
    // postFrameCallback can get here first and read `enabled` as false — leaving
    // an armed alarm with no audio prepared until the app happened to be
    // backgrounded and resumed. Same reason _applyDefaultTab re-reads its pref.
    await AlarmService.load();
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
      // Use the CURRENT API (onPopInvokedWithResult). The deprecated
      // onPopInvoked does not fire reliably under Android's predictive-back
      // (Android 13+/Samsung gesture nav), so at a tab root the "go to Home /
      // press-back-again-to-exit" logic was skipped and the OS exited the app
      // directly — the reported "exits without going Home / no exit toast" bug.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 1) Deep inside the current tab → step back one page (retrace exactly
        //    the way the user came IN THIS TAB — Spotify/Apple behaviour).
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

        // 3) On the Home tab root: first back shows a toast "Press back again to
        //    exit"; a second back within 2s exits (Spotify-style).
        final now = DateTime.now();
        if (_lastPressedAt == null || now.difference(_lastPressedAt!) > const Duration(seconds: 2)) {
          _lastPressedAt = now;
          AnimatedToast.show(context, text: 'Press back again to exit', icon: Icons.exit_to_app, color: themeColor);
          return;
        }

        SystemNavigator.pop();
      },
      child: DynamicBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false, 
          body: Stack(
            children: [
              // 1. Content / Pages (Bottom Layer)
              Positioned.fill(
                bottom: isKeyboardOpen ? keyboardHeight : totalBottomHeight,
                // Swallow the tab navigators' NavigationNotifications so they
                // never reach the framework's system-back dispatcher. Each inner
                // Navigator broadcasts "canHandlePop: false" when it sits at its
                // own root; on Android 13+ predictive back that signal would flap
                // the OS registration to "app can't handle back", and the NEXT
                // back gesture from a Search/Library root would exit the app
                // directly — bypassing the logic below. The root PopScope
                // (canPop:false) already declares that WE always handle back and
                // manually forward pops to the active tab, so it must be the one
                // and only authority. This is the fix for the intermittent
                // "exits straight from Search/Library" bug.
                child: NotificationListener<NavigationNotification>(
                  onNotification: (_) => true,
                  // Tab switches used to be a bare IndexedStack — an instant,
                  // unanimated swap. This is where HYDRV actually uses its
                  // fragment transition (moving between bottom-nav
                  // destinations), so it's the most faithful place to apply it.
                  // The IndexedStack is untouched underneath, so every tab keeps
                  // its navigator stack and scroll position.
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
                      // Solid banner — this floats over scrolling pages while a
                      // download runs, so the old BackdropFilter re-blurred on
                      // every scroll frame for a near-opaque look.
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
                    child: (hasSong && !isKeyboardOpen && miniPlayerVisible) 
                      ? const CoachAnchor(
                          id: 'miniplayer',
                          child: MiniPlayer(key: ValueKey('active_miniplayer'))) 
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
    );
  }
}