import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/database_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';

// PRIVACY — one screen that answers "what does Auvy keep about me?".
//
// Each "pause X history" switch is paired with a "clear X history" action,
// because that pairing is what makes the switch honest: pausing stops NEW recording
// but deletes nothing, so without a clear action next to it the screen quietly
// implies more than it does. Auvy already had both pause switches (buried in
// "Listening data" alongside unrelated playback preferences) and both clear
// actions (one on the History page, one in the search sheet), but never in the
// same place, so no single screen answered "what does Auvy keep about me?".
//
// The third group is screenshot blocking: Android's FLAG_SECURE.

class PrivacyPage extends ConsumerStatefulWidget {
  const PrivacyPage({super.key});

  @override
  ConsumerState<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends ConsumerState<PrivacyPage> {
  /// Destructive confirms. Returns true only on an explicit "Clear".
  Future<bool> _confirm(String title, String body, String action) async {
    final themeColor = ref.read(themeProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(body,
            style: const TextStyle(color: Colors.white60, fontSize: 13.5, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action,
                style: TextStyle(color: themeColor, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _clearListenHistory() async {
    // The wording is exact on purpose. `clearListeningHistory()` empties the
    // RECORD of what was played; it does not touch play counts, stats, Wrapped
    // or the taste model, and claiming otherwise here would be the same class
    // of lie as a switch that isn't wired to anything. The two controls that do
    // clear those are named so the user can find them.
    if (!await _confirm(
      'Clear listening history?',
      'Removes the record of what you have played, including the log Auvy '
          'keeps on this device.\n\nPlay counts, stats and Wrapped are kept — '
          'they are built from counts, not from this list. To clear the '
          'predictions built on top of them, use Settings → Intelligence → '
          'Reset taste profile.',
      'Clear',
    )) {
      return;
    }
    // The same two calls the History page's own clear button makes — reused
    // rather than reimplemented so the two entry points can never drift apart.
    ref.read(intelligenceProvider.notifier).clearListeningHistory();
    ref.read(playerProvider.notifier).clearPlaybackHistory();
    // Plus the sqflite play log, which neither of those touches. Nothing reads
    // that table today, which is precisely why it would otherwise sit there
    // holding a timestamped list of every play the user just asked to remove.
    try {
      await DatabaseService().clearListenHistoryTable();
    } catch (_) {
      // A locked/absent DB must not make the in-memory clear look like it failed.
    }
    HapticService.medium();
    AnimatedToast.message('Listening history cleared');
    if (mounted) setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    if (!await _confirm(
      'Clear search history?',
      'Removes every query you have searched for. Suggestions keep working — '
          'those come from YouTube as you type and were never stored.',
      'Clear',
    )) {
      return;
    }
    await ref.read(searchProvider.notifier).clearHistory();
    HapticService.medium();
    AnimatedToast.message('Search history cleared');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: 'Privacy',
      children: [
        // Private session, FIRST
        //
        // Above the standing switches because it is the one you reach for in the
        // moment — handing your phone to someone, or playing something you don't
        // want shaping your recommendations for the next month. It suspends
        // everything the rows below control, at once.
        //
        // The subtitle states that it ends when Auvy closes. That is deliberate
        // (see ListeningPolicy.privateSession) and it MUST be said: a privacy
        // mode you think is still on when it isn't is worse than no mode at all,
        // and the reverse — one silently still on weeks later — quietly throws
        // away everything you listen to.
        Column(children: [
          SettingsToggleRow(
            icon: Icons.visibility_off_rounded,
            tint: const Color(0xFFB39DDB),
            title: 'Private session',
            subtitle: ListeningPolicy.privateSession
                ? 'On — nothing is being recorded. Ends when Auvy closes'
                : 'Pause all history and scrobbling until Auvy closes',
            value: ListeningPolicy.privateSession,
            onChanged: (v) {
              // No await: session-only, so there is nothing to persist.
              ListeningPolicy.privateSession = v;
              HapticService.medium();
              if (mounted) setState(() {});
            },
          ),
        ]),
        Column(children: [
          SettingsToggleRow(
            icon: Icons.history_toggle_off_rounded,
            tint: const Color(0xFFFFAB91),
            title: 'Pause listening history',
            subtitle: 'Stop counting plays, stats and recommendations',
            value: ListeningPolicy.pauseListeningHistory,
            onChanged: (v) async {
              await ListeningPolicy.setPauseListeningHistory(v);
              if (mounted) setState(() {});
            },
          ),
          const SettingsDivider(),
          SettingsActionRow(
            icon: Icons.delete_sweep_rounded,
            tint: const Color(0xFFFF8A80),
            title: 'Clear listening history',
            subtitle: 'Delete the record of what you have played (counts kept)',
            destructive: true,
            onTap: _clearListenHistory,
          ),
        ]),
        Column(children: [
          SettingsToggleRow(
            icon: Icons.search_off_rounded,
            tint: const Color(0xFF80CBC4),
            title: 'Pause search history',
            subtitle: "Don't save what you search for",
            value: ListeningPolicy.pauseSearchHistory,
            onChanged: (v) async {
              await ListeningPolicy.setPauseSearchHistory(v);
              if (mounted) setState(() {});
            },
          ),
          const SettingsDivider(),
          SettingsActionRow(
            icon: Icons.clear_all_rounded,
            tint: const Color(0xFFFF8A80),
            title: 'Clear search history',
            subtitle: 'Delete every query already saved',
            destructive: true,
            onTap: _clearSearchHistory,
          ),
        ]),
        Column(children: [
          SettingsToggleRow(
            icon: Icons.screenshot_monitor_rounded,
            tint: const Color(0xFFB39DDB),
            title: 'Block screenshots',
            subtitle: 'Also blocks screen recording and the recents preview',
            value: ListeningPolicy.blockScreenshots,
            onChanged: (v) async {
              await ListeningPolicy.setBlockScreenshots(v);
              if (mounted) setState(() {});
            },
          ),
          // The one consequence that surprises people: FLAG_SECURE hides the
          // window from every non-secure display, so screen mirroring goes black
          // too. Song recognition is NOT affected — that captures audio through
          // AudioPlaybackCaptureConfiguration, which FLAG_SECURE doesn't govern.
          if (ListeningPolicy.blockScreenshots)
            const Padding(
              padding: EdgeInsets.fromLTRB(60, 0, 16, 14),
              child: Text(
                'Screen mirroring and casting will show a black screen while this '
                'is on. Playback, Android Auto and song recognition are unaffected.',
                style: TextStyle(color: Colors.white38, fontSize: 11.5, height: 1.4),
              ),
            ),
        ]),
      ],
    );
  }
}
