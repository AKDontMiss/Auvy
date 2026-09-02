import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/wheel_time_picker.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/data/dummy_data.dart';

/// Region codes offered by the content-region picker. A short curated list beats
/// all ~250 ISO codes: these are the markets with distinct YouTube Music charts
/// that someone would plausibly want to switch to. 'Auto' (empty string) follows
/// the device locale and is the default.
/// Bottom sheet for choosing the ONE track the alarm plays.
///
/// Deliberately a filter over songs Auvy already has metadata for rather than a
/// live search: this list needs no network, appears instantly, and every entry
/// is something the user demonstrably listens to. Whatever they pick is
/// downloaded right after choosing, so it plays at 07:00 with no connection.
class _SongPickerSheet extends StatefulWidget {
  const _SongPickerSheet({required this.songs});

  final List<Song> songs;

  @override
  State<_SongPickerSheet> createState() => _SongPickerSheetState();
}

class _SongPickerSheetState extends State<_SongPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.songs
        : widget.songs
            .where((s) =>
                s.title.toLowerCase().contains(q) ||
                s.artist.toLowerCase().contains(q))
            .toList();

    return SafeArea(
      child: Padding(
        // Keeps the field above the keyboard instead of behind it.
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Wake up to this song',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                autofocus: false,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search your music',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                  prefixIcon:
                      const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.06),
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(
                      child: Text('Nothing matches',
                          style: TextStyle(color: Colors.white38, fontSize: 13)),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (ctx, i) {
                        final s = shown[i];
                        return ListTile(
                          onTap: () => Navigator.of(ctx).pop(s),
                          leading: AuvyImage(
                              path: s.image,
                              width: 42,
                              height: 42,
                              borderRadius: 8),
                          title: Text(s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13.5)),
                          subtitle: Text(s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11.5)),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

const List<(String, String)> kRegionOptions = [
  ('', 'Auto (device)'),
  ('US', 'United States'),
  ('GB', 'United Kingdom'),
  ('SE', 'Sweden'),
  ('NO', 'Norway'),
  ('DK', 'Denmark'),
  ('DE', 'Germany'),
  ('FR', 'France'),
  ('ES', 'Spain'),
  ('IT', 'Italy'),
  ('NL', 'Netherlands'),
  ('CA', 'Canada'),
  ('AU', 'Australia'),
  ('BR', 'Brazil'),
  ('MX', 'Mexico'),
  ('IN', 'India'),
  ('JP', 'Japan'),
  ('KR', 'South Korea'),
  ('NG', 'Nigeria'),
  ('ZA', 'South Africa'),
  ('TR', 'Türkiye'),
  ('PL', 'Poland'),
];

/// Wake-up alarm settings: time, repeat days, what to play, gentle fade-in.
///
/// The alarm is scheduled NATIVELY (`AlarmScheduler.kt`) because only
/// `AlarmManager` survives Doze and process death — this block only edits the
/// config and lets [AlarmService] re-arm. Self-contained (its own row widgets)
/// so it doesn't depend on settings_page's private helpers.
class AlarmSettingsBlock extends ConsumerStatefulWidget {
  const AlarmSettingsBlock({super.key});

  @override
  ConsumerState<AlarmSettingsBlock> createState() => _AlarmSettingsBlockState();
}

class _AlarmSettingsBlockState extends ConsumerState<AlarmSettingsBlock> {
  /// null while unknown; false means Android will batch the alarm.
  bool? _canExact;
  bool? _canFullScreen;

  /// When a pending snooze fires, or null when none is armed.
  ///
  /// Polled rather than pushed: a snooze is armed NATIVELY, usually from the
  /// alarm's notification while this isolate does not exist, so there is no
  /// in-app event to listen for. The ticker only runs while a snooze is actually
  /// pending and this block is on screen.
  DateTime? _snoozeAt;
  Timer? _snoozeTick;

  @override
  void initState() {
    super.initState();
    _checkExact();
    _checkFullScreen();
    _checkSnooze();
  }

  @override
  void dispose() {
    _snoozeTick?.cancel();
    super.dispose();
  }

  /// "07:10" — 24-hour, matching the alarm's own time label.
  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// " · in 8 min", or empty when it is under a minute away — "in 0 min" reads
  /// like a bug, and at that point the clock time says everything.
  static String _inMinutes(DateTime t) {
    final mins = t.difference(DateTime.now()).inMinutes;
    return mins < 1 ? '' : ' · in $mins min';
  }

  Future<void> _checkSnooze() async {
    final at = await AlarmService.snoozeTarget();
    if (!mounted) return;
    setState(() => _snoozeAt = at);
    _snoozeTick?.cancel();
    // Keep the countdown honest, and let the row disappear by itself the moment
    // the snooze fires — nothing else would take it away while this page is open.
    if (at != null) {
      _snoozeTick = Timer.periodic(const Duration(seconds: 15), (_) => _checkSnooze());
    }
  }

  Future<void> _checkFullScreen() async {
    final ok = await AlarmService.canUseFullScreen();
    if (mounted) setState(() => _canFullScreen = ok);
  }

  Future<void> _checkExact() async {
    final ok = await AlarmService.canScheduleExact();
    if (mounted) setState(() => _canExact = ok);
  }

  /// Wheel picker for the alarm CLOCK TIME. Shared with the sleep timer via
  /// [showWheelTimePicker] so both feel identical (and the 150-line picker isn't
  /// duplicated).
  Future<void> _pickTime() async {
    final picked = await showWheelTimePicker(
      context,
      theme: ref.read(themeProvider),
      title: 'WAKE ME AT',
      initialHour: AlarmService.hour,
      initialMinute: AlarmService.minute,
      hourCount: 24,
    );
    if (picked == null) return;
    await AlarmService.save(atHour: picked.hour, atMinute: picked.minute);
    if (mounted) setState(() {});
  }

  Widget _chip(IconData icon, Color tint) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: tint.withOpacity(0.16),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: tint, size: 18),
      );

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(height: 1, color: Colors.white.withOpacity(0.05)),
      );

  Widget _toggle({
    required IconData icon,
    required Color tint,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(children: [
        _chip(icon, tint),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }

  /// Download the alarm's audio now, so the file is ready long before 07:00.
  ///
  /// Fire-and-forget: the settings screen must never sit there waiting on a
  /// download, and the alarm falls back to the system tone if this never lands.
  void _refreshPreparedTrack() {
    if (!AlarmService.enabled) return;
    final picked = AlarmService.pickedSong;
    final lib = ref.read(libraryProvider);
    final coll = AlarmService.pickedCollection;
    final pool = AlarmService.source == 'song' && picked != null
        ? <Song>[picked]
        : (AlarmService.source == 'collection' && coll != null
            // First track of the collection — the same one prepareAlarmTrack
            // pins, so the file staged matches what will play.
            ? (lib.playlistSongs[coll] ?? const <Song>[])
            : <Song>[
                ...lib.likedSongs,
                ...ref.read(playerProvider).history,
              ]);
    if (pool.isEmpty) return;
    ref.read(playerProvider.notifier).prepareAlarmTrack(pool);
  }

  /// Choose a saved album or playlist to wake up to.
  ///
  /// Offered from playlistSongs, which is what the library actually holds tracks
  /// in, so anything with songs on disk or in the library is selectable, and the
  /// alarm pre-caches the FIRST track of it.
  Future<void> _pickCollection() async {
    final lib = ref.read(libraryProvider);
    // Only collections we can actually play: a title with no tracks would arm an
    // alarm that has nothing to prepare.
    final names = lib.playlistSongs.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (names.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Save or download an album or playlist first.'),
      ));
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Wake up to this album or playlist',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: names.length,
                itemBuilder: (c, i) {
                  final name = names[i];
                  final tracks = lib.playlistSongs[name] ?? const <Song>[];
                  return ListTile(
                    onTap: () => Navigator.of(c).pop(name),
                    leading: AuvyImage(
                        path: tracks.isEmpty ? '' : tracks.first.image,
                        width: 42,
                        height: 42,
                        borderRadius: 8),
                    title: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5)),
                    subtitle: Text('${tracks.length} songs',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11.5)),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );

    if (chosen == null) return;
    await AlarmService.save(pickCollection: chosen);
    if (mounted) setState(() {});
    _refreshPreparedTrack();
  }

  /// Choose ONE track to wake up to.
  ///
  /// Offered from what Auvy already knows the user listens to — liked, recently
  /// played, and everything with play history — rather than a fresh search, so
  /// the list is instant and offline. Anything picked is downloaded straight
  /// after, so an uncached track works at 07:00 in airplane mode just the same.
  Future<void> _pickSong() async {
    final seen = <String>{};
    final all = <Song>[
      ...ref.read(libraryProvider).likedSongs,
      ...ref.read(playerProvider).history,
      ...ref.read(intelligenceProvider).trackMetadata.values,
    ].where((s) => s.id.isNotEmpty && seen.add(s.id)).toList();

    if (all.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Play or like a few songs first, then pick one here.'),
      ));
      return;
    }

    final chosen = await showModalBottomSheet<Song>(
      context: context,
      // Same reason as the sheet that opens this one: the mini-player floats
      // above the tab navigator, so anything shown below it gets covered.
      useRootNavigator: true,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SongPickerSheet(songs: all),
    );

    if (chosen == null) return;
    // Choosing the track also switches the source to 'song'. See save().
    await AlarmService.save(pickSong: chosen);
    if (mounted) setState(() {});
    _refreshPreparedTrack();
  }

  /// [_chipRow] for STRING values. Same layout; a separate function rather than a
  /// generic one because the int version's call sites read better with plain
  /// tuples, and two eight-line builders beat one clever signature.
  Widget _chipRowStr({
    required IconData icon,
    required Color tint,
    required String label,
    required List<(String, String)> options,
    required String current,
    required Future<void> Function(String) onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _chip(icon, tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                GestureDetector(
                  onTap: () => onPick(o.$1),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: current == o.$1
                          ? tint
                          : Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(o.$2,
                        style: TextStyle(
                            color:
                                current == o.$1 ? Colors.black : Colors.white60,
                            fontSize: 11,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// A labelled row of small preset chips.
  ///
  /// Presets rather than a slider: these are choices with conventional answers
  /// (nobody wants a 37-second fade), and a chip states the current value in
  /// words where a slider makes you read a thumb position. Wrapped, so adding a
  /// fifth option later cannot push one off the screen edge, which is exactly
  /// how the "Song" source chip became invisible.
  Widget _chipRow({
    required IconData icon,
    required Color tint,
    required String label,
    required List<(int, String)> options,
    required int current,
    required Future<void> Function(int) onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _chip(icon, tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                GestureDetector(
                  onTap: () => onPick(o.$1),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: current == o.$1
                          ? tint
                          : Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(o.$2,
                        style: TextStyle(
                            color: current == o.$1
                                ? Colors.black
                                : Colors.white60,
                            fontSize: 11,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    const dayNames = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const sources = [
      ('liked', 'Liked'),
      ('top', 'Top'),
      ('recent', 'Recent'),
      ('song', 'Song'),
      ('collection', 'Album/Playlist'),
    ];

    return Column(
      children: [
        _toggle(
          icon: Icons.alarm_rounded,
          tint: const Color(0xFFFFCC80),
          title: 'Wake up to music',
          subtitle: AlarmService.enabled
              ? '${AlarmService.timeLabel} · ${AlarmService.daysLabel}'
              : 'Start your music instead of a ringtone',
          value: AlarmService.enabled,
          onChanged: (v) async {
            await AlarmService.save(isEnabled: v);
            if (mounted) setState(() {});
            if (v) {
              _checkExact();
              // Download the audio NOW. Without this the file only appeared on
              // the next app resume, so someone who set an alarm and put the
              // phone down would be woken by the system tone instead of their
              // music — the one night it matters most.
              _refreshPreparedTrack();
            }
          },
        ),
        if (AlarmService.enabled) ...[
          _divider(),
          InkWell(
            onTap: _pickTime,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(children: [
                _chip(Icons.schedule_rounded, const Color(0xFFFFCC80)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Alarm time',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                ),
                Text(AlarmService.timeLabel,
                    style: TextStyle(
                        color: theme,
                        fontSize: 20,
                        fontWeight: FontWeight.w900)),
              ]),
            ),
          ),
          _divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _chip(Icons.repeat_rounded, const Color(0xFFB39DDB)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Repeat',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(AlarmService.daysLabel,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (int d = 1; d <= 7; d++)
                      GestureDetector(
                        onTap: () async {
                          // No days selected at all = fire ONCE at the next
                          // occurrence, which AlarmService handles.
                          final next = Set<int>.of(AlarmService.days);
                          if (!next.remove(d)) next.add(d);
                          await AlarmService.save(onDays: next);
                          if (mounted) setState(() {});
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AlarmService.days.contains(d)
                                ? theme
                                : Colors.white.withOpacity(0.07),
                            shape: BoxShape.circle,
                          ),
                          child: Text(dayNames[d - 1],
                              style: TextStyle(
                                  color: AlarmService.days.contains(d)
                                      ? Colors.black
                                      : Colors.white54,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          _divider(),
          // THE CHIPS GET THEIR OWN LINE. They used to sit on the same Row as
          // the "Play" label, which fit exactly three — adding a fourth pushed it
          // off the right edge, so the "Song" option existed and could not be
          // seen or tapped. A Wrap under the label has room for this one and the
          // next.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _chip(Icons.queue_music_rounded, const Color(0xFF80CBC4)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Play',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
              for (final s in sources)
                Padding(
                  padding: const EdgeInsets.only(left: 0),
                  child: GestureDetector(
                    onTap: () async {
                      // 'Song' is a choice that needs an argument, so tapping it
                      // asks for one instead of selecting an empty mode.
                      if (s.$1 == 'song') {
                        await _pickSong();
                        return;
                      }
                      if (s.$1 == 'collection') {
                        await _pickCollection();
                        return;
                      }
                      await AlarmService.save(playSource: s.$1);
                      if (mounted) setState(() {});
                      _refreshPreparedTrack();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AlarmService.source == s.$1
                            ? const Color(0xFF80CBC4)
                            : Colors.white.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(s.$2,
                          style: TextStyle(
                              color: AlarmService.source == s.$1
                                  ? Colors.black
                                  : Colors.white60,
                              fontSize: 11,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
                  ],
                ),
              ],
            ),
          ),
          // The chosen track, when 'Song' is the source. Shown as a real row —
          // artwork and title, because "which song will actually play at 07:00"
          // is the one thing about this alarm a user needs to be certain of.
          if (AlarmService.source == 'song' && AlarmService.pickedSong != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: GestureDetector(
                onTap: _pickSong,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    AuvyImage(
                      path: AlarmService.pickedSong!.image,
                      width: 40,
                      height: 40,
                      borderRadius: 8,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AlarmService.pickedSong!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          Text(AlarmService.pickedSong!.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11.5)),
                        ],
                      ),
                    ),
                    const Text('Change',
                        style: TextStyle(
                            color: Color(0xFF80CBC4),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 4),
                  ]),
                ),
              ),
            ),
          _divider(),
          // Alarm loudness. Separate from the in-app player volume on purpose:
          // the alarm runs on the ALARM stream (so Do Not Disturb lets it
          // through), and this scales beneath the system alarm slider.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              _chip(Icons.campaign_rounded, const Color(0xFFFFAB91)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Alarm volume',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
              ),
              Text('${(AlarmService.volume * 100).round()}%',
                  style: const TextStyle(
                      color: Color(0xFFFFAB91),
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 16, 8),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFFFFAB91),
                inactiveTrackColor: Colors.white24,
                thumbColor: const Color(0xFFFFAB91),
                overlayColor: const Color(0x22FFAB91),
                trackHeight: 3,
              ),
              child: Slider(
                value: AlarmService.volume.clamp(0.05, 1.0),
                min: 0.05,
                max: 1.0,
                // Persist only when the drag ENDS — writing prefs on every
                // pixel of a slider drag is dozens of disk writes per gesture.
                onChanged: (v) => setState(() => AlarmService.volume = v),
                onChangeEnd: (v) async {
                  await AlarmService.save(atVolume: v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          _divider(),
          _toggle(
            icon: Icons.volume_up_rounded,
            tint: const Color(0xFF9FA8DA),
            title: 'Gentle fade-in',
            // Reads the LIVE value. Hardcoding "~30 seconds" was true only until
            // the duration became adjustable, and a subtitle that contradicts the
            // control right below it is worse than no subtitle.
            subtitle: AlarmService.fadeIn
                ? 'Ramp the volume up over ${AlarmService.fadeSeconds}s'
                : 'Start at your chosen volume straight away',
            value: AlarmService.fadeIn,
            onChanged: (v) async {
              await AlarmService.save(withFadeIn: v);
              if (mounted) setState(() {});
            },
          ),
          // How LONG the ramp takes. Only meaningful while fade-in is on, so it
          // is hidden when off rather than shown greyed out — a disabled control
          // still costs a glance to work out why it is disabled.
          if (AlarmService.fadeIn)
            _chipRow(
              icon: Icons.timelapse_rounded,
              tint: const Color(0xFF9FA8DA),
              label: 'Ramp over',
              options: const [(2, '2s'), (5, '5s'), (10, '10s'), (15, '15s')],
              current: AlarmService.fadeSeconds,
              onPick: (v) async {
                await AlarmService.save(atFadeSeconds: v);
                if (mounted) setState(() {});
              },
            ),
          _divider(),
          // How the ringing screen looks. Worth a setting: it is the screen you
          // meet at the most light-sensitive moment of the day.
          _chipRowStr(
            icon: Icons.wallpaper_rounded,
            tint: const Color(0xFF80DEEA),
            label: 'Alarm screen',
            options: const [
              ('accent', 'Accent'),
              ('art', 'Cover art'),
              ('plain', 'Plain'),
            ],
            current: AlarmService.background,
            onPick: (v) async {
              await AlarmService.save(atBackground: v);
              if (mounted) setState(() {});
            },
          ),
          _toggle(
            icon: Icons.blur_on_rounded,
            tint: const Color(0xFF80DEEA),
            title: 'Pulse while playing',
            subtitle: 'The artwork breathes gently with the music',
            value: AlarmService.pulse,
            onChanged: (v) async {
              await AlarmService.save(withPulse: v);
              if (mounted) setState(() {});
            },
          ),
          _divider(),
          _chipRow(
            icon: Icons.snooze_rounded,
            tint: const Color(0xFFCE93D8),
            label: 'Snooze',
            options: const [(5, '5m'), (10, '10m'), (15, '15m')],
            current: AlarmService.snoozeMinutes,
            onPick: (v) async {
              await AlarmService.save(atSnoozeMinutes: v);
              if (mounted) setState(() {});
            },
          ),
          // A snooze in flight, AND the way out of it
          //
          // Only shown while one is actually armed. Snooze used to be a one-way
          // door: once tapped, the alarm WAS coming back, and the only way to stop
          // it was switching the whole alarm off, which also throws away
          // tomorrow's schedule. The notification carries the same Cancel (that is
          // where it gets used at 07:00); this is here for the times the phone is
          // already in your hand and the banner has been swiped away.
          if (_snoozeAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: Row(
                children: [
                  Icon(Icons.snooze_rounded,
                      size: 18, color: const Color(0xFFCE93D8).withOpacity(0.9)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Snoozed — rings again at ${_clock(_snoozeAt!)}'
                      '${_inMinutes(_snoozeAt!)}',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.75),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () async {
                      HapticService.selection();
                      await AlarmService.cancelSnooze();
                      await _checkSnooze();
                      if (mounted) {
                        AnimatedToast.message('Snooze cancelled');
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          // Android 12+ can refuse EXACT alarms until the user allows it. Say so
          // plainly — an alarm silently drifting by minutes is worse than a
          // warning, and this is the one feature where being late is a failure.
          // WITHOUT THIS THE ALARM SCREEN NEVER APPEARS ON ITS OWN. Android 14+
          // gates the full-screen intent behind a per-app permission; refused, the
          // alarm still rings but the user has to unlock the phone to find the stop
          // button. That is exactly the sort of thing that must not be discovered
          // at 07:00, so it is stated here.
          if (_canFullScreen == false)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: GestureDetector(
                onTap: () async {
                  await AlarmService.requestFullScreen();
                  _checkFullScreen();
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withOpacity(0.35)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.lock_outline_rounded,
                        color: Colors.orangeAccent, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Android will not show the alarm screen over your '
                        'lockscreen yet, so you would have to unlock the phone to '
                        'stop it. Tap to allow.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          if (_canExact == false)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: GestureDetector(
                onTap: () async {
                  await AlarmService.requestExactPermission();
                  _checkExact();
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withOpacity(0.35)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.orangeAccent, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Android is batching this alarm, so it may fire a few '
                        'minutes late. Tap to allow exact alarms.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
