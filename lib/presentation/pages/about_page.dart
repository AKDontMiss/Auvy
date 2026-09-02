import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/app_icon_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';

// ABOUT — premium, lightweight makeover in the app-wide design language:
// transparent scaffold over the shared DynamicBackground, collapsing title,
// rounded cards with tinted icon chips (matches Settings / Library).

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  Future<void> _launchUrl(String url) async {
    final Uri uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw Exception('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            _buildHeaderBar(context),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    const SizedBox(height: 18),

                    // App icon & wordmark
                    Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                            color: themeColor.withOpacity(0.30),
                            blurRadius: 30,
                            spreadRadius: 2,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: AuvyImage(
                        // Accent-matched, same as the launcher icon and splash.
                        path: AppIconService.assetForAccent(themeColor),
                        borderRadius: 26,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Auvy",
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.8,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Dynamic version badge
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (context, snapshot) {
                        final versionText = snapshot.hasData
                            ? "Version ${snapshot.data!.version}"
                            : "…";
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                          decoration: BoxDecoration(
                            color: themeColor.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: themeColor.withOpacity(0.35)),
                          ),
                          child: Text(
                            versionText,
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 26),

                    // Mission
                    _card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          "Experience music your way. Designed for seamless streaming "
                          "and smart offline access, Auvy lets you cache your library "
                          "locally and shape your listening experience without cost "
                          "or compromise.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: 14,
                            height: 1.65,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Connect
                    _sectionLabel("Connect"),
                    _card(
                      child: Column(
                        children: [
                          _SocialRow(
                            iconPath: 'assets/icons/github_logo.webp',
                            fallbackIcon: Icons.code_rounded,
                            tint: const Color(0xFFB0BEC5),
                            title: "GitHub",
                            subtitle: "Source, releases and issue tracker",
                            // Straight to the repository that holds THIS build's source, not the
                            // profile. GPL-3.0 asks that whoever has the binary can get
                            // the corresponding source; one tap to the right repo is the
                            // clearest way to honour that.
                            onTap: () => _launchUrl(
                                "https://github.com/AKDontMiss/Auvy"),
                          ),
                          _divider(),
                          // No linkedin row, no discord user ID.
                          //
                          // Both linked the app to a real-world identity: a
                          // LinkedIn profile carries a name, employer and career
                          // history, and a `discord.com/users/<id>` link is a
                          // permanent personal handle. Neither is needed to run,
                          // support or update the app — the GitHub row above
                          // already covers releases and issues, which is the only
                          // contact route the app actually depends on.
                          //
                          // Do not re-add a personal social link here. If a
                          // contact channel is wanted, use one that belongs to the
                          // PROJECT (a repo issue tracker, a project-owned server
                          // invite), not to a person.
                          // Third-party attribution. The app bundles 36 open-source
                          // packages under MIT, BSD and Apache-2.0, and every one of
                          // those licences requires its notice to be reproduced in
                          // distributions. Flutter aggregates them from the package
                          // metadata, so this is both the correct and the complete
                          // way to satisfy that — a hand-written list would go stale
                          // the next time a dependency changed.
                          _SocialRow(
                            iconPath: null,
                            fallbackIcon: Icons.description_outlined,
                            tint: const Color(0xFF9FA8DA),
                            title: "Open-source licences",
                            subtitle: "The libraries Auvy is built on",
                            // THIS IS THE "APPROPRIATE LEGAL NOTICES" §7(b) MEANS
                            //
                            // NOTICE.md carries an additional term under GPL-3.0
                            // §7(b) requiring the attribution below to be preserved
                            // in the notices a conveying work DISPLAYS. This screen,
                            // and the licence page it opens, are those notices — so
                            // the line has to be here and not only in a file in the
                            // repository, or the term would refer to nothing.
                            //
                            // The copyright line comes FIRST for the same reason: §4
                            // asks that notices be kept intact, and a notice buried
                            // under a paragraph about libraries is easy to lose in a
                            // reword.
                            onTap: () => showLicensePage(
                              context: context,
                              applicationName: 'Auvy',
                              applicationLegalese:
                                  'Auvy — © 2026 Akram Ahmed. GPL-3.0.\n\n'
                                  'Free software under the GNU General Public '
                                  'License v3.0; the full text is included below. '
                                  'Contains code derived from Metrolist and SongRec, '
                                  'both GPL-3.0 — see NOTICE.md in the source '
                                  'repository, which also carries additional terms '
                                  'under GPL-3.0 §7(b) and §7(c): keep this '
                                  'attribution, and do not present a modified '
                                  'version as Auvy.\n\n'
                                  'The licences of the bundled open-source '
                                  'libraries follow.',
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),

                    // Footer
                    Icon(Icons.graphic_eq_rounded,
                        color: themeColor.withOpacity(0.55), size: 20),
                    const SizedBox(height: 10),
                    // Copyright
                    //
                    // "All rights reserved" was dropped: it is a vestige of the
                    // Buenos Aires Convention and has had no legal effect anywhere
                    // since 2000. Copyright attaches automatically; the year and
                    // the holder are the only parts that do any work.
                    Text(
                      // Names the AUTHOR, not just the app. A notice that says
                      // only "Auvy" attributes the work to itself, which gives
                      // §4 and the §7(b) term in NOTICE.md nothing to preserve.
                      "© 2026 Akram Ahmed · Auvy · GPL-3.0",
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Disclaimer
                    //
                    // THE OLD LINE WAS REASSURANCE, NOT A DISCLAIMER. It read
                    // "Auvy™ is provided for hobbyist and educational purposes",
                    // and "educational purposes" is not a defence to anything — not
                    // copyright, not a terms-of-service breach. It sounded like
                    // legal cover while providing none, which is worse than saying
                    // nothing, because it invites relying on it.
                    //
                    // What replaces it says only things that are true and useful:
                    // no warranty (the part that actually limits liability), no
                    // affiliation (the part that prevents implied endorsement), and
                    // not for sale (which is what makes the non-commercial terms
                    // Auvy's bundled artwork relies on hold).
                    Text(
                      "Provided as is, without warranty. Not affiliated with, "
                      "endorsed by, or sponsored by any music, streaming or "
                      "media-recognition service. Not for sale or redistribution.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 110),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Collapsing large-title bar (same pattern as Settings).
  Widget _buildHeaderBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      expandedHeight: 108,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      flexibleSpace: LayoutBuilder(builder: (context, constraints) {
        final double topPad = MediaQuery.of(context).padding.top;
        final double collapsedH = kToolbarHeight + topPad;
        final double t =
            ((constraints.maxHeight - collapsedH) / (108 - collapsedH)).clamp(0.0, 1.0);
        return Stack(fit: StackFit.expand, children: [
          Opacity(
            opacity: 1.0 - t,
            child: Container(color: Colors.black.withOpacity(0.55)),
          ),
          Padding(
            padding: EdgeInsets.only(
                left: 20 + (36 * (1 - t)), bottom: 14 + (2 * t), top: topPad),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                "About",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20 + (8 * t),
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _sectionLabel(String label) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 10),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withOpacity(0.66),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.045),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
      ),
      child: child,
    );
  }

  Widget _divider() =>
      Divider(color: Colors.white.withOpacity(0.06), height: 1, indent: 62);
}

class _SocialRow extends StatelessWidget {
  /// Null for rows with no brand asset — the [fallbackIcon] is used instead.
  final String? iconPath;
  final IconData fallbackIcon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SocialRow({
    this.iconPath,
    required this.fallbackIcon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticService.selection();
        onTap();
      },
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tint.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: iconPath == null
                  ? Icon(fallbackIcon, color: tint, size: 18)
                  : Image.asset(
                iconPath!,
                color: tint,
                errorBuilder: (_, __, ___) => Icon(fallbackIcon, color: tint, size: 18),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
            Icon(Icons.open_in_new_rounded,
                color: Colors.white.withOpacity(0.25), size: 17),
          ],
        ),
      ),
    );
  }
}
