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

/// Song recognition audio capture (Android).
///
/// [capture] is the in-app path: it asks for consent (MediaProjection), records
/// another app's playback for a few seconds, and releases. Android only grants
/// MediaProjection to a running foreground service of type `mediaProjection`, so
/// the recording is done natively (`AudioCaptureService`).
///
/// The quick-settings tile records from the microphone instead (see
/// TileCaptureActivity). Its captures land on disk, and [takePendingCapture]
/// collects them; if Auvy isn't running, native code identifies them in a
/// headless engine.
///
/// Apps may opt out of playback capture (`ALLOW_CAPTURE_BY_NONE`; Spotify,
/// Netflix and most DRM video do), so a silent capture is a normal outcome,
/// reported as [CaptureFailure.noAudio].
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
      // The return value matters: native uses it to decide whether to run the
      // headless recogniser instead. False means "nobody here can take it", so native
      // goes headless.
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

  /// Posts the "found" notification for a recognised song.

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
      // reload() is required. SharedPreferences caches values in memory after the
      // first read, and this key is written by native code
      // (AudioCaptureService.micToFile), which can't invalidate the Dart cache. Without
      // the reload, a running app would miss a capture sitting on disk until it was
      // restarted.
      await prefs.reload();
      final path = prefs.getString(_kPending);
      if (path == null || path.isEmpty) return null;
      await prefs.remove(_kPending);
      final f = File(path);
      if (!await f.exists()) {
        // Marker present but the audio file is gone: something deleted it between the
        // write and this read.
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

  /// Asks for consent, then captures [seconds] of this device's audio as 16-bit
  /// mono little-endian PCM at [sampleRate].
  ///
  /// Throws [CaptureException] instead of returning null so the caller must handle
  /// why it failed: "declined" and "nothing was playing" need different messages.
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
