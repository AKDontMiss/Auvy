import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/adaptive_bitrate.dart';

/// Pins the bitrate ladder. The failure modes being guarded against are all
/// AUDIBLE ones, so each test names the sound the user would hear if it broke:
/// quality that ratchets down and never recovers, a cold start that begins at
/// the floor, oscillation between two rungs, and a data-saver cap that a fast
/// network quietly overrides.

BitrateDecision _decide(
  BitrateDecision from, {
  int stalls = 0,
  int estimate = 1000000,
  bool dataSaver = false,
}) =>
    nextBitrateDecision(
      current: from,
      stalls: stalls,
      estimateBps: estimate,
      dataSaver: dataSaver,
    );

void main() {
  group('downgrade', () {
    test('a stall steps down exactly one rung', () {
      // One rung at a time: a single stall can be a tunnel, and dropping
      // straight to the floor is how quality ends up stuck there.
      final d = _decide(const BitrateDecision(rung: 0), stalls: 1);
      expect(d.rung, 1);
      expect(d.ceilingBps, 160000);
    });

    test('repeated stalls walk down, and stop at the floor', () {
      var d = const BitrateDecision(rung: 0);
      for (var i = 0; i < 10; i++) {
        d = _decide(d, stalls: 1);
      }
      expect(d.rung, kBitrateLadder.length - 1);
      expect(d.ceilingBps, 64000);
    });

    test('throughput below the floor drops immediately, without waiting for a stall', () {
      // Adapting means acting on the measurement. Waiting for the stall would
      // make the user hear the problem first.
      final d = _decide(const BitrateDecision(rung: 0), estimate: 20000);
      expect(d.rung, kBitrateLadder.length - 1);
    });

    test('a stall resets any progress toward climbing', () {
      final d = _decide(const BitrateDecision(rung: 2, cleanRuns: 2), stalls: 1);
      expect(d.rung, 3);
      expect(d.cleanRuns, 0);
    });
  });

  group('cold start', () {
    test('no estimate yet HOLDS instead of dropping', () {
      // The bug this prevents: every launch starting at the lowest quality and
      // audibly climbing back up, because "unknown" was read as "bad".
      final d = _decide(const BitrateDecision(rung: 0), estimate: kNoEstimate);
      expect(d.rung, 0);
    });

    test('no estimate does not count as a clean run either', () {
      final d = _decide(const BitrateDecision(rung: 2, cleanRuns: 2),
          estimate: kNoEstimate);
      expect(d.rung, 2, reason: 'must not climb on no evidence');
      expect(d.cleanRuns, 0);
    });
  });

  group('upgrade', () {
    test('one good run is not enough to climb', () {
      // Oscillation guard: upgrading on the first clean track walks straight
      // back into the next stall.
      final d = _decide(const BitrateDecision(rung: 2));
      expect(d.rung, 2);
      expect(d.cleanRuns, 1);
    });

    test('a streak of clean runs with headroom climbs one rung', () {
      var d = const BitrateDecision(rung: 2);
      for (var i = 0; i < kRunsBeforeUpgrade; i++) {
        d = _decide(d, estimate: 5000000);
      }
      expect(d.rung, 1);
      expect(d.cleanRuns, 0, reason: 'streak restarts after a climb');
    });

    test('a clean streak WITHOUT headroom does not climb', () {
      // Clean only because the current rung is modest. 130 kbps of throughput
      // cannot carry the 160 kbps rung above with any margin.
      var d = const BitrateDecision(rung: 2);
      for (var i = 0; i < kRunsBeforeUpgrade + 2; i++) {
        d = _decide(d, estimate: 130000);
      }
      expect(d.rung, 2);
    });

    test('already at the top stays at the top', () {
      var d = const BitrateDecision(rung: 0);
      for (var i = 0; i < 10; i++) {
        d = _decide(d, estimate: 9000000);
      }
      expect(d.rung, 0);
    });
  });

  group('data saver', () {
    test('pins the ceiling even on a fast network', () {
      // It protects a data allowance, not the listening experience — so a fast
      // network is NOT a reason to start spending someone's megabytes.
      var d = const BitrateDecision(rung: 0);
      for (var i = 0; i < 10; i++) {
        d = _decide(d, estimate: 9000000, dataSaver: true);
      }
      expect(d.ceilingBps, lessThanOrEqualTo(kDataSaverCeiling));
    });

    test('still allows dropping BELOW the cap on a bad network', () {
      final d = _decide(const BitrateDecision(rung: 3),
          stalls: 1, dataSaver: true);
      expect(d.ceilingBps, 64000);
    });
  });

  group('format picking', () {
    final formats = <Map<String, dynamic>>[
      {'itag': 251, 'bitrate': 160000},
      {'itag': 140, 'bitrate': 128000},
      {'itag': 250, 'bitrate': 70000},
      {'itag': 249, 'bitrate': 50000},
    ];

    test('no cap takes the best', () {
      expect(pickFormatForCeiling(formats, ceilingBps: 0)!['itag'], 251);
    });

    test('takes the highest at or below the cap', () {
      expect(pickFormatForCeiling(formats, ceilingBps: 128000)!['itag'], 140);
      expect(pickFormatForCeiling(formats, ceilingBps: 96000)!['itag'], 250);
      expect(pickFormatForCeiling(formats, ceilingBps: 64000)!['itag'], 249);
    });

    test('a cap below everything still returns the smallest, not null', () {
      // Returning nothing here would mean silence. A stream slightly larger
      // than requested still plays.
      expect(pickFormatForCeiling(formats, ceilingBps: 1000)!['itag'], 249);
    });

    test('bitrate as a STRING is handled', () {
      // YouTube's payload is not consistently typed, and a parse failure would
      // read as bitrate 0 and silently pick the worst format.
      final asStrings = <Map<String, dynamic>>[
        {'itag': 251, 'bitrate': '160000'},
        {'itag': 140, 'bitrate': '128000'},
      ];
      expect(pickFormatForCeiling(asStrings, ceilingBps: 130000)!['itag'], 140);
    });

    test('empty list returns null rather than throwing', () {
      expect(pickFormatForCeiling(const [], ceilingBps: 0), isNull);
    });
  });
}
