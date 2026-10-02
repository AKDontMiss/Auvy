import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What this device played, counted separately from the running total.
///
/// `intel_play_counts` is cumulative, and summing two devices' cumulative copies
/// counts every already-exchanged play twice, and again on every merge. Play
/// counts drive recommendations, so inflated counts quietly skew every shelf.
///
/// Each device tallies only its own plays. Those tallies don't overlap, so
///
///     total = historical baseline + sum of every device's own tally
///
/// stays exact however many times it is recomputed.
///
/// The baseline: counts from before this existed belong to no device (two
/// devices that synced back then hold overlapping copies), so seeding tallies
/// from them would double that history. The old total stays as a baseline that
/// travels in the snapshot as before, and tallies start empty.
class PlayTally {
  PlayTally._();
  static final PlayTally instance = PlayTally._();

  /// This device's own plays. songId → count.
  static const String prefsKey = 'auvy_play_tally_own_v1';

  /// The pre-sharding total, frozen the first time this device tallies.
  ///
  /// Kept so a merged total can be computed as baseline + tallies without
  /// re-reading a value the merge itself has already written — which would feed
  /// the output back into the input and inflate on every pass.
  static const String baselineKey = 'auvy_play_counts_baseline_v1';

  Map<String, int> _own = {};
  bool _loaded = false;

  /// Drops this device's tally, in memory and on disk. Must be called on an
  /// account wipe: the tally is read once per process, so otherwise the old
  /// account's plays would be summed into the new account's counts. The frozen
  /// baseline goes too; it belongs to the account that froze it.
  Future<void> reset() async {
    _own = {};
    _loaded = true; // nothing to load, and nothing may be loaded back
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
      await prefs.remove(baselineKey);
    } catch (_) {}
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _own = decode(prefs.getString(prefsKey));
    } catch (_) {
      _own = {};
    }
  }

  /// Count one play by this device. Fire-and-forget: recording a play must not
  /// wait on disk, and a lost tally costs a merge rather than the play itself —
  /// `intel_play_counts` is incremented independently.
  void increment(String songId) {
    if (songId.isEmpty) return;
    _incrementAsync(songId);
  }

  Future<void> _incrementAsync(String songId) async {
    await _ensureLoaded();
    _own[songId] = (_own[songId] ?? 0) + 1;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encode(_own));
    } catch (_) {}
  }

  /// This device's tally, for publishing into its shard.
  Future<String> exportJson() async {
    await _ensureLoaded();
    return encode(_own);
  }

  /// Freezes the historical total once, the first time sharding runs, and returns
  /// it. After the first call the stored value is used and `currentTotal` is
  /// ignored, because by then the total includes merged tallies.
  ///
  /// The cloud baseline takes priority when there is one. The merged total is
  /// written back into `intel_play_counts`, which also travels in the snapshot, so
  /// a device freezing for the first time could otherwise freeze a total that
  /// already includes tallies and then add them again. Whichever device migrates
  /// first publishes the baseline and the others adopt it.
  ///
  /// [cloudBaseline] is null when the cloud has none yet (offline, or the first
  /// migration); then the local freeze is used and the caller publishes it.
  Future<Map<String, int>> baseline(
    Map<String, int> currentTotal, {
    Map<String, int>? cloudBaseline,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (cloudBaseline != null) {
        // Adopt and remember, so a later offline launch uses the same number
        // rather than re-deriving one from a merged total.
        await prefs.setString(baselineKey, encode(cloudBaseline));
        return Map<String, int>.from(cloudBaseline);
      }
      final stored = prefs.getString(baselineKey);
      if (stored != null) return decode(stored);

      // An empty total almost always means "not loaded yet", not "no plays": on a
      // first sign-in the shard merge runs before the snapshot restore. Freezing it
      // would publish a zero baseline that every device adopts, discarding all
      // earlier plays. So an empty freeze is refused; the baseline is set one merge
      // later, when the real total is known.
      if (currentTotal.isEmpty) return const {};

      await prefs.setString(baselineKey, encode(currentTotal));
      return Map<String, int>.from(currentTotal);
    } catch (_) {
      return Map<String, int>.from(cloudBaseline ?? currentTotal);
    }
  }

  // Pure helpers, so the merge rule can be tested without prefs.

  static Map<String, int> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      final out = <String, int>{};
      for (final e in m.entries) {
        final v = e.value;
        if (v is int && v > 0) out[e.key.toString()] = v;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static String encode(Map<String, int> m) => jsonEncode(m);

  /// baseline + sum of every device's tally.
  ///
  /// Exact because the tallies are disjoint, and idempotent because none of the
  /// inputs is derived from the output. Recomputing it a hundred times gives
  /// the same answer — which is precisely what a cumulative total could not do.
  static Map<String, int> total({
    required Map<String, int> baseline,
    required Iterable<Map<String, int>> deviceTallies,
  }) {
    final out = Map<String, int>.from(baseline);
    for (final t in deviceTallies) {
      for (final e in t.entries) {
        out[e.key] = (out[e.key] ?? 0) + e.value;
      }
    }
    return out;
  }
}
