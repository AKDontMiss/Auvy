import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/theme_provider.dart';

// Terms and data: what the terms of using Auvy are, and what actually leaves the
// device. About carries the copyright notice and licences, and Privacy carries
// the controls; neither answers these two questions.
//
// Every statement here must match what the code does and name the destination
// whenever data is sent somewhere: no "we may collect", no generic security
// promises. Where a behaviour is optional, say which switch turns it on; where
// data stays local, say so. If any of this stops being true, update this page as
// part of the change.

class TermsPage extends ConsumerWidget {
  const TermsPage({super.key});

  /// The date the wording below was last reviewed against the code.
  ///
  /// Shown rather than a version number: a reader wants to know how old the
  /// statement is, and the app version tells them nothing about that.
  static const String lastReviewed = '8 September 2026';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tint = ref.watch(themeProvider);
    return SettingsSubPage(
      title: 'Terms & data',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
        child: Text(
          'Plain language, and only things the app actually does. '
          'Last reviewed against the code on $lastReviewed.',
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
      ),
      children: [
        _Section(
          tint: tint,
          icon: Icons.gavel_rounded,
          heading: 'Terms of use',
          paragraphs: [
            'Auvy is free software, published under the GNU General Public '
                'License v3.0. You may use, study, modify and redistribute it '
                'under those terms, including for a fee. Two additional terms '
                'apply, both permitted by GPL-3.0 §7 and neither restricting '
                'what you may do: keep the author attribution, and do not '
                'present a modified version as Auvy. Their full text is in '
                'NOTICE.md in the source repository; the licence page in About '
                'states them in short and points there.',
            'The cover artwork Auvy offers for playlists is NOT covered by that '
                'licence — images carry their own terms. It is community art '
                'used by permission for non-commercial purposes, it is served '
                'at runtime rather than bundled, and it is not part of the '
                'source distribution. A fork supplies its own.',
            'Auvy is not sold. There is no price, no subscription, no in-app '
                'purchase and no advertising — so there is nothing to refund, '
                'and no payment details are ever asked for or handled.',
            'The app is provided as is, with no warranty of any kind and no '
                'liability for how it behaves or what it does to your data. '
                'That is GPL-3.0 §15 and §16, and it is meant literally: keep '
                'your own backups of anything you cannot lose.',
            'Auvy is not affiliated with, endorsed by or sponsored by any '
                'music, streaming, recognition or messaging service it talks '
                'to. Their names are used only to say what a feature connects '
                'to.',
            'Auvy plays and displays content from third-party services. It '
                'grants you no rights over that content, and using it does not '
                'change whatever terms those services set. Complying with them '
                'is yours to do.',
            'Access is granted per account and can be withdrawn. A sign-in is '
                'checked against an approval list, and a specific device can be '
                'signed out remotely — which is the mechanism that protects a '
                'lost phone, and also the mechanism that ends access if it is '
                'abused.',
            'Do not use Auvy to redistribute content, to work around the '
                'access check, or to pass a modified build off as this one. The '
                'source is open precisely so that a fork is the honest way to '
                'change something.',
            'These terms may change as the app does. The review date above is '
                'how you tell whether what you read still matches the build '
                'you are running.',
          ],
        ),
        _Section(
          tint: tint,
          icon: Icons.cloud_upload_outlined,
          heading: 'What leaves this device',
          paragraphs: [
            'There is no analytics, no crash reporter and no advertising or '
                'tracking library in this app. Nothing reports back on how you '
                'use it.',
            'SIGNING IN sends the identity you sign in with, and an identifier '
                'for this device, to Auvy\'s own service. It stores whether the '
                'account is approved and which devices are signed in, which is '
                'what makes remote sign-out possible. A device that has been '
                'signed out remotely stops the next time it contacts that '
                'service, not the instant the button is pressed.',
            'STARTING THE APP asks Google Play Integrity to attest that this '
                'is a genuine, unmodified install, and hands that attestation '
                'to Firebase. It is what lets the backup store refuse traffic '
                'that is not the real app. It says nothing about you or about '
                'what you listen to.',
            'PLAYING A TRACK sends the request needed to find and stream it to '
                'YouTube and Google, the same as opening the site would. Audio '
                'is streamed from there, and cached on this device.',
            'LYRICS AND METADATA go to Auvy\'s own service first, which holds '
                'the API keys and answers from its cache where it can. The '
                'lookup carries the track title, artist and length — not who '
                'you are. When that service cannot answer, the request falls '
                'back to the source ITSELF, and then that source sees your '
                'connection directly. The sources are lrclib, NetEase, KuGou '
                'and lyrics.ovh for lyrics; iTunes and Deezer for podcast and '
                'artist details, and iTunes for What\'s New (the names of the '
                'artists and podcasts you follow, to find their new releases); '
                'Last.fm for artist information only, never '
                'for scrobbling; radio-browser and Swedish Radio for stations '
                'and schedules; and the Internet Archive for public-domain '
                'audiobooks.',
            'TRANSLATING LYRICS sends the lines being translated to Google '
                'Translate. It happens only when you pick a language.',
            'IDENTIFYING A SONG captures up to 12 seconds of audio and builds '
                'a fingerprint from it ON THIS DEVICE. Only that fingerprint '
                'is sent, to Shazam\'s public discovery endpoint, along with '
                'its length and your device\'s timezone. The recording itself '
                'never leaves the phone, and no location is sent — Auvy holds '
                'no location permission. It runs when you start it, either in '
                'the app or from the quick-settings tile, which can identify '
                'with the app closed.',
            'IMPORTING A SPOTIFY LINK reads that public playlist using the '
                'anonymous token Spotify\'s own web player mints. You are not '
                'signed in to Spotify and no Spotify credentials are asked '
                'for or stored.',
            'CLOUD BACKUP is off until you switch it on. When it is on, your '
                'library, playlists, listening history, play counts and '
                'settings are encrypted on this device with AES-256-GCM and '
                'then uploaded to Google Firestore, so a new device can '
                'restore them. Downloaded and cached AUDIO is never uploaded — '
                'only the record of what you have. Deleting your account '
                'deletes the backup.',
            'To be exact about what that encryption protects: the key is '
                'issued to your account by Auvy\'s own service, derived from '
                'your account id and a secret kept there. Firestore therefore '
                'holds ciphertext and never the key, which is what stops the '
                'storage itself — or anyone who reaches it — from reading your '
                'library. It is NOT end-to-end encryption: the service that '
                'issues the key can derive it again. If it ever fails to issue '
                'one, the app falls back to uploading in the clear rather than '
                'silently skipping the backup.',
            'SCROBBLING is off until you enter a ListenBrainz token, and '
                'then sends what you listen to to ListenBrainz. Nothing is '
                'scrobbled to Last.fm — Auvy has no Last.fm scrobbling at all.',
            'CHECKING FOR UPDATES asks Auvy\'s own service, which asks GitHub '
                'and caches the answer — GitHub rate-limits anonymous callers '
                'per IP, and users behind one carrier share that. When you '
                'install an update the APK bytes come straight from GitHub '
                'over a redirect; the service only passes the redirect along.',
            'SHARING A TRACK hands the text and image you are sharing to '
                'whichever app you pick. The link in it is a song.link address '
                'built on this device — Auvy does not contact song.link to '
                'make it.',
          ],
        ),
        _Section(
          tint: tint,
          icon: Icons.phone_android_rounded,
          heading: 'What stays here',
          paragraphs: [
            'Your listening history, play counts, the taste model behind '
                'recommendations, downloads, cached audio and artwork, and the '
                'diagnostic log all live on this device. Cloud backup, when it '
                'is on, uploads the history, the counts and the taste model as '
                'part of the encrypted backup above; the downloaded and cached '
                'audio and artwork stay here either way.',
            'The diagnostic log is never sent anywhere on its own. It is '
                'written locally and only leaves the device if you export it '
                'and send it yourself. Identity hashes are shortened and '
                'tokens are stripped as each line is written, not at export, '
                'so a redacted line is the only version that ever exists on '
                'disk.',
            'Where each of these is controlled: Settings → Privacy pauses and '
                'clears the listening and search history, and holds the '
                'private-session switch that suspends both at once. Settings → '
                'Storage & data clears cached audio and artwork, keeping '
                'downloads. Settings → Reset taste profile forgets the learned '
                'preferences while keeping the counts they were built from. '
                'Each of those screens states exactly what it does and does '
                'not remove.',
          ],
        ),
      ],
    );
  }
}

/// One prose card: an icon, a heading, and paragraphs.
///
/// A short paragraph per idea rather than one block of text, because this page
/// is scanned before it is read — someone opens it to answer one question, and
/// a wall of prose hides the answer.
class _Section extends StatelessWidget {
  final Color tint;
  final IconData icon;
  final String heading;
  final List<String> paragraphs;

  const _Section({
    required this.tint,
    required this.icon,
    required this.heading,
    required this.paragraphs,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIconChip(icon: icon, tint: tint),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  heading,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final p in paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                p,
                style: const TextStyle(
                  // 0.78 rather than the 0.55 used for captions elsewhere.
                  // This is body text meant to be READ, and low-opacity white
                  // on a near-black card is the app's weakest contrast; a
                  // caption can afford it, a paragraph of terms cannot.
                  color: Color(0xC7FFFFFF),
                  fontSize: 13.5,
                  height: 1.55,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
