import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:auvy/core/app_colors.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/app_commands.dart';

/// The shared "Open in Auvy" shortcut (an iCloud link to the
/// Shortcuts app). Empty, so the sheet shows the steps to build it instead of
/// the one-tap install.
///
/// Stays empty while the shortcut uses Auvy's "Play a Music Link" action. On
/// iPhone, SideStore installs Auvy under an id ending in the installer's own
/// team id (`com.auvy.app.<team>`), and a shared shortcut names the maker's
/// copy: on anyone else's phone that step doesn't resolve, and the shared file
/// publishes the maker's team id. Only a shortcut with no app action of Auvy's
/// (one that opens an `auvy://open?url=` link, say) works everywhere and names
/// nobody. The public export refuses any iCloud shortcut link, and
/// sidestore_auto_refresh_test keeps them out of the source.
const String kOpenInAuvyShortcutUrl = '';

/// How to send a Spotify, Apple Music or YouTube link to Auvy from another app.
///
/// iPhone: a free Apple ID can't give Auvy a share extension (it would be a
/// fourth app next to SideStore, Auvy and its widget), so the ways in are the
/// copied-link offer, an "Open in Auvy" Shortcut in the share sheet, and Search.
/// Android: "Share → Auvy" works everywhere, and music links can open in Auvy
/// once allowed under "Open by default".
void showLinksFromOtherAppsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _LinksSheet(),
  );
}

class _LinksSheet extends ConsumerWidget {
  const _LinksSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final ios = Platform.isIOS;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.modalPanel,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('Open links from other apps',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Songs, albums and playlists from Spotify, Apple Music, YouTube and YouTube Music.',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5, height: 1.35)),
                const SizedBox(height: 18),
                if (ios) ...[
                  _step(accent, Icons.content_copy_rounded, 'Copy the link, then open Auvy',
                      'In the other app: Share → Copy Link. Open Auvy and it offers to play what you copied.'),
                  _step(
                      accent,
                      Icons.ios_share_rounded,
                      'Add "Open in Auvy" to the Share menu',
                      kOpenInAuvyShortcutUrl.isNotEmpty
                          ? 'One tap adds a shortcut that puts Auvy in every Share menu.'
                          : 'In Shortcuts: + → name it "Open in Auvy" → add the action "Play a Music Link" (Auvy) '
                              '→ set Link to Shortcut Input → ⓘ → turn on "Show in Share Sheet". '
                              'Then Share → Open in Auvy plays the link straight away.'),
                  const SizedBox(height: 4),
                  _button(
                    accent,
                    kOpenInAuvyShortcutUrl.isNotEmpty ? 'Add the shortcut' : 'Open Shortcuts',
                    () => launchUrl(
                        Uri.parse(kOpenInAuvyShortcutUrl.isNotEmpty ? kOpenInAuvyShortcutUrl : 'shortcuts://'),
                        mode: LaunchMode.externalApplication),
                  ),
                  const SizedBox(height: 14),
                  _step(accent, Icons.search_rounded, 'Or paste it into Search',
                      'Pasting a link into the search box opens it instead of searching for it.'),
                ] else ...[
                  _step(accent, Icons.share_rounded, 'Share → Auvy',
                      'From Spotify, YouTube or any app: Share, then pick Auvy.'),
                  _step(
                      accent,
                      Icons.open_in_new_rounded,
                      'Open music links in Auvy directly',
                      'Allow Auvy to open Spotify, Apple Music and YouTube Music links: '
                          'Open by default → Add links → tick them.'),
                  const SizedBox(height: 4),
                  _button(accent, 'Open "Open by default"', () async {
                    if (!await AppCommands.openLinkSettings()) {
                      AnimatedToast.message('Settings → Apps → Auvy → Open by default');
                    }
                  }),
                  const SizedBox(height: 14),
                  _step(accent, Icons.content_copy_rounded, 'Or copy it and open Auvy',
                      'Auvy offers to play a link you copied (Android 12 and newer), or paste it into Search.'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(Color accent, IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(Color accent, String label, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 46,
          width: double.infinity,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.55)),
          ),
          child: Center(
            child: Text(label, style: TextStyle(color: accent, fontSize: 14.5, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}
