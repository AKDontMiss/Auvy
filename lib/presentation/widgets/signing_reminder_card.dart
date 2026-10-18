import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/signing_reminder_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// iOS only, on Home: "refresh Auvy in SideStore" once two days or less of the
/// signature remain, and before that, once, the offer of reminders. Nothing on
/// Android, on an App Store build, or while there is nothing to say. See
/// [SigningReminderNotifier].
class SigningReminderCard extends ConsumerWidget {
  const SigningReminderCard({super.key});

  static Future<void> openSideStore() async {
    for (final scheme in const ['sidestore', 'altstore']) {
      final uri = Uri.parse('$scheme://');
      try {
        if (await canLaunchUrl(uri) &&
            await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (_) {}
    }
    AnimatedToast.message("SideStore isn't installed on this iPhone");
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final s = ref.watch(signingReminderProvider);
    final theme = ref.watch(themeProvider);
    final notifier = ref.read(signingReminderProvider.notifier);

    Future<void> refreshed() async {
      await notifier.markRefreshed();
      final at = ref.read(signingReminderProvider).expiresAt;
      if (at == null) return;
      final loc = MaterialLocalizations.of(context);
      AnimatedToast.message('Got it: signed until ${loc.formatMediumDate(at)}');
    }

    // SideStore renewed Auvy but Auvy wasn't told, so it has no date to count
    // down to (see SigningReminderNotifier). Said once per refresh.
    if (s.renewedUnseen && s.dismissed != s.renewedDismissKey) {
      return _card(
        theme: theme,
        urgent: false,
        icon: Icons.verified_rounded,
        title: 'SideStore renewed Auvy',
        body: "Auvy can't see the new date SideStore set, so its reminders are "
            "paused. After your next refresh, tap \"I've refreshed\" here or on "
            'the reminder to keep them on time. SideStore warns before it runs '
            'out too.',
        primary: "I've just refreshed",
        onPrimary: refreshed,
        secondary: 'OK',
        onSecondary: notifier.dismissRenewed,
      );
    }

    final expiresAt = s.expiresAt;
    if (expiresAt == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final stage = signingStage(expiresAt, now);

    if (stage != SigningStage.fine && s.dismissed != s.dismissKey(stage)) {
      final expired = stage == SigningStage.expired;
      // The reminder offer rides on this card rather than following it: a
      // second card sliding into the same place took a double tap on "Later"
      // as "Not now" (seen on device).
      final offer = s.enabled == null && !expired;
      return _card(
        theme: theme,
        urgent: stage == SigningStage.hours || expired,
        icon: Icons.update_rounded,
        title: expired ? "Auvy's signature has run out" : 'Refresh Auvy in SideStore',
        body: expired
            ? "Refresh it in SideStore before closing Auvy. Once closed, it won't "
                'open again until you do.'
            : 'Its signature runs out in ${formatSigningLeft(expiresAt.difference(now))}. '
                'Turn on LocalDevVPN, open SideStore and tap Refresh All.',
        primary: 'Open SideStore',
        onPrimary: openSideStore,
        secondary: 'Later',
        onSecondary: () => notifier.dismiss(stage),
        // SideStore's refresh can't be seen from here, so it's confirmed by hand.
        refreshedLabel: "I've refreshed",
        onRefreshed: refreshed,
        extra: offer ? 'Remind me' : null,
        onExtra: offer
            ? () async {
                if (await notifier.enable()) {
                  AnimatedToast.message("You'll be reminded before it runs out");
                }
              }
            : null,
      );
    }

    // Only while no refresh card can show (see above).
    if (s.enabled == null && stage == SigningStage.fine) {
      final loc = MaterialLocalizations.of(context);
      return _card(
        theme: theme,
        urgent: false,
        icon: Icons.notifications_active_outlined,
        title: 'Remind me before Auvy runs out?',
        body: 'SideStore signs Auvy for a few days at a time, and if a renewal is '
            'missed Auvy stops opening. This one lasts until '
            '${loc.formatMediumDate(expiresAt)}. Get a quiet notification the day '
            'before, and one 3 hours before.',
        primary: 'Remind me',
        onPrimary: () async {
          final ok = await notifier.enable();
          if (ok) AnimatedToast.message("You'll be reminded before it runs out");
        },
        secondary: 'Not now',
        onSecondary: notifier.disable,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _card({
    required Color theme,
    required bool urgent,
    required IconData icon,
    required String title,
    required String body,
    required String primary,
    required VoidCallback onPrimary,
    required String secondary,
    required VoidCallback onSecondary,
    String? extra,
    VoidCallback? onExtra,
    String? refreshedLabel,
    VoidCallback? onRefreshed,
  }) {
    final accent = urgent ? const Color(0xFFFFB74D) : theme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(body,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12.5,
                              height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
            // A Wrap, not a Row: with four buttons a narrow phone wraps them
            // onto two lines instead of overflowing.
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    HapticService.selection();
                    onSecondary();
                  },
                  child: Text(secondary,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
                ),
                if (extra != null && onExtra != null)
                  TextButton(
                    onPressed: () {
                      HapticService.selection();
                      onExtra();
                    },
                    child: Text(extra, style: const TextStyle(color: Colors.white)),
                  ),
                if (refreshedLabel != null && onRefreshed != null)
                  TextButton(
                    onPressed: () {
                      HapticService.selection();
                      onRefreshed();
                    },
                    child: Text(refreshedLabel, style: const TextStyle(color: Colors.white)),
                  ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () {
                    HapticService.selection();
                    onPrimary();
                  },
                  child: Text(primary,
                      style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
