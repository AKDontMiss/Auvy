/// Adaptive bitrate
///
/// Picks the audio format ceiling from what the network is ACTUALLY doing,
/// rather than from what kind of network it claims to be.
///
/// WHY "AM I ON WI-FI?" WAS NOT GOOD ENOUGH. Quality used to be a boolean
/// flipped by the connectivity type: Wi-Fi got the highest format, mobile got a
/// lower one. Both halves of that are wrong often enough to matter — a café
/// Wi-Fi behind a captive portal is far worse than good 5G, and the switch fired
/// on the transition rather than on any evidence the network could not keep up.
/// A track that is stalling right now kept stalling.
///
/// The rule here is the one Spotify describes: when the connection degrades,
/// drop to a lower bitrate so the music KEEPS PLAYING instead of stopping, and
/// climb back when it recovers.
///
/// Everything in this file is pure. The decision is the part that has to be
/// right, so it is separated from the plumbing that measures and applies it and
/// is pinned by test/adaptive_bitrate_verify.dart.
library;

/// Ceilings in bits per second, best first. 0 means "no cap — take the best
/// format on offer".
///
/// Chosen against what YouTube actually serves for music: opus 251 is ~160 kbps,
/// AAC 140 is ~128 kbps, and the smaller opus formats sit around 70 and 50 kbps.
/// Each rung therefore corresponds to a format that really exists, rather than a
/// round number that would land between two of them and pick the lower by
/// accident.
const List<int> kBitrateLadder = <int>[0, 160000, 128000, 96000, 64000];

/// The rung a data-saving user is pinned to. Deliberately not the floor: the
/// point is to use less data, not to make music sound bad.
const int kDataSaverCeiling = 96000;

/// Below this, an estimate is treated as "the network cannot sustain music".
const int kFloorEstimate = 40000;

/// media3 reports this when it has not measured anything yet.
const int kNoEstimate = -1;

/// Above this, the "measured throughput" did not come from the network.
///
/// The estimate is polluted by disk reads
///
/// media3's bandwidth meter counts bytes moved by every DataSource the player
/// uses, and two of Auvy's read from local storage: `localFileSource` plays a
/// downloaded file outright, and `CacheDataSource` serves the play-cache
/// whenever the next 512 KB is already on disk. A disk read is hundreds of Mbps,
/// so those transfers inflate a number that is then used to decide what the
/// NETWORK can carry.
///
/// Measured on device 2026-08-31, on LTE reporting `LinkDnBandwidth>=6673Kbps`:
///
///     adaptive bitrate: rung 0 → 1 (ceiling 160000 bps, est 119837256 bps, stalls 3)
///     playback stalled — buffering for 3s with no audio
///
/// 119 Mbps on a 6.7 Mbps link — roughly eighteen times the real capacity — and
/// the ladder duly picked the top rung and then stalled its way back down.
///
/// 40 Mbps is far above anything audio needs (the highest rung is 160 kbps, so
/// this is 250x headroom) and far below what a disk read reports. An estimate
/// above it says nothing about the network, so it is treated as no estimate at
/// all rather than as good news.
const int kImplausibleEstimate = 40000000;

/// How much more throughput than the stream's bitrate we insist on before
/// choosing it. Audio is a steady trickle and the buffer is deep, but an
/// estimate that exactly equals the bitrate leaves nothing for a wobble — and
/// the cost of guessing high is a stall, which is the thing being avoided.
const double kHeadroom = 1.4;

/// State the ladder carries between decisions. Immutable so a decision is a pure
/// function of (previous state, new measurements).
class BitrateDecision {
  /// Index into [kBitrateLadder].
  final int rung;

  /// Consecutive decisions with no stalls and throughput to spare. Climbing
  /// needs several in a row, because one good moment on a bad network is normal
  /// and re-upgrading into the next stall is how you get audible oscillation.
  final int cleanRuns;

  const BitrateDecision({this.rung = 0, this.cleanRuns = 0});

  /// The cap to hand the format picker, in bps. 0 = uncapped.
  int get ceilingBps => kBitrateLadder[rung];

  @override
  String toString() =>
      'BitrateDecision(rung: $rung, ceiling: $ceilingBps, clean: $cleanRuns)';
}

/// How many clean runs in a row before climbing one rung.
const int kRunsBeforeUpgrade = 3;

/// Work out the next ceiling.
///
/// [stalls] is the count of MID-TRACK buffer underruns since the last decision
/// (read-and-cleared natively — a running total would re-trigger the same
/// downgrade forever). [estimateBps] is media3's measured throughput, or
/// [kNoEstimate] before it has seen enough traffic.
///
/// [dataSaver] pins the result at [kDataSaverCeiling] or lower. It is a HARD cap
/// and never climbs above that, because it exists to protect a data allowance
/// rather than the playback experience — a fast network is not a reason to spend
/// someone's megabytes when they asked you not to.
BitrateDecision nextBitrateDecision({
  required BitrateDecision current,
  required int stalls,
  required int estimateBps,
  bool dataSaver = false,
}) {
  var rung = current.rung;
  var clean = current.cleanRuns;

  // Discard a reading that cannot be the network. See [kImplausibleEstimate].
  // Treated as UNMEASURED rather than clamped to the ceiling: a disk read is not
  // weak evidence of a fast network, it is no evidence at all, and the branch
  // below already knows how to hold position when nothing has been measured.
  final estimate =
      estimateBps > kImplausibleEstimate ? kNoEstimate : estimateBps;

  if (stalls > 0) {
    // Something actually broke. Step down and reset the climb — one rung per
    // decision, not straight to the floor: a single stall can be a passing
    // tunnel, and over-correcting is why quality ratchets down and never
    // recovers.
    rung = (rung + 1).clamp(0, kBitrateLadder.length - 1);
    clean = 0;
  } else if (estimate != kNoEstimate && estimate < kFloorEstimate) {
    // No stall yet, but the measured throughput cannot sustain music. Acting on
    // this is the difference between adapting and merely reacting.
    rung = kBitrateLadder.length - 1;
    clean = 0;
  } else if (estimate == kNoEstimate) {
    // Nothing measured yet (cold start). Hold — do NOT treat unknown as bad, or
    // every launch would begin at the lowest quality and climb back up audibly.
    clean = 0;
  } else {
    // A clean run. Climbing needs both a streak AND enough headroom for the rung
    // above, so we never upgrade into a network that visibly cannot take it.
    clean = current.cleanRuns + 1;
    if (rung > 0 && clean >= kRunsBeforeUpgrade) {
      final target = kBitrateLadder[rung - 1];
      // Rung 0 is uncapped, so there is no number to clear — require comfortably
      // more than the highest real format instead.
      final needed = (target == 0 ? 160000 : target) * kHeadroom;
      if (estimate >= needed) {
        rung -= 1;
        clean = 0;
      }
    }
  }

  if (dataSaver) {
    // Find the first rung at or below the data-saver cap and never go above it.
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

  return BitrateDecision(rung: rung, cleanRuns: clean);
}

/// Pick the audio format to play from what the server offered.
///
/// [formats] is a list of `{bitrate: int}`-shaped maps (YouTube's
/// adaptiveFormats). [ceilingBps] of 0 means take the best available.
///
/// Returns the highest-bitrate format at or below the ceiling, and — when
/// nothing clears that bar — the LOWEST available rather than nothing. Refusing
/// to return a format would mean silence, and a stream that is more than we
/// asked for still plays.
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
  // Everything on offer is above the cap — take the smallest of them, which is
  // the closest thing to honouring it.
  return sorted.last;
}
