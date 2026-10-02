import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// When each item joined or left a collection, so two devices can be reconciled.
///
/// A plain set of ids can't be merged across devices because "absent" means two
/// opposite things:
///
///   * never added here — the other device's addition should win
///   * deliberately removed here — the removal should win
///
/// A union treats both as the first, so un-liking a song on one phone would
/// bring it back when the other phone's data merges. Recording when each
/// decision was made settles it: the newest action per item wins, whichever
/// device made it.
///
/// Collections covered:
///
///   songs      liked songs
///   albums     liked albums
///   playlists  liked/saved playlists
///   artists    followed artists
///   blacklist  "don't play this again"
///   pl:<name>  membership of one user playlist (see below)
///
/// Order is not membership: for a user playlist this log only decides which
/// tracks are in it. The order comes from the ordinary snapshot, so the most
/// recent editor's order wins. Merging order properly would need per-item order
/// keys and a change to how playlists are stored; membership was where data was
/// being lost (tracks disappearing), so that is what's merged.
class SetLog {
  SetLog._();
  static final SetLog instance = SetLog._();

  static const String prefsKey = 'auvy_set_log_v1';

  /// collection → itemId → (member, atMs)
  Map<String, Map<String, ({bool member, int atMs})>> _log = {};
  bool _loaded = false;

  /// Drops everything, in memory and on disk. Must be called on an account wipe:
  /// the log is read from disk once per process, so otherwise the old account's
  /// timestamped removals would outrank the new account's choices and un-like
  /// their songs.
  Future<void> reset() async {
    _log = {};
    _loaded = true; // nothing to load, and nothing may be loaded back
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {}
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _log = decode(prefs.getString(prefsKey));
    } catch (_) {
      _log = {};
    }
  }

  /// Record a decision. Fire-and-forget: a tap must not wait on disk, and a
  /// lost timestamp costs a merge rather than the change itself — the set is
  /// written independently.
  void record(String collection, String itemId, {required bool member}) {
    if (collection.isEmpty || itemId.isEmpty) return;
    _recordAsync(collection, itemId, member);
  }

  Future<void> _recordAsync(String collection, String itemId, bool member) async {
    await _ensureLoaded();
    (_log[collection] ??= {})[itemId] =
        (member: member, atMs: DateTime.now().millisecondsSinceEpoch);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encode(_log));
    } catch (_) {}
  }

  /// This device's log, for publishing into its shard.
  Future<String> exportJson() async {
    await _ensureLoaded();
    return encode(_log);
  }

  /// Adopts a merged log as this device's own. Safe because the merge is
  /// last-write-wins per item, so republishing a decision this device didn't make
  /// gives the same log every round. Worth doing because a device that stops
  /// syncing would otherwise take its decisions with it.
  ///
  /// Play tallies must never do this: their merge is a sum of per-device counts,
  /// so adopting and republishing another device's tally would count those plays
  /// again every round. That is why the two are separate structures (see
  /// PlayTally).
  Future<void> absorb(
      Map<String, Map<String, ({bool member, int atMs})>> merged) async {
    await _ensureLoaded();
    _log = merge([_log, merged]);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encode(_log));
    } catch (_) {}
  }

  // Pure helpers, so the merge rule can be tested without prefs.

  static Map<String, Map<String, ({bool member, int atMs})>> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final top = jsonDecode(raw);
      if (top is! Map) return {};
      final out = <String, Map<String, ({bool member, int atMs})>>{};
      for (final c in top.entries) {
        final inner = c.value;
        if (inner is! Map) continue;
        final items = <String, ({bool member, int atMs})>{};
        for (final e in inner.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final at = (v['at'] as num?)?.toInt();
          // No timestamp means no orderable decision, so it is not one.
          if (at == null) continue;
          items[e.key.toString()] = (member: v['m'] == true, atMs: at);
        }
        if (items.isNotEmpty) out[c.key.toString()] = items;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static String encode(Map<String, Map<String, ({bool member, int atMs})>> log) =>
      jsonEncode({
        for (final c in log.entries)
          c.key: {
            for (final e in c.value.entries)
              e.key: {'m': e.value.member, 'at': e.value.atMs},
          },
      });

  /// Newest decision per item, per collection.
  ///
  /// Ties keep the first seen rather than flipping, so a merge is stable when
  /// two devices record the same millisecond — arbitrary but consistent beats
  /// alternating between runs.
  static Map<String, Map<String, ({bool member, int atMs})>> merge(
      Iterable<Map<String, Map<String, ({bool member, int atMs})>>> logs) {
    final out = <String, Map<String, ({bool member, int atMs})>>{};
    for (final log in logs) {
      for (final c in log.entries) {
        final target = out[c.key] ??= {};
        for (final e in c.value.entries) {
          final known = target[e.key];
          if (known == null || e.value.atMs > known.atMs) target[e.key] = e.value;
        }
      }
    }
    return out;
  }

  /// What one collection should contain after a merge.
  ///
  /// [localIds] is what this device currently holds. Returns the ids to keep
  /// and the ids another device added that are not present locally — REPORTED
  /// rather than invented, because the log holds ids and not the items
  /// themselves, and a placeholder row is worse than a late one.
  static ({List<String> keepIds, List<String> missingIds}) resolve({
    required Map<String, Map<String, ({bool member, int atMs})>> mergedLog,
    required String collection,
    required List<String> localIds,
  }) {
    final decisions = mergedLog[collection] ?? const {};
    final local = localIds.toSet();
    final keep = <String>[];
    final missing = <String>[];
    for (final e in decisions.entries) {
      if (!e.value.member) continue;
      if (local.contains(e.key)) {
        keep.add(e.key);
      } else {
        missing.add(e.key);
      }
    }
    // Local ids the log has never seen predate the log and stay. Treating them as
    // removed would empty every collection the first time this ran.
    for (final id in localIds) {
      if (!decisions.containsKey(id)) keep.add(id);
    }
    return (keepIds: keep, missingIds: missing);
  }

  /// Collection names, so a typo cannot silently create a parallel set.
  static const String songs = 'songs';
  static const String albums = 'albums';
  static const String playlists = 'playlists';
  static const String artists = 'artists';
  static const String blacklist = 'blacklist';

  /// Membership of one user playlist. Its ORDER is not tracked here — see the
  /// note on the class.
  static String playlistItems(String playlistTitle) => 'pl:$playlistTitle';
}
