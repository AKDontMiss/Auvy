import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:auvy/services/audio_capture_service.dart';
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/services/song_recognition_service.dart';

/// Identify with the app closed
///
/// Entry point for a HEADLESS Flutter engine, started from
/// AudioCaptureService when a tile capture lands and no normal engine exists.
///
/// The problem it solves: fingerprinting and the catalogue lookup are Dart, so
/// with Auvy closed there was nobody to run them. The capture sat on disk and the
/// notification could only say "tap to identify in Auvy", which made opening the
/// app look like a required step in what should be a one-tap feature.
///
/// A headless engine runs Dart with no Activity, no window and no UI. It boots,
/// identifies the pending capture, reports the answer back over a channel so
/// native can post the notification, and asks to be torn down. Lifetime is a few
/// seconds.
///
/// MUST BE A TOP-LEVEL FUNCTION MARKED `@pragma('vm:entry-point')`. Release
/// builds tree-shake anything unreachable from `main`, and this is only ever
/// called by name from the native side — without the pragma it is compiled away
/// and the engine starts into nothing.
@pragma('vm:entry-point')
Future<void> headlessRecognitionMain() async {
  // Needed even with no UI: the channel is a platform message and requires the
  // binding to exist.
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.auvy.app/headless_recognition');

  /// Tell native which step we just reached.
  ///
  /// THE ONLY DIAGNOSTIC THIS PATH HAS. Release builds swallow print() and a
  /// headless isolate has no screen, so a run that stalled produced one line —
  /// "timed out", and no way to tell a missing plugin from a slow lookup from a
  /// hang before the first await. Native logs each phase and names the last one
  /// in its timeout message.
  ///
  /// Constants only. Never a title, artist, query or file path: this ships in
  /// release, and a log line that cannot leak beats one that relies on print()
  /// being compiled out.
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
      // Nothing to fall back to — native tears the engine down on a timeout.
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
      // Recorded here as well as in the in-app path, so a match found while the
      // app was closed still shows up in Recognised songs — the whole point of
      // keeping that list.
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
