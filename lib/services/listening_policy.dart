import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/catalog_api_clients.dart';
import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/services/stream_resolver.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:auvy/services/romanization_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';

/// What Auvy is allowed to RECORD about the listener, and what counts as a
/// "play". Read from hot paths (the position tick, every search submit), so
/// these are plain statics loaded once at startup — the same pattern
/// `HapticService.enabled` uses. Never read prefs from those paths directly.
///
/// The pause switches are privacy controls: with history paused, Auvy keeps
/// playing normally but stops feeding the taste model, stats and Top 50 —
/// matching the "pause history" control users expect from Spotify/YouTube.
/// Nothing already recorded is deleted (that's Settings → clear/delete).
class ListeningPolicy {
  ListeningPolicy._();

  /// Same gate the rest of the app uses: `print` is compiled out of a normal
  /// release, and only a build passing --dart-define=AUVY_DEBUG_LOG=true emits
  /// anything. Settings are read once at startup and written on a tap, so these
  /// are a handful of lines per session, not a stream.
  static const bool _kDebugLog =
      bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false);

  static const String kPauseListening = 'auvy_pause_listen_history';
  static const String kPauseSearch = 'auvy_pause_search_history';
  static const String kScrobbleSeconds = 'auvy_scrobble_seconds';
  static const String kScrobblePercent = 'auvy_scrobble_percent';

  /// Stop crediting plays: no playCounts, no taste/affinity updates, no
  /// listening history, no "recently played" collections on the Home mosaic.
  static bool pauseListeningHistory = false;

  /// Stop persisting search queries (suggestions from the network still work).
  static bool pauseSearchHistory = false;

  /// Private session
  ///
  /// One switch that suspends EVERYTHING Auvy would otherwise remember about
  /// this listening session: play counts, taste/affinity updates, listening
  /// history, recently-played collections, search history, and ListenBrainz
  /// scrobbling.
  ///
  /// DELIBERATELY NOT PERSISTED. That is the feature, not an oversight. The
  /// two `pause*` switches above are standing preferences — you set them and
  /// forget them. A private session is for right now: you hand your phone to
  /// someone, or you play something you don't want shaping your recommendations
  /// for the next month. If it survived a restart it would quietly keep
  /// discarding everything you listen to, and the most likely way to discover
  /// that is noticing weeks later that your Top 50 stopped moving. Ending with
  /// the process is the safe failure direction.
  ///
  /// Read through [historyPaused] / [searchPaused], never directly — those are
  /// what the enforcement points consult.
  static bool privateSession = false;

  /// True when listening must not be recorded — either the standing preference
  /// or a private session. Every play-crediting path checks THIS.
  static bool get historyPaused => pauseListeningHistory || privateSession;

  /// True when search queries must not be persisted, for either reason.
  static bool get searchPaused => pauseSearchHistory || privateSession;

  /// A track counts as a play after EITHER this many seconds OR
  /// [scrobblePercent] of its length — whichever comes first (Last.fm's rule).
  /// Defaults match the previously hardcoded behaviour, so upgrading changes
  /// nothing until the user moves a slider.
  static int scrobbleSeconds = 30;
  static double scrobblePercent = 0.5;

  /// Liking a track also downloads it for offline (Wi-Fi only). Off by default
  /// — a download is the user's data, so it stays opt-in.
  static bool autoDownloadOnLike = false;
  static const String kAutoDownloadOnLike = 'auvy_auto_download_on_like';

  /// Content region + language for YouTube Music (`gl`/`hl`). Empty string means
  /// "follow the device locale", which is the default and the right answer for
  /// almost everyone — an explicit value is for people who want another
  /// country's charts and releases. Mirrored into [CatalogApiClients].
  static String contentCountry = '';
  static String contentLanguage = '';
  static const String kContentCountry = 'auvy_content_country';
  static const String kContentLanguage = 'auvy_content_language';

  /// Stream sources the user switched OFF.
  /// Stored as the DISABLED set: a client added by a future version is then on by
  /// default instead of missing from every existing user's saved list.
  static const String kDisabledStreamSources = 'auvy_disabled_stream_sources';

  /// Pause playback when the media volume is turned to ZERO. Android keeps
  /// playing into silence otherwise, still spending data and battery. Opt-in:
  /// some people mute deliberately while keeping their place.
  static bool pauseOnMute = false;
  static const String kPauseOnMute = 'auvy_pause_on_mute';

  /// Keep the screen awake while Auvy is in the foreground. Off by default —
  /// it's for reading lyrics or watching the player, not for everyone.
  static bool keepScreenOn = false;
  static const String kKeepScreenOn = 'auvy_keep_screen_on';

  /// Block screenshots, screen recording and the recents-screen thumbnail
  /// (Android's `FLAG_SECURE`). The same one-flag approach any Android app uses's `DisableScreenshotKey`.
  ///
  /// It also hides the window from non-secure external displays, so screen
  /// mirroring/casting shows black — stated in the UI, since that is the part
  /// people don't expect.
  ///
  /// It does NOT affect song recognition: that captures via
  /// `AudioPlaybackCaptureConfiguration`, which is governed by the *playing*
  /// app's `allowedCapturePolicy`, not by the capturing window's FLAG_SECURE.
  /// (An earlier version of this comment claimed otherwise — it's a display
  /// flag, and audio capture never goes through the display pipeline.)
  static bool blockScreenshots = false;
  static const String kBlockScreenshots = 'auvy_block_screenshots';

  /// May an external PLAY (headset button, AVRCP, media resumption) start Auvy
  /// when it isn't already playing and isn't on screen?
  ///
  /// ON by default, because "press play on my headphones to resume" is a
  /// feature. Turn it OFF if you use a MULTIPOINT Bluetooth headset paired to a
  /// second device: those forward their transport keys over BOTH links, so
  /// pressing play on a computer also tells the phone to play. Android gives no
  /// way to detect that a key was misrouted, so the guards in
  /// `AuvyAudioHandler._shouldIgnoreExternalPlay` are heuristics — this switch
  /// is the certain answer for someone who knows their hardware does it.
  static bool allowExternalPlayStart = true;
  static const String kAllowExternalPlayStart = 'auvy_allow_external_play';

  /// How many lyric lines can go on one shared card.
  ///
  /// Capped at 10 rather than unlimited: the card is a fixed 9:16, so every extra
  /// line shrinks the type, and past ten the quote is unreadable at the size a
  /// story is actually viewed. 6 is the default — a chorus or a couplet.
  static int lyricShareMaxLines = 6;
  static const String kLyricShareMaxLines = 'auvy_lyric_share_max_lines';

  /// Lyric type size on the player's lyrics face, as a MULTIPLIER (0.8–1.4).
  ///
  /// A multiplier rather than an absolute point size: the active line, inactive
  /// lines and the translation line are three different sizes that have to keep
  /// their relationship, and scaling them together is the only way a preference
  /// can't break the hierarchy. The same control is common in music apps
  /// (`lyricsTextSize`); the need is real — synced lyrics are read at arm's
  /// length, often across a room.
  static double lyricTextScale = 1.0;
  static const String kLyricTextScale = 'auvy_lyric_text_scale';

  /// How round COVER ART is throughout the app, as a multiplier (0.0 – 2.0)
  /// applied to each surface's own base radius. 1.0 = as designed.
  ///
  /// A MULTIPLIER, not an absolute radius, because artwork appears at wildly
  /// different sizes — a 46px mini-player thumbnail and a 300px album header
  /// cannot share one corner value without one of them looking wrong. Scaling
  /// each surface's designed radius keeps their relationship intact while still
  /// letting the whole app go sharp or pill-soft.
  ///
  /// Scoped to COVER ART deliberately, and labelled that way. Auvy has ~360
  /// `borderRadius` uses; the vast majority are buttons, sheets, pills and cards,
  /// and a setting that rounded those too would be a theme engine, not a
  /// preference. Artwork is a coherent, nameable set.
  static double artworkRoundness = 1.0;
  static const String kArtworkRoundness = 'auvy_artwork_roundness';

  /// Scale [base] by the user's roundness preference.
  static double roundArtwork(double base) => base * artworkRoundness;

  static Future<void> setArtworkRoundness(double v) async {
    artworkRoundness = v.clamp(0.0, 2.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kArtworkRoundness, artworkRoundness);
    CloudSyncService.instance.scheduleBackup();
  }

  /// Shape of the PLAYER's artwork: 0 square, 1 rounded (default), 2 circle.
  ///
  /// Scoped to the player on purpose, and named that way in the UI. A global
  /// "corner radius" control would be the more obvious feature, but every list
  /// tile, sheet and card in Auvy passes its own explicit radius, so a single
  /// setting could only reach some of them — a control that changes half the app
  /// and silently ignores the rest is worse than not offering it. The player's
  /// cover is one surface, it is the one people actually look at, and it is fully
  /// honoured here.
  ///
  /// Circle is not a gimmick: it is how a record reads, and paired with the
  /// artwork-derived glow it turns the player into something closer to a turntable
  /// than a card.
  static int playerArtworkShape = 1;
  static const String kPlayerArtworkShape = 'auvy_player_artwork_shape';

  /// Corner radius for the player artwork. 999 clips a square box to a circle,
  /// which is why the circle case needs no size information.
  ///
  /// Five steps rather than three: square → circle in two jumps skipped the range
  /// people actually want. The middle values are where a cover stops looking like
  /// a screenshot and starts looking placed, and 'Soft' in particular is the
  /// modern-Android look that 14px doesn't quite reach.
  static double get playerArtworkRadius => switch (playerArtworkShape) {
        0 => 0.0, // Square
        1 => 14.0, // Rounded
        2 => 28.0, // Soft
        3 => 52.0, // Squircle — heavy corners, still recognisably a square
        4 => 999.0, // Circle
        _ => 14.0,
      };

  static Future<void> setPlayerArtworkShape(int v) async {
    playerArtworkShape = v.clamp(0, 4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPlayerArtworkShape, playerArtworkShape);
    CloudSyncService.instance.scheduleBackup();
  }

  /// Centre the lyrics instead of left-aligning them.
  ///
  /// Not cosmetic-only: centred reads better for song lyrics (it is how they are
  /// printed in sleeves and how Apple Music shows them), while left-aligned is
  /// easier to track line-to-line for long lines and for spoken-word/rap. There
  /// is no universally right answer, which is exactly why it's a setting.
  static bool lyricsCentered = false;
  static const String kLyricsCentered = 'auvy_lyrics_centered';

  /// Which scripts to romanise in lyrics. Empty = off (the default: most people's
  /// libraries are in a script they read).
  ///
  /// Stored as the enum NAMES, so [RomanizableScript.key] is a persistence format.
  static Set<RomanizableScript> romanizeScripts = {};
  static const String kRomanizeScripts = 'auvy_romanize_scripts';

  /// Show the romanisation INSTEAD of the original line, rather than under it.
  ///
  /// Both are wanted for different reasons: under-the-line lets you follow the
  /// original while checking pronunciation; replacing it is what you want when you
  /// can't read the script at all and the original is just noise.
  static bool romanizeAsMain = false;

  /// Which STANDARD each script is romanised with.
  ///
  /// Stored by enum name for the same reason the script set is: an index would
  /// silently repoint at a different system the moment one is added.
  static KanaSystem kanaSystem = KanaSystem.hepburn;
  static const String kKanaSystem = 'auvy_romanize_kana_system';

  static HangulSystem hangulSystem = HangulSystem.revised;
  static const String kHangulSystem = 'auvy_romanize_hangul_system';

  static CyrillicSystem cyrillicSystem = CyrillicSystem.practical;
  static const String kCyrillicSystem = 'auvy_romanize_cyrillic_system';

  /// The scripts to romanise a WHOLE LYRIC with.
  ///
  /// A lyric sheet should be in one script.
  ///
  /// The per-line rule (a line containing kanji is left alone, because
  /// converting the kana around it produces something readable as neither
  /// language) is right for the line and wrong for the page. Observed on device
  /// with a real Japanese song:
  ///
  ///   LT romanize: lines=33 detected=kana applied=kana changedLines=6/33
  ///
  /// Six lines happened to be pure kana and became romaji; the other 27 kept
  /// their kanji and stayed in Japanese. With "show romanization as the main
  /// line" on, that is a page of Japanese with six romaji lines scattered
  /// through it — no longer wrong, but jumbled.
  ///
  /// So the decision is made ONCE for the lyric: if any line carries an
  /// ideograph, the kana pass is dropped for all of them. Cyrillic and Hangul
  /// are untouched by this — neither is ambiguous, and a Russian song with a
  /// stray CJK character should still convert.
  static Set<RomanizableScript> scriptsForLyric(String wholeText) {
    if (!romanizeScripts.contains(RomanizableScript.kana)) return romanizeScripts;
    if (!RomanizationService.hasIdeograph(wholeText)) return romanizeScripts;
    return romanizeScripts.where((s) => s != RomanizableScript.kana).toSet();
  }

  /// Romanise [text] with the user's current script set and standards.
  ///
  /// EVERY CALLER SHOULD USE THIS rather than RomanizationService.romanize
  /// directly. The service takes the three systems as parameters and defaults
  /// them, so a call site that forgets one silently renders a different standard
  /// than the settings screen is previewing.
  /// [scripts] lets a caller that holds the whole lyric pass the song-wide
  /// decision from [scriptsForLyric]; it defaults to the raw setting.
  static String romanizeLine(String text, {Set<RomanizableScript>? scripts}) =>
      RomanizationService.romanize(
        text,
        scripts ?? romanizeScripts,
        kana: kanaSystem,
        hangul: hangulSystem,
        cyrillic: cyrillicSystem,
      );
  static const String kRomanizeAsMain = 'auvy_romanize_as_main';

  /// Which bottom-nav tab the app opens on: 0 Home / 1 Search / 2 Library.
  /// Someone who lives in their own library shouldn't have to tap past a
  /// recommendation feed every launch.
  static int defaultOpenTab = 0;
  static const String kDefaultOpenTab = 'auvy_default_open_tab';

  /// Keep playing similar music once the queue runs dry (Spotify's "Autoplay").
  ///
  /// On by default because endless play is what most people expect, but it was
  /// previously unconditional: `_topUpQueue` always injected recommendations, so
  /// a deliberately-chosen album or playlist NEVER ended. Some listeners want
  /// silence when their record finishes — this gives them that.
  static bool autoplay = true;
  static const String kAutoplay = 'auvy_autoplay_similar';

  /// Drop the travel from navigation transitions, keeping only a short cross-fade.
  /// For motion sensitivity, and it makes the app feel quicker on older hardware.
  static bool reduceMotion = false;
  static const String kReduceMotion = 'auvy_reduce_motion';

  /// How adventurous autoplay and radio should be: 0 = stay with what you know,
  /// 1 = push unfamiliar music. Read by `_scoreAndRankRecommendations`, where it
  /// scales the learned-taste terms against the novelty bonus.
  ///
  /// 0.5 is the default and reproduces the behaviour that existed before the
  /// control was added, so upgrading changes nothing until it's moved.
  static double discoveryBias = 0.5;
  static const String kDiscoveryBias = 'auvy_discovery_bias';

  /// Milliseconds of playback after which [durationMs] counts as a real play.
  /// Falls back to the seconds threshold when the duration isn't known yet.
  static int thresholdMsFor(int durationMs) {
    final secondsMs = scrobbleSeconds * 1000;
    if (durationMs <= 0) return secondsMs;
    final percentMs = (durationMs * scrobblePercent).round();
    return secondsMs < percentMs ? secondsMs : percentMs;
  }

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      reloadFrom(prefs);
    } catch (_) {
      // Keep the defaults — never block startup on a prefs hiccup.
    }
  }

  /// Re-read from an already-open prefs instance. Used by the post-restore
  /// settings refresh so a cloud restore applies without an app restart.
  static void reloadFrom(SharedPreferences prefs) {
    pauseListeningHistory = prefs.getBool(kPauseListening) ?? false;
    pauseSearchHistory = prefs.getBool(kPauseSearch) ?? false;
    scrobbleSeconds = (prefs.getInt(kScrobbleSeconds) ?? 30).clamp(5, 240);
    scrobblePercent = (prefs.getDouble(kScrobblePercent) ?? 0.5).clamp(0.1, 1.0);
    autoDownloadOnLike = prefs.getBool(kAutoDownloadOnLike) ?? false;
    defaultOpenTab = (prefs.getInt(kDefaultOpenTab) ?? 0).clamp(0, 2);
    // The result filters read the SearchService mirror, not this class.

    pauseOnMute = prefs.getBool(kPauseOnMute) ?? false;
    keepScreenOn = prefs.getBool(kKeepScreenOn) ?? false;
    // No apply() here: MainActivity.onCreate reads the same pref natively and has
    // already set the flag before the first frame. Pushing it again from Dart
    // would be a redundant channel hop on every launch.
    blockScreenshots = prefs.getBool(kBlockScreenshots) ?? false;
    autoplay = prefs.getBool(kAutoplay) ?? true;
    allowExternalPlayStart = prefs.getBool(kAllowExternalPlayStart) ?? true;
    lyricShareMaxLines = (prefs.getInt(kLyricShareMaxLines) ?? 6).clamp(1, 10);
    lyricTextScale =
        (prefs.getDouble(kLyricTextScale) ?? 1.0).clamp(0.8, 1.4);
    lyricsCentered = prefs.getBool(kLyricsCentered) ?? false;
    playerArtworkShape = (prefs.getInt(kPlayerArtworkShape) ?? 1).clamp(0, 4);
    artworkRoundness = (prefs.getDouble(kArtworkRoundness) ?? 1.0).clamp(0.0, 2.0);
    // Unknown names are DROPPED rather than throwing: a stored value could come
    // from a cloud restore written by a newer build that knows more scripts.
    final storedScripts = prefs.getStringList(kRomanizeScripts) ?? const [];
    romanizeScripts = RomanizableScript.values
        .where((s) => storedScripts.contains(s.key))
        .toSet();
    romanizeAsMain = prefs.getBool(kRomanizeAsMain) ?? false;
    kanaSystem = KanaSystem.values.firstWhere(
        (v) => v.key == prefs.getString(kKanaSystem),
        orElse: () => KanaSystem.hepburn);
    hangulSystem = HangulSystem.values.firstWhere(
        (v) => v.key == prefs.getString(kHangulSystem),
        orElse: () => HangulSystem.revised);
    cyrillicSystem = CyrillicSystem.values.firstWhere(
        (v) => v.key == prefs.getString(kCyrillicSystem),
        orElse: () => CyrillicSystem.practical);
    if (_kDebugLog) {
      // The toggle surviving a restart is the first thing to rule out when
      // romanisation "does nothing": a key written under the wrong TYPE by an
      // older build reads back as null here and the setting silently resets.
      // Printing BOTH the raw stored names and what survived the filter
      // separates "nothing was saved" from "saved, but the name is unknown".
      final dropped =
          storedScripts.where((k) => !romanizeScripts.any((s) => s.key == k));
      print('romanize loaded: stored=$storedScripts '
          'active=${romanizeScripts.map((s) => s.key).toList()} '
          'asMain=$romanizeAsMain'
          '${dropped.isEmpty ? '' : ' DROPPED-UNKNOWN=${dropped.toList()}'}');
    }
    // Pushed into HydrvMotion because route transitions are built in callbacks
    // with no `ref` and no chance to await a prefs read.
    reduceMotion = prefs.getBool(kReduceMotion) ?? false;
    discoveryBias = (prefs.getDouble(kDiscoveryBias) ?? 0.5).clamp(0.0, 1.0);
    HydrvMotion.reduceMotion = reduceMotion;

    contentCountry = prefs.getString(kContentCountry) ?? '';
    contentLanguage = prefs.getString(kContentLanguage) ?? '';
    _applyRegion();
    // Auto resolves from the SIM/network country, which needs a platform call —
    // deliberately NOT awaited here so load() stays synchronous-fast on the boot
    // path. Until it lands the locale default is in place; it is applied before
    // any catalog request that matters because load() runs during startup.
    if (contentCountry.isEmpty) unawaited(resolveAutoRegion());

    CatalogApiClients.applyDisabledStreamSources(
        prefs.getStringList(kDisabledStreamSources) ?? const []);
  }

  /// Change which stream clients the player is allowed to resolve from.
  ///
  /// Drops the RESOLVED-STREAM cache (not the catalog cache): those URLs came
  /// from a client the user may have just switched off, and they stay valid for
  /// ~5 hours, so the change would appear to do nothing until they expired. The
  /// track already playing is unaffected — its URL is with the native player.
  static Future<void> setDisabledStreamSources(Iterable<String> keys) async {
    CatalogApiClients.applyDisabledStreamSources(keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        kDisabledStreamSources, CatalogApiClients.disabledStreamSources.toList());
    CloudSyncService.instance.scheduleBackup();
    StreamResolver().clear();
  }

  static Future<void> setPauseOnMute(bool v) async {
    pauseOnMute = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPauseOnMute, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setKeepScreenOn(bool v) async {
    keepScreenOn = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kKeepScreenOn, v);
    CloudSyncService.instance.scheduleBackup();
    await applyKeepScreenOn();
  }

  static Future<void> setLyricShareMaxLines(int v) async {
    lyricShareMaxLines = v.clamp(1, 10);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kLyricShareMaxLines, lyricShareMaxLines);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setLyricTextScale(double v) async {
    lyricTextScale = v.clamp(0.8, 1.4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kLyricTextScale, lyricTextScale);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setLyricsCentered(bool v) async {
    lyricsCentered = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLyricsCentered, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setRomanizeScripts(Set<RomanizableScript> v) async {
    romanizeScripts = {...v};
    final prefs = await SharedPreferences.getInstance();
    final keys = romanizeScripts.map((s) => s.key).toList();
    final ok = await prefs.setStringList(kRomanizeScripts, keys);
    if (_kDebugLog) print('romanize set: $keys persisted=$ok');
    // MISSING UNTIL NOW, unlike every other setter on this class. The key is
    // listed in CloudSyncService's backup set, so it looked covered, but with
    // nothing scheduling a write the value only ever reached the cloud if some
    // unrelated setting happened to be changed afterwards.
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setKanaSystem(KanaSystem v) async {
    kanaSystem = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kKanaSystem, v.key);
    if (_kDebugLog) print('romanize kana system: ${v.key}');
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setHangulSystem(HangulSystem v) async {
    hangulSystem = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kHangulSystem, v.key);
    if (_kDebugLog) print('romanize hangul system: ${v.key}');
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setCyrillicSystem(CyrillicSystem v) async {
    cyrillicSystem = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kCyrillicSystem, v.key);
    if (_kDebugLog) print('romanize cyrillic system: ${v.key}');
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setRomanizeAsMain(bool v) async {
    romanizeAsMain = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kRomanizeAsMain, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setAllowExternalPlayStart(bool v) async {
    allowExternalPlayStart = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAllowExternalPlayStart, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setAutoplay(bool v) async {
    autoplay = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAutoplay, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setDiscoveryBias(double v) async {
    discoveryBias = v.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kDiscoveryBias, discoveryBias);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setReduceMotion(bool v) async {
    reduceMotion = v;
    HydrvMotion.reduceMotion = v; // takes effect on the very next navigation
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kReduceMotion, v);
    CloudSyncService.instance.scheduleBackup();
  }

  /// Screenshot blocking. The native side writes the pref itself as well, so the
  /// flag survives an Activity recreate that Dart never hears about.
  static Future<void> setBlockScreenshots(bool v) async {
    blockScreenshots = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBlockScreenshots, v);
    CloudSyncService.instance.scheduleBackup();
    try {
      await const MethodChannel('com.auvy.app/window')
          .invokeMethod('setSecure', {'enabled': v});
    } catch (_) {
      // Non-Android / channel not up yet — the pref is stored, and onCreate
      // applies it on the next launch.
    }
  }

  /// Push the flag to the activity window. Also called at startup so the setting
  /// takes effect without opening Settings.
  static Future<void> applyKeepScreenOn() async {
    try {
      // /window, NOT /native_player. This asked the PLAYER channel for a
      // window flag it has never implemented, so the call returned
      // notImplemented and the catch below hid it — the setting did nothing at
      // all. The handler lives on the window channel next to setSecure.
      await const MethodChannel('com.auvy.app/window')
          .invokeMethod('keepScreenOn', {'enabled': keepScreenOn});
    } catch (_) {
      // Non-Android, or no Activity in this engine (headless audio_service
      // boot) — there is no window to flag, and nothing is lost.
    }
  }

  /// Push the region into the InnerTube layer. An EMPTY stored value means
  /// "Auto", which resolves through [resolveAutoRegion] rather than forcing US.
  static void _applyRegion() {
    if (contentCountry.isNotEmpty) {
      CatalogApiClients.contentCountry = contentCountry;
    }
    if (contentLanguage.isNotEmpty) {
      CatalogApiClients.contentLanguage = contentLanguage;
    }
  }

  /// Resolve "Auto" to the country the user is actually IN, and apply it.
  ///
  /// THE LOCALE IS NOT A LOCATION. Auto used to come from
  /// `CatalogApiClients.deviceCountry()`, which parses `Platform.localeName` —
  /// that is the UI LANGUAGE's country. A phone set to English (United States)
  /// reports `en_US` wherever it is on Earth, so Auto silently meant US for
  /// anyone using US English, and YouTube served that country's catalog, charts
  /// and release dates. Confirmed on the test device: `persist.sys.locale =
  /// en-US` while the SIM country was `se`.
  ///
  /// The native side (`com.auvy.app/region`) reports the SIM country, then the
  /// network country — both actual signals about where the device is, and both
  /// permission-free. The locale stays as the last resort for a tablet with no
  /// radio at all.
  ///
  /// No-ops when the user has chosen an explicit region: that choice outranks
  /// any detection.
  static Future<void> resolveAutoRegion() async {
    if (contentCountry.isNotEmpty) return; // explicit choice wins
    try {
      final iso = await const MethodChannel('com.auvy.app/region')
          .invokeMethod<String>('deviceRegion');
      if (iso != null && iso.length == 2) {
        CatalogApiClients.contentCountry = iso.toUpperCase();
        return;
      }
    } catch (_) {
      // Non-Android / channel not up yet — keep the locale fallback below.
    }
    CatalogApiClients.contentCountry = CatalogApiClients.deviceCountry();
  }

  /// Change the content region. Drops the catalog caches — cached search and
  /// browse responses are region-specific, so keeping them would serve the old
  /// country's charts and releases until they expired.
  static Future<void> setRegion({String? country, String? language}) async {
    contentCountry = country ?? contentCountry;
    contentLanguage = language ?? contentLanguage;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kContentCountry, contentCountry);
    CloudSyncService.instance.scheduleBackup();
    await prefs.setString(kContentLanguage, contentLanguage);
    CloudSyncService.instance.scheduleBackup();
    if (contentCountry.isEmpty) {
      // Switching BACK to Auto must re-detect, not fall to the locale's country.
      await resolveAutoRegion();
    }
    if (contentLanguage.isEmpty) {
      CatalogApiClients.contentLanguage = CatalogApiClients.deviceLanguage();
    }
    _applyRegion();
    CatalogApiClient.clearCaches();
  }

  /// The region actually in effect (after the device-locale fallback).
  static String get effectiveCountry => CatalogApiClients.contentCountry;
  static String get effectiveLanguage => CatalogApiClients.contentLanguage;

  static Future<void> setDefaultOpenTab(int v) async {
    defaultOpenTab = v.clamp(0, 2);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kDefaultOpenTab, defaultOpenTab);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setAutoDownloadOnLike(bool v) async {
    autoDownloadOnLike = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAutoDownloadOnLike, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setPauseListeningHistory(bool v) async {
    pauseListeningHistory = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPauseListening, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setPauseSearchHistory(bool v) async {
    pauseSearchHistory = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPauseSearch, v);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setScrobbleSeconds(int v) async {
    scrobbleSeconds = v.clamp(5, 240);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kScrobbleSeconds, scrobbleSeconds);
    CloudSyncService.instance.scheduleBackup();
  }

  static Future<void> setScrobblePercent(double v) async {
    scrobblePercent = v.clamp(0.1, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kScrobblePercent, scrobblePercent);
    CloudSyncService.instance.scheduleBackup();
  }
}
