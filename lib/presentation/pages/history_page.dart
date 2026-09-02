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

// LISTENING HISTORY — makeover in the Stats-page design language.
// Overview cards (today / this week / total plays) → day-grouped timeline
// (Today, Yesterday, dated sections) with play-count badges and quick actions.

class _HistoryEntry {
  final Song song;
  final DateTime? playedAt;
  final int playCount;
  _HistoryEntry(this.song, this.playedAt, this.playCount);
}

class _DayGroup {
  final String label;
  final List<_HistoryEntry> entries = [];
  _DayGroup(this.label);
}

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final intel = ref.watch(intelligenceProvider);
    final rawHistory = ref.watch(playerProvider.select((ps) => ps.history));

    final now = DateTime.now();

    // The ledger is the history, NOT the player's session list
    //
    // THIS PAGE USED TO SHOW ONLY `playerState.history` — the in-memory list
    // of what this app had played, capped at 50 and rebuilt from scratch. So it
    // could not show a play the app did not personally make:
    //
    //  • an imported library arrived with 324 tracks carrying real play dates and
    //    NONE of them appeared here, which is exactly the "history isn't coming"
    //    report;
    //  • and the overview cards above (built from the intelligence ledger) were
    //    already counting plays this list could not display, so the numbers and
    //    the timeline disagreed on screen.
    //
    // `lastPlayTimestamps` IS the record — it is what the stats page, the streak
    // and the yearly wrap-up all read, it survives restarts, and it is what an
    // import writes into. The player's session list is still merged in, because a
    // track played seconds ago may not have crossed the scrobble threshold yet.
    final seenIds = <String>{};
    final entries = <_HistoryEntry>[];

    void add(Song s, int? ms) {
      if (s.id.startsWith('onb_') ||
          s.id.startsWith('dummy') ||
          s.title.isEmpty ||
          !seenIds.add(s.id)) {
        return;
      }
      entries.add(_HistoryEntry(
        s,
        ms != null
            ? DateTime.fromMillisecondsSinceEpoch(
                ms < 10000000000 ? ms * 1000 : ms)
            : null,
        intel.playCounts[s.id] ?? 0,
      ));
    }

    // This session first: these are the most recent plays by definition, and
    // some have no ledger stamp yet.
    for (final s in rawHistory) {
      add(s, intel.lastPlayTimestamps[s.id]);
    }
    // Then everything the ledger knows, newest first.
    final tracked = intel.lastPlayTimestamps.entries
        .where((e) => intel.trackMetadata.containsKey(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in tracked) {
      final song = intel.trackMetadata[e.key];
      if (song != null) add(song, e.value);
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

    // Group into day sections.
    //
    // Two bugs lived here. (1) The old loop only started a new group when the
    // label DIFFERED FROM THE PREVIOUS ONE, so a day could appear more than once
    // — "Today", "Yesterday", then "Today" again, because `history` is ordered
    // by when a track was last *queued*, which does not have to agree with its
    // timestamp. (2) Entries with no timestamp were labelled "Earlier" inline,
    // so an "Earlier" heading could surface in the middle of today's plays.
    //
    // Now: bucket by calendar day, sort the days newest-first and each day's
    // entries newest-first, and collect every unknown-timestamp entry into a
    // SINGLE "Earlier" group pinned to the bottom (shown only if non-empty).
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
      final g = _DayGroup(_dayLabel(day, now));
      g.entries.addAll(byDay[day]!
        ..sort((a, b) => b.playedAt!.compareTo(a.playedAt!)));
      groups.add(g);
    }
    if (undated.isNotEmpty) {
      groups.add(_DayGroup('Earlier')..entries.addAll(undated));
    }

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
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

              if (entries.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.history_rounded,
                            size: 56, color: Colors.white.withOpacity(0.2)),
                        const SizedBox(height: 16),
                        Text('No listening history yet',
                            style:
                                TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 16)),
                        const SizedBox(height: 6),
                        Text('Tracks you play will show up here',
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
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(song.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
                      ),
                      if (time.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text('· $time',
                            style: TextStyle(
                                color: theme.withOpacity(0.85),
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (entry.playCount > 1) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${entry.playCount}×',
                    style: TextStyle(
                        color: theme, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ],
            IconButton(
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
              onPressed: onMenu,
            ),
          ],
        ),
      ),
    );
  }
}
