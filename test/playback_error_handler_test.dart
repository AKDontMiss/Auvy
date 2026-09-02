import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/logic/playback_error_handler.dart';

/// `PlaybackErrorHandler` — the line a playback failure leaves in the transcript.
///
/// ── WHY THIS NEEDED TESTS ───────────────────────────────────────────────────
///
/// It had none, and it was broken in a way tests would have caught immediately:
/// the classifier tested `errorStr.contains('http')` and
/// `errorStr.contains('source')`. Dart exceptions from the play path quote the
/// stream URL, and media3 reports "Source error" for most IO faults — so that
/// branch absorbed nearly every failure and answered "Connection lost.
/// Retrying..." to all of them, leaving the `format` branch below it
/// unreachable.
///
/// A log line that says the same thing whatever happened is worse than no line:
/// it sends the reader after a network problem that is often not there. That
/// cost real time during the 2026-08-30 throttle, where the distinction between
/// a REFUSAL and an OUTAGE was the whole question.
///
/// The exceptions below are the real shapes this receives — the play path
/// catches Dart exceptions, not the native error payload.
void main() {
  final h = PlaybackErrorHandler();

  String kindOf(Object e) => h.handleError(e, 'abc12345678');

  group('classifies the failure it actually got', () {
    test('a DNS failure is no network', () {
      expect(
          kindOf(const SocketException('Failed host lookup: googlevideo.com')),
          contains('no network'));
    });

    test('a timeout is a timeout, even though its message names a url', () {
      expect(
          kindOf(TimeoutException(
              'Future not completed for https://rr3---sn-x.googlevideo.com/videoplayback')),
          contains('timed out'));
    });

    test('403 is a refusal, not an outage', () {
      // THE DISTINCTION THAT MATTERED MOST. During the throttle every client
      // refused while the network was perfectly fine, and calling that
      // "connection lost" is what made it look like an outage.
      expect(kindOf(Exception('CatalogApiException(statusCode: 403)')),
          contains('refused by the server'));
    });

    test('404 and 410 are an expired stream', () {
      expect(kindOf(Exception('HTTP 404 for https://x/videoplayback')),
          contains('stream gone'));
      expect(kindOf(Exception('HTTP 410 Gone')), contains('stream gone'));
    });

    test('a decoder failure is NOT reported as a connection problem', () {
      // The old code could never reach its own format branch, because the
      // message quotes the URI and 'http' was matched first.
      expect(
          kindOf(PlatformException(
              code: 'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED',
              message: 'Decoding format unsupported for '
                  'https://rr3---sn-x.googlevideo.com/videoplayback?itag=251')),
          contains('decoder will not take'));
    });

    test('a resolver that found nothing says so', () {
      expect(kindOf(Exception('No fresh stream available during heal')),
          contains('nothing resolved'));
    });

    test('an unknown failure is admitted as unknown, not guessed at', () {
      // HONESTY IS THE POINT. A fallback that claims a cause invents one.
      expect(kindOf(Exception('something nobody has seen before')),
          contains('unrecognised'));
    });
  });

  group('the line is diagnostic, not a canned phrase', () {
    test("it carries the exception's own text and type", () {
      final line = kindOf(const SocketException('Failed host lookup: x.com'));
      expect(line, contains('SocketException'),
          reason: 'The runtime type is what lets a reader tell two failures of '
              'the same category apart.');
      expect(line, contains('Failed host lookup: x.com'),
          reason: "The exception's own message was thrown away by the previous "
              'version, leaving nothing to search a transcript for.');
    });

    test('it names the track, so a retry landing elsewhere is visible', () {
      expect(h.handleError(Exception('boom'), 'abc12345678'),
          contains('abc12345678'));
    });

    test('an empty songId adds no empty brackets', () {
      final line = h.handleError(Exception('boom'), '');
      expect(line, isNot(contains('[]')));
      expect(line, startsWith('playback failed —'));
    });
  });

  group('getRetryDelay', () {
    test('climbs 2, 4, 8, 16', () {
      expect(h.getRetryDelay(0), const Duration(seconds: 2));
      expect(h.getRetryDelay(1), const Duration(seconds: 4));
      expect(h.getRetryDelay(2), const Duration(seconds: 8));
      expect(h.getRetryDelay(3), const Duration(seconds: 16));
    });

    test('WARN: is clamped at BOTH ends rather than throwing', () {
      // The caller passes a running error count, which is exactly the kind of
      // value that walks past what a fixed table assumed. An index error here
      // would crash the recovery path — the one path whose job is to survive a
      // failure.
      expect(h.getRetryDelay(4), const Duration(seconds: 16));
      expect(h.getRetryDelay(99), const Duration(seconds: 16));
      expect(h.getRetryDelay(-1), const Duration(seconds: 2));
      expect(h.getRetryDelay(-100), const Duration(seconds: 2));
    });

    test('never returns zero, so a retry storm cannot be instant', () {
      for (var i = -5; i < 20; i++) {
        expect(h.getRetryDelay(i).inSeconds, greaterThan(0));
      }
    });
  });
}
