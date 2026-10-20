import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which device each play happened on, for the history page.
///
/// The history lists every play, but the device used to be looked up per SONG
/// (the device of its latest play), so every play of a song showed that one
/// device, sometimes the wrong one, and older plays showed none. A play is
/// identified by its song and the exact
/// stamp in `playHistory` (`<songId>@<ms>`), which every device holds the same
/// once the ledger has synced.
///
/// Each device records its own plays here, and publishes the latest ones in its
/// shard (sealed with the account's key; see CloudSyncService). Reading the
/// shards maps the other devices' plays to their names. A play known to
/// neither shows no device, never a guessed one.
class PlayDevices {
  PlayDevices._();
  static final PlayDevices instance = PlayDevices._();

  /// This device's own plays, newest last.
  static const String ownKey = 'auvy_play_devices_own_v1';

  /// Other devices' plays, as their shards named them: play → device name.
  static const String othersKey = 'auvy_play_devices_others_v1';

  /// How many of its own plays a device publishes, and how many of the others'
  /// are kept: about the history page's span, and a few tens of KB.
  static const int ownCap = 1500;
  static const int othersCap = 4000;

  /// Bumped when the record changes, so the history page redraws.
  final ValueNotifier<int> version = ValueNotifier(0);

  List<String> _own = [];
  Map<String, String> _others = {};
  Set<String> _ownSet = {};
  bool _loaded = false;

  static String keyFor(String songId, int stamp) => '$songId@${normalize(stamp)}';

  /// Stamps are seconds in older records and milliseconds in newer ones; every
  /// reader normalises with the same 10-digit test (see playHistory).
  static int normalize(int stamp) => stamp < 10000000000 ? stamp * 1000 : stamp;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _own = prefs.getStringList(ownKey) ?? [];
      _ownSet = _own.toSet();
      final raw = prefs.getString(othersKey);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) _others = {for (final e in d.entries) e.key.toString(): e.value.toString()};
      }
      version.value++;
    } catch (_) {}
  }

  /// Drops both records, in memory and on disk. Called on an account wipe, like
  /// the play tally: they belong to the account that played.
  Future<void> reset() async {
    _own = [];
    _ownSet = {};
    _others = {};
    _loaded = true;
    version.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(ownKey);
      await prefs.remove(othersKey);
    } catch (_) {}
  }

  /// One play on this device, at the stamp `playHistory` got. Fire-and-forget.
  void recordOwn(String songId, int stamp) {
    if (songId.isEmpty || stamp <= 0) return;
    _recordOwnAsync(keyFor(songId, stamp));
  }

  Future<void> _recordOwnAsync(String key) async {
    await ensureLoaded();
    if (_ownSet.contains(key)) return;
    _own.add(key);
    _ownSet.add(key);
    if (_own.length > ownCap) {
      final drop = _own.length - ownCap;
      _ownSet.removeAll(_own.take(drop));
      _own.removeRange(0, drop);
    }
    version.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(ownKey, _own);
    } catch (_) {}
  }

  /// This device's latest plays, for its shard.
  Future<List<String>> exportOwn() async {
    await ensureLoaded();
    return List.of(_own);
  }

  /// Other devices' plays from their shards: (device name, its plays). Each
  /// device's own list is authoritative for its plays, so the latest read wins.
  Future<void> absorbOthers(Iterable<(String, List<String>)> shards) async {
    await ensureLoaded();
    final next = Map<String, String>.from(_others);
    var changed = false;
    for (final (name, plays) in shards) {
      final device = name.trim();
      if (device.isEmpty) continue;
      for (final p in plays) {
        if (p.isEmpty || p.length > 200 || _ownSet.contains(p)) continue;
        if (next[p] != device) {
          next[p] = device;
          changed = true;
        }
      }
    }
    if (!changed) return;
    _others = capNewest(next, othersCap);
    version.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(othersKey, jsonEncode(_others));
    } catch (_) {}
  }

  /// The device a play happened on: [thisDevice] for one of this device's own,
  /// another device's name from its shard, or null when nobody said.
  String? deviceFor(String songId, int stamp, String thisDevice) {
    final k = keyFor(songId, stamp);
    if (_ownSet.contains(k)) return thisDevice;
    return _others[k];
  }

  /// Keeps the [cap] newest plays (by the stamp after the `@`).
  @visibleForTesting
  static Map<String, String> capNewest(Map<String, String> plays, int cap) {
    if (plays.length <= cap) return plays;
    int stampOf(String k) => int.tryParse(k.substring(k.lastIndexOf('@') + 1)) ?? 0;
    final keys = plays.keys.toList()..sort((a, b) => stampOf(b).compareTo(stampOf(a)));
    return {for (final k in keys.take(cap)) k: plays[k]!};
  }
}
