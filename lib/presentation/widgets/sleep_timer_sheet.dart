import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_provider.dart';
import 'animated_toast.dart';
import 'wheel_time_picker.dart';

/// The one and only sleep-timer UI.
///
/// It used to exist twice: the player menu opened a wheel sheet while Settings →
/// Playback kept its own row of fixed pills (10/15/30/45/60/90). Two widgets
/// writing the same three bits of player state meant the pills could show "Off"
/// while a wheel-set timer was actually running, and any behaviour change had to
/// be made in both. Both entry points now call this.
///
/// Wheels rather than presets because presets only ever fit by accident —
/// wanting 25 minutes meant taking 30. The two non-duration choices ("End of
/// track", "Off") ride along as [extraActions] so nothing is lost.
Future<void> showSleepTimerSheet(
    BuildContext context, WidgetRef ref, Color themeColor) async {
  final notifier = ref.read(playerProvider.notifier);

  // Seed the wheels from whatever is already armed so reopening the sheet shows
  // the current timer instead of snapping back to the 30-minute default.
  final armedMinutes = ref.read(playerProvider).sleepTimerMinutes;
  final seed = (armedMinutes != null && armedMinutes > 0) ? armedMinutes : 30;

  // Resolved before the sheet closes: `context` belongs to the caller (a menu
  // sheet that may itself be popping), so a toast fired on it afterwards can
  // land on a defunct element.
  final rootCtx = Navigator.of(context, rootNavigator: true).context;

  void toast(String text) {
    if (rootCtx.mounted) {
      AnimatedToast.show(rootCtx,
          text: text, icon: Icons.bedtime_rounded, color: themeColor);
    }
  }

  final picked = await showWheelTimePicker(
    context,
    theme: themeColor,
    title: 'STOP PLAYING IN',
    initialHour: seed ~/ 60,
    initialMinute: seed % 60,
    hourCount: 12,
    durationMode: true,
    extraActions: [
      (
        icon: Icons.music_note_rounded,
        label: 'End of current track',
        onTap: () {
          notifier.setSleepAtEndOfTrack(true);
          toast('Sleeping at end of track');
        },
      ),
      (
        icon: Icons.close_rounded,
        label: 'Turn sleep timer off',
        onTap: () {
          notifier.setSleepTimer(null);
          toast('Sleep timer off');
        },
      ),
    ],
  );

  if (picked == null) return; // cancelled, or an extraAction handled it
  notifier.setSleepTimer(Duration(hours: picked.hour, minutes: picked.minute));
  final label = picked.hour == 0
      ? '${picked.minute} minutes'
      : picked.minute == 0
          ? '${picked.hour}h'
          : '${picked.hour}h ${picked.minute}m';
  toast('Sleeping in $label');
}
