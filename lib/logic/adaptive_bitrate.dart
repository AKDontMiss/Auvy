/// Adaptive bitrate: picks the audio quality ceiling from how the network is
/// actually performing, not from the connection type.
///
/// When playback stalls mid-track it steps down one quality level so music keeps
/// playing, and climbs back once the network has been clean for a while. The
/// decision logic is pure and tested in test/adaptive_bitrate_verify.dart.
library;

/// Ceilings in bits per second, best first; 0 means no cap. Each rung matches a
/// format YouTube actually serves (Opus ~160 kbps, AAC ~128 kbps, smaller Opus
/// formats around 70 and 50 kbps).
const List<int> kBitrateLadder = <int>[0, 160000, 128000, 96000, 64000];

/// The ceiling used in data-saver mode: less data, but not the lowest quality.
const int kDataSaverCeiling = 96000;

/// Below this, an estimate is treated as "the network cannot sustain music".
const int kFloorEstimate = 40000;

/// media3 reports this when it has not measured anything yet.
const int kNoEstimate = -1;

/// Above this, the "measured throughput" did not come from the network.
///
/// The player's bandwidth meter also counts reads from downloaded files and the
/// play cache, which report hundreds of Mbps. Such readings say nothing about the
/// network, so they are treated as "no estimate". 40 Mbps is far above anything
/// audio needs and far below a disk read.
const int kImplausibleEstimate = 40000000;

/// Required throughput margin over a format's bitrate before choosing it, since
/// guessing too high causes a stall.
const double kHeadroom = 1.4;

/// State carried between decisions. Immutable, so each decision is a pure
/// function of the previous state and new measurements.
class BitrateDecision {
  /// Index into [kBitrateLadder].
  final int rung;

  /// Consecutive decisions with no stalls. Climbing needs several in a row, so one
  /// good moment on a bad network does not cause back-and-forth switching.
  final int cleanRuns;

  /// When the last downgrade happened (epoch ms, 0 if never). Passed in rather
  /// than read from a clock so decisions stay pure (see [kDowngradeCooldownMs]).
  final int lastDowngradeMs;

  const BitrateDecision({
    this.rung = 0,
    this.cleanRuns = 0,
    this.lastDowngradeMs = 0,
  });

  /// The cap to hand the format picker, in bps. 0 = uncapped.
  int get ceilingBps => kBitrateLadder[rung];

  @override
  String toString() =>
      'BitrateDecision(rung: $rung, ceiling: $ceilingBps, clean: $cleanRuns)';
}

/// Clean runs needed before climbing one rung, when throughput was measured.
const int kRunsBeforeUpgrade = 3;

/// Clean runs needed before climbing when throughput could not be measured.
///
/// Usually the reading is a cache read and gets discarded, so requiring a
/// measurement would mean never climbing back after a stall. Twice the measured
/// threshold, because this infers recovery from the absence of stalls. If the
/// network cannot carry the higher rung, it stalls and steps back down.
const int kRunsBeforeBlindUpgrade = 6;

/// Minimum time between two downgrades. Decisions happen per resolve and
/// resolves come in bursts (queue refill, preloads), so without spacing one bad
/// moment could drop several rungs at once.
const int kDowngradeCooldownMs = 60000;

/// Works out the next quality ceiling.
///
/// [stalls] is the number of mid-track stalls since the last decision (reset
/// natively on each read). [estimateBps] is measured throughput, or
/// [kNoEstimate] before enough traffic has been seen.
///
/// [dataSaver] caps the result at [kDataSaverCeiling]: it protects the user's
/// data allowance, so a fast network is no reason to exceed it.
///
/// [nowMs] is the current time in epoch ms, passed in to keep this pure; it is
/// only used to space downgrades.
BitrateDecision nextBitrateDecision({
  required BitrateDecision current,
  required int stalls,
  required int estimateBps,
  required int nowMs,
  bool dataSaver = false,
  int? userQualityCeiling,
}) {
  var rung = current.rung;
  var clean = current.cleanRuns;
  var lastDowngradeMs = current.lastDowngradeMs;

  // Discard a reading that cannot be the network (see [kImplausibleEstimate]);
  // it counts as unmeasured, not as fast.
  final estimate =
      estimateBps > kImplausibleEstimate ? kNoEstimate : estimateBps;

  if (stalls > 0) {
    // A stall: step down one rung (not straight to the lowest, since one stall can
    // be a brief dropout) and reset the climb streak. Limited to one downgrade per
    // cooldown period; the stall count is consumed either way.
    final firstEver = lastDowngradeMs == 0;
    if (firstEver || nowMs - lastDowngradeMs >= kDowngradeCooldownMs) {
      rung = (rung + 1).clamp(0, kBitrateLadder.length - 1);
      lastDowngradeMs = nowMs;
    }
    clean = 0;
  } else if (estimate != kNoEstimate && estimate < kFloorEstimate) {
    // No stall yet, but measured throughput cannot sustain music: go to the lowest
    // rung now. Not limited by the cooldown, since this is a direct measurement.
    rung = kBitrateLadder.length - 1;
    lastDowngradeMs = nowMs;
    clean = 0;
  } else {
    // A clean run: no stall and nothing measured as failing. Cold start lands here
    // too (at rung 0 there is nothing to climb to). An unmeasurable reading does not
    // reset the streak, since that is the normal state when playing from cache.
    clean = current.cleanRuns + 1;
    final measured = estimate != kNoEstimate;
    final needRuns = measured ? kRunsBeforeUpgrade : kRunsBeforeBlindUpgrade;
    if (rung > 0 && clean >= needRuns) {
      if (!measured) {
        // Climbing on the absence of stalls alone (see [kRunsBeforeBlindUpgrade]).
        rung -= 1;
        clean = 0;
      } else {
        final target = kBitrateLadder[rung - 1];
        // Rung 0 is uncapped, so require comfortable margin over the highest format.
        final needed = (target == 0 ? 160000 : target) * kHeadroom;
        if (estimate >= needed) {
          rung -= 1;
          clean = 0;
        }
      }
    }
  }

  if (dataSaver) {
    // Find the first rung at or below the data-saver cap.
    var pinned = rung;
    for (var i = 0; i < kBitrateLadder.length; i++) {
      final c = kBitrateLadder[i];
      if (c != 0 && c <= kDataSaverCeiling) {
        pinned = i;
        break;
      }
    }
    if (rung < pinned) rung = pinned;
  }

  if (userQualityCeiling != null && userQualityCeiling > 0) {
    var pinned = rung;
    for (var i = 0; i < kBitrateLadder.length; i++) {
      final c = kBitrateLadder[i];
      if (c != 0 && c <= userQualityCeiling) {
        pinned = i;
        break;
      }
    }
    if (rung < pinned) rung = pinned;
  }

  return BitrateDecision(
    rung: rung,
    cleanRuns: clean,
    lastDowngradeMs: lastDowngradeMs,
  );
}

/// Picks the format to play from what the server offered.
///
/// [formats] are `{bitrate: int}` maps (YouTube's adaptiveFormats); a
/// [ceilingBps] of 0 means take the best. Returns the best format at or below the
/// ceiling, or the lowest available if all exceed it (something always plays).
Map<String, dynamic>? pickFormatForCeiling(
  List<Map<String, dynamic>> formats, {
  required int ceilingBps,
}) {
  if (formats.isEmpty) return null;

  int rateOf(Map<String, dynamic> f) => int.tryParse('${f['bitrate'] ?? 0}') ?? 0;

  final sorted = [...formats]..sort((a, b) => rateOf(b).compareTo(rateOf(a)));
  if (ceilingBps <= 0) return sorted.first;

  for (final f in sorted) {
    if (rateOf(f) <= ceilingBps) return f;
  }
  // Everything is above the cap: take the smallest.
  return sorted.last;
}
