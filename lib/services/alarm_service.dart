import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/data/dummy_data.dart';

/// Wake up to MUSIC instead of a ringtone.
///
/// Neither Spotify nor Apple Music does this properly — it's one of
/// the few things a music app is uniquely placed to do well, because it already
/// knows your taste and holds your offline library.
///
/// Split of responsibility: the SCHEDULE is native (`AlarmScheduler.kt`) because
/// `AlarmManager` is the only thing that survives Doze and process death, while
/// the CONFIG and the actual playback stay in Dart. Nothing about the
/// resolve/queue/audio-focus pipeline is duplicated natively — that's how the
/// two-audio-focus-owners bug happened once already.
class AlarmService {
  AlarmService._();

  static const MethodChannel _ch = MethodChannel('com.auvy.app/alarm');

  // These pref keys are ALSO read natively, by AlarmReceiver, to re-arm after
  // a reboot — where they appear with SharedPreferences' `flutter.` prefix
  // (`flutter.auvy_alarm_enabled`, …). Renaming one here means renaming it there.
  static const String kEnabled = 'auvy_alarm_enabled';
  static const String kHour = 'auvy_alarm_hour';
  static const String kMinute = 'auvy_alarm_minute';
  static const String kDays = 'auvy_alarm_days';
  static const String kSource = 'auvy_alarm_source';
  static const String kFadeIn = 'auvy_alarm_fade_in';
  /// ALSO READ NATIVELY by AlarmAudioService (`PREF_VOLUME`).
  ///
  /// Stored as an INT PERCENT (5–100), not a double, because the native side has
  /// to read it out of the raw SharedPreferences file. A Dart int lands as a Java
  /// Long, which AlarmReceiver already relies on for the alarm hour — whereas
  /// how shared_preferences encodes a double is an implementation detail of the
  /// plugin. Guessing it wrong would read as the default and the slider would
  /// silently do nothing.
  static const String kVolumePct = 'auvy_alarm_volume_pct';
  /// ALSO READ NATIVELY (AlarmAudioService.PREF_SNOOZE_MIN / PREF_FADE_SEC).
  /// Ints for the same reason as the volume above.
  static const String kSnoozeMin = 'auvy_alarm_snooze_min';
  static const String kFadeSec = 'auvy_alarm_fade_seconds';

  // The PRE-CACHED alarm track
  //
  // ALSO READ NATIVELY, by AlarmAudioService, which is what actually plays
  // the alarm. See AlarmAudioService.PREF_* — the two lists must match.
  //
  // The alarm plays a local FILE prepared in advance, not a stream resolved at
  // 07:00. A signed googlevideo url is IP-bound and expires, YouTube may be
  // unreachable, and the phone may be in airplane mode — an alarm that needs a
  // working network at the moment it fires is not an alarm.
  static const String kTrackPath = 'auvy_alarm_track_path';
  static const String kTrackId = 'auvy_alarm_track_id';
  static const String kTrackTitle = 'auvy_alarm_track_title';
  static const String kTrackArtist = 'auvy_alarm_track_artist';
  static const String kTrackAt = 'auvy_alarm_track_at';
  static const String kPickedSong = 'auvy_alarm_picked_song';
  static const String kPickedCollection = 'auvy_alarm_picked_collection';
  static const String kBackground = 'auvy_alarm_background';
  static const String kPulse = 'auvy_alarm_pulse';

  /// Re-pick the track once a day, so waking up is not Groundhog Day. Long
  /// enough that a normal morning always finds a file already there.
  static const Duration _trackFreshFor = Duration(hours: 20);

  static bool enabled = false;
  static int hour = 7;
  static int minute = 30;

  /// `DateTime.monday`..`DateTime.sunday`. EMPTY = fire once, at the next
  /// occurrence of [hour]:[minute].
  static Set<int> days = <int>{};

  /// What to play: 'liked' (a random liked song), 'top' (your most played),
  /// 'recent' (what you last listened to), or 'song' — one specific track the
  /// user chose, held in [pickedSong].
  static String source = 'liked';

  /// The exact track to wake up to when [source] is 'song'.
  ///
  /// Stored as JSON rather than an id: the alarm has to name the track on the
  /// notification while the app is not running, and re-looking-up a title from
  /// an id would mean a network call at 07:00 for the sake of a label.
  static Song? pickedSong;

  /// Title of the saved album or playlist to wake up to when [source] is
  /// 'collection'. A TITLE, because that is what playlistSongs is keyed by — the
  /// same key the rest of the library uses.
  static String? pickedCollection;

  /// Ramp the volume up over ~30s instead of starting at full blast. On by
  /// default — being jolted awake at full volume is nobody's idea of a good
  /// morning, and it's the whole reason to use music as an alarm.
  static bool fadeIn = true;

  /// How loud the alarm plays, 0.05–1.0, as a fraction of the device's ALARM
  /// stream volume.
  ///
  /// Not the same knob as the in-app player volume: the alarm runs on
  /// USAGE_ALARM (so Do Not Disturb lets it through), which means the system
  /// alarm slider sets the ceiling and this scales beneath it. Defaults to full,
  /// because the failure mode of a quiet alarm is oversleeping.
  static double volume = 1.0;

  /// How the ringing screen is painted: 'accent' (the theme colour bleeding up
  /// from behind the artwork), 'art' (the cover art itself, blurred, filling the
  /// screen) or 'plain' (near-black, nothing behind).
  ///
  /// A setting rather than a fixed look, because this is the screen you meet at
  /// the most light-sensitive moment of your day — what reads as calm at 07:00 in
  /// a dark room is a personal call, not a design one.
  static String background = 'accent';

  /// Whether the artwork breathes while the alarm plays. Off is a real
  /// preference: movement is the first thing that grates when you have just woken
  /// up, and it is also the only animation on this screen.
  static bool pulse = true;

  /// Valid [background] values, in the order the settings chips show them.
  static const List<String> backgrounds = ['accent', 'art', 'plain'];

  /// Minutes a snooze lasts.
  ///
  /// 10, not 9. Nine is the mechanical clock-radio convention — it exists because
  /// a single-digit counter fits on the drum, and inheriting it here only made
  /// people ask why the snooze was a minute short of the round number the button
  /// looks like it promises. Still a setting; the default is just no longer a
  /// quirk of 1970s hardware. Must match
  /// `AlarmAudioService.SNOOZE_MINUTES_DEFAULT`, which reads the same pref.
  static const int kSnoozeMinutesDefault = 10;
  static int snoozeMinutes = kSnoozeMinutesDefault;

  /// Seconds the fade-in takes to reach [volume]. Only used when [fadeIn] is on.
  static int fadeSeconds = 30;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      reloadFrom(prefs);
    } catch (_) {
      // Keep defaults — never block startup on a prefs hiccup.
    }
  }

  static void reloadFrom(SharedPreferences prefs) {
    enabled = prefs.getBool(kEnabled) ?? false;
    hour = (prefs.getInt(kHour) ?? 7).clamp(0, 23);
    minute = (prefs.getInt(kMinute) ?? 30).clamp(0, 59);
    source = prefs.getString(kSource) ?? 'liked';
    fadeIn = prefs.getBool(kFadeIn) ?? true;
    // Floored at 0.05, never 0: a slider dragged to the bottom would otherwise
    // produce an alarm that runs, holds a wake lock and makes no sound.
    volume = ((prefs.getInt(kVolumePct) ?? 100) / 100).clamp(0.05, 1.0);
    snoozeMinutes =
        (prefs.getInt(kSnoozeMin) ?? kSnoozeMinutesDefault).clamp(1, 60);
    fadeSeconds = (prefs.getInt(kFadeSec) ?? 30).clamp(0, 300);
    pickedSong = _decodeSong(prefs.getString(kPickedSong));
    pickedCollection = prefs.getString(kPickedCollection);
    background = prefs.getString(kBackground) ?? 'accent';
    // Validated, not trusted: a value from an older build or a hand-edited pref
    // would otherwise render nothing at all on the one screen that must render.
    if (!backgrounds.contains(background)) background = 'accent';
    pulse = prefs.getBool(kPulse) ?? true;
    // A collection alarm with nothing chosen would wake the user to silence.
    if (source == 'collection' && (pickedCollection ?? '').isEmpty) source = 'liked';
    // A 'song' alarm with nothing chosen would wake the user to silence, so it
    // degrades to their liked songs rather than trusting the pair to be in sync.
    if (source == 'song' && pickedSong == null) source = 'liked';
    final csv = prefs.getString(kDays) ?? '';
    days = csv
        .split(',')
        .map((e) => int.tryParse(e.trim()))
        .whereType<int>()
        .where((d) => d >= 1 && d <= 7)
        .toSet();
  }

  /// Persist the config AND (re)arm or cancel the native alarm.
  ///
  /// Native `schedule` cancels everything before re-arming, so this is safe to
  /// call repeatedly — it can't leave a stale alarm at an old time behind.
  static Future<void> save({
    bool? isEnabled,
    int? atHour,
    int? atMinute,
    Set<int>? onDays,
    String? playSource,
    bool? withFadeIn,
    double? atVolume,
    int? atSnoozeMinutes,
    int? atFadeSeconds,
    String? atBackground,
    bool? withPulse,
    Song? pickSong,
    String? pickCollection,
    bool clearPick = false,
  }) async {
    enabled = isEnabled ?? enabled;
    hour = atHour ?? hour;
    minute = atMinute ?? minute;
    days = onDays ?? days;
    source = playSource ?? source;
    fadeIn = withFadeIn ?? fadeIn;
    if (atVolume != null) volume = atVolume.clamp(0.05, 1.0);
    if (atSnoozeMinutes != null) snoozeMinutes = atSnoozeMinutes.clamp(1, 60);
    if (atFadeSeconds != null) fadeSeconds = atFadeSeconds.clamp(0, 300);
    if (atBackground != null && backgrounds.contains(atBackground)) {
      background = atBackground;
    }
    if (withPulse != null) pulse = withPulse;
    if (clearPick) {
      pickedSong = null;
    } else if (pickSong != null) {
      pickedSong = pickSong;
      // Choosing a track IS choosing the source. Making the user also flip a
      // separate radio button is the kind of two-step that ends with an alarm
      // playing something they did not pick.
      source = 'song';
    } else if (pickCollection != null) {
      pickedCollection = pickCollection;
      // Choosing a collection IS choosing the source, same as a single song.
      source = 'collection';
    }

    final prefs = await SharedPreferences.getInstance();
    if (pickedSong == null) {
      await prefs.remove(kPickedSong);
    } else {
      await prefs.setString(kPickedSong, jsonEncode(pickedSong!.toMap()));
    }
    await prefs.setBool(kEnabled, enabled);
    await prefs.setInt(kHour, hour);
    await prefs.setInt(kMinute, minute);
    await prefs.setString(kDays, days.join(','));
    await prefs.setString(kSource, source);
    if (pickedCollection == null) {
      await prefs.remove(kPickedCollection);
    } else {
      await prefs.setString(kPickedCollection, pickedCollection!);
    }
    await prefs.setBool(kFadeIn, fadeIn);
    await prefs.setInt(kVolumePct, (volume * 100).round().clamp(5, 100));
    await prefs.setInt(kSnoozeMin, snoozeMinutes);
    await prefs.setInt(kFadeSec, fadeSeconds);
    await prefs.setString(kBackground, background);
    await prefs.setBool(kPulse, pulse);

    await _apply();
  }

  static Future<void> _apply() async {
    try {
      if (!enabled) {
        await _ch.invokeMethod('cancel');
        return;
      }
      await _ch.invokeMethod('schedule', {
        'hour': hour,
        'minute': minute,
        // Dart's Monday..Sunday is 1..7; Calendar's Sunday..Saturday is 1..7.
        // Convert here so the native side can use Calendar constants directly.
        'days': days.map(_toCalendarDay).toList(),
      });
    } on PlatformException catch (_) {
      // A refused alarm must not break the settings screen.
    } on MissingPluginException catch (_) {
      // Non-Android platform / channel absent.
    }
  }

  /// Dart `DateTime.monday`(1)…`sunday`(7) → java `Calendar.SUNDAY`(1)…`SATURDAY`(7).
  static int _toCalendarDay(int dartWeekday) =>
      dartWeekday == DateTime.sunday ? 1 : dartWeekday + 1;

  /// True when the OS will honour an exact alarm. False on Android 12+ until the
  /// user allows it — the alarm still fires, just possibly minutes late.
  static Future<bool> canScheduleExact() async {
    try {
      return await _ch.invokeMethod<bool>('canScheduleExact') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// True when the OS will let the alarm SCREEN appear over the lockscreen.
  ///
  /// False (Android 14+, permission not granted) means the alarm still rings, but
  /// the user has to unlock the phone to see the stop button — worth saying out
  /// loud in settings rather than discovering at 07:00.
  static Future<bool> canUseFullScreen() async {
    try {
      return await _ch.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the OS toggle behind [canUseFullScreen].
  static Future<void> requestFullScreen() async {
    try {
      await _ch.invokeMethod('requestFullScreenIntent');
    } catch (_) {}
  }

  /// Opens the OS "Alarms & reminders" toggle (Android 12+).
  static Future<void> requestExactPermission() async {
    try {
      await _ch.invokeMethod('requestExactPermission');
    } catch (_) {}
  }

  /// Was this launch triggered BY the alarm? Read-and-clear on the native side,
  /// so it answers true exactly once per firing.
  static Future<bool> consumePendingAlarm() async {
    try {
      return await _ch.invokeMethod<bool>('consumePendingAlarm') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Song? _decodeSong(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Song.fromMap(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // A malformed entry must not brick the alarm screen — treat as "none".
    }
    return null;
  }

  // Pre-caching the alarm track

  /// Where the alarm's audio lives. Deliberately its OWN file, outside the LRU
  /// play-cache and outside the user's Downloads:
  ///   • the play-cache evicts, and an alarm whose file was evicted overnight is
  ///     the one failure that matters;
  ///   • a Downloads entry would show up in their library as if they had asked
  ///     for it.
  /// One track, overwritten in place, so this can never grow.
  static Future<File> _alarmFile() async {
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}/alarm');
    if (!sub.existsSync()) sub.createSync(recursive: true);
    return File('${sub.path}/alarm_track.m4a');
  }

  /// True when the prepared file is missing, stale, or for the wrong track.
  ///
  /// [wantId] is the track the caller intends to prepare. When [source] is
  /// 'song' that is the user's explicit pick and it must match exactly;
  /// otherwise any track from the pool will do and only freshness matters, so a
  /// re-pick happens about once a day instead of on every app resume.
  static Future<bool> needsPreparation({String? wantId}) async {
    try {
      final f = await _alarmFile();
      if (!f.existsSync() || f.lengthSync() <= 0) return true;
      final prefs = await SharedPreferences.getInstance();
      final haveId = prefs.getString(kTrackId);
      if (wantId != null && haveId != wantId) return true;
      final at = prefs.getInt(kTrackAt) ?? 0;
      return DateTime.now().millisecondsSinceEpoch - at > _trackFreshFor.inMilliseconds;
    } catch (_) {
      return true;
    }
  }

  /// The title of the track currently sitting in the alarm slot, for logging and
  /// for telling the user what will actually play.
  static Future<String> preparedTitle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(kTrackTitle) ?? '(none)';
    } catch (_) {
      return '(none)';
    }
  }

  /// Copy an already-downloaded track into the alarm slot. Free — no network.
  static Future<bool> storeFromFile(Song song, String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync() || src.lengthSync() <= 0) return false;
      final dst = await _alarmFile();
      await src.copy(dst.path);
      await _recordPrepared(song, dst.path);
      // Logged like the download path. Without this the copy — the FAST, common
      // case for an already-cached track — completed silently, which made a
      // working prepare indistinguishable from one that never ran.
      print('alarm track ready (copied from cache): ${song.title}');
      return true;
    } catch (e) {
      print('WARN: alarm track copy failed: $e');
      return false;
    }
  }

  /// Download a track into the alarm slot.
  ///
  /// Writes to a temp file and renames on success, so an interrupted download
  /// can never leave a truncated file where the alarm expects a playable one —
  /// which would trade "wrong song" for "no alarm".
  static Future<bool> storeFromUrl(Song song, String url, String? userAgent) async {
    final client = http.Client();
    try {
      final dst = await _alarmFile();
      final tmp = File('${dst.path}.part');
      final request = http.Request('GET', Uri.parse(url));
      if (userAgent != null && userAgent.isNotEmpty) {
        request.headers['User-Agent'] = userAgent;
      }
      final response =
          await client.send(request).timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        print('WARN: alarm track download refused (${response.statusCode})');
        return false;
      }
      final sink = tmp.openWrite();
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      if (!tmp.existsSync() || tmp.lengthSync() <= 0) return false;
      await tmp.rename(dst.path);
      await _recordPrepared(song, dst.path);
      print('alarm track ready: ${song.title}');
      return true;
    } catch (e) {
      print('WARN: alarm track download failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  static Future<void> _recordPrepared(Song song, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTrackPath, path);
    await prefs.setString(kTrackId, song.id);
    await prefs.setString(kTrackTitle, song.title);
    await prefs.setString(kTrackArtist, song.artist);
    await prefs.setInt(kTrackAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Forget the prepared track (alarm turned off). Leaves the file: re-arming
  /// soon after is common, and one track is not worth re-downloading.
  static Future<void> clearPreparedTrack() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kTrackPath);
      await prefs.remove(kTrackId);
    } catch (_) {}
  }

  // Handover from the native alarm

  /// What the native alarm service is currently playing, if anything:
  /// `{active, videoId, positionMs, fallback}`.
  static Future<Map<String, dynamic>> audioState() async {
    try {
      final res = await _ch.invokeMapMethod<String, dynamic>('alarmAudioState');
      return res ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// Stop the native alarm audio, so Dart can own the audio output instead.
  static Future<void> stopAudio() async {
    try {
      await _ch.invokeMethod('stopAlarmAudio');
    } catch (_) {}
  }

  /// Called when the alarm was stopped by something OTHER than the on-screen
  /// buttons — currently the volume rocker. Set by the ringing screen so it can
  /// close itself; the audio is already stopped by then.
  static void Function()? onStoppedExternally;

  /// Wire the native -> Dart direction of the alarm channel. Idempotent.
  static void listenForExternalStop() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'alarmStoppedExternally') onStoppedExternally?.call();
      return null;
    });
  }

  /// Close the alarm screen: drop the lockscreen flags and, when the alarm is
  /// what opened Auvy, leave the app so the phone returns to where it was.
  static Future<void> exitAlarmScreen() async {
    try {
      await _ch.invokeMethod('exitAlarmScreen');
    } catch (_) {}
  }

  // There was a second exit here, AND it did nothing
  //
  // `releaseAlarmScreen()` sat below [exitAlarmScreen] with a confident doc
  // comment — "dropping them promptly is what keeps the rest of the app off a
  // locked phone", and it invoked `releaseAlarmScreen` on the alarm channel.
  // That method has never existed on the native side. The call returned
  // notImplemented and the `catch (_) {}` swallowed it, so it was a silent no-op
  // wearing the description of a privacy control.
  //
  // No harm was done, because it had ZERO callers: every real path goes through
  // [exitAlarmScreen], which calls showOverLockscreen(false) and works. It was
  // removed rather than wired up — a plausible second way to do something that
  // is already handled is a trap, and the identical mistake had already been made
  // once with `keepScreenOn` (invoked on the player channel, which has no window
  // handler, so the setting did nothing at all).
  //
  // If a caller ever needs this, call [exitAlarmScreen]. Do not reintroduce a
  // parallel method: test/documented_invariants_test.dart now fails the build if
  // any Dart channel call has no native handler, which is what would have caught
  // both of these on the day they were written.

  /// Stop the audio and re-arm this alarm in [snoozeMinutes] minutes.
  ///
  /// The re-arm happens natively via AlarmManager, so it survives the app being
  /// killed while the user goes back to sleep, which is the whole point of a
  /// snooze and something a Dart timer could not promise.
  static Future<void> snooze() async {
    try {
      await _ch.invokeMethod('snoozeAlarm');
    } catch (_) {}
  }

  /// When a pending snooze will fire, or null when none is armed.
  ///
  /// ASKED NATIVELY EVERY TIME, NEVER CACHED. Snooze is usually tapped from the
  /// alarm's own notification, which means it can be armed while this Dart isolate
  /// does not exist. Nothing in the app is told; the only durable record is the one
  /// the native service writes, cross-checked there against the live AlarmManager
  /// PendingIntent. A cached copy here would go stale the moment the alarm fires,
  /// the phone reboots, or the alarm is switched off.
  static Future<DateTime?> snoozeTarget() async {
    try {
      final at = await _ch.invokeMethod<int>('snoozeAt');
      if (at == null || at <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {
      return null;
    }
  }

  /// Call off a pending snooze. True when there was one to cancel.
  ///
  /// Snooze used to be a one-way door: tap it half asleep and the alarm WAS coming
  /// back, with no way to change your mind short of switching the whole alarm off
  ///, which then also loses the schedule for tomorrow.
  static Future<bool> cancelSnooze() async {
    try {
      return await _ch.invokeMethod<bool>('cancelSnooze') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// "07:30" for display.
  static String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// "Every day" / "Weekdays" / "Mon, Wed, Fri" / "Once".
  static String get daysLabel {
    if (days.isEmpty) return 'Once';
    if (days.length == 7) return 'Every day';
    const weekdays = {1, 2, 3, 4, 5};
    if (days.length == 5 && days.containsAll(weekdays)) return 'Weekdays';
    if (days.length == 2 && days.contains(6) && days.contains(7)) return 'Weekends';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final sorted = days.toList()..sort();
    return sorted.map((d) => names[d - 1]).join(', ');
  }
}
