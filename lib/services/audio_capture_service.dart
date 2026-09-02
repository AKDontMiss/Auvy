import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Why a capture attempt failed, so the UI can say something true.
enum CaptureFailure {
  /// User declined Android's screen-capture consent dialog.
  denied,

  /// Captured successfully, but the stream was silence — almost always an app
  /// that opts out of playback capture, or nothing actually playing.
  noAudio,

  /// Android 9 or older: `AudioPlaybackCapture` doesn't exist.
  unsupported,

  other,
}

class CaptureException implements Exception {
  final CaptureFailure reason;
  final String message;
  const CaptureException(this.reason, this.message);
  @override
  String toString() => message;
}

/// Captures the audio ANOTHER app on this device is playing, for recognition.
///
/// The heavy lifting is native (`AudioCaptureService`) because Android only grants
/// `MediaProjection` to a running foreground service of type `mediaProjection`.
/// This just triggers it and receives the PCM.
///
/// ## Two ways in
/// [capture] is the one-shot path used by the in-app long-press: it prompts for
/// consent, records, releases. Only useful for audio that keeps playing while Auvy
/// is foreground.
///
/// [arm] is the quick-settings path. It prompts ONCE and keeps the projection, so
/// every later tile tap records with no dialog, which is the only way to identify
/// something in an app that pauses when it loses focus (Instagram Reels and most
/// short-video feeds do). Tile captures land on disk; [takePendingCapture] collects
/// them when Auvy next opens.
///
/// ## What to expect
/// Apps may opt out of being captured (`ALLOW_CAPTURE_BY_NONE`) — Spotify, Netflix
/// and most DRM video do. A silent capture is therefore a normal outcome, reported
/// as [CaptureFailure.noAudio] rather than a crash.
class AudioCaptureService {
  const AudioCaptureService._();

  static const MethodChannel _channel =
      MethodChannel('com.auvy.app/audiocapture');

  /// Matches what the Shazam signature pipeline expects, so captured PCM can go
  /// straight into it with no resampling.
  static const int sampleRate = 44100;

  /// Pref the NATIVE side writes when a quick-settings capture is waiting. Read
  /// (and cleared) by [takePendingCapture].
  static const String _kPending = 'auvy_pending_capture';

  /// False on Android 9 and older, where the API doesn't exist.
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the quick-settings tile can currently capture.
  /// Called the moment a tile capture is ready to identify.
  ///
  /// This is what turns the tile from "captured, go and look" into an answer: the
  /// native service posts "Identifying…", fires this, and whoever is listening
  /// identifies the audio and replaces that notification with the song.
  static void Function()? onPendingReady;

  /// Wire the native → Dart direction. Idempotent; safe to call more than once.
  static void listenForPendingCaptures() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'pendingCaptureReady') return null;
      // THE RETURN VALUE IS LOAD-BEARING. Native waits on it to decide whether
      // to run the headless recogniser instead, so returning true without a
      // listener attached would strand the capture, which is the bug this
      // replaced. False means "nobody here can take it", and native goes headless.
      final handler = onPendingReady;
      if (handler == null) {
        print('handoff declined: no listener attached');
        return false;
      }
      print('handoff accepted — identifying the tile capture');
      // Not awaited: native only needs to know the work was TAKEN, and holding
      // the reply until recognition finishes would trip its timeout.
      handler();
      return true;
    });
  }

  /// Grant screen-audio capture ONCE, so later captures need no further consent.
  ///
  /// THIS HAD NO DART WRAPPER, WHICH MADE ARMED MODE UNREACHABLE. The native
  /// `arm` / `disarm` handlers and `isArmed` all existed, and AudioCaptureService's
  /// whole ARMED path was built around them, but nothing in Dart could call them,
  /// so the mode could be reported and never entered. The quick-settings tile
  /// depends on it: without arming it can only ever say "Open Auvy to enable".
  ///
  /// Shows the system MediaProjection dialog, so it must be called from a visible
  /// screen. Returns false if the user declines or the device is pre-Android 10.
  static Future<bool> arm() async {
    try {
      return await _channel.invokeMethod<bool>('arm') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Drop the capture grant. The tile goes unavailable again.
  static Future<void> disarm() async {
    try {
      await _channel.invokeMethod('disarm');
    } catch (_) {}
  }

  static Future<bool> isArmed() async {
    try {
      return await _channel.invokeMethod<bool>('isArmed') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Grants capture ONCE and keeps it, so the tile never prompts again.
  ///
  /// `MediaProjection` only prompts on acquisition, so retaining one projection is
  /// what makes the tile usable at all — re-acquiring per capture would throw the
  /// system dialog over whatever app you're watching and pause it, which is exactly
  /// the failure the tile exists to avoid.
  ///
  /// Costs a persistent notification for as long as it stays armed. Android
  /// mandates that; it is not something Auvy can suppress.
  // Arm / disarm removed with the quick-settings tile
  //
  // Arming existed so a TILE could capture without an Activity: MediaProjection
  // consent can only be raised from one, so the grant had to be taken in-app and
  // held. That made identifying a song a two-step setup — grant here, then find
  // the tile in the shade — for something the in-app button does directly.
  //
  // The tile is gone (its found-notification hand-off also never wrote to
  // RecognitionHistory, so tapping it opened an app with nothing to show). The
  // in-app path asks for consent per capture, which is one dialog instead of a
  // permanent projection plus its mandatory ongoing notification.
  //
  // The native service still understands ACTION_ARM/ACTION_DISARM. Left there
  // deliberately: background recognition is the one thing the tile could do that
  // the button cannot, so if it is ever wanted back the plumbing is intact.

  /// Posts a "song found" notification so the answer survives in the shade rather
  /// than living only in a sheet the user might dismiss. Tapping it returns to Auvy
  /// and opens the album.
  ///
  /// Fire-and-forget: a failed receipt must never surface as a failed
  /// identification.
  static Future<void> notifyFound(String title, String artist) async {
    try {
      await _channel
          .invokeMethod('notifyFound', {'title': title, 'artist': artist});
    } catch (_) {}
  }

  /// `"title artist"` when Auvy was opened by tapping a found-notification, else
  /// null. Read-and-clear natively, so a later resume can't re-open the same album.
  static Future<String?> consumeFoundTap() async {
    try {
      return await _channel.invokeMethod<String>('consumeFoundTap');
    } catch (_) {
      return null;
    }
  }

  /// Returns PCM left behind by a tile capture, or null if there isn't one.
  ///
  /// Clears the marker and deletes the file whether or not recognition then
  /// succeeds: a stale capture identified minutes later would name whatever was
  /// playing at some forgotten moment, which is worse than no answer at all.
  static Future<Uint8List?> takePendingCapture() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // reload() IS THE WHOLE FIX. DO NOT REMOVE IT.
      //
      // SharedPreferences reads the platform ONCE and serves every later
      // getString from an in-memory cache. This particular key is written by
      // NATIVE code (AudioCaptureService.micToFile, straight into the
      // FlutterSharedPreferences XML with .apply()), and a native write cannot
      // invalidate the Dart cache. So a RUNNING app asked its cache, was told
      // the key was absent, and dropped a capture that was sitting on disk.
      //
      // Which produced the exact reported behaviour: the tile records, the
      // notification sticks on "Identifying…", and then the answer appears the
      // instant Auvy is force-closed and reopened, because a fresh process
      // builds a fresh cache from the same XML that had the marker in it all
      // along. It looked like restarting the app was a required step.
      //
      // It was intermittent for the same reason it was confusing: with the
      // process DEAD the native side runs the headless engine, which is a new
      // isolate with a cold cache and therefore always worked. Only the live
      // path — the common one, since audio_service keeps the process alive long
      // after the UI is gone — could fail.
      await prefs.reload();
      final path = prefs.getString(_kPending);
      if (path == null || path.isEmpty) return null;
      await prefs.remove(_kPending);
      final f = File(path);
      if (!await f.exists()) {
        // Marker present, audio gone. Distinct from "nothing pending" and worth
        // saying so: it means something deleted the file between the write and
        // this read, which is a different bug from the one above.
        print('identify: marker pointed at a missing file');
        return null;
      }
      final bytes = await f.readAsBytes();
      try {
        await f.delete();
      } catch (_) {
        // A leftover temp file is harmless — the marker is already cleared, so it
        // can never be picked up twice.
      }
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Prompts for consent, then captures [seconds] of this device's audio as
  /// 16-bit mono little-endian PCM at [sampleRate].
  ///
  /// Throws [CaptureException] rather than returning null so the caller has to
  /// deal with WHY it failed — "declined" and "nothing was playing" need very
  /// different copy, and collapsing them was how the mic path used to mislead.
  static Future<Uint8List> capture({double seconds = 8.0}) async {
    try {
      final bytes = await _channel
          .invokeMethod<Uint8List>('capture', {'seconds': seconds});
      if (bytes == null || bytes.isEmpty) {
        throw const CaptureException(
            CaptureFailure.noAudio, 'No audio was captured.');
      }
      return bytes;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'DENIED':
          throw const CaptureException(CaptureFailure.denied,
              'Auvy needs permission to capture this device\'s audio.');
        case 'NO_AUDIO':
          throw const CaptureException(CaptureFailure.noAudio,
              'Nothing capturable was playing. Some apps block audio capture.');
        case 'UNSUPPORTED':
          throw const CaptureException(CaptureFailure.unsupported,
              'Capturing app audio needs Android 10 or newer.');
        default:
          throw CaptureException(
              CaptureFailure.other, e.message ?? 'Capture failed.');
      }
    } on MissingPluginException {
      throw const CaptureException(
          CaptureFailure.unsupported, 'Capturing app audio isn\'t available.');
    }
  }
}
