import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The tile capture that only appeared after restarting the app.
///
/// ── WHAT HAPPENED ───────────────────────────────────────────────────────────
///
/// Captured live on device, 2026-08-31:
///
///   AuvyCapture: mic capture written: 708608 bytes
///   flutter    : handoff accepted — identifying the tile capture
///   flutter    : identify: nothing pending
///
/// 708 KB of audio on disk, the handoff accepted, and Dart reporting nothing to
/// do — 1ms apart.
///
/// SharedPreferences reads the platform once and answers every later getString
/// from an in-memory cache. The pending marker is written by NATIVE code
/// (AudioCaptureService.micToFile) straight into the FlutterSharedPreferences
/// XML, and a native write cannot invalidate a Dart cache. A live app therefore
/// asked a cache that predated the capture and was told there wasn't one.
///
/// Restarting the app "fixed" it because a new process builds a new cache from
/// the same XML that had held the marker the whole time. And it only ever hit
/// the LIVE path: with the process dead, native runs the headless engine, whose
/// isolate has a cold cache, so that route always worked. Hence intermittent,
/// and hence the appearance that reopening Auvy was a required step.
void main() {
  final svc = codeOf('lib/services/audio_capture_service.dart');

  group('takePendingCapture', () {
    /// Everything from the method head to its first return of the marker.
    String head() {
      final start = svc.indexOf('static Future<Uint8List?> takePendingCapture');
      expect(start, greaterThan(-1),
          reason: 'takePendingCapture is gone or was renamed.');
      final end = svc.indexOf('final path =', start);
      expect(end, greaterThan(start));
      return svc.substring(start, end);
    }

    test('reloads before reading the marker', () {
      expect(head().contains('await prefs.reload()'), isTrue,
          reason: 'The reload is gone. Without it a running app reads a cache '
              'that predates the capture, and the tile silently drops it.');
    });

    test('the reload comes BEFORE the read, not after', () {
      // Ordering is the entire fix — a reload afterwards refreshes a cache
      // nobody then consults.
      final reload = svc.indexOf('await prefs.reload()');
      final read = svc.indexOf("prefs.getString(_kPending)");
      final remove = svc.indexOf('prefs.remove(_kPending)');
      expect(reload, greaterThan(-1));
      expect(read, greaterThan(-1));
      expect(reload, lessThan(read),
          reason: 'The reload moved after the read, which restores the bug '
              'while looking like the fix is still present.');
      expect(read, lessThan(remove),
          reason: 'The marker is cleared before it is read.');
    });

    test('a marker with no file is reported, not silently dropped', () {
      // "nothing pending" and "the audio vanished" are different failures with
      // different causes, and one message for both is what made the original
      // bug so hard to place.
      expect(svc.contains('marker pointed at a missing file'), isTrue,
          reason: 'The missing-file case is silent again.');
    });
  });

  group('the native side still writes what Dart reads', () {
    final kotlin =
        codeOf('android/app/src/main/kotlin/com/auvy/app/AudioCaptureService.kt');

    test('the pref key matches on both sides', () {
      // Dart namespaces it plainly; native has to add shared_preferences own
      // `flutter.` prefix. A rename on one side alone is silent in both
      // directions, so pin the pair.
      expect(svc.contains("_kPending = 'auvy_pending_capture'"), isTrue,
          reason: 'The Dart key changed.');
      expect(kotlin.contains('"flutter.auvy_pending_capture"'), isTrue,
          reason: 'The native key changed and no longer matches Dart.');
    });

    test('native writes the marker with apply(), which Dart cannot observe', () {
      // Documents WHY the reload above is required — if this ever becomes a
      // MethodChannel push instead, the reload can go.
      expect(kotlin.contains('putString(PREF_PENDING'), isTrue,
          reason: 'Native no longer writes the marker through prefs. If the '
              'handoff now carries the path directly, takePendingCapture can '
              'drop its reload — check before deleting this test.');
    });
  });
}
