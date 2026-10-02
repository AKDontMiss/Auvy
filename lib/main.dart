import 'dart:async';
import 'dart:io' show Platform;
import 'package:auvy/services/catalog_api_client.dart';
import 'dart:ui' show PlatformDispatcher;
import 'package:auvy/services/activity_log.dart';
import 'package:auvy/services/performance_monitor.dart';
import 'package:flutter/material.dart';
import 'package:auvy/core/native_licenses.dart';

import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/core/net/app_token.dart';
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
// LicenseRegistry/LicenseEntryWithLineBreaks are imported for the GPL licence
// registration in main().
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, kReleaseMode, LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/logic/stall_watchdog.dart';
import 'package:auvy/logic/recognition/headless_recognition.dart'
    show headlessRecognitionMain;
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/services/device_info_service.dart';
import 'package:auvy/core/utils/container_path_resolver.dart';

/// Entry point for the headless engine that identifies a quick-settings capture
/// while Auvy is closed. Started by name from AudioCaptureService.
///
/// It must live in main.dart: the engine only looks up named entry points in the
/// root library. The `show` import above is also required, because it is what
/// compiles the implementation into the app; it is not an unused import.
@pragma('vm:entry-point')
Future<void> auvyHeadlessRecognitionMain() => headlessRecognitionMain();

void main() {
  // Run the app in a zone that silences print() in release builds (each print is
  // a synchronous platform log write). Debug builds keep full logging.
  runZoned(
    // Async because the headless check below must finish before runApp.
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Start the activity log first, so startup problems are captured. Recording
      // stays off unless the user enabled it.
      await ActivityLog.instance.init();
      await DeviceInfoService.init();
      await ContainerPathResolver.ensureInitialized();

      // Performance sampler. Does nothing unless the activity log is on (or this is
      // an AUVY_DEBUG_LOG build).
      PerformanceMonitor.instance.syncWithDiagnostics();

      // GPL-3.0 §4: ship the licence text with the program. Registered here so it
      // appears at the top of the licence page the About screen opens. Loaded only
      // when that page is viewed.
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          const <String>['Auvy'],
          await rootBundle.loadString('LICENSE'),
        );
      });
      // Native libraries the Dart-generated list doesn't know about.
      if (!kIsWeb && Platform.isIOS) {
        LicenseRegistry.addLicense(() async* {
          yield const LicenseEntryWithLineBreaks(<String>['libwebp'], kLibwebpLicense);
        });
      }

      // Image cache limit. Decoded artwork is uncompressed (a 1200×1200 cover is about
      // 5.8 MB), and Flutter's 100 MB default makes the app an easy target for being
      // killed in the background. 48 MB is plenty since AuvyImage decodes at the
      // painted size.
      PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;

      // Swallow two known framework races that are not app bugs; everything else
      // still propagates:
      //  • Material's ink renderer handling a scroll-end notification after its
      //    route was popped mid-scroll.
      //  • The debug-only '!semantics.parentDataDirty' assertion, triggered by
      //    accessibility services during layout.
      final defaultOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('semantics.parentDataDirty')) return;
        // Debug: print the full report every time (the default collapses repeats).
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

      // Decide whether there is a screen before calling runApp.
      //
      // audio_service starts a headless Flutter engine that runs main() whenever its
      // service starts without an Activity (a quick-settings tile, a widget update, a
      // headset button, a Bluetooth connect, the system's media-resumption probe).
      // Building the whole app there would resolve streams and touch the library with
      // nothing on screen, racing the real app.
      //
      // The reliable signal is whether the native player channel exists: MainActivity
      // registers it, and a headless engine does not have it. The check costs one
      // channel call; in a headless engine it fails immediately.
      // Starts the real app exactly once, however we got here.
      var appStarted = false;
      void startApp(String why) {
        if (appStarted) return;
        appStarted = true;
        print('Starting app UI ($why)');

        // 1. Start the UI immediately so launch never hangs.
        // Stall watchdog (only with --dart-define=AUVY_DEBUG_LOG=true): detects
        // main-isolate freezes, which frame statistics cannot see.
        StallWatchdog.start();
        runApp(const ProviderScope(child: MyApp()));

        // 2. Start the heavier background services without blocking the UI.
        _initBackgroundServices();
      }

      // Headless: don't start the app, but stay ready. MainActivity reuses
      // audio_service's cached engine, so the engine that started headless may later
      // gain a screen, and main() will not run again. When an Activity attaches, the
      // platform side pings `auvy/engine_lifecycle` and the app starts then.
      const lifecycle = MethodChannel('auvy/engine_lifecycle');
      lifecycle.setMethodCallHandler((call) async {
        if (call.method != 'activityAttached') return null;
        // The Activity registered its channels on this engine, so clear the earlier
        // "no native player" verdict.
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
        // Every print passes through here, so the activity log records it without any
        // call-site changes. This sits before the release check because the point is to
        // record release builds. When the log is off this costs one boolean check.
        ActivityLog.instance.add(line);

        // Release builds drop print() output; debug builds keep it. Build with
        // --dart-define=AUVY_DEBUG_LOG=true to see Dart logs in a release build.
        const debugLog =
            bool.fromEnvironment("AUVY_DEBUG_LOG", defaultValue: false);
        if (!kReleaseMode || debugLog) {
          parent.print(zone, line);
        } else if (ActivityLog.instance.isEnabled) {
          // A release build with the activity log on also mirrors to the
          // system console, for USB debugging — redacted, like the log file,
          // because the system log outlives the app and ships in diagnostics.
          parent.print(zone, ActivityLog.redact(line));
        }
      },
    ),
  );
}

/// Starts Firebase and App Check, or stays local-only.
///
/// Runs alongside the other startup work. Everything is inside a try, so a
/// missing Firebase config leaves the app working without cloud sync.
Future<void> _initFirebase() async {
  final t = DateTime.now();
  try {
    await Firebase.initializeApp();
    // App Check attests that requests come from the genuine app. Safe to activate
    // before enforcement is enabled in the Firebase console.
    //   • Debug builds use the debug provider; register the printed debug token in
    //     Firebase console → App Check → Manage debug tokens.
    //   • Release builds use Play Integrity (Android) and App Attest (iOS).
    //
    // Firestore access is currently protected by the security rules (the user's uid
    // from the Worker's custom token), not by App Check. To enforce App Check:
    // Firebase console → App Check → register both apps → set Firestore to
    // "Enforced".
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider:
            kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
        appleProvider:
            kDebugMode ? AppleProvider.debug : AppleProvider.appAttest,
      );
      print('App Check activated (${kDebugMode ? "debug" : "playIntegrity/appAttest"})');
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
  // Is there a UI to serve? A headless engine (see main) would otherwise run
  // everything below with no screen, including permission requests nobody can
  // answer. In a normal launch the player's own probe has usually already set
  // the result, so this costs nothing.
  await NativeAudioEngine.isMusicActive();
  if (!NativeAudioEngine.platformAvailable) {
    print('STOP: headless engine (no Activity) — skipping app startup entirely');
    return;
  }

  // Load .env first, so anything reading it during startup sees its values.
  // Release builds do not bundle .env (keys arrive via --dart-define), so a
  // missing file is normal and not logged as a warning.
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {
    print("no .env on this build — keys come from --dart-define (expected)");
  }

  // The haptics setting must apply app-wide even if Settings is never opened.
  try {
    final prefs = await SharedPreferences.getInstance();
    HapticService.enabled = prefs.getBool('auvy_haptics_enabled') ?? true;
    // The history-pause switches gate hot paths and must be set before the first
    // play.
    ListeningPolicy.reloadFrom(prefs);
    // The alarm may be what launched the app, so its config is needed up front.
    AlarmService.reloadFrom(prefs);
    // Apply the keep-screen-on setting now.
    ListeningPolicy.applyKeepScreenOn();
  } catch (e) { print("WARN: Haptics pref load failed: $e"); }

  // The audio cache scan, the session restore and Firebase start in parallel,
  // since none depends on the others. Each keeps its own try/catch so one failure
  // cannot stop the rest. The preferences block above stays first because the
  // alarm launch handler needs it.
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

  // Load remembered play counts. Not awaited: rows update as the cache fills.
  CatalogApiClient.primeViewCounts();

  // Load the proxy token before the first Worker request needs it.
  unawaited(AuvyAppToken.load());


  try { await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]); } catch (e) { print("WARN: Orientation lock failed: $e"); }

  // Android only: Android 13+ requires notification permission for the media
  // notification (and its controls) to appear. iOS shows playback on the lock
  // screen without a notification, so it asks for nothing.
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final isDenied = await Permission.notification.isDenied;
      if (isDenied) await Permission.notification.request();
    } catch (e) { print("WARN: Permission request failed: $e"); }
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(densityProvider);
    final primaryColor = ref.watch(themeProvider);

    // "Accent follows artwork": listened to at the root so the accent tracks the
    // playing artwork across the whole app. `ref.listen` rather than `ref.watch`,
    // so MaterialApp is not rebuilt on every colour.
    ref.listen(playerColorProvider, (_, next) {
      if (!ref.read(dynamicAccentProvider)) return;
      ref.read(themeProvider.notifier).applyDynamic(next);
    });
    ref.listen(dynamicAccentProvider, (_, on) {
      if (on) {
        // Apply immediately rather than waiting for the next track.
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
        // UI density: ListTiles and Material controls read these two theme values, so
        // every list row in the app follows the setting (see density_provider.dart).
        visualDensity: density.visual,
        listTileTheme: ListTileThemeData(
          minVerticalPadding: density.minVerticalPadding,
        ),
        // One look for every dialog, defined once so new dialogs inherit it.
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.modalPanel,
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
        // Bottom sheets use the same surface and a matching top radius.
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.modalPanel,
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