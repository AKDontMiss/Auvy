import 'dart:async';
import 'package:auvy/services/catalog_api_client.dart';
import 'dart:ui' show PlatformDispatcher;
import 'package:auvy/services/activity_log.dart';
import 'package:flutter/material.dart';

import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter/services.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/presentation/widgets/splash_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/providers/connectivity_provider.dart';
// LicenseRegistry/LicenseEntryWithLineBreaks are named explicitly because this
// import carries a show clause. See the GPL note in main() for why they are here.
import 'package:flutter/foundation.dart'
    show kDebugMode, kReleaseMode, LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/logic/stall_watchdog.dart';
import 'package:auvy/logic/recognition/headless_recognition.dart'
    show headlessRecognitionMain;

/// Entry point for the HEADLESS engine that identifies a quick-settings capture
/// while Auvy is closed. Started by name from AudioCaptureService.
///
/// IT LIVES IN main.dart FOR TWO REASONS, BOTH LEARNED THE HARD WAY.
///
/// 1. THE ENGINE LOOKS IN THE ROOT LIBRARY. `DartEntrypoint(bundle, name)`
///    leaves `dartEntrypointLibrary` null, and the engine then searches only
///    `package:auvy/main.dart`. A function in any other file is simply not
///    found, and there is no callback, no exception and no output when that
///    happens. The engine starts, runs nothing, and sits there: from the outside
///    identical to a slow network, which is how it was misdiagnosed for a long
///    time as "takes ages, then no match".
///
/// 2. NOTHING IMPORTED THE IMPLEMENTATION FILE, SO IT WAS NEVER COMPILED. Naming
///    the library explicitly in the DartEntrypoint only moved the failure on to
///    `Dart_LookupLibrary: library not found`, because AOT compiles the
///    libraries reachable from main's import graph, and that file was reachable
///    from nothing. `@pragma('vm:entry-point')` retains a MEMBER of a compiled
///    library; it cannot resurrect a library that was never in the graph.
///
/// The `show` import above is therefore load-bearing, not tidiness: it is what
/// puts the implementation into the snapshot. Do not remove it as an unused
/// import — the call below is what keeps it honest.
@pragma('vm:entry-point')
Future<void> auvyHeadlessRecognitionMain() => headlessRecognitionMain();

void main() {
  // Run the whole app in a zone that swallows print() in RELEASE builds: the
  // codebase logs heavily (recommendation engine, player, cache) and every
  // print is a synchronous platform log write. Debug builds keep full logging.
  runZoned(
    // async because the headless check below must complete BEFORE runApp — see
    // the note there for why that ordering is the whole point.
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // The flight recorder, first
      //
      // Before anything else logs, so a cold-start problem is IN the transcript
      // rather than just before it. Reads one pref and returns; recording stays
      // off unless the user switched it on.
      await ActivityLog.instance.init();

      // Gpl-3.0 §4: the licence travels with the program
      //
      // The About screen links to the source repository, which is what §6 asks
      // for (corresponding source). It is not what §4 asks for: a copy of the
      // licence itself, given to whoever received the binary. A link is not a
      // copy — it needs a network, and a repository that still exists.
      //
      // Registering it here puts the full text at the TOP of the licence page
      // the About screen already opens (showLicensePage reads this registry), so
      // it sits above the bundled libraries and needs no new screen. Lazy: the
      // 35KB is read only if someone opens that page.
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          const <String>['Auvy'],
          await rootBundle.loadString('LICENSE'),
        );
      });

      // Image cache ceiling
      //
      // Flutter's default is 100MB of DECODED images, and decoded artwork is
      // uncompressed ARGB — a 1200×1200 cover is ~5.8MB whatever the JPEG
      // weighed. On device this app was holding 194MB of GPU textures
      // (`dumpsys meminfo`, `GL mtrack`), which is a lot for a music player and
      // is memory the OS can reclaim by killing us in the background.
      //
      // 48MB is generous for a grid of covers at their painted size, and paired
      // with AuvyImage now sizing its decode from the LAYOUT (see the
      // LayoutBuilder there) rather than decoding unbounded slots at full source
      // resolution. Eviction only costs a re-decode from the file/network cache.
      PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;

      // Two KNOWN-BENIGN framework races pollute sessions as unhandled
      // exceptions; swallow exactly those two, let everything else propagate:
      //  • Material's ink renderer catches the final ScrollEndNotification
      //    AFTER its element was deactivated (route popped mid-scroll) and
      //    calls findRenderObject() on the inactive element (framework race,
      //    not app code — observed live: artist/playlist pop while settling).
      //  • The '!semantics.parentDataDirty' assertion — a debug-only semantics
      //    race tripped by accessibility services scanning mid-layout.
      final defaultOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('semantics.parentDataDirty')) return;
        // Debug: full report on EVERY occurrence — the default collapses
        // repeats to one-liners, which hides where recurring errors fire.
        if (kDebugMode) {
          FlutterError.dumpErrorToConsole(details, forceReport: true);
          return;
        }
        defaultOnError?.call(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        final msg = error.toString();
        if (msg.contains('Cannot get renderObject of inactive element') &&
            stack.toString().contains('dispatchScrollEndNotification')) {
          print('Ignored benign framework race: ink renderer got scroll-end after pop');
          return true;
        }
        return false; // not handled — normal crash reporting continues
      };

      // IS THERE A SCREEN? DECIDE BEFORE runApp, NOT AFTER IT.
      //
      // audio_service boots a HEADLESS Flutter engine running main() whenever
      // its service starts with no Activity — a quick-settings tile being
      // rendered, a widget update, a headset button, a Bluetooth connect,
      // SystemUI's media-resumption probe. There is a guard for this in
      // _initBackgroundServices, and it was USELESS, because runApp ran first
      // and unconditionally: by the time it printed "skipping app startup
      // entirely", ProviderScope had already built the player, the library, the
      // audio handler and MainLayout.
      //
      // Captured live from a process the system started only to draw the QS tile:
      //
      // headless engine (no Activity) — skipping app startup entirely
      // Media controls initialised (Native Bridge)
      // Audio session configured with smart-resume
      //   Skip detected: Levitating (0% played)
      // Native-resolving stream: Cheap Thrills
      // Unable to detect current Android Activity
      //
      // A complete, invisible copy of Auvy resolving streams and skipping
      // tracks. That is the "ghosting": music starting on its own, the media
      // notification appearing, the alarm re-arming, all with nothing on screen.
      //
      // It is also a DATA HAZARD, which is the more serious half. That instance
      // logged "enableCloudBackup: Firebase NOT available — staying local-only",
      // so a second LibraryNotifier was live with cloud sync disabled — two
      // writers racing over one library, which is exactly the shape of the
      // disappearing-playlists bug.
      //
      //`implicitView == null` DOES NOT WORK — I tried it and the device said
      // no. An engine keeps its implicit view for as long as it exists; with no
      // FlutterView attached that view is UNATTACHED, not absent. So the check
      // never fired and the ghost app started anyway.
      //
      // The reliable signal is whether the NATIVE PLAYER CHANNEL exists. It is
      // registered in MainActivity.configureFlutterEngine, so an engine created
      // by audio_service (`new FlutterEngine(applicationContext)` +
      // `DartEntrypoint.createDefault()`, i.e. main(), from
      // AudioServicePlugin.getFlutterEngine) simply does not have it.
      //
      // This costs ONE method-channel round trip before the first frame, which
      // is why it was originally placed after runApp. That ordering is what made
      // the guard useless, so the round trip is now paid deliberately: in a real
      // launch the handler answers immediately, and in a headless engine it
      // raises MissingPluginException and latches `_platformGone` just as fast —
      // no network, nothing that can hang.
      // Starts the real app exactly once, however we got here.
      var appStarted = false;
      void startApp(String why) {
        if (appStarted) return;
        appStarted = true;
        print('Starting app UI ($why)');

        // 1. Fire up the app UI immediately so it never hangs on launch
        // Diagnostic only, and a no-op without --dart-define=AUVY_DEBUG_LOG=true.
        // Catches main-isolate stalls, which frame stats CANNOT see: a blocked
        // isolate submits no frame, so `dumpsys gfxinfo` records nothing at all
        // while the screen is visibly frozen. See StallWatchdog.
        StallWatchdog.start();
        runApp(const ProviderScope(child: MyApp()));

        // 2. Initialize all heavy background services without blocking runApp
        _initBackgroundServices();
      }

      // THE HEADLESS CHECK DEFERS THE APP. IT MUST NOT ABANDON IT.
      //
      // This used to `return` here, which was correct about not building a ghost
      // app and WRONG about the engine being throwaway. MainActivity extends
      // audio_service's AudioServiceActivity, which gives the Activity the engine
      // audio_service already cached instead of creating a new one, so the
      // engine that starts life headless is the SAME ONE the UI later attaches
      // to, and main() only ever runs once in it.
      //
      // Captured on device:
      //
      //   (pid 18675) …normal session…                    <- app swiped away, dies
      //   (pid 32522) Using the Impeller rendering backend (Vulkan)
      //   (pid 32522) No native player in this engine — NOT starting the app
      //
      // …then opening Auvy showed a BLACK SCREEN, permanently, and a headset
      // connect played nothing. Both are the same thing: main() had already
      // returned, so no widget tree and no player existed, and attaching an
      // Activity to that engine could not create them.
      //
      // So: still no ghost app in a genuinely screenless engine, but the engine
      // is left ARMED. If an Activity attaches, the platform side clears the
      // latch and pings `auvy/engine_lifecycle`, and the app starts then.
      const lifecycle = MethodChannel('auvy/engine_lifecycle');
      lifecycle.setMethodCallHandler((call) async {
        if (call.method != 'activityAttached') return null;
        // The Activity has registered the hand-rolled channels on this engine, so
        // the earlier verdict is now stale — clear it before trusting it again.
        NativeAudioEngine.onActivityAttached();
        await NativeAudioEngine.isMusicActive();
        if (NativeAudioEngine.platformAvailable) {
          startApp('Activity attached to a previously headless engine');
        }
        return null;
      });

      await NativeAudioEngine.isMusicActive();
      if (!NativeAudioEngine.platformAvailable) {
        print('STOP: No native player in this engine — it has no screen. NOT '
            'starting the app YET. (headless service engine: QS tile render, '
            'widget update, media button, Bluetooth connect, media-resumption '
            'probe). Armed: will start if an Activity attaches.');
        return;
      }

      startApp('normal launch with a screen');
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        // The recorder taps in here, before the release gate below.
        //
        // Every print in the app already passes through this one function, which
        // makes it the only place a transcript can be captured without touching
        // a call site, and without anyone being able to forget to.
        //
        // It sits ABOVE the kReleaseMode test on purpose: the whole point is to
        // record a RELEASE build in ordinary use, where `parent.print` is
        // deliberately silent. The recorder is off unless the user turned it on,
        // buffers in memory, and writes on a timer, so a disabled log costs one
        // boolean per line and an enabled one costs no per-line I/O. See
        // ActivityLog for why that matters on these hot paths.
        ActivityLog.instance.add(line);

        // Release swallows ALL print() output: every call is a synchronous
        // platform-log write on hot paths (recommendation engine, player), so
        // shipping them costs real frames. Debug builds still log normally.
        // TEMPORARY DIAGNOSTIC — gated on a define so it cannot ship by
        // accident. Build with --dart-define=AUVY_DEBUG_LOG=true to see Dart
        // logs in a RELEASE build; without it, behaviour is unchanged.
        const debugLog =
            bool.fromEnvironment("AUVY_DEBUG_LOG", defaultValue: false);
        if (!kReleaseMode || debugLog) parent.print(zone, line);
      },
    ),
  );
}

/// Bring up Firebase and App Check, or stay local-only.
///
/// Its own function so it can run ALONGSIDE the disk scan and the session
/// restore rather than behind them. See the note at the call site. The whole
/// body is inside a try, so a missing google-services.json leaves the app fully
/// working without cloud sync, exactly as before.
Future<void> _initFirebase() async {
  final t = DateTime.now();
  try {
    await Firebase.initializeApp();
    // App Check: attest that requests come from the genuine app so the Firestore
    // backup can be locked to real clients (blocks scraping/abuse). Activating
    // here is SAFE before you turn on enforcement in the Firebase console —
    // until then Firestore still accepts requests, so this can't break sync.
    //   • Debug builds use the debug provider: a debug token is printed to
    //     logcat ("App Check debug token: ...") — paste it into
    //     Firebase console → App Check → Apps → Manage debug tokens.
    //   • Release builds use Play Integrity.
    // Console steps to actually enforce (do LAST, after registering the token):
    //   Firebase console → App Check → register the Android app → set Firestore
    //   to "Enforced".
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider:
            kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      );
      print("App Check activated (${kDebugMode ? 'debug' : 'playIntegrity'})");
    } catch (e) {
      print("WARN: App Check activation failed (non-fatal): $e");
    }
    CloudSyncService.markAvailable();
    print("Firebase ready — cloud sync enabled");
  } catch (e) {
    print("Firebase not configured — running local-only: $e");
  }

  print('boot: firebase ${DateTime.now().difference(t).inMilliseconds}ms');
}

Future<void> _initBackgroundServices() async {
  // Is there actually a UI to serve?
  //
  // audio_service starts a HEADLESS Flutter engine whenever its service is
  // launched with no Activity — a Bluetooth connect, a headset button, Android
  // Auto, or SystemUI's media-resumption probe. That engine runs main() and
  // therefore everything below: .env, Firebase, the session restore, permission
  // requests. Observed live, a headless boot logged
  // "PlatformException(PermissionHandler, Unable to detect current Android
  // Activity)" while asking for permissions nobody could grant, then hammered
  // channels that do not exist in that engine.
  //
  // One cheap native call answers it. In a real launch this is a sub-millisecond
  // round trip that has already been made by the player's own probe, so the
  // latch below is usually set before we get here and this costs nothing.
  await NativeAudioEngine.isMusicActive();
  if (!NativeAudioEngine.platformAvailable) {
    print('STOP: headless engine (no Activity) — skipping app startup entirely');
    return;
  }

  // Load .env FIRST: ExternalCatalogService reads its Spotify keys from dotenv
  // in a getter, so any search / home-feed call in the cold-start window
  // (before this used to run — it was after Firebase) saw an empty key and
  // silently returned nothing, then started working seconds later. It's a tiny
  // local asset, so loading it up front is safe and cheap.
  //
  // ABSENT IS THE NORMAL CASE IN A RELEASE BUILD, so this is not a warning.
  // `.env` is deliberately NOT bundled — shipped keys would be extractable from
  // the APK, and every release key arrives by --dart-define instead. Every
  // reader guards on `dotenv.isInitialized`, so nothing here is left broken.
  // Logged as a warning it appeared on all five launches in the 2026-08-30
  // transcript, which is how a reader learns to skip the warnings that matter.
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {
    print("no .env on this build — keys come from --dart-define (expected)");
  }

  // Haptics kill-switch must be correct app-wide even if Settings never opens.
  try {
    final prefs = await SharedPreferences.getInstance();
    HapticService.enabled = prefs.getBool('auvy_haptics_enabled') ?? true;
    // Same reason: the history-pause switches gate hot paths (the position
    // tick, every search submit) and MUST be right before the first play.
    ListeningPolicy.reloadFrom(prefs);
    // Alarm config. Loaded here (not lazily in Settings) because the alarm can
    // be what LAUNCHED the app, and the launch handler needs to know the source.
    AlarmService.reloadFrom(prefs);
    // Apply the keep-screen-on window flag now, so the setting works without
    // needing Settings to be opened first.
    ListeningPolicy.applyKeepScreenOn();
  } catch (e) { print("WARN: Haptics pref load failed: $e"); }

  // These three waited on each other for no reason
  //
  // The disk scan, the secure-storage read and the Firebase handshake were
  // awaited one after another, and not one of them needs anything the others
  // produce. The scan walks the downloads folder, so on a full library it is
  // the long pole, and Firebase, which decides whether cloud sync exists at
  // all, could not even begin until it finished. Downloads, session and sync
  // therefore came up in series after the first frame, which is the window
  // where the library looks empty and the account looks logged out.
  //
  // Run together instead. Each keeps its OWN try/catch, so a failure in one
  // still cannot take the others down — that isolation was the point of the
  // separate blocks and it is preserved exactly.
  //
  // THE PREFS BLOCK ABOVE STAYS SEQUENTIAL AND FIRST. It is one platform
  // call, and the alarm may be what LAUNCHED the app — the launch handler has
  // to be able to read AlarmService's config before anything else runs.
  final bootStart = DateTime.now();
  await Future.wait([
    () async {
      final t = DateTime.now();
      try {
        final cacheManager = AudioCacheManager();
        await cacheManager.initialize();
        Timer.periodic(const Duration(hours: 1), (_) => cacheManager.cleanup());
      } catch (e) { print("WARN: CacheManager init error: $e"); }
      print('boot: cache manager ${DateTime.now().difference(t).inMilliseconds}ms');
    }(),
    () async {
      final t = DateTime.now();
      try {
        final cookieManager = SessionCookieManager();
        await cookieManager.loadCookies();
      } catch (e) { print("WARN: CookieManager init error: $e"); }
      print('boot: session cookies ${DateTime.now().difference(t).inMilliseconds}ms');
    }(),
    _initFirebase(),
  ]);
  print('boot: background services ready in '
      '${DateTime.now().difference(bootStart).inMilliseconds}ms');

  // Play counts already looked up, so a playlist costs its lookups once rather
  // than once per launch. Not awaited: rows read the cache as it fills, and a
  // count arriving a moment late costs nothing.
  CatalogApiClient.primeViewCounts();


  try { await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]); } catch (e) { print("WARN: Orientation lock failed: $e"); }

  try {
    final isDenied = await Permission.notification.isDenied;
    if (isDenied) await Permission.notification.request();
  } catch (e) { print("WARN: Permission request failed: $e"); }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(densityProvider);
    final primaryColor = ref.watch(themeProvider);

    // ACCENT FOLLOWS ARTWORK (Appearance → Accent colour)
    //
    // Wired at the ROOT rather than inside the player, because the point of the
    // setting is that the colour reaches the whole app, and the player screen is
    // the one place it already worked. Listening here means the accent keeps
    // tracking the queue while you are browsing somewhere else entirely.
    //
    // `ref.listen`, not `ref.watch`: this reacts to a colour arriving, it does
    // not read one for the build below. Watching would rebuild MaterialApp on
    // every extraction even with the mode off.
    ref.listen(playerColorProvider, (_, next) {
      if (!ref.read(dynamicAccentProvider)) return;
      ref.read(themeProvider.notifier).applyDynamic(next);
    });
    ref.listen(dynamicAccentProvider, (_, on) {
      if (on) {
        // Apply immediately instead of waiting for the next track: a toggle that
        // appears to do nothing until the song changes reads as broken.
        ref.read(themeProvider.notifier).applyDynamic(ref.read(playerColorProvider));
      } else {
        ref.read(themeProvider.notifier).restoreManual();
      }
    });
    ref.listen(connectivityProvider, (previous, next) {
      if (previous?.isOffline == false && next.isOffline) {
        print("App went offline");
      } else if (previous?.isOffline == true && next.isConnected) {
        print("OK: App back online");
      }
    });

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Auvy', 
      builder: (context, child) => DynamicBackground(child: child!),
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: primaryColor,
        colorScheme: ColorScheme.dark(
          primary: primaryColor,
          secondary: primaryColor,
          surface: const Color(0xFF121212),
        ),
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
        useMaterial3: true,
        // UI DENSITY (Appearance → Lists)
        // The whole feature, in two theme values. Auvy's list rows are ListTiles,
        // and ListTile reads visualDensity + ListTileThemeData from the ambient
        // theme, so this reaches every row in the app (library, search, playlist,
        // album, artist, home) without touching a call site, and applies the same
        // scale to Material's buttons and chips at the same time.
        // See density_provider.dart for what it deliberately does NOT change.
        visualDensity: density.visual,
        listTileTheme: ListTileThemeData(
          minVerticalPadding: density.minVerticalPadding,
        ),
        // One popup look, defined once
        // An audit found FOURTEEN different hardcoded surface greys across the
        // app's dialogs and sheets — 0xFF17171C, 1E1E1E, 2A2A2E, 1E1E24, 1A1A1E,
        // 0E0E12, 1B1B24, 181818, 161616 … Individually each looked fine; side by
        // side, two popups in the same flow were visibly different shades, with
        // different corner radii and title sizes. That is what "not on theme"
        // actually was: not a wrong colour, an absence of a single one.
        //
        // Setting it HERE rather than fixing each call site means new dialogs
        // inherit it automatically — the per-dialog overrides were removed so
        // this can't be silently bypassed again.
        //
        // 0xFF17171C is the canonical surface: it was already the most-used
        // (6 of the 14), so the app moves toward its own majority rather than
        // toward a new invention.
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF17171C),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: Colors.white.withOpacity(0.07)),
          ),
          titleTextStyle: const TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
          contentTextStyle: TextStyle(
              color: Colors.white.withOpacity(0.78), fontSize: 13.5, height: 1.45),
        ),
        // Modal sheets get the same surface and a matching top radius, so a sheet
        // and a dialog raised from the same page read as the same material.
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF17171C),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        progressIndicatorTheme: ProgressIndicatorThemeData(color: primaryColor),
        sliderTheme: SliderThemeData(
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
          overlayColor: primaryColor.withOpacity(0.2),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}