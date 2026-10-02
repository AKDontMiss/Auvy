/// Keep fresh playlists and Weekly Discovery.
///
/// Keep fresh is a switch on the listener's own playlists. Each period (weekly,
/// from Monday, or daily) it rests a few of the listener's songs (about one in
/// four, 3 to 10) and puts suggestions that fit in their places, so the playlist
/// stays the same size. Resting songs wait in a hidden reserve in the library
/// (see [freshReserveKey]) and come back at the next swap; nothing is deleted,
/// and turning it off brings them all back. A suggestion the listener keeps
/// (from its sparkle) or likes stays for good.
///
/// Weekly Discovery is a built-in playlist rebuilt in the first session of each
/// week from the listener's most-played and liked songs, leaving out anything
/// already in the library.
///
/// The state is one backed-up preference, so another phone on the account sees
/// that a refresh already happened this period and doesn't repeat it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/library_integrity.dart';
import 'package:auvy/logic/playlist_suggester.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/whats_new_provider.dart';

enum FreshCadence { daily, weekly }

/// One Keep fresh playlist.
class FreshPlaylist {
  final FreshCadence cadence;

  /// When it last rotated (ms since epoch), 0 before its first fill.
  final int lastRefreshMs;

  /// Songs it added that are still rotating. A kept or liked one leaves this list.
  final List<String> suggestionIds;

  /// Recently rotated out, so the next fill reaches for something new. Bounded.
  final List<String> retiredIds;

  const FreshPlaylist({
    required this.cadence,
    this.lastRefreshMs = 0,
    this.suggestionIds = const [],
    this.retiredIds = const [],
  });

  FreshPlaylist copyWith({
    FreshCadence? cadence,
    int? lastRefreshMs,
    List<String>? suggestionIds,
    List<String>? retiredIds,
  }) =>
      FreshPlaylist(
        cadence: cadence ?? this.cadence,
        lastRefreshMs: lastRefreshMs ?? this.lastRefreshMs,
        suggestionIds: suggestionIds ?? this.suggestionIds,
        retiredIds: retiredIds ?? this.retiredIds,
      );

  Map<String, dynamic> toJson() => {
        'cadence': cadence.name,
        'last': lastRefreshMs,
        'ids': suggestionIds,
        'retired': retiredIds,
      };

  static FreshPlaylist? fromJson(Object? raw) {
    if (raw is! Map) return null;
    List<String> ids(Object? v) =>
        v is List ? [for (final x in v) if (x is String) x] : const [];
    return FreshPlaylist(
      cadence: raw['cadence'] == FreshCadence.daily.name
          ? FreshCadence.daily
          : FreshCadence.weekly,
      lastRefreshMs: (raw['last'] as num?)?.toInt() ?? 0,
      suggestionIds: ids(raw['ids']),
      retiredIds: ids(raw['retired']),
    );
  }
}

class KeepFreshState {
  /// Keep fresh playlists by title.
  final Map<String, FreshPlaylist> playlists;

  /// The Monday (yyyy-mm-dd) of the week Weekly Discovery was last built for.
  final String weeklyFor;

  /// Playlists being filled right now, so the UI can show it.
  final Set<String> busy;

  const KeepFreshState({
    this.playlists = const {},
    this.weeklyFor = '',
    this.busy = const {},
  });

  KeepFreshState copyWith({
    Map<String, FreshPlaylist>? playlists,
    String? weeklyFor,
    Set<String>? busy,
  }) =>
      KeepFreshState(
        playlists: playlists ?? this.playlists,
        weeklyFor: weeklyFor ?? this.weeklyFor,
        busy: busy ?? this.busy,
      );
}

class KeepFreshNotifier extends StateNotifier<KeepFreshState> {
  KeepFreshNotifier(this._ref) : super(const KeepFreshState()) {
    _ready = reload();
  }

  final Ref _ref;

  /// The first load. Changes wait for it, so it can't land afterwards and
  /// overwrite a toggle made in the first moments.
  late final Future<void> _ready;

  /// Backed up (CloudSyncService._stringKeys).
  static const String kPrefsKey = 'auvy_keep_fresh_v1';

  /// A playlist needs this many songs of the listener's own before Keep fresh can
  /// tell what belongs in it.
  static const int minOwnSongs = 5;
  static const int _maxRetired = 120;

  /// The least worth publishing for a week. The size itself depends on the
  /// listener (see [weeklyDiscoveryTarget]).
  static const int _weeklyMin = 10;

  Future<void>? _running;
  bool _weeklyBusy = false;

  /// Reads the stored state. Also called before each check, because a restore
  /// can have brought another phone's refreshes in since this one last looked.
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final raw = prefs.getString(kPrefsKey);
    // Absent means wiped (an account switch) or never set: start empty, so a
    // previous account's settings are never written back under this one.
    if (raw == null || raw.isEmpty) {
      state = KeepFreshState(busy: state.busy);
      return;
    }
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final lists = data['playlists'];
      state = state.copyWith(
        playlists: {
          if (lists is Map)
            for (final e in lists.entries)
              e.key.toString(): ?FreshPlaylist.fromJson(e.value),
        },
        weeklyFor: data['weeklyFor'] as String? ?? '',
      );
    } catch (e) {
      print('WARN: keep fresh: stored state unreadable ($e)');
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefsKey,
        jsonEncode({
          'playlists': {
            for (final e in state.playlists.entries) e.key: e.value.toJson(),
          },
          'weeklyFor': state.weeklyFor,
        }));
  }

  bool isOn(String title) => state.playlists.containsKey(title);

  bool isSuggestion(String title, String songId) =>
      state.playlists[title]?.suggestionIds.contains(songId) ?? false;

  /// Turns Keep fresh on and fills the playlist straight away.
  Future<bool> enable(String title, FreshCadence cadence) async {
    await _ready;
    if (isOn(title)) return setCadence(title, cadence).then((_) => true);
    state = state.copyWith(
        playlists: {...state.playlists, title: FreshPlaylist(cadence: cadence)});
    await _save();
    print('keep fresh: on for "$title" (${cadence.name})');
    return refreshPlaylist(title, force: true);
  }

  Future<void> setCadence(String title, FreshCadence cadence) async {
    await _ready;
    final entry = state.playlists[title];
    if (entry == null || entry.cadence == cadence) return;
    state = state.copyWith(
        playlists: {...state.playlists, title: entry.copyWith(cadence: cadence)});
    await _save();
    print('keep fresh: "$title" now refreshes ${cadence.name}');
  }

  /// Turns Keep fresh off, taking back the suggestions not kept or liked.
  Future<void> disable(String title) async {
    await _ready;
    final entry = state.playlists[title];
    if (entry == null) return;
    final lib = _ref.read(libraryProvider);
    final out = {
      for (final id in entry.suggestionIds)
        if (!lib.likedSongIds.contains(id)) id,
    };
    final playlist = lib.playlistSongs[title];
    final reserve = lib.playlistSongs[freshReserveKey(title)] ?? const <Song>[];
    if (playlist != null && (out.isNotEmpty || reserve.isNotEmpty)) {
      final plan = planFreshSwap(
          playlist: playlist, reserve: reserve, outgoing: out, picks: const [],
          want: 0, random: math.Random());
      _ref.read(libraryProvider.notifier).applyFreshRotation(title, plan.playlist, const []);
    }
    state = state.copyWith(playlists: {...state.playlists}..remove(title));
    await _save();
    print('keep fresh: off for "$title" — ${reserve.length} of yours back, '
        '${out.length} suggestion(s) out, ${entry.suggestionIds.length - out.length} liked kept');
  }

  /// Makes a suggestion permanent: it stops rotating.
  Future<void> keep(String title, String songId) async {
    await _ready;
    final entry = state.playlists[title];
    if (entry == null || !entry.suggestionIds.contains(songId)) return;
    state = state.copyWith(playlists: {
      ...state.playlists,
      title: entry.copyWith(
          suggestionIds: [for (final id in entry.suggestionIds) if (id != songId) id]),
    });
    await _save();
    print('keep fresh: kept a suggestion in "$title" '
        '(${entry.suggestionIds.length - 1} still rotating)');
  }

  void rename(String oldTitle, String newTitle) {
    final entry = state.playlists[oldTitle];
    if (entry == null || oldTitle == newTitle) return;
    state = state.copyWith(
        playlists: {...state.playlists}
          ..remove(oldTitle)
          ..[newTitle] = entry);
    unawaited(_save());
  }

  /// Runs whatever is due: each Keep fresh playlist past its period, then Weekly
  /// Discovery when this week's hasn't been built. Overlapping calls share a run.
  Future<void> refreshDue() =>
      _running ??= _refreshDue().whenComplete(() => _running = null);

  Future<void> _refreshDue() async {
    await reload();
    if (!mounted) return;
    if (_ref.read(connectivityProvider).isOffline) {
      if (state.playlists.isNotEmpty) {
        print('fresh check: offline — ${state.playlists.length} keep-fresh '
            'playlist(s) wait for the network');
      }
      return;
    }
    final lib = _ref.read(libraryProvider);
    final titles = lib.allItems.map((i) => i.title).toSet();
    // A playlist that no longer exists takes its setting with it. Checked here,
    // well after any delete, so an undone delete keeps its setting.
    final gone = state.playlists.keys.where((t) => !titles.contains(t)).toList();
    if (gone.isNotEmpty) {
      state = state.copyWith(
          playlists: {...state.playlists}..removeWhere((t, _) => gone.contains(t)));
      await _save();
    }
    // Resting songs whose playlist has no Keep fresh setting any more (the
    // setting was lost, say, to a backup from an older build): return them, or
    // drop them with their playlist if it was deleted.
    final libNow = _ref.read(libraryProvider);
    for (final key in libNow.playlistSongs.keys.where(isFreshReserveKey).toList()) {
      final title = key.substring(kFreshReservePrefix.length);
      if (state.playlists.containsKey(title)) continue;
      final playlist = libNow.playlistSongs[title];
      final reserve = libNow.playlistSongs[key] ?? const <Song>[];
      if (playlist == null) {
        _ref.read(libraryProvider.notifier).dropFreshReserve(title);
        print('keep fresh: dropped ${reserve.length} resting song(s) of a deleted playlist');
      } else {
        final plan = planFreshSwap(
            playlist: playlist, reserve: reserve, outgoing: const {}, picks: const [],
            want: 0, random: math.Random());
        _ref.read(libraryProvider.notifier).applyFreshRotation(title, plan.playlist, const []);
        print('keep fresh: returned ${reserve.length} resting song(s) to "$title" '
            '(its Keep fresh setting was gone)');
      }
    }
    var refreshed = 0;
    for (final title in state.playlists.keys.toList()) {
      if (!mounted) return;
      if (await refreshPlaylist(title)) refreshed++;
    }
    if (!mounted) return;
    final built = await refreshWeeklyDiscovery();
    // One line per check, and only when there is something to say, since this
    // runs on every resume.
    if (state.playlists.isNotEmpty || built || gone.isNotEmpty) {
      final upToDate = state.weeklyFor == weekKey(DateTime.now()) &&
          (_ref.read(libraryProvider).playlistSongs[kWeeklyDiscoveryTitle]?.isNotEmpty ?? false);
      print('fresh check: ${state.playlists.length} keep-fresh playlist(s), '
          '$refreshed refreshed${gone.isNotEmpty ? ", ${gone.length} gone" : ""}; '
          'weekly discovery ${built ? "built" : upToDate ? "up to date" : "not built"}');
    }
  }

  /// The start of the period [now] falls in: today's midnight, or this week's
  /// Monday. Calendar-based, so every phone agrees on when the next one is due.
  static DateTime periodStart(FreshCadence cadence, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return cadence == FreshCadence.daily
        ? day
        : day.subtract(Duration(days: now.weekday - DateTime.monday));
  }

  static String weekKey(DateTime now) {
    final m = periodStart(FreshCadence.weekly, now);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${m.year}-${two(m.month)}-${two(m.day)}';
  }

  /// Swaps a playlist's rotating suggestions for new ones. Does nothing before
  /// the period is up unless [force]d, or when the playlist has too few songs of
  /// its own to read.
  Future<bool> refreshPlaylist(String title, {bool force = false}) async {
    final entry = state.playlists[title];
    if (entry == null || state.busy.contains(title)) return false;
    final now = DateTime.now();
    if (!force &&
        entry.lastRefreshMs >=
            periodStart(entry.cadence, now).millisecondsSinceEpoch) {
      return false;
    }
    if (_ref.read(connectivityProvider).isOffline) return false;
    final lib = _ref.read(libraryProvider);
    final songs = lib.playlistSongs[title];
    if (songs == null) return false;
    final rotating = {
      for (final id in entry.suggestionIds)
        if (!lib.likedSongIds.contains(id)) id,
    };
    // The listener's songs: those in the playlist plus those resting.
    final own = [
      for (final s in songs) if (!rotating.contains(s.id)) s,
      ...?lib.playlistSongs[freshReserveKey(title)],
    ];
    if (own.length < minOwnSongs) {
      print('keep fresh: "$title" has ${own.length} song(s) of its own, needs '
          '$minOwnSongs — not refreshed');
      return false;
    }
    final want = (own.length / 4).round().clamp(3, 10);

    state = state.copyWith(busy: {...state.busy, title});
    try {
      final picks = await suggestTracksForPlaylist(
        search: _ref.read(searchServiceProvider),
        intel: _ref.read(intelligenceProvider.notifier),
        existing: own,
        seed: math.Random().nextInt(1 << 20),
        exclude: {...rotating, ...entry.retiredIds},
        limit: want,
      );
      if (!mounted) return false;
      // Nothing came back (offline, every source refused): keep the current
      // suggestions rather than emptying them, and try again next time.
      if (picks.isEmpty) {
        print('keep fresh: no suggestions came back for "$title" — kept the '
            'current ${rotating.length}, will try again');
        return false;
      }
      // Re-read after the fetch: Keep fresh may have been turned off, or a
      // suggestion kept or liked, while it ran.
      final current = state.playlists[title];
      if (current == null) {
        print('keep fresh: "$title" was turned off while suggestions loaded — '
            'nothing changed');
        return false;
      }
      final libNow = _ref.read(libraryProvider);
      final playlistNow = libNow.playlistSongs[title];
      if (playlistNow == null) return false;
      final out = {
        for (final id in current.suggestionIds)
          if (rotating.contains(id) && !libNow.likedSongIds.contains(id)) id,
      };
      final plan = planFreshSwap(
        playlist: playlistNow,
        reserve: libNow.playlistSongs[freshReserveKey(title)] ?? const <Song>[],
        outgoing: out,
        picks: picks,
        want: want,
        random: math.Random(),
      );
      _ref
          .read(libraryProvider.notifier)
          .applyFreshRotation(title, plan.playlist, plan.reserve);
      final retired = [...current.retiredIds, ...out];
      state = state.copyWith(playlists: {
        ...state.playlists,
        title: current.copyWith(
          lastRefreshMs: now.millisecondsSinceEpoch,
          suggestionIds: [for (final s in plan.added) s.id],
          retiredIds: retired.length > _maxRetired
              ? retired.sublist(retired.length - _maxRetired)
              : retired,
        ),
      });
      await _save();
      print('keep fresh: refreshed "$title" (${current.cadence.name}${force ? ", by hand" : ""}) — '
          '${plan.returned} of yours back, ${plan.reserve.length} resting, '
          '${out.length} suggestion(s) out, ${plan.added.length} in; '
          '${playlistNow.length} → ${plan.playlist.length} songs');
      // A swap the listener didn't ask for is news; one they just tapped isn't.
      if (!force && plan.added.isNotEmpty) {
        final period = periodStart(current.cadence, now);
        unawaited(_ref.read(whatsNewProvider.notifier).addMadeForYou(
            key: 'mfy:fresh:$title:${period.millisecondsSinceEpoch}',
            title: '${plan.added.length} new song${plan.added.length == 1 ? '' : 's'} '
                'in $title',
            target: title,
            image: plan.added.first.image));
      }
      return true;
    } catch (e) {
      print('WARN: keep fresh: refresh failed ($e)');
      return false;
    } finally {
      if (mounted) state = state.copyWith(busy: {...state.busy}..remove(title));
    }
  }

  /// Builds this week's Weekly Discovery, once per week unless [force]d. Skipped
  /// until there is enough listening to read, and when the result would be thin.
  Future<bool> refreshWeeklyDiscovery({bool force = false}) async {
    final week = weekKey(DateTime.now());
    if (_weeklyBusy || _ref.read(connectivityProvider).isOffline) return false;
    final lib = _ref.read(libraryProvider);
    // Done for the week only if the playlist is actually there: a stamp without
    // its list (another account's, or a restore that brought one without the
    // other) must not stop this week's being built.
    final hasList = lib.playlistSongs[kWeeklyDiscoveryTitle]?.isNotEmpty ?? false;
    if (!force && state.weeklyFor == week && hasList) return false;
    final intel = _ref.read(intelligenceProvider);
    final seen = <String>{};
    final seeds = <Song>[
      for (final s in [
        ...computeTop50(intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps)
            .take(40),
        ...lib.likedSongs.reversed.take(20),
      ])
        if (seen.add(s.id)) s,
    ];
    if (seeds.length < minOwnSongs) {
      print('weekly discovery: not enough listening yet (${seeds.length} seed '
          'song(s), needs $minOwnSongs)');
      return false;
    }
    // Discovery means new to the listener: nothing already in the library,
    // including last week's list.
    final inLibrary = <String>{
      ...lib.likedSongIds,
      for (final list in lib.playlistSongs.values)
        for (final s in list) s.id,
    };

    final target = weeklyDiscoveryTarget(
      playsLastWeek: playsInLastWeek(intel.playHistory, DateTime.now()),
      artists: {for (final s in seeds) s.artist.toLowerCase()}.length,
      genres: {
        for (final s in seeds)
          ...(intel.artistGenres[s.artist] ??
              intel.artistGenres[s.artist.toLowerCase()] ??
              const <String>[]),
      }.length,
      week: week,
    );
    // Half the aim is still a good week; less is tried again next session.
    final least = math.max(_weeklyMin, target ~/ 2);

    _weeklyBusy = true;
    try {
      // One pass reads only a few songs and artists, and its one-per-artist rule
      // trims the rest, so it often falls short of a full week. Further passes
      // start from different seeds and skip what is already picked.
      final picks = <Song>[];
      final pickedSigs = <String>{};
      final passes = (target / 12).ceil() + 1;
      for (var pass = 0; pass < passes && picks.length < target; pass++) {
        final more = await suggestTracksForPlaylist(
          search: _ref.read(searchServiceProvider),
          intel: _ref.read(intelligenceProvider.notifier),
          existing: seeds,
          seed: (week.hashCode + pass * 7919) & 0xFFFFF,
          exclude: {...inLibrary, for (final s in picks) s.id},
          limit: target - picks.length,
        );
        if (!mounted) return false;
        if (more.isEmpty) break;
        for (final s in more) {
          if (pickedSigs.add(suggestionSig(s))) picks.add(s);
        }
      }
      if (picks.length > target) picks.removeRange(target, picks.length);
      if (picks.length < least) {
        print('weekly discovery: only ${picks.length} new song(s) came back '
            '(aimed for $target, needs $least) — trying again next session');
        return false;
      }
      _ref.read(libraryProvider.notifier).setWeeklyDiscovery(picks);
      state = state.copyWith(weeklyFor: week);
      await _save();
      unawaited(_ref.read(whatsNewProvider.notifier).addMadeForYou(
          key: 'mfy:weekly:$week',
          title: 'Your Weekly Discovery is ready: ${picks.length} new songs',
          target: kWeeklyDiscoveryTitle,
          image: 'assets/images/weekly_discovery_cyan.webp'));
      print('weekly discovery: built ${picks.length} songs for the week of $week '
          '(aimed for $target) from ${seeds.length} seed songs');
      return true;
    } catch (e) {
      print('WARN: weekly discovery: build failed ($e)');
      return false;
    } finally {
      _weeklyBusy = false;
    }
  }
}

/// How many songs this week's Weekly Discovery aims for, 20 to 60.
///
/// A listener who plays a lot gets more (about one new song per eight plays
/// last week), and so does a wide taste (many artists and genres among the
/// seeds); a light or narrow week gets fewer, better-matched ones. A small
/// variation from the week itself keeps it from being the same number every
/// Monday, and is the same on every phone for that week.
int weeklyDiscoveryTarget({
  required int playsLastWeek,
  required int artists,
  required int genres,
  required String week,
}) {
  final base = 20 +
      math.min(25, playsLastWeek ~/ 8) +
      math.min(10, artists ~/ 4) +
      math.min(5, genres ~/ 3);
  // A stable hash: String.hashCode is not promised to be the same everywhere.
  var h = 17;
  for (final c in week.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final vary = 0.9 + (h % 1000) / 1000 * 0.2; // ±10%
  return (base * vary).round().clamp(20, 60);
}

/// Plays in the seven days before [now], from the per-play ledger (older
/// entries are in seconds, newer in milliseconds).
int playsInLastWeek(Map<String, List<int>> playHistory, DateTime now) {
  final from = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
  var n = 0;
  for (final stamps in playHistory.values) {
    for (final t in stamps) {
      final ms = t < 100000000000 ? t * 1000 : t;
      if (ms >= from) n++;
    }
  }
  return n;
}

/// One Keep fresh swap, worked out without touching any state (tested directly).
///
/// Each outgoing suggestion gives its place back to a resting song, in order; a
/// resting song left without a place is appended, and a place left without a
/// resting song is dropped. Then up to [want] of the songs in the playlist (never
/// one that just came back, so they really rotate) go to rest, each place taken
/// by a new pick. So the playlist keeps its length, and only as many songs rest
/// as there are picks to replace them.
({List<Song> playlist, List<Song> reserve, List<Song> added, int returned})
    planFreshSwap({
  required List<Song> playlist,
  required List<Song> reserve,
  required Set<String> outgoing,
  required List<Song> picks,
  required int want,
  required math.Random random,
}) {
  final next = <Song>[];
  var back = 0;
  for (final s in playlist) {
    if (!outgoing.contains(s.id)) {
      next.add(s);
    } else if (back < reserve.length) {
      next.add(reserve[back++]);
    }
  }
  while (back < reserve.length) {
    next.add(reserve[back++]);
  }

  final haveIds = {for (final s in next) s.id};
  final haveSigs = {for (final s in next) suggestionSig(s)};
  final fresh = <Song>[
    for (final p in picks)
      if (!outgoing.contains(p.id) && haveIds.add(p.id) && haveSigs.add(suggestionSig(p))) p,
  ];

  final justBack = {for (final s in reserve) s.id};
  final eligible = [
    for (var i = 0; i < next.length; i++)
      if (!justBack.contains(next[i].id)) i,
  ]..shuffle(random);
  final n = math.min(want, math.min(fresh.length, eligible.length));
  final places = eligible.take(n).toList()..sort();
  final resting = <Song>[];
  for (var j = 0; j < n; j++) {
    resting.add(next[places[j]]);
    next[places[j]] = fresh[j];
  }
  return (
    playlist: next,
    reserve: resting,
    added: fresh.take(n).toList(),
    returned: reserve.length,
  );
}

final keepFreshProvider =
    StateNotifierProvider<KeepFreshNotifier, KeepFreshState>(
        (ref) => KeepFreshNotifier(ref));
