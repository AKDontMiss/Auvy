import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/player_menu_sheet.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/services/device_info_service.dart';
import 'package:auvy/services/play_devices.dart';

// LISTENING HISTORY — makeover in the Stats-page design language.
// Overview cards (today / this week / total plays) → day-grouped timeline
// (Today, Yesterday, dated sections) with play-count badges and quick actions.

class _HistoryEntry {
  final Song song;
  final DateTime? playedAt;
  final int playCount;
  final String? deviceName;
  _HistoryEntry(this.song, this.playedAt, this.playCount, {this.deviceName});
}

class _DayGroup {
  final String label;
  final List<_HistoryEntry> entries = [];
  _DayGroup(this.label);
}

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();

  static String _dayLabel(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (diff < 7) return week[d.weekday - 1];
    final year = d.year != now.year ? ' ${d.year}' : '';
    return '${months[d.month - 1]} ${d.day}$year';
  }

  static String _timeLabel(DateTime d) {
    final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  }

}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  /// What the listener is looking for. Kept in state rather than a provider —
  /// nothing outside this page needs it, and a provider would rebuild readers
  /// on every keystroke.
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Which device each play was on arrives with the shards; redraw when it does.
    PlayDevices.instance.version.addListener(_onDevicesChanged);
    PlayDevices.instance.ensureLoaded();
  }

  void _onDevicesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PlayDevices.instance.version.removeListener(_onDevicesChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final intel = ref.watch(intelligenceProvider);
    final rawHistory = ref.watch(playerProvider.select((ps) => ps.history));
    final historyPlayedAt = ref.watch(playerProvider.select((ps) => ps.historyPlayedAt));
    final historyPlayedDevice = ref.watch(playerProvider.select((ps) => ps.historyPlayedDevice));
    final ledger = ref.watch(playLedgerProvider);
    final currentDevice = DeviceInfoService.currentDeviceName;

    final now = DateTime.now();
    final q = _query.trim().toLowerCase();

    // Built from the play ledger (`lastPlayTimestamps` and the per-play stamps), not
    // just the player's in-memory session list, so it includes imported plays and
    // agrees with the overview cards above. The session list is merged in for tracks
    // played moments ago. No per-track dedupe: repeats are the information.
    // Onboarding and placeholder ids are filtered where the ledger is built.
    final entries = <_HistoryEntry>[];

    // One row per play, not one per track, so the history shows every time something
    // was played (which is what searching for a track is for). Not deduplicated.
    bool matchesQuery(Song s, [String? device]) =>
        q.isEmpty ||
        s.title.toLowerCase().contains(q) ||
        s.artist.toLowerCase().contains(q) ||
        s.albumTitle.toLowerCase().contains(q) ||
        (device != null && device.toLowerCase().contains(q));

    // The device of each PLAY, not of the song's latest play (which used to be
    // shown on every play of that song, and nothing on older ones): from the
    // per-play record (see PlayDevices); failing that, the song's history entry
    // names the device of its latest play, so that one play gets it when the
    // times agree. Otherwise nothing: an unknown device is left blank, never
    // guessed.
    final seenSong = <String>{};
    String? deviceOf(PlayEvent play) {
      final known = PlayDevices.instance.deviceFor(
          play.song.id, play.playedAt.millisecondsSinceEpoch, currentDevice);
      final isLatest = seenSong.add(play.song.id); // the ledger is newest first
      if (known != null) return known;
      if (!isLatest) return null;
      final at = historyPlayedAt[play.song.id];
      if (at == null || at <= 0) return null;
      final gap = (play.playedAt.millisecondsSinceEpoch - at).abs();
      return gap <= const Duration(minutes: 15).inMilliseconds
          ? historyPlayedDevice[play.song.id]
          : null;
    }

    for (final play in ledger) {
      final songDevice = deviceOf(play);
      if (!matchesQuery(play.song, songDevice)) continue;
      entries.add(_HistoryEntry(
        play.song,
        play.playedAt,
        intel.playCounts[play.song.id] ?? 0,
        deviceName: songDevice,
      ));
    }

    // This session's plays not yet written to the ledger (a track only gets a stamp
    // once it crosses the listen threshold). Added only when the ledger has no stamp
    // for it, so a playing track doesn't appear twice.
    for (final s in rawHistory) {
      if (intel.playHistory[s.id]?.isNotEmpty ?? false) continue;
      final songDevice = historyPlayedDevice[s.id] ?? currentDevice;
      if (!matchesQuery(s, songDevice)) continue;

      final rawTs = historyPlayedAt[s.id] ??
          (intel.lastPlayTimestamps[s.id] != null
              ? (intel.lastPlayTimestamps[s.id]! < 10000000000
                  ? intel.lastPlayTimestamps[s.id]! * 1000
                  : intel.lastPlayTimestamps[s.id]!)
              : 0);

      entries.add(_HistoryEntry(
        s,
        rawTs > 0 ? DateTime.fromMillisecondsSinceEpoch(rawTs) : null,
        intel.playCounts[s.id] ?? 0,
        deviceName: songDevice,
      ));
    }

    // Overview numbers from the exact play ledger.
    int playsToday = 0, playsWeek = 0, playsTotal = 0;
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = todayStart.subtract(const Duration(days: 6));
    intel.playHistory.forEach((_, stamps) {
      for (final raw in stamps) {
        int ts = raw;
        if (ts <= 0) continue;
        if (ts < 10000000000) ts *= 1000;
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        playsTotal++;
        if (!d.isBefore(todayStart)) playsToday++;
        if (!d.isBefore(weekStart)) playsWeek++;
      }
    });

    // Group into day sections: bucket by calendar day, newest day first and newest
    // entry first within each day, with all entries lacking a timestamp in a single
    // "Earlier" group at the bottom (shown only if non-empty).
    final byDay = <DateTime, List<_HistoryEntry>>{};
    final undated = <_HistoryEntry>[];
    for (final e in entries) {
      final at = e.playedAt;
      if (at == null) {
        undated.add(e);
        continue;
      }
      final day = DateTime(at.year, at.month, at.day);
      byDay.putIfAbsent(day, () => []).add(e);
    }

    final orderedDays = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final groups = <_DayGroup>[];
    for (final day in orderedDays) {
      final g = _DayGroup(HistoryPage._dayLabel(day, now));
      final sorted = byDay[day]!
        ..sort((a, b) => b.playedAt!.compareTo(a.playedAt!));

      // Collapse near-simultaneous duplicate entries for the exact same track
      // (e.g. if recorded at both start and scrobble threshold, or synced).
      final deduped = <_HistoryEntry>[];
      for (final e in sorted) {
        if (deduped.isNotEmpty) {
          final prev = deduped.last;
          if (prev.song.id == e.song.id &&
              prev.playedAt != null &&
              e.playedAt != null &&
              prev.playedAt!.difference(e.playedAt!).abs() <
                  const Duration(seconds: 90)) {
            continue;
          }
        }
        deduped.add(e);
      }
      g.entries.addAll(deduped);
      groups.add(g);
    }
    if (undated.isNotEmpty) {
      final seenUndated = <String>{};
      final dedupedUndated = <_HistoryEntry>[];
      for (final e in undated) {
        if (seenUndated.add(e.song.id)) {
          dedupedUndated.add(e);
        }
      }
      groups.add(_DayGroup('Earlier')..entries.addAll(dedupedUndated));
    }

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The keyboard must not resize this page: DynamicBackground sits outside the
        // Scaffold, so a resized body would leave a visible strip. Matches the other pages
        // with search fields.
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      const Text('History',
                          style: TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
                      const Spacer(),
                      if (entries.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.delete_sweep_rounded, color: Colors.white70),
                          tooltip: 'Clear history',
                          onPressed: () => _confirmClear(context, ref, theme),
                        ),
                    ],
                  ),
                ),
              ),

              // Search. Filters the plays themselves, so a query answers
              // "when did I listen to this, and how often" rather than just
              // "is it in my history".
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                    // The list filters as you type, so the action key has
                    // nothing left to submit — it closes the keyboard and
                    // hands the results back. Declared rather than left to
                    // the default, which offers a newline in a single-line
                    // field.
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    cursorColor: theme,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search a track, artist or album',
                      hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 14),
                      prefixIcon: Icon(Icons.search_rounded,
                          color: Colors.white.withOpacity(0.55), size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: Icon(Icons.close_rounded,
                                  color: Colors.white.withOpacity(0.55), size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.06),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),

              // How many plays the current view is showing. With a query this
              // IS the answer to "how often did I play this", so it is worth
              // stating rather than leaving the reader to count rows.
              if (entries.isNotEmpty && _query.trim().isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                    child: Text(
                      '${entries.length} play${entries.length == 1 ? '' : 's'} found',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),

              if (entries.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            _query.trim().isEmpty
                                ? Icons.history_rounded
                                : Icons.search_off_rounded,
                            size: 56,
                            color: Colors.white.withOpacity(0.2)),
                        const SizedBox(height: 16),
                        // The empty state must say WHICH empty it is: nothing
                        // played yet, versus nothing matching what was typed.
                        Text(
                            _query.trim().isEmpty
                                ? 'No listening history yet'
                                : 'Nothing played matches that',
                            style:
                                TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 16)),
                        const SizedBox(height: 6),
                        Text(
                            _query.trim().isEmpty
                                ? 'Tracks you play will show up here'
                                : 'Try part of a title, artist or album',
                            style:
                                TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13)),
                      ],
                    ),
                  ),
                )
              else ...[
                // Overview cards
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        _statCard(theme, Icons.today_rounded, '$playsToday', 'Today'),
                        const SizedBox(width: 10),
                        _statCard(theme, Icons.date_range_rounded, '$playsWeek', 'This week'),
                        const SizedBox(width: 10),
                        _statCard(theme, Icons.all_inclusive_rounded, '$playsTotal', 'All plays'),
                      ],
                    ),
                  ),
                ),

                // Day-grouped timeline
                for (final group in groups) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                      child: Row(
                        children: [
                          Text(group.label.toUpperCase(),
                              style: TextStyle(
                                  color: theme,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2)),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Divider(color: Colors.white.withOpacity(0.08), height: 1)),
                          const SizedBox(width: 10),
                          Text('${group.entries.length}',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.66),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final entry = group.entries[i];
                          // Global index for "resume from here" queueing.
                          final globalIndex = entries.indexOf(entry);
                          return _HistoryTile(
                            entry: entry,
                            theme: theme,
                            onTap: () {
                              HapticService.light();
                              final queue =
                                  entries.sublist(globalIndex).map((e) => e.song).toList();
                              ref.read(playerProvider.notifier).playSong(
                                    entry.song,
                                    newQueue: queue,
                                    isManual: true,
                                    source: 'History',
                                  );
                            },
                            onMenu: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                useRootNavigator: true,
                                builder: (_) => PlayerMenuSheet(song: entry.song),
                              );
                            },
                          );
                        },
                        childCount: group.entries.length,
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 180)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard(Color theme, IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme, size: 18),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref, Color theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: const Text('Clear history?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This removes every track from your listening history. Your stats are kept.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              ref.read(intelligenceProvider.notifier).clearListeningHistory();
              ref.read(playerProvider.notifier).clearPlaybackHistory();
              Navigator.pop(ctx);
            },
            child: Text('Clear', style: TextStyle(color: theme, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final _HistoryEntry entry;
  final Color theme;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const _HistoryTile({
    required this.entry,
    required this.theme,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final song = entry.song;
    final time = entry.playedAt != null ? HistoryPage._timeLabel(entry.playedAt!) : '';
    final name = entry.deviceName?.trim() ?? '';
    final device = name.isEmpty || name == 'Unknown device' ? null : name;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        // Hand-built row: the ListTile theme funnel cannot reach it, so it
// reads the density setting directly.
        padding: EdgeInsets.symmetric(
            horizontal: 8, vertical: 2 + densityNow.rowVerticalPadding),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(10)),
              child: Stack(children: [
                AuvyImage(
                    path: song.image,
                    width: densityNow.artwork(50),
                    height: densityNow.artwork(50),
                    fit: BoxFit.cover),
                NowPlayingArtOverlay(
                    rowId: song.id,
                    title: song.title,
                    artist: song.displayArtist,
                    duration: song.duration,
                    size: 50,
                    borderRadius: 0),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NowPlayingTitle(
                      title: song.title,
                      rowId: song.id,
                      artist: song.displayArtist,
                      duration: song.duration,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(song.displayArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
                  if (time.isNotEmpty || device != null || entry.playCount > 1) ...[
                    const SizedBox(height: 3),
                    // One line, trimmed at the end: when, on which device, how
                    // often. Nothing beside it, so nothing can overlap it.
                    Text.rich(
                      TextSpan(children: [
                        if (time.isNotEmpty)
                          TextSpan(
                              text: time,
                              style: TextStyle(color: theme.withOpacity(0.9), fontWeight: FontWeight.w700)),
                        if (device != null) ...[
                          if (time.isNotEmpty) const TextSpan(text: '  ·  '),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(_deviceIcon(device),
                                  size: 12, color: Colors.white.withOpacity(0.55)),
                            ),
                          ),
                          TextSpan(text: device),
                        ],
                        if (entry.playCount > 1) ...[
                          if (time.isNotEmpty || device != null) const TextSpan(text: '  ·  '),
                          TextSpan(text: '${entry.playCount} plays'),
                        ],
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'More options',
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
              onPressed: onMenu,
            ),
          ],
        ),
      ),
    );
  }
}

/// The icon for a device name in the history's details line.
IconData _deviceIcon(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('iphone') ||
      lower.contains('ipad') ||
      lower.contains('ipod') ||
      lower.contains('apple') ||
      lower.contains('mac') ||
      lower.contains('ios')) {
    return Icons.phone_iphone_rounded;
  }
  if (lower.contains('android') ||
      lower.contains('samsung') ||
      lower.contains('pixel') ||
      lower.contains('xiaomi') ||
      lower.contains('oneplus') ||
      lower.contains('galaxy') ||
      lower.startsWith('sm-')) {
    return Icons.phone_android_rounded;
  }
  return Icons.devices_rounded;
}
