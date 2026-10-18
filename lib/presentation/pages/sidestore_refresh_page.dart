import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/signing_reminder_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// iOS: everything about keeping the SideStore signature fresh, behind the one
/// "SideStore refresh" row in Settings → Updates.
///
/// Three rows used to sit in Updates side by side (the reminders switch, "I've
/// refreshed" and the automation guide), which read as three things to look
/// after. With a Shortcuts automation there is usually nothing to do, so Updates
/// shows the status and the controls wait here: the automation first, then the
/// reminders as the net under it, then the by-hand confirmation.
class SideStoreRefreshPage extends ConsumerWidget {
  const SideStoreRefreshPage({super.key});

  static const _tint = Color(0xFFA5D6A7);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(signingReminderProvider);
    final notifier = ref.read(signingReminderProvider.notifier);
    final blocked = s.enabled == true && s.permission == 'denied';
    return SettingsSubPage(
      title: 'SideStore refresh',
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          sideStoreRefreshSummary(context, s),
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13.5, height: 1.4),
        ),
      ),
      children: [
        SettingsNavRow(
          icon: Icons.autorenew_rounded,
          tint: _tint,
          title: 'Refresh automatically',
          subtitle: shortcutIsWorking(s, DateTime.now())
              ? 'Set up: your shortcut refreshes SideStore and tells Auvy.'
              : 'A shortcut refreshes SideStore when you plug in at home, then tells '
                  'Auvy. About two minutes, once.',
          onTap: () {
            HapticService.selection();
            Navigator.push(context, MainLayout.smoothRoute(const AutoRefreshSetupPage()));
          },
        ),
        Column(
          children: [
            SettingsToggleRow(
              icon: Icons.notifications_none_rounded,
              tint: _tint,
              title: "Remind me if it isn't refreshed",
              subtitle: blocked
                  ? 'Notifications are off for Auvy in iOS Settings; tap to open them.'
                  : 'A quiet notification a day before it runs out, and one 3 hours before. '
                      'While the shortcut works, they never come.',
              value: s.enabled == true && !blocked,
              onChanged: (v) async {
                if (blocked) {
                  await notifier.openSettings();
                } else if (v) {
                  await notifier.enable();
                } else {
                  await notifier.disable();
                }
              },
            ),
            const SettingsDivider(),
            SettingsActionRow(
              icon: Icons.check_circle_outline_rounded,
              tint: _tint,
              title: 'I refreshed by hand',
              subtitle: "After refreshing in SideStore yourself, so the date follows. "
                  'The shortcut tells Auvy on its own.',
              onTap: () async {
                HapticService.selection();
                await notifier.markRefreshed();
                final at = ref.read(signingReminderProvider).expiresAt;
                if (at != null && context.mounted) {
                  final loc = MaterialLocalizations.of(context);
                  AnimatedToast.message('Got it: signed until ${loc.formatMediumDate(at)}');
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// One line on the signature, for the Settings row and the top of the page:
/// until when, and what keeps it fresh.
String sideStoreRefreshSummary(BuildContext context, SigningReminderState s) {
  final expiresAt = s.expiresAt;
  if (expiresAt == null) {
    return "SideStore renewed Auvy, but the new date can't be seen from inside "
        'the app. It shows again after the next refresh the shortcut, or you, '
        'tells Auvy about.';
  }
  final loc = MaterialLocalizations.of(context);
  final time = loc.formatTimeOfDay(TimeOfDay.fromDateTime(expiresAt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  final now = DateTime.now();
  final signed = 'Signed until ${loc.formatMediumDate(expiresAt)}, $time '
      '(${formatSigningLeft(expiresAt.difference(now))} left).';
  final at = s.refreshedAt;
  if (at != null && shortcutIsWorking(s, now)) {
    return '$signed Your shortcut last refreshed it ${_ago(now.difference(at))}.';
  }
  if (s.enabled == true && s.permission == 'granted') {
    return '$signed You get a reminder before it runs out.';
  }
  return '$signed Set it to refresh by itself, or get a reminder.';
}

/// Whether the last refresh came from the shortcut recently enough to say the
/// automation runs (it refreshes at least weekly, so a week and a day).
bool shortcutIsWorking(SigningReminderState s, DateTime now) {
  final at = s.refreshedAt;
  return s.refreshedVia == 'shortcut' &&
      at != null &&
      now.difference(at) < const Duration(days: 8);
}

String _ago(Duration d) {
  if (d.inMinutes < 2) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} minutes ago';
  if (d.inDays < 1) return d.inHours == 1 ? 'an hour ago' : '${d.inHours} hours ago';
  return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
}

/// Setting up the automatic refresh without leaving the phone: the shortcut's
/// five actions by their exact names, buttons into the Shortcuts app, and a
/// line that turns to "working" when the shortcut's first run reaches Auvy.
///
/// Walked through rather than imported, because it can't be imported. SideStore
/// installs each app under the installer's own team, so a shared shortcut's
/// SideStore and Auvy steps name the maker's copies and fail on every other
/// phone (and the shared file carries the maker's team id). Auvy can't build one
/// for the listener either: since iOS 15 the Shortcuts app imports only files
/// signed through Apple, which happens on a Mac. And no app can share or create
/// an automation.
class AutoRefreshSetupPage extends ConsumerWidget {
  const AutoRefreshSetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final s = ref.watch(signingReminderProvider);
    final now = DateTime.now();
    final working = shortcutIsWorking(s, now);
    final at = s.refreshedAt;
    final dim = TextStyle(color: Colors.white.withValues(alpha: 0.62), fontSize: 12.5, height: 1.4);

    return SettingsSubPage(
      title: 'Refresh automatically',
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          'SideStore has to renew Auvy at least every 7 days, on Wi-Fi with '
          'LocalDevVPN on. A shortcut and an automation can do it each time you '
          'plug in at home. About two minutes, once.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13.5, height: 1.4),
        ),
      ),
      children: [
        _SetupCard(
          accent: accent,
          number: 1,
          title: 'Make the shortcut',
          intro: 'Tap the button, then add these actions in order. In the editor, tap '
              'Search Actions and type each name.',
          steps: const [
            ('Set VPN', 'Connect, LocalDevVPN'),
            ('Wait', '3 seconds, so the VPN is up'),
            ('Refresh All Apps', "SideStore's action. It renews SideStore too."),
            ('Set VPN', 'Disconnect, LocalDevVPN'),
            ('Mark Auvy as Refreshed', "Auvy's action (iOS 16 and later). It says the new "
                'date; turn off its Show When Run to keep it quiet.'),
          ],
          outro: 'Name it, for example, Refresh SideStore.',
          button: 'Start the shortcut',
          onButton: () => _openShortcuts('shortcuts://create-shortcut'),
        ),
        _SetupCard(
          accent: accent,
          number: 2,
          title: 'Let it run by itself',
          intro: 'In Shortcuts, open the Automation tab:',
          steps: const [
            ('+', 'then Charger → Is Connected'),
            ('Run Immediately', 'so it never asks'),
            ('Your shortcut', 'pick it, then Done'),
          ],
          outro: 'On iOS 15 and 16: Create Personal Automation, add Run Shortcut, and '
              'turn off Ask Before Running. A second one at a set Time of Day is a '
              'good backup.',
          button: 'Open Shortcuts',
          onButton: () => _openShortcuts('shortcuts://'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SetupTitle(accent: accent, number: 3, title: 'Check it'),
              const SizedBox(height: 8),
              Text('Run the shortcut once by hand. When it finishes, this says so.', style: dim),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(working ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: working ? accent : Colors.white.withValues(alpha: 0.4), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      working && at != null
                          ? 'Working: your shortcut refreshed Auvy ${_ago(now.difference(at))}.'
                          : 'Not seen yet.',
                      style: TextStyle(
                          color: working ? Colors.white : Colors.white.withValues(alpha: 0.6),
                          fontSize: 13.5,
                          fontWeight: working ? FontWeight.w600 : FontWeight.w400),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Why isn't there one to download?",
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'SideStore installs Auvy and itself under your own Apple ID, so a '
                "shortcut made on another phone points at that phone's apps and can't "
                "find yours. iOS doesn't let automations be shared either.",
                style: dim,
              ),
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () async {
                  HapticService.selection();
                  if (!await launchUrl(Uri.parse(kAutoRefreshGuideUrl),
                      mode: LaunchMode.externalApplication)) {
                    AnimatedToast.message("Couldn't open the guide");
                  }
                },
                child: Text('The full guide, with troubleshooting',
                    style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Future<void> _openShortcuts(String url) async {
    HapticService.selection();
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    // The plain scheme opens the app even where a deeper one isn't understood.
    if (url != 'shortcuts://' &&
        await launchUrl(Uri.parse('shortcuts://'), mode: LaunchMode.externalApplication)) {
      return;
    }
    AnimatedToast.message("Couldn't open Shortcuts");
  }
}

class _SetupTitle extends StatelessWidget {
  final Color accent;
  final int number;
  final String title;
  const _SetupTitle({required this.accent, required this.number, required this.title});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text('$number',
                style: TextStyle(color: accent, fontSize: 13.5, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
          ),
        ],
      );
}

/// One numbered part of the setup: what to do, the actions as a list (name in
/// bold, then what to set), and a button into the Shortcuts app.
class _SetupCard extends StatelessWidget {
  final Color accent;
  final int number;
  final String title;
  final String intro;
  final List<(String, String)> steps;
  final String outro;
  final String button;
  final VoidCallback onButton;

  const _SetupCard({
    required this.accent,
    required this.number,
    required this.title,
    required this.intro,
    required this.steps,
    required this.outro,
    required this.button,
    required this.onButton,
  });

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: Colors.white.withValues(alpha: 0.62), fontSize: 12.5, height: 1.4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SetupTitle(accent: accent, number: number, title: title),
          const SizedBox(height: 8),
          Text(intro, style: dim),
          const SizedBox(height: 10),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text('${i + 1}.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13.5)),
                  ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: steps[i].$1,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        TextSpan(text: '  ${steps[i].$2}', style: dim),
                      ]),
                      style: const TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 2),
          Text(outro, style: dim),
          const SizedBox(height: 12),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onButton,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 46,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                ),
                child: Text(button,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
