import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:auvy/services/audio_capture_service.dart';
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/services/song_recognition_service.dart';

/// Identifies a song while the app is closed (Android).
///
/// AudioCaptureService starts a headless Flutter engine here when a Quick
/// Settings tile capture finishes and no normal engine is running. Fingerprinting
/// and the catalogue lookup are Dart, so without this the user would have to open
/// the app to get an answer.
///
/// The engine has no Activity and no UI. It identifies the pending capture, sends
/// the result back over a channel so native code can post the notification, and
/// asks to be shut down, all within a few seconds.
///
/// Must stay a top-level function marked `@pragma('vm:entry-point')`: native code
/// calls it by name, and without the pragma release builds tree-shake it away.
@pragma('vm:entry-point')
Future<void> headlessRecognitionMain() async {
  // Needed even without UI, because channels are platform messages and require
  // the binding.
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.auvy.app/headless_recognition');

  /// Tells native code which step was just reached.
  ///
  /// This is the only diagnostic this path has: release builds drop print() and a
  /// headless isolate has no screen. Native code logs each step and names the last
  /// one if it times out.
  ///
  /// Pass constants only, never a title, artist, query or file path, since this
  /// runs in release builds.
  Future<void> phase(String name) async {
    try {
      await channel.invokeMethod('phase', {'name': name});
    } catch (_) {}
  }

  Future<void> report(String title, String text, {bool found = false}) async {
    try {
      await channel.invokeMethod('result', {
        'title': title,
        'text': text,
        'found': found,
      });
    } catch (_) {
      // Nothing to fall back to; native code shuts the engine down on a timeout.
    }
  }

  try {
    await phase('booted');
    final pcm = await AudioCaptureService.takePendingCapture();
    if (pcm == null || pcm.isEmpty) {
      await report('Nothing to identify', 'No audio was captured.');
      return;
    }
    await phase('captured');

    final outcome = await SongRecognitionService().recognizeFromPcm(pcm);
    await phase('looked-up');
    final r = outcome.result;
    if (r != null) {
      // Also recorded here so a match found while the app was closed still appears
      // in Recognised songs.
      try {
        await RecognitionHistory.add(RecognitionEntry(
          title: r.title,
          artist: r.artist,
          coverArtUrl: r.bestCoverArt,
          at: DateTime.now(),
        ));
      } catch (_) {}
      await report(r.title, r.artist, found: true);
    } else {
      await report(
          'No match', outcome.message ?? 'Could not identify that audio.');
    }
  } catch (e) {
    await report('Could not identify', 'Something went wrong listening.');
  }
}
