import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/haptic_service.dart';
import 'animated_toast.dart';
import 'wheel_time_picker.dart';
import 'package:auvy/core/app_colors.dart';

/// The one sleep-timer UI, opened from both the player menu and Settings →
/// Playback.
///
/// It leads with what's already set ("42 minutes left") and preset durations,
/// since the answer to "when should the music stop" is usually a round number.
/// "End of track" and "Off" are shown as their own choices. "Custom" opens the
/// same two-wheel picker as the alarm, so any duration can still be set.
Future<void> showSleepTimerSheet(
    BuildContext context, WidgetRef ref, Color themeColor) async {
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _SleepTimerSheet(),
  );
}

class _SleepTimerSheet extends ConsumerStatefulWidget {
  const _SleepTimerSheet();

  @override
  ConsumerState<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends ConsumerState<_SleepTimerSheet> {
  /// Every sheet's surface, defined once. See [AppColors.modalPanel] for why it
  /// is not a hex literal here.
  static const _card = AppColors.modalPanel;

  /// The round numbers people actually pick. An album, a wind-down, a nap.
  static const _presets = <int>[15, 30, 45, 60, 90];

  /// Redraws the remaining-time line. ONE SECOND, and only while a timer is
  /// armed — a countdown that updates per minute looks frozen, and one that
  /// runs when nothing is set is a timer for its own sake.
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _syncTicker(bool armed) {
    if (armed && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!armed && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  void _toast(String text, Color themeColor) {
    // The ROOT context, resolved before this sheet pops: the caller's context
    // may belong to a menu that is itself closing, and a toast fired on a
    // defunct element goes nowhere.
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    if (rootCtx.mounted) {
      AnimatedToast.show(rootCtx,
          text: text, icon: Icons.bedtime_rounded, color: themeColor);
    }
  }

  String _left(DateTime endsAt) {
    final d = endsAt.difference(DateTime.now());
    if (d.isNegative) return 'any moment now';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    // Seconds only in the last minute, where they are the interesting part.
    if (h > 0) return '${h}h ${m}m left';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s left';
    return '${s}s left';
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final notifier = ref.read(playerProvider.notifier);
    final s = ref.watch(playerProvider.select((p) =>
        (p.sleepTimerEndsAt, p.sleepTimerMinutes, p.sleepAtEndOfTrack)));
    final endsAt = s.$1;
    final armedMinutes = s.$2;
    final endOfTrack = s.$3;
    final armed = endsAt != null || endOfTrack;
    _syncTicker(endsAt != null);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _header(themeColor, endsAt, endOfTrack),
              const SizedBox(height: 18),

              // Presets. Wrap, not Row: five pills don't fit one line on a narrow phone, and a
              // horizontal scroller would hide the later ones.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in _presets)
                    _pill(
                      label: m < 60
                          ? '$m min'
                          : m == 60
                              ? '1 hour'
                              : '${m ~/ 60}h ${m % 60}m',
                      // Selected only when the timer was ARMED at this value,
                      // which is what `sleepTimerMinutes` records. It is not
                      // derived from the time remaining, or every pill would
                      // deselect itself a second after being tapped.
                      selected: endsAt != null && armedMinutes == m,
                      themeColor: themeColor,
                      onTap: () {
                        HapticService.selection();
                        notifier.setSleepTimer(Duration(minutes: m));
                        _toast(
                            'Sleeping in ${m < 60 ? '$m minutes' : m == 60 ? '1 hour' : '${m ~/ 60}h ${m % 60}m'}',
                            themeColor);
                        Navigator.of(context).pop();
                      },
                    ),
                  _pill(
                    label: 'Custom',
                    icon: Icons.tune_rounded,
                    // A custom value is one that is armed but not a preset.
                    selected: endsAt != null &&
                        armedMinutes != null &&
                        !_presets.contains(armedMinutes),
                    themeColor: themeColor,
                    onTap: () => _openWheel(notifier, themeColor,
                        seed: armedMinutes ?? 30),
                  ),
                ],
              ),

              const SizedBox(height: 14),
              Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
              const SizedBox(height: 6),

              // The choice that isn't a duration.
              _row(
                icon: Icons.music_note_rounded,
                label: 'End of current track',
                subtitle: 'Finish what is playing, then stop',
                selected: endOfTrack,
                themeColor: themeColor,
                onTap: () {
                  HapticService.selection();
                  notifier.setSleepAtEndOfTrack(true);
                  _toast('Sleeping at end of track', themeColor);
                  Navigator.of(context).pop();
                },
              ),

              // Only offered when there's a timer to turn off.
              if (armed) ...[
                _row(
                  icon: Icons.close_rounded,
                  label: 'Turn off',
                  subtitle: endOfTrack
                      ? 'Keep playing past this track'
                      : 'Keep playing',
                  selected: false,
                  themeColor: themeColor,
                  destructive: true,
                  onTap: () {
                    HapticService.light();
                    notifier.setSleepTimer(null);
                    _toast('Sleep timer off', themeColor);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Color themeColor, DateTime? endsAt, bool endOfTrack) {
    // The subtitle is the whole reason to reopen this sheet: what is set, and
    // how long is left. "Off" is stated rather than left blank, so the sheet
    // always answers the question it was opened to ask.
    final String subtitle;
    if (endsAt != null) {
      subtitle = _left(endsAt);
    } else if (endOfTrack) {
      subtitle = 'Stopping at the end of this track';
    } else {
      subtitle = 'Off — music keeps playing';
    }
    final active = endsAt != null || endOfTrack;

    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: active ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
                color: themeColor.withValues(alpha: active ? 0.34 : 0.18)),
          ),
          child: Icon(Icons.bedtime_rounded, color: themeColor, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Sleep timer',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  // The accent carries "something is armed" without needing a
                  // second badge to say so.
                  color: active
                      ? themeColor
                      : Colors.white.withValues(alpha: 0.60),
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openWheel(
      PlayerNotifier notifier, Color themeColor, {required int seed}) async {
    HapticService.light();
    final picked = await showWheelTimePicker(
      context,
      theme: themeColor,
      title: 'STOP PLAYING IN',
      initialHour: seed ~/ 60,
      initialMinute: seed % 60,
      hourCount: 12,
      durationMode: true,
    );
    if (picked == null || !mounted) return;
    notifier.setSleepTimer(
        Duration(hours: picked.hour, minutes: picked.minute));
    final label = picked.hour == 0
        ? '${picked.minute} minutes'
        : picked.minute == 0
            ? '${picked.hour}h'
            : '${picked.hour}h ${picked.minute}m';
    _toast('Sleeping in $label', themeColor);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _pill({
    required String label,
    required bool selected,
    required Color themeColor,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
              horizontal: icon == null ? 16 : 13, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? themeColor.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected
                  ? themeColor.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.09),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 15,
                    color: selected
                        ? themeColor
                        : Colors.white.withValues(alpha: 0.70)),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected ? themeColor : Colors.white,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool selected,
    required Color themeColor,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final tint = destructive
        ? const Color(0xFFE57373)
        : (selected ? themeColor : Colors.white);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
          child: Row(
            children: [
              Icon(icon,
                  size: 19,
                  color: destructive
                      ? tint.withValues(alpha: 0.85)
                      : (selected
                          ? themeColor
                          : Colors.white.withValues(alpha: 0.75))),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: tint,
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.50),
                            fontSize: 11.5)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: themeColor),
            ],
          ),
        ),
      ),
    );
  }
}
