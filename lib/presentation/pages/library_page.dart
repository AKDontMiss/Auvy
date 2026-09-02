import 'package:auvy/providers/artist_image_provider.dart';
import 'package:auvy/presentation/widgets/item_transfer_overlay.dart';
import 'package:auvy/presentation/widgets/info_hint.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart'; 
import 'package:auvy/providers/theme_provider.dart'; 
import 'package:auvy/presentation/pages/artist_page.dart'; 
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/presentation/pages/playlist_page.dart'; 
import 'package:auvy/data/artist_model.dart'; 
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/presentation/pages/settings_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/pages/stats_page.dart';
import 'package:auvy/presentation/pages/history_page.dart';
import 'package:auvy/presentation/pages/theme_page.dart';
import 'package:auvy/presentation/pages/privacy_page.dart';
import 'package:auvy/presentation/pages/about_page.dart';
import 'package:auvy/presentation/pages/recognition_history_page.dart';
import 'package:auvy/presentation/pages/hidden_content_page.dart';
import 'package:auvy/presentation/widgets/sleep_timer_sheet.dart';
import 'package:auvy/presentation/pages/alarm_settings_page.dart';
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/presentation/widgets/splash_screen.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/presentation/widgets/undo_toast.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/presentation/pages/podcast_page.dart';
import 'package:auvy/providers/podcast_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';
import 'package:auvy/providers/density_provider.dart';


String _getColorSuffix(Color themeColor) {
  if (themeColor.value == Colors.purpleAccent.value) return "purple";
  if (themeColor.value == Colors.greenAccent.value) return "green";
  if (themeColor.value == Colors.orangeAccent.value) return "orange";
  if (themeColor.value == Colors.redAccent.value) return "red";
  if (themeColor.value == Colors.pinkAccent.value) return "pink";
  return "cyan";
}

String _getThemedIcon(String originalPath, String title, String suffix) {
  if (!originalPath.startsWith('assets/')) return originalPath;

  if (title == "Liked Songs") return "assets/images/liked_songs_$suffix.webp";
  if (title == "My Top 50") return "assets/images/top_50_$suffix.webp";

  // Followed artists / followed podcasts
  //
  //"Your Artists" IS STILL MATCHED, AND MUST STAY MATCHED. The folder title
  // is PERSISTED inside the library blob, so every existing install has an item
  // called "Your Artists" on disk until the rename migration has run once. Drop
  // this line and those installs ask for an asset that no longer exists and get a
  // blank tile.
  //
  // The ARTWORK swapped owners deliberately: the old your_artists_* art (the
  // shattered figure) now belongs to Followed Podcasts, and Followed Artists uses
  // new art. The files were renamed rather than copied, so there is no
  // your_artists_* asset left to point at.
  // Placeholder art, on purpose, until the artist variants exist.
  //
  // The shattered-figure mark that used to be your_artists_* now belongs to
  // Followed Podcasts — RENAMED, not copied, so there is no artist artwork left
  // in assets/images at all. Naming followed_artists_$suffix.webp here would ask
  // Flutter for a file that does not exist and render a blank tile, which looks
  // like a bug rather than a pending asset.
  //
  // Falls back to the generic playlist mark meanwhile. When the six
  // followed_artists_<accent>.webp variants land, this becomes a one-line change.
  if (title == "Followed Artists" || title == "Your Artists") {
    return "assets/images/followed_artists_$suffix.webp";
  }
  if (title == "Followed Podcasts") {
    return "assets/images/followed_podcasts_$suffix.webp";
  }
  if (title == "Liked Albums") return "assets/images/liked_albums_$suffix.webp";
  if (title == "Liked Playlists") return "assets/images/playlist_$suffix.webp"; 
  if (title == "Cached") return "assets/images/cached_$suffix.webp";
  if (title == "Downloads") return "assets/images/download_$suffix.webp";
 
  return "assets/images/playlist_$suffix.webp";
}

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  // Anchor for the account menu so it can expand OUT of the avatar icon
  // (top-left) instead of sliding up from the bottom.
  final GlobalKey _accountIconKey = GlobalKey();

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  

  // Spotify/Apple-Music style profile menu, opened by tapping the avatar
  // (top-left). Just two items now: Settings (→ full-screen, ROOT navigator) and
  // Log out. The old "Account & connections" panel was removed — everything in
  // it duplicated Settings → Account, and its connect/disconnect actions moved
  // there. This is where Settings lives instead of a standalone header gear, so
  // it never gets stuck as a Library-tab sub-page.
  void _showAccountMenu(BuildContext context) {
    HapticService.selection();

    // SIDE PANEL, not a dropdown
    //
    // It used to be a 244px card that scaled out of the avatar. Two problems:
    // that width could hold about three rows before feeling cramped, so the menu
    // could never grow past "Settings / Log out"; and a small floating card that
    // expands from a corner reads as a tooltip, which is the wrong weight for the
    // place you go to change how the app works.
    //
    // A panel anchored to the LEFT edge — the side the avatar is on — has room for
    // grouped destinations, matches where Spotify and YouTube Music put the same
    // menu, and its slide direction says "this came from the edge you touched"
    // rather than "this popped out of a button".
    //
    // 50% width, capped at 232 — the third and final narrowing (84%/360 →
    // 68%/300 → 50%/232), each one reported as still covering too much. At 84%
    // the panel stopped reading as a panel over your library and read as a page
    // you had navigated to, which also made tap-outside-to-dismiss less obvious.
    //
    // What made this width possible rather than just cramped: the row labels were
    // the binding constraint, not the panel. "Listening history" needed ~136px of
    // text, so the panel had to be wide enough to hold it. Under the YOU group
    // header "History" says the same thing in half the space, and the trailing
    // chevron was decoration — nothing in a drawer this narrow needs an
    // affordance hint. With those gone the longest label is "Appearance" (~80px),
    // so at 232px the rows have MORE breathing room than they did at 300px.
    //
    // Half the library stays visible, which is the point: it should look like
    // something resting over your library, not replacing it.
    showGeneralDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'Account',
      barrierColor: Colors.black.withOpacity(0.55),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, a, b) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, sec, child) {
        final curved = CurvedAnimation(
            parent: anim,
            // Same curve pair as HydrvTransition: decelerate in, accelerate out.
            curve: Curves.fastOutSlowIn,
            reverseCurve: const Cubic(0.4, 0.0, 1.0, 1.0));
        final width =
            (MediaQuery.of(ctx).size.width * 0.50).clamp(196.0, 232.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: SizedBox(
              width: width,
              height: double.infinity,
              child: _accountPanel(ctx),
            ),
          ),
        );
      },
    );
  }

  /// The side panel's content: profile header, grouped destinations, sign out.
  ///
  /// Deliberately label-only. Subtitles were tried and removed — they wrapped to
  /// two lines and turned a list you scan into a wall of text. What replaced them
  /// is the GROUP headers (You / App): they carry the context a subtitle would
  /// have, for the whole group, in one line instead of one per row. That is also
  /// what lets the labels themselves be short enough for a narrow panel.
  Widget _accountPanel(BuildContext ctx) {
    // The Library page's own context — stable after the panel (`ctx`) is closed,
    // so it's safe to navigate with once the panel has been popped.
    final pageContext = context;
    return Material(
      color: Colors.transparent,
      child: Consumer(
        builder: (context, ref, _) {
          final account = ref.watch(accountProvider);
          final themeColor = ref.watch(themeProvider);

          // Rows use the app's ICON-CHIP language (a tinted rounded square behind
          // the glyph) — the same shape settings_kit uses everywhere else, so the
          // panel looks like part of Auvy rather than a stock drawer. Subtitles
          // dropped: at 300px they wrapped to two lines and turned a scannable
          // list into a wall, and the labels are self-evident.
          Widget item(IconData icon, String label, VoidCallback onTap,
              {Color? color}) {
            final tint = color ?? themeColor;
            return InkWell(
              onTap: () {
                HapticService.selection();
                onTap();
              },
              splashColor: tint.withOpacity(0.06),
              highlightColor: tint.withOpacity(0.04),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(
                  children: [
                    Container(
                      width: 31,
                      height: 31,
                      decoration: BoxDecoration(
                        color: tint.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(icon, size: 17, color: tint),
                    ),
                    const SizedBox(width: 11),
                    // No trailing chevron. It was pure decoration — every row in
                    // a drawer this narrow is obviously tappable, and it cost
                    // 17px of the label's width, which is what forced the panel
                    // wider than it needed to be.
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: color ?? Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14.5)),
                    ),
                  ],
                ),
              ),
            );
          }

          Widget groupLabel(String text) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 17, 16, 6),
                child: Text(text.toUpperCase(),
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 9.5,
                        letterSpacing: 1.9,
                        fontWeight: FontWeight.w800)),
              );

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF17171B),
              // Rounded on the RIGHT only — the left edge is the screen edge, and
              // rounding a corner that has nothing beside it just shows the
              // barrier through the gap.
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
              border: Border(
                  right: BorderSide(color: Colors.white.withOpacity(0.07))),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.6),
                    blurRadius: 34,
                    offset: const Offset(8, 0)),
              ],
            ),
            // SafeArea + scroll: the panel is full height, so it has to clear the
            // status bar and the gesture inset, and still work at a large system
            // font size where the rows no longer fit.
            child: SafeArea(
              child: ListView(
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
              children: [
                // Profile header. Tighter right inset than left: the name/email
                // ellipsize anyway at this width, so the spare pixels are worth
                // more to the text than to the margin.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 21,
                        backgroundColor: const Color(0xFF2A2A2E),
                        backgroundImage: account.avatarUrl != null
                            ? NetworkImage(account.avatarUrl!)
                            : null,
                        child: account.avatarUrl == null
                            ? const Icon(Icons.person_rounded,
                                color: Colors.white70, size: 20)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                account.isLoggedIn
                                    ? (account.displayName ?? 'User')
                                    : 'Guest',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            if (account.email != null)
                              Text(account.email!,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.72),
                                      fontSize: 11.5),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.07), height: 1),

                // Both moved here from the HOME header, where they were permanent
                // chrome on the feed. They are places you look BACK at your own
                // listening from — the same category as the account itself.
                groupLabel('You'),
                item(Icons.history_rounded, 'History', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      pageContext, MainLayout.smoothRoute(const HistoryPage()));
                }),
                item(Icons.bar_chart_rounded, 'Stats', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      pageContext, MainLayout.smoothRoute(const StatsPage()));
                }),

                groupLabel('App'),
                item(Icons.settings_outlined, 'Settings', () {
                  Navigator.pop(ctx);
                  AppNavigation.pushRoot(pageContext, const SettingsPage(),
                      opaque: true);
                }),
                item(Icons.palette_outlined, 'Appearance', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      pageContext, MainLayout.smoothRoute(const ThemePage()));
                }),
                item(Icons.shield_outlined, 'Privacy', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      pageContext, MainLayout.smoothRoute(const PrivacyPage()));
                }),
                item(Icons.info_outline_rounded, 'About', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      pageContext, MainLayout.smoothRoute(const AboutPage()));
                }),

                // Tools
                //
                // Added into the panel's existing empty VERTICAL space rather
                // than by widening it — the width was cut twice for covering too
                // much, and rows cost height, which was going spare.
                //
                // The test for belonging here is "act-now utility that is slow to
                // reach otherwise". Sleep timer passes hardest: it is something
                // you want in bed, and it was buried in Settings behind a scroll.
                // Equalizer and Recognition history are the same shape of thing.
                //
                // Deliberately NOT added: Downloads and Liked (already library
                // shelves one tap away), Listen Together (belongs in the player,
                // where the session actually lives), Wrapped (seasonal — it earns
                // a home-feed card, not permanent chrome).
                groupLabel('Tools'),
                // Opens the timer sheet DIRECTLY, not Settings. Sending someone
                // to a settings page to find it would defeat the reason for
                // putting it here.
                // Shows ARMED STATE, not just a label. The settings row this
                // replaced displayed "Music stops at 23:15", and dropping that on
                // the move would have made the panel a worse home for it: a timer
                // you can't confirm is running is a timer you check by waiting.
                // The stop time replaces the label and takes the accent, so the
                // row reads as live at a glance in a 206px panel.
                Builder(builder: (_) {
                  final t = ref.watch(playerProvider.select((p) => (
                        endsAt: p.sleepTimerEndsAt,
                        endOfTrack: p.sleepAtEndOfTrack,
                      )));
                  final armed = t.endsAt != null || t.endOfTrack;
                  final label = t.endOfTrack
                      ? 'Stops after track'
                      : (t.endsAt != null
                          ? 'Stops '
                              '${t.endsAt!.hour.toString().padLeft(2, '0')}:'
                              '${t.endsAt!.minute.toString().padLeft(2, '0')}'
                          : 'Sleep timer');
                  return item(Icons.bedtime_outlined, label, () {
                    Navigator.pop(ctx);
                    showSleepTimerSheet(pageContext, ref, themeColor);
                  }, color: armed ? themeColor : null);
                }),
                // Wake-up alarm. MOVED HERE from Settings (and removed there, so
                // there is one place, not two that can disagree). It belongs
                // beside the sleep timer for the same reason that one earned its
                // place: both are things you reach for in bed, and a setting you
                // adjust at bedtime should not be behind a settings scroll.
                //
                // Shows the armed time in the label, like the sleep timer above —
                // an alarm you cannot confirm is set is an alarm you lie awake
                // doubting.
                Builder(builder: (_) {
                  final armed = AlarmService.enabled;
                  return item(
                    Icons.alarm_rounded,
                    armed ? 'Wake ${AlarmService.timeLabel}' : 'Wake up to music',
                    () async {
                      Navigator.pop(ctx);
                      // A PAGE, like Hidden Songs and Recognised Songs beside it.
                      // A bottom sheet here rendered underneath the mini-player
                      // (which floats above the tab navigator), leaving its lower
                      // rows unreachable. See AlarmSettingsPage.
                      await Navigator.push(pageContext,
                          MainLayout.smoothRoute(const AlarmSettingsPage()));
                      // The page edits AlarmService statics, so this row's label
                      // is stale the moment it closes.
                      if (context.mounted) setState(() {});
                    },
                    color: armed ? themeColor : null,
                  );
                }),
                // NO "ENABLE SCREEN AUDIO" ROW HERE ANY MORE.
                //
                // There was one, showing "Screen audio: on" once armed, and that
                // was a claim it could not keep. Arming holds a MediaProjection in
                // memory; Android reclaims the process whenever it likes and the
                // grant dies with it, so the row would say "on" while the tile had
                // nothing. Two surfaces disagreeing about a state that expires on
                // its own is worse than no surface at all.
                //
                // The tile now asks for consent itself when the grant has lapsed
                // (see CaptureConsentActivity), so there is nothing left to set up
                // in advance, which was the point of the complaint that started
                // this: "I only want to tap the tile."
                item(Icons.graphic_eq_rounded, 'Recognised songs', () {
                  Navigator.pop(ctx);
                  Navigator.push(pageContext,
                      MainLayout.smoothRoute(const RecognitionHistoryPage()));
                }),
                // Was the most buried destination in the app — several sections
                // down a long settings scroll, despite being the ONLY way to undo
                // a "don't recommend this".
                item(Icons.block_flipped, 'Hidden songs', () {
                  Navigator.pop(ctx);
                  Navigator.push(pageContext,
                      MainLayout.smoothRoute(const HiddenContentPage()));
                }),
                // Equalizer is deliberately absent: there is no equalizer PAGE to
                // link to (its controls live inline in Settings), and a row that
                // dumps you on a settings screen to go hunting is the kind of
                // half-link that makes a menu feel unreliable. If it gets its own
                // page it belongs here.

                // Appearance, Privacy and About are the SOLE entry points to those
                // pages now — their duplicate rows were removed from SettingsPage.
                // They are destinations you visit occasionally, so one doorway each
                // is right; Settings keeps the switches you actually toggle.
                // ("Account & connections" stays out — everything it had lives in
                // Settings → Account.)

                if (account.isLoggedIn) ...[
                  Divider(
                      color: Colors.white.withOpacity(0.07),
                      height: 22,
                      indent: 16,
                      endIndent: 16),
                  item(Icons.logout_rounded, 'Log out', () async {
                    // No guest mode: sign out fully, then hard-reset the stack to
                    // the splash → sign-in gate (a returning user re-authenticates
                    // there). Capture the root navigator BEFORE the async gap.
                    final rootNav =
                        Navigator.of(pageContext, rootNavigator: true);
                    // CAPTURE THE NOTIFIER BEFORE THE PANEL CLOSES — this is
                    // why logging out did nothing at all.
                    //
                    // `ref` belongs to the side-panel widget, and the pop below
                    // disposes it. Reading `ref` afterwards threw
                    // "Bad state: Cannot use ref after the widget was disposed",
                    // which propagated out of this handler BEFORE logout() was even
                    // called, so no sign-out happened and the navigation to the
                    // sign-in gate never ran either. The symptom was simply "Log out
                    // does nothing", with the real cause only visible as an
                    // unhandled exception in logcat.
                    //
                    // Same reasoning as rootNav above, which was already captured
                    // early for exactly this hazard.
                    final accountNotifier = ref.read(accountProvider.notifier);
                    Navigator.pop(ctx); // close the panel

                    // CONFIRM FIRST. A mis-tap used to sign the user straight out
                    // with no warning and no undo — they then had to
                    // re-authenticate with Google to get back in. One tap of
                    // friction is the right trade for an action that costs a full
                    // sign-in to reverse. (It now also sits below a divider rather
                    // than directly under Settings, which was the mis-tap.)
                    final confirmed =
                        await _confirmLogout(pageContext, account.displayName);
                    if (confirmed != true) return;

                    await accountNotifier.logout();
                    rootNav.pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const SplashScreen()),
                      (route) => false,
                    );
                  }, color: Colors.redAccent),
                ],
                const SizedBox(height: 12),
              ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Confirmation for signing out — the destructive-action dialog in the app's
  /// panel language.
  ///
  /// Names the account being signed out of, and says plainly what is and isn't
  /// lost: downloads and cached audio are wiped with the session, but library,
  /// playlists and history are on the cloud backup and come back on sign-in. That
  /// distinction is the whole reason someone hesitates here.
  Future<bool?> _confirmLogout(BuildContext context, String? displayName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.logout_rounded,
                  color: Colors.redAccent, size: 18),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Log out?',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 17)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              displayName == null || displayName.isEmpty
                  ? "You'll need to sign in with Google again to get back in."
                  : "You'll be signed out of $displayName and will need to sign in "
                      'with Google again to get back in.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.78),
                  fontSize: 13.5,
                  height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.cloud_done_rounded,
                      size: 15, color: Colors.white.withOpacity(0.4)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Your library, playlists and listening history are backed up '
                      'and restore when you sign back in. Downloads are removed.',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11.5,
                          height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay signed in',
                style: TextStyle(
                    color: Colors.white54, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () {
              HapticService.medium();
              Navigator.pop(ctx, true);
            },
            child: const Text('Log out',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  // Multi-link Spotify import dialog.
  // Called by both the "Sync" button on a connected Spotify session
  // and the "Connect Spotify" button when no session exists.
  void _showLinkImportDialog(BuildContext context, WidgetRef ref) {
    final List<TextEditingController> controllers = [TextEditingController()];
    // Track EVERY controller ever created and dispose them ALL exactly once —
    // AFTER the dialog is fully closed (see showDialog(...).then below). Disposing
    // inside the button handlers raced the pending rebuild and crashed with
    // "TextEditingController used after being disposed" (the red-screen bug).
    final List<TextEditingController> allControllers = [...controllers];
    bool isImporting = false;
    String statusText = '';
    int totalImported = 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setState) {
          return AlertDialog(
            // App panel treatment (matches the sheets: 0xFF17171C, radius 26,
            // hairline border) instead of the stock grey AlertDialog.
            backgroundColor: const Color(0xFF17171C),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
              side: BorderSide(color: Colors.white.withOpacity(0.06)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
            contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            title: Row(
              children: [
                // Spotify green stays — it identifies the source, and the accent
                // colour would misrepresent this as an Auvy-native feature.
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1DB954).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.queue_music_rounded,
                      color: Color(0xFF1DB954), size: 19),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Import from Spotify',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 17)),
                ),
                // The two paragraphs of guidance that used to sit inline now live
                // behind this. They matter once and are noise forever after, while
                // permanently making the dialog look dense.
                const InfoHint(
                  title: 'Importing from Spotify',
                  message:
                      'Paste one or more Spotify links — playlists, albums or single '
                      'tracks. Each one is imported into its own Auvy playlist.\n\n'
                      'The playlist must be PUBLIC for Auvy to read it. In Spotify: '
                      'open the playlist → ⋯ → Share → Copy link. If a link fails, '
                      'that is almost always because it is still private.\n\n'
                      'Auvy matches each Spotify track to the closest result on '
                      'YouTube Music, so occasional mismatches on rare or live '
                      'recordings are normal.',
                  tint: Color(0xFF1DB954),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // One line, not three. Detail is behind the ⓘ above.
                    Text(
                      'Paste public Spotify links — one per row.',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 12.5),
                    ),
                    const SizedBox(height: 16),

                    // Dynamic list of URL fields
                    ...controllers.asMap().entries.map((entry) {
                      final i = entry.key;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controllers[i],
                                enabled: !isImporting,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: InputDecoration(
                                  //  FIX: Realistic hint text
                                  hintText: 'https://open.spotify.com/playlist/...',
                                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.08),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide.none),
                                  prefixIcon: const Icon(Icons.link, color: Color(0xFF1DB954), size: 18),
                                  // Show remove button on all rows except first
                                  suffixIcon: i > 0
                                      ? IconButton(
                                          icon: const Icon(Icons.close, color: Colors.white38, size: 16),
                                          onPressed: () {
                                            // Just hide it; allControllers still
                                            // owns it and disposes it on close.
                                            setState(() => controllers.removeAt(i));
                                          },
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),

                    // Add another link button
                    if (!isImporting)
                      TextButton.icon(
                        onPressed: () => setState(() {
                          final c = TextEditingController();
                          controllers.add(c);
                          allControllers.add(c); // tracked for disposal on close
                        }),
                        icon: const Icon(Icons.add, color: Color(0xFF1DB954), size: 18),
                        label: const Text('Add another playlist',
                            style: TextStyle(color: Color(0xFF1DB954), fontSize: 13)),
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      ),

                    // Progress area
                    if (isImporting) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(
                        backgroundColor: Colors.white12,
                        color: Color(0xFF1DB954),
                      ),
                      const SizedBox(height: 10),
                      Text(statusText,
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],

                    if (!isImporting && totalImported > 0) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Color(0xFF1DB954), size: 16),
                          const SizedBox(width: 6),
                          Text('$totalImported tracks imported',
                              style: const TextStyle(color: Color(0xFF1DB954), fontSize: 13)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (!isImporting)
                TextButton(
                  // Just pop — controllers are disposed in showDialog(...).then.
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close', style: TextStyle(color: Colors.white54)),
                ),
              if (!isImporting)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Import',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () async {
                    final urls = controllers
                        .map((c) => c.text.trim())
                        //  FIX: Allow any string that looks like a Spotify link or ID
                        .where((u) => u.isNotEmpty && (u.contains('spotify') || u.contains('open.spotify') || u.length > 20))
                        .toList();

                    if (urls.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please paste a valid Spotify or YouTube link.')),
                      );
                      return;
                    }

                    setState(() {
                      isImporting = true;
                      totalImported = 0;
                      statusText = 'Starting import...';
                    });

                    final searchService = ref.read(searchServiceProvider);
                    int successCount = 0;
                    int failCount = 0;

                    for (int i = 0; i < urls.length; i++) {
                      if (dialogContext.mounted) {
                        setState(() => statusText =
                            'Importing playlist ${i + 1} of ${urls.length}...');
                      }
                      try {
                        final count = await ref
                            .read(libraryProvider.notifier)
                            .importPlaylistFromUrl(urls[i], searchService);
                        // A 0-track result means the import failed (bad/private
                        // link or nothing matched), not a success.
                        if (count > 0) {
                          totalImported += count;
                          successCount++;
                        } else {
                          failCount++;
                        }
                      } catch (_) {
                        failCount++;
                      }
                    }

                    // Dialog may have been dismissed during the async import —
                    // guard setState so it can't fire after dispose (red screen).
                    if (!dialogContext.mounted) return;
                    setState(() {
                      isImporting = false;
                      statusText = '';
                    });

                    final msg = failCount == 0
                        ? '$totalImported tracks imported across $successCount playlist(s) ✓'
                        : '$totalImported tracks imported. $failCount link(s) failed — make sure each is a PUBLIC Spotify playlist/album/track.';
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(msg)));

                    // Close automatically if everything succeeded. Pop FIRST, then
                    // dispose the controllers on the next frame — disposing before
                    // the pending rebuild made the still-mounted TextFields use a
                    // disposed TextEditingController ("used after being disposed"
                    // red screen).
                    if (failCount == 0) {
                      // Just pop — controllers are disposed in showDialog(...).then.
                      Navigator.pop(dialogContext);
                    }
                  },
                ),
            ],
          );
        },
      ),
    ).then((_) {
      // Dispose AFTER the dialog's EXIT ANIMATION finishes. showDialog's future
      // completes the instant pop() is called, but the AlertDialog keeps
      // rebuilding its TextFields for the ~200ms fade-out — disposing right then
      // made them use a disposed controller ("TextEditingController used after
      // being disposed" → red screen). A short delay lets the route fully leave
      // the tree first. allControllers is captured per-open, so this only ever
      // touches this dialog's controllers.
      Future.delayed(const Duration(milliseconds: 600), () {
        for (final c in allControllers) {
          c.dispose();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final libState = ref.watch(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);
    final themeColor = ref.watch(themeProvider);
    final suffix = _getColorSuffix(themeColor); 
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bool isKeyboardOpen = keyboardHeight > 0;
    final double bottomGap = isKeyboardOpen ? 20.0 : 150.0;

    // Compute pinned/unpinned partitions ONCE per build instead of re-filtering
    // in both itemCount and itemBuilder of each SliverReorderableList.
    final pinnedItems = libState.filteredItems.where((i) => i.isPinned).toList();
    final unpinnedItems = libState.filteredItems.where((i) => !i.isPinned).toList();

      return DynamicBackground(child: Scaffold(
    backgroundColor: Colors.transparent, 
    resizeToAvoidBottomInset: false, 
    body: NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _isSearching ? _buildSearchBar(notifier) : _buildDefaultHeader(notifier),
              ),
            ),
          ),
        ),

        if (!_isSearching)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 16, bottom: 16),
              child: Row(
                children: [
                  _FilterChip(label: "Playlists", isSelected: libState.selectedCategory == LibraryCategory.playlist, onTap: () => notifier.setCategory(libState.selectedCategory == LibraryCategory.playlist ? LibraryCategory.all : LibraryCategory.playlist)),
                  const SizedBox(width: 8),
                  _FilterChip(label: "Albums", isSelected: libState.selectedCategory == LibraryCategory.album, onTap: () => notifier.setCategory(libState.selectedCategory == LibraryCategory.album ? LibraryCategory.all : LibraryCategory.album)),
                ],
              ),
            ),
          ),

        if (!_isSearching)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("RECENTS",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4)),
                  GestureDetector(
                    onTap: () {
                      HapticService.selection();
                      notifier.toggleView();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                          libState.isGrid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                          color: Colors.white.withOpacity(0.7),
                          size: 19),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: libState.isGrid
            // Block mode: pin + reorder
            //
            // NEITHER WAS POSSIBLE HERE. List mode gets both from
            // SwipeActionTile (swipe left to pin) and SliverReorderableList, but
            // a grid tile has nowhere to swipe to and GridView cannot reorder —
            // so switching to blocks silently took two features away.
            //
            // Grid gestures, matched to what the shape affords:
            //   • LONG-PRESS AND DRAG a tile onto another to reorder, the
            //     standard grid gesture (Flutter ships no reorderable grid, so
            //     this is LongPressDraggable + DragTarget per tile).
            //   • A PIN BUTTON on each tile, because there is no swipe to give.
            //
            // Reordering stays WITHIN a zone and reuses the list's own
            // reorderLibraryItems(isPinned:) — dragging a pinned tile among the
            // unpinned would have to silently unpin it, and a drag that changes
            // more than position is a drag people undo.
            ? CustomScrollView(
                key: ValueKey('grid_${libState.selectedCategory}_$_isSearching'),
                slivers: [
                  if (pinnedItems.isNotEmpty) ...[
                    _gridSection(
                      context: context,
                      ref: ref,
                      items: pinnedItems,
                      suffix: suffix,
                      isPinnedZone: true,
                      notifier: notifier,
                      onTapItem: (it) => _handleItemTap(context, it, ref),
                    ),
                  ],
                  _gridSection(
                    context: context,
                    ref: ref,
                    items: unpinnedItems,
                    suffix: suffix,
                    isPinnedZone: false,
                    onTapItem: (it) => _handleItemTap(context, it, ref),
                    notifier: notifier,
                  ),
                  SliverToBoxAdapter(child: SizedBox(height: bottomGap)),
                ],
              )
            : CustomScrollView(
                key: ValueKey('list_scroll_${libState.selectedCategory}_$_isSearching'),
                slivers: [
                  // Zone A: Pinned Items
                  SliverReorderableList(
                    onReorder: (oldIdx, newIdx) => notifier.reorderLibraryItems(isPinned: true, oldIndex: oldIdx, newIndex: newIdx),
                    itemCount: pinnedItems.length,
                    itemBuilder: (context, index) {
                      final item = pinnedItems[index];
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey('pinned_${item.title}_$index'),
                        index: index,
                        child: _SwipeableLibraryTile(
                          index: index, 
                          item: item,
                          suffix: suffix,
                          onTap: () => _handleItemTap(context, item, ref),
                          onPin: () => notifier.togglePin(item),
                          onDelete: (pos) => _showDeleteConfirmation(context, item, notifier, pos),
                        ),
                      );
                    },
                  ),
                  // Zone B: Unpinned Items
                  SliverReorderableList(
                    onReorder: (oldIdx, newIdx) => notifier.reorderLibraryItems(isPinned: false, oldIndex: oldIdx, newIndex: newIdx),
                    itemCount: unpinnedItems.length,
                    itemBuilder: (context, index) {
                      final item = unpinnedItems[index];
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey('unpinned_${item.title}_$index'),
                        index: index,
                        child: _SwipeableLibraryTile(
                          index: index, 
                          item: item,
                          suffix: suffix,
                          onTap: () => _handleItemTap(context, item, ref),
                          onPin: () => notifier.togglePin(item),
                          onDelete: (pos) => _showDeleteConfirmation(context, item, notifier, pos),
                        ),
                      );
                    },
                  ),
                  //  FIX: Dynamic bottom gap instead of fixed 150
                  SliverToBoxAdapter(child: SizedBox(height: bottomGap)), 
                ],
              ),
          ),
        ),
      ),
    );
  }


  Widget _buildSearchBar(LibraryNotifier notifier) {
    // Shared pill. See [AuvySearchField] for why a fixed-height Container plus a
    // prefixIcon can't centre its text.
    return AuvySearchField(
      key: const ValueKey('searchBar'),
      controller: _searchController,
      hint: "Search library",
      height: 46,
      fontSize: 14.5,
      hintColor: Colors.white30,
      iconColor: Colors.white30,
      autofocus: true,
      onChanged: (val) => notifier.setSearchQuery(val),
      trailing: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
        onPressed: () {
          setState(() => _isSearching = false);
          _searchController.clear();
          notifier.setSearchQuery('');
        },
      ),
    );
  }

  // Spotify-style header: profile avatar leads, actions trail as quiet icons.
  Widget _buildDefaultHeader(LibraryNotifier notifier) {
    Widget action(IconData icon, String tooltip, VoidCallback onTap) {
      return Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: () {
            HapticService.selection();
            onTap();
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Icon(icon, color: Colors.white.withOpacity(0.85), size: 24),
          ),
        ),
      );
    }

    // assetAction (an asset-glyph variant of [action]) was removed along with
    // the Spotify mark: it existed only to render a brand SVG, and no bundled
    // glyph needs it now. Reinstate it only for a NON-trademark asset.

    return Row(
      key: const ValueKey('defaultHeader'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final account = ref.watch(accountProvider);
            return GestureDetector(
              key: _accountIconKey,
              onTap: () => _showAccountMenu(context),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: account.isLoggedIn
                          ? ref.watch(themeProvider).withOpacity(0.8)
                          : Colors.white24,
                      width: 1.6),
                ),
                child: CircleAvatar(
                  backgroundColor: const Color(0xFF2A2A2E),
                  radius: 16,
                  backgroundImage: account.avatarUrl != null
                      ? NetworkImage(account.avatarUrl!)
                      : null,
                  child: account.avatarUrl == null
                      ? const Icon(Icons.person_rounded, color: Colors.white70, size: 18)
                      : null,
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 12),
        const Text("Library",
            style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6)),
        const Spacer(),
        action(Icons.search_rounded, 'Search library',
            () => setState(() => _isSearching = true)),
        action(Icons.add_rounded, 'Create playlist',
            () => _showAddPlaylistDialog(context, notifier)),
        // A generic glyph, NOT spotify's mark.
        //
        // This used to render spotify.svg, on the reasoning that the brand says
        // "import from Spotify" faster than a chain-link does. True, but a
        // trademark in the UI implies a relationship, and there isn't one: the
        // import has no working API credentials in a release build and falls back
        // to reading the public embed page. Showing their logo on top of that is
        // the combination worth avoiding.
        //
        // The LABEL still says "Import from Spotify", which is fine — naming a
        // service to describe interoperability is ordinary descriptive use. It is
        // the logo, not the word, that makes a claim.
        action(Icons.playlist_add_check_rounded, 'Import from Spotify',
            () => _showLinkImportDialog(context, ref)),
        // Settings moved OFF the header into the account (avatar) menu, top-left
        // — Spotify/Apple-Music style. It now opens full-screen on the ROOT
        // navigator (see _showAccountMenu → AppNavigation.pushRoot), so it no
        // longer lingers as a stuck sub-page of the Library tab.
      ],
    );
  }

  /// Resolve a library row back to its live PodcastShow (subscribed stations
  /// are stored as likedAlbums with recordType 'podcast' and the RSS feed URL
  /// in Album.id). Null for everything that isn't a podcast.
  PodcastShow? _podcastShowFor(LibraryItem item, WidgetRef ref) {
    if (item.isSystemFolder) return null;
    final libState = ref.read(libraryProvider);
    for (final a in libState.likedAlbums) {
      if (a.recordType == 'podcast' && a.title == item.title) {
        final artist = item.subtitle.startsWith('Podcast • ')
            ? item.subtitle.substring('Podcast • '.length)
            : '';
        return PodcastShow(
          collectionName: a.title,
          artistName: artist,
          artworkUrl: a.image.isNotEmpty ? a.image : item.image,
          feedUrl: a.id,
        );
      }
    }
    return null;
  }

  void _handleItemTap(BuildContext context, LibraryItem item, WidgetRef ref) {
    _dismissKeyboard();
    // Subscribed podcast stations open the LIVE episode sheet (fresh RSS pull)
    // instead of the frozen snapshot playlist, so new daily episodes show up
    // the moment you open the show.
    final podcastShow = _podcastShowFor(item, ref);
    if (podcastShow != null) {
      if (!ref.read(connectivityProvider).isOffline) {
        // Force a re-fetch past the provider's 24h keepAlive so today's
        // episodes appear; offline keeps serving the cached feed.
        ref.invalidate(podcastEpisodesProvider(podcastShow));
      }
      openPodcastShow(context, podcastShow, ref.read(themeProvider));
      return;
    }
    // Both titles route here: the folder title is persisted, so an install that
    // has not yet run the rename migration still says "Your Artists".
    if (item.title == "Followed Artists" || item.title == "Your Artists") {
      AppNavigation.push(context,
          _FolderPage(title: item.title, type: 'artist'));
    }
    else if (item.title == "Followed Podcasts") {
      AppNavigation.push(context,
          const _FolderPage(title: "Followed Podcasts", type: 'podcast'));
    }
    else if (item.title == "Liked Albums") {
      AppNavigation.push(context, const _FolderPage(title: "Liked Albums", type: 'album'));
    }
    else if (item.title == "Liked Playlists") {
      AppNavigation.push(context, const _FolderPage(title: "Liked Playlists", type: 'playlist_liked'));
    }
    else if (item.title == "Cached") {
      AppNavigation.push(context, PlaylistPage(libraryPlaylist: item), name: AppNavigation.playlistTag(item.title));
    }
    else if (item.title == "Downloads") {
      AppNavigation.push(context, PlaylistPage(libraryPlaylist: item), name: AppNavigation.playlistTag(item.title));
    }
    else if (item.category == LibraryCategory.album) {
      // Downloaded/saved albums open as a REAL album page (release header,
      // year, album chrome), not the playlist editor view. The item stores no
      // browse id, so the album resolves by name — artist parsed from the
      // "Album • <artist> • N songs" subtitle, tracks falling back to the
      // downloaded copies via the album page's name-resolution cache.
      final parts = item.subtitle.split('•').map((p) => p.trim()).toList();
      final artistName = parts.length >= 2 ? parts[1] : '';
      final localTracks =
          ref.read(libraryProvider).playlistSongs[item.title] ?? const <Song>[];
      AppNavigation.push(
        context,
        AlbumPage(
          album: Album(
            id: '',
            title: item.title,
            image: item.image,
            releaseDate: '',
            recordType: 'album',
            artist: artistName,
          ),
          artistName: artistName.isNotEmpty ? artistName : 'Unknown',
          fallbackTrack: localTracks.isNotEmpty ? localTracks.first : null,
        ),
        name: AppNavigation.albumTag(Album(
          id: '',
          title: item.title,
          image: item.image,
          releaseDate: '',
          recordType: 'album',
        )),
      );
    }
    else if (
      item.title == "Liked Songs" ||
      item.title == "My Top 50" ||
      item.category == LibraryCategory.playlist
    ) {
      AppNavigation.push(
        context,
        PlaylistPage(
          libraryPlaylist: item,
        ),
        name: AppNavigation.playlistTag(item.title),
      );
    }
  }

  /// [origin] is where the swipe action was released — the ghost has to start
  /// from the row, and this method only ever receives the PAGE context, whose
  /// centre is the middle of the screen.
  void _showDeleteConfirmation(BuildContext context, LibraryItem item,
      LibraryNotifier notifier, [Offset? origin]) {
    if (item.isSystemFolder) return;

    // Dynamically change text based on whether it is an Album or a Playlist
    final type = item.category == LibraryCategory.album ? "Album" : "Playlist";

    // Optimistic delete + floating Undo — same pattern as per-track deletes
    // (the old blocking confirm dialog is gone). The item vanishes instantly;
    // the IRREVERSIBLE disk wipe of downloaded files only runs when the undo
    // window closes without an undo.
    final snapshot = notifier.deleteItem(item);
    ItemTransferOverlay.discard(context, origin: origin);
    if (snapshot == null) return;
    HapticService.medium();
    UndoToast.show(
      context,
      text: "$type \"${item.title}\" deleted",
      icon: item.category == LibraryCategory.album
          ? Icons.album_rounded
          : Icons.playlist_remove_rounded,
      onUndo: () => notifier.restoreItem(snapshot),
      onExpire: () async {
        await AudioCacheManager().deleteCollectionLocally(item.title);
        notifier.refreshDownloadsFolder();
      },
    );
  }

  void _showAddPlaylistDialog(BuildContext context, LibraryNotifier notifier) {
    final controller = TextEditingController();
    final themeColor = ref.read(themeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: const Text("Create Playlist", style: TextStyle(color: Colors.white)),
        content: TextField(controller: controller, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: "Playlist Name", hintStyle: TextStyle(color: Colors.white54)), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(onPressed: () {
            if (controller.text.isNotEmpty) {
              _dismissKeyboard(); 
              notifier.addPlaylist(controller.text);
              Navigator.pop(context);
            }
          }, child: Text("Create", style: TextStyle(color: themeColor))),
        ],
      ),
    ).whenComplete(() =>
        // Dispose AFTER the dialog's exit animation finishes. whenComplete fires
        // the instant pop() is called, but the AlertDialog keeps rebuilding its
        // TextField during the ~200ms fade-out — disposing right then made it use
        // a disposed controller ("TextEditingController used after being disposed"
        // → red screen when tapping the add-playlist + icon).
        Future.delayed(const Duration(milliseconds: 600), controller.dispose));
  }
}

/// Cloud-backup status + on-demand "Back up now" for the account panel. Shows
/// whether sync is active and lets the user push a backup immediately (useful,
/// unlike the removed "Logout All"). Owns its own busy/result state.
class _CloudBackupCard extends ConsumerStatefulWidget {
  const _CloudBackupCard();
  @override
  ConsumerState<_CloudBackupCard> createState() => _CloudBackupCardState();
}

class _CloudBackupCardState extends ConsumerState<_CloudBackupCard> {
  bool _busy = false;
  String? _result;

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final active = ref.read(accountProvider.notifier).isCloudActive;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: themeColor.withOpacity(0.15), shape: BoxShape.circle),
            child: Icon(active ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                color: themeColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Cloud backup",
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                    _result ??
                        (active
                            ? "Library & settings sync automatically"
                            : "Connecting…"),
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: () async {
                    HapticService.selection();
                    setState(() {
                      _busy = true;
                      _result = null;
                    });
                    final ok = await ref
                        .read(accountProvider.notifier)
                        .backupNow();
                    if (!mounted) return;
                    setState(() {
                      _busy = false;
                      _result = ok
                          ? "Backed up just now ✓"
                          : "Backup failed — tap to retry";
                    });
                  },
                  child: Text("Back up now",
                      style: TextStyle(
                          color: themeColor, fontWeight: FontWeight.w700)),
                ),
        ],
      ),
    );
  }
}

class _FolderPage extends ConsumerWidget {
  final String title;
  final String type;

  const _FolderPage({required this.title, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libState = ref.watch(libraryProvider);
    final cacheManager = AudioCacheManager();
    // Build a Set of cached song ids ONCE per build instead of linear-scanning
    // the "Cached" list with .any() for every row in the itemBuilder below.
    final Set<String> cachedIds =
        (libState.playlistSongs["Cached"] ?? const []).map((s) => s.id).toSet();
    List<dynamic> items = [];

    if (type == 'cached') {
      items = libState.playlistSongs["Cached"] ?? [];
    } else if (type == 'downloads') {
      items = libState.playlistSongs["Downloads"] ?? [];
    } else if (type == 'artist') {
      items = libState.subscribedArtists;
    } else if (type == 'album') {
      // PODCASTS LIVE IN likedAlbums TOO, AND USED TO SHOW UP HERE.
      //
      // Following a show stores it as an Album with recordType 'podcast'. Only
      // the Liked Albums *count* filtered those out (see the actualAlbumCount
      // note in library_provider), so the folder itself listed podcast shows
      // among the albums — reported as "Liked Albums holding podcast stations".
      // The count and the contents now agree.
      items = libState.likedAlbums.where((a) => a.recordType != 'podcast').toList();
    } else if (type == 'podcast') {
      items = libState.likedAlbums.where((a) => a.recordType == 'podcast').toList();
    } else if (type == 'playlist_liked') {
      items = libState.likedPlaylists;
    }

    return DynamicBackground(child: Scaffold(
      // Transparent over the shared DynamicBackground — the old solid
      // 0xFF121212 scaffold + appbar painted over the app's ambient backdrop,
      // making this the one flat-grey page in the whole app.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                letterSpacing: -0.4)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (type == 'cached' || type == 'downloads')
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
              onPressed: () {
                final notifier = ref.read(libraryProvider.notifier);
                if (type == 'cached') {
                  notifier.refreshCachedFolder();
                } else if (type == 'downloads') {
                  notifier.refreshDownloadsFolder();
                }
              },
            ),
        ],
      ),
      body: items.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_open_rounded,
                    size: 48, color: Colors.white.withOpacity(0.18)),
                const SizedBox(height: 12),
                Text("Nothing here yet",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 14)),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              String imageUrl = '';
              String titleText = '';
              String subtitleText = '';
              bool isDownloaded = false;
              bool isCached = false; 
              
              if (item is Song) { 
                imageUrl = item.image; 
                titleText = item.title; 
              subtitleText = item.artist; 
              isDownloaded = cacheManager.isExplicitlyDownloaded(item.id);                
              isCached = !isDownloaded && cachedIds.contains(item.id);
              }
              else if (item is Album) {
                imageUrl = item.image;
                titleText = item.title;
                // A followed show is stored as an Album, so the kind has to come
                // from the folder being viewed — otherwise every podcast row in
                // Followed Podcasts introduces itself as "Album • …".
                final kind = type == 'podcast' ? 'Podcast' : 'Album';
                subtitleText =
                    item.artist.isNotEmpty ? "$kind • ${item.artist}" : kind;
                // Spotify-style album badges: green tick when EVERY track is an
                // explicit download; offline bolt when every track is at least
                // cached; no badge when the album is merely liked.
                final albumTracks = libState.playlistSongs[item.title] ?? const <Song>[];
                if (albumTracks.isNotEmpty) {
                  final allDownloaded = albumTracks
                      .every((t) => cacheManager.isExplicitlyDownloaded(t.id));
                  final allOffline = allDownloaded ||
                      albumTracks.every((t) =>
                          cacheManager.isExplicitlyDownloaded(t.id) ||
                          cacheManager.isCached(t.id));
                  isDownloaded = allDownloaded;
                  isCached = !allDownloaded && allOffline;
                }
              }
              else if (item is LibraryItem) { 
                imageUrl = item.image;
                titleText = item.title;
                subtitleText = item.subtitle;
              }

              // Artists resolve their OFFICIAL channel picture; everything else
              // uses the image it came with. `subscribedArtists` stores whatever
              // was on screen when the artist was liked — often a track thumbnail
              // or album cover, so this grid used to show faces that did not
              // match the artists' own pages. Progressive: the stored image shows
              // until the lookup lands, because a wrong-but-present picture beats
              // an empty circle. Resolution is memoised per name for the session
              // (see artistImageProvider).
              final String artworkPath = type == 'artist'
                  ? (ref.watch(artistImageProvider(titleText)).valueOrNull
                          ?.isNotEmpty ==
                      true
                      ? ref.watch(artistImageProvider(titleText)).value!
                      : imageUrl)
                  : imageUrl;

              // Charged hold. See HoldToOpen. Wrapping keeps the ListTile own
              // onTap and ripple exactly as they were.
              return HoldToOpen(
                borderRadius: BorderRadius.circular(10),
                onHold: item is Song
                    ? () => ContentMenus.showSongMenu(context, item, ref)
                    : null,
                child: ListTile(
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // WAS a flat `borderRadius: 22` for every type — 22 on a
                    // 52px cover is 42%, i.e. very nearly a circle. That is why
                    // covers looked DIFFERENT between library views: this list
                    // rounded albums and playlists almost into circles while the
                    // shelf list used 10/54 (~19%) and the grid 32 on a large tile
                    // (~19% too). Those two agreed; this one was the outlier.
                    //
                    // Artists keep the circle — that is a convention, not an
                    // inconsistency, and the same tile is circular on the artist
                    // page and in search. Everything else now matches the app's
                    // ~19% proportion, and both go through the roundness setting.
                    // Artists resolve their OFFICIAL channel picture, falling back
                    // to the stored one until it lands. `subscribedArtists` keeps
                    // whatever image was on screen when the artist was liked —
                    // frequently a track thumbnail or album cover, so this grid
                    // showed faces that didn't match the artists' own pages.
                    // Progressive on purpose: a stored-but-wrong picture beats an
                    // empty circle while the lookup runs.
                    AuvyImage(
                        path: artworkPath,
                        width: 52,
                        height: 52,
                        borderRadius: type == 'artist' ? 26 : 10),
                    if (isDownloaded || isCached)
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isDownloaded ? Icons.check_circle : Icons.offline_bolt_rounded, 
                            color: isDownloaded ? Colors.greenAccent : Colors.blueGrey, 
                            size: 18
                          ),
                        ),
                      ),
                  ],
                ),
                title: Text(titleText,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(subtitleText,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 12.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                onTap: () {
                  if (type == 'artist') {
                    final s = item as Song;
                    AppNavigation.push(context, ArtistPage(artist: s),
                        name: AppNavigation.artistTag(s));
                  } else if (type == 'album') {
                    final album = item as Album;
                    // Resolve the REAL artist: stored on the album (new likes),
                    // else recover it from the LibraryItem subtitle
                    // ("Album • <artist>") for albums liked before the artist
                    // was persisted. Passing "Unknown" broke name-resolution
                    // and made liked albums open empty.
                    String artistName = album.artist;
                    if (artistName.isEmpty) {
                      final match = libState.allItems
                          .where((i) => i.title == album.title && i.subtitle.contains('•'))
                          .toList();
                      if (match.isNotEmpty) {
                        artistName = match.first.subtitle.split('•').last.trim();
                      }
                    }
                    AppNavigation.push(context,
                        AlbumPage(album: album, artistName: artistName),
                        name: AppNavigation.albumTag(album));
                  } else if (type == 'podcast') {
                    // Without this branch the rows were untappable.
                    //
                    // Followed Podcasts holds Album objects (a followed show is
                    // stored as an Album with recordType 'podcast'), so none of
                    // the tests around this one matched: not 'artist', not
                    // 'album', and an Album is neither a LibraryItem nor a Song.
                    // Every branch missed and the tap silently did nothing.
                    //
                    // Opens the LIVE episode sheet, same as tapping the show in
                    // the library grid — a podcast's whole point is that new
                    // episodes appear, so a frozen snapshot would be wrong.
                    final album = item as Album;
                    String artistName = album.artist;
                    if (artistName.isEmpty) {
                      final match = libState.allItems
                          .where((i) =>
                              i.title == album.title &&
                              i.subtitle.startsWith('Podcast • '))
                          .toList();
                      if (match.isNotEmpty) {
                        artistName = match.first.subtitle
                            .substring('Podcast • '.length);
                      }
                    }
                    final show = PodcastShow(
                      collectionName: album.title,
                      artistName: artistName,
                      artworkUrl: album.image,
                      feedUrl: album.id,
                    );
                    if (!ref.read(connectivityProvider).isOffline) {
                      // Past the provider's keepAlive so today's episodes show.
                      ref.invalidate(podcastEpisodesProvider(show));
                    }
                    openPodcastShow(context, show, ref.read(themeProvider));
                  } else if (item is LibraryItem) {
                    AppNavigation.push(context, PlaylistPage(libraryPlaylist: item),
                        name: AppNavigation.playlistTag(item.title));
                  } else if (item is Song) {
                    // Kind on the first line, NAME on the second — passing the
                    // shelf title as `source` put it on the kind line and left
                    // the name line showing the track's own album instead.
                    ref.read(playerProvider.notifier)
                        .playSong(item, source: 'Library', locationName: title);
                  }
                },
                // The hold lives on HoldToOpen above, so the visual and the
                // action share one clock.
              ));
            },
          ),
        ),
      );
    }
}

class _SwipeableLibraryTile extends ConsumerWidget {
  final int index;
  final LibraryItem item;
  final String suffix;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final Function(Offset) onDelete;

  // No `key`: the reorderable wrapper at the call site carries it, so one here
  // would never be given a value.
  const _SwipeableLibraryTile({
    required this.index,
    required this.item,
    required this.suffix,
    required this.onTap,
    required this.onPin,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    final iconSuffix = _getColorSuffix(themeColor);
    final themedIconPath = _getThemedIcon(item.image, item.title, iconSuffix);

    return Material(
      color: Colors.transparent,
      child: SwipeActionTile(
        swipeId: item.title,
        onTap: onTap,
        enableTapShrink: true,
        // Pin is the left pill, remove is the right one
        //
        // Library rows are the one surface where the LEFT pill (revealed by
        // dragging right) carries the positive action, because these tiles are
        // playlists, albums and folders — not tracks, so QUEUE never applies
        // here and the "drag left to queue" reflex has nothing to collide with.
        // That frees the left pill for PIN, which is the action people actually
        // reach for on this page, and puts it where the swipe starts.
        //
        // IT DOES MEAN REMOVE SHARES A SIDE WITH QUEUE ELSEWHERE. Dragging
        // left queues a track on album/artist/search/playlist rows and reveals
        // REMOVE here. Mitigated rather than ignored: the pill is red, labelled
        // REMOVE, and goes solid before release, and system folders pass null so
        // that side is locked entirely for them.
        leftAction: SwipeAction(
          icon: item.isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          label: item.isPinned ? "UNPIN" : "PIN",
          color: themeColor,
          onTap: (pos) => onPin(),
        ),
        // System folders can't be removed — a null action locks that side.
        rightAction: item.isSystemFolder
            ? null
            : SwipeAction(
                icon: Icons.delete_outline_rounded,
                label: "REMOVE",
                color: Colors.redAccent,
                onTap: (pos) => onDelete(pos),
              ),
        child: Container(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.symmetric(
                horizontal: 16, vertical: densityNow.rowVerticalPadding),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AuvyImage(
                    path: themedIconPath,
                    width: densityNow.artwork(54),
                    height: densityNow.artwork(54),
                    borderRadius: 10),
              ],
            ),
            trailing: Icon(Icons.drag_handle_rounded, color: Colors.white.withOpacity(0.22), size: 22),
            title: Row(
              children: [
                if (item.isPinned) ...[
                  Icon(Icons.push_pin_rounded, color: themeColor.withOpacity(0.85), size: 13),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    item.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(item.subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 12.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),

                // The per-item progress bar
                Consumer(builder: (context, ref, _) {
                  final progress = ref.watch(libraryProvider.select(
                    (s) => s.downloadProgressMap[item.title] ?? 0.0
                  ));

                  if (progress <= 0 || progress >= 1.0) return const SizedBox.shrink();

                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.white10,
                        color: themeColor,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label; final bool isSelected; final VoidCallback onTap;
  const _FilterChip({required this.label, required this.isSelected, required this.onTap});

  @override Widget build(BuildContext context) {
    return Consumer(builder: (context, ref, _) {
      final themeColor = ref.watch(themeProvider);
      return GestureDetector(
        onTap: () {
          HapticService.selection();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? themeColor : Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: isSelected ? themeColor : Colors.white.withOpacity(0.08)),
          ),
          child: Text(label,
              style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white70,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600)),
        ),
      );
    });
  }
}

/// One zone of the block-mode grid (pinned or unpinned), with long-press drag
/// reordering and a per-tile pin button. See the note at the call site.
Widget _gridSection({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryItem> items,
  required String suffix,
  required bool isPinnedZone,
  required dynamic notifier,
  // Passed in rather than called directly: _handleItemTap is a State method and
  // this builder is top-level, so the tap has to arrive as a callback.
  required void Function(LibraryItem) onTapItem,
}) {
  return SliverPadding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      delegate: SliverChildBuilderDelegate(
        childCount: items.length,
        (context, index) {
          final item = items[index];
          final tile = GestureDetector(
            onTap: () => onTapItem(item),
            child: _LibraryGridItem(
              item: item,
              suffix: suffix,
              // Still no PIN on a system folder — Liked Songs, Downloads, Cached
              // and My Top 50 are structural, and the list mode locks their swipe
              // side for the same reason.
              onPin: item.isSystemFolder ? null : () => notifier.togglePin(item),
            ),
          );
          // NO EARLY RETURN FOR SYSTEM FOLDERS. This used to be
          // `if (item.isSystemFolder) return tile;`, which made the default
          // playlists the one thing in grid mode that would not budge: not
          // draggable, and — worse — not a drop TARGET either, so a real playlist
          // dragged onto Liked Songs was silently rejected.
          //
          // "Cannot be pinned" was read as "cannot be moved", but they are
          // different rules. Pinning a structural folder is meaningless; ORDERING
          // is exactly what someone rearranging their library wants, and the LIST
          // mode has always allowed it (every row there gets a drag listener).
          // Grid and list were simply inconsistent.
          //
          // Nothing downstream objects: reorderLibraryItems only permutes
          // `allItems`, and `_applyFilterAndSort` sorts by that order with pinned
          // first — it has no separate rule that floats system folders to the top.

          // DragTarget accepts the index being dragged and hands both to the
          // same reorder call list mode uses.
          return DragTarget<int>(
            onWillAcceptWithDetails: (d) => d.data != index,
            onAcceptWithDetails: (d) {
              HapticService.light();
              notifier.reorderLibraryItems(
                isPinned: isPinnedZone,
                oldIndex: d.data,
                // SliverReorderableList's contract: a forward move lands one
                // past the target, because the dragged item is removed first.
                newIndex: d.data < index ? index + 1 : index,
              );
            },
            builder: (context, candidate, rejected) {
              final hovering = candidate.isNotEmpty;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(
                    color: hovering
                        ? ref.read(themeProvider)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: LongPressDraggable<int>(
                  data: index,
                  onDragStarted: HapticService.medium,
                  // Half-size ghost so the grid underneath stays readable while
                  // aiming — a full-size one covers the drop target.
                  feedback: Opacity(
                    opacity: 0.85,
                    child: SizedBox(
                      width: 130,
                      height: 175,
                      child: _LibraryGridItem(item: item, suffix: suffix),
                    ),
                  ),
                  childWhenDragging: Opacity(opacity: 0.25, child: tile),
                  child: tile,
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

class _LibraryGridItem extends ConsumerWidget {
  final LibraryItem item;
  final String suffix;

  /// Pin toggle. Null on system folders and on the drag ghost, which needs no
  /// controls. Block mode has no swipe to offer, so pinning needs a real target.
  final VoidCallback? onPin;
  const _LibraryGridItem(
      {required this.item, required this.suffix, this.onPin});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    
    // Check if there is a local cached image for this album/playlist title
    final String? localArt = AudioCacheManager().getAlbumCoverArt(item.title);
    
    // Resolve path: Local Art > Themed Icon > Original Item Image
    final String displayPath = localArt ?? _getThemedIcon(item.image, item.title, suffix);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              color: Colors.white.withOpacity(0.05),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Stack(
              children: [
                // Pin toggle, top-right. Filled + accented when pinned, so the
                // state is readable at a glance across a grid.
                if (onPin != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: Colors.black.withOpacity(0.45),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {
                          HapticService.selection();
                          onPin!();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(7),
                          child: Icon(
                            item.isPinned
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 15,
                            color: item.isPinned ? themeColor : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  // double.infinity is not FINITE, so _decodeDim returns null and this
                  // decoded at full source size. 720 matches the ladder cap.
                  child: AuvyImage(path: displayPath, width: double.infinity, decodeWidth: 720, borderRadius: 32, fit: BoxFit.cover),
                ),
                if (item.isPinned)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: Icon(Icons.push_pin_rounded, color: themeColor, size: 13),
                    ),
                  ),
              ],
            )
          )
        ),
        const SizedBox(height: 9),
        Text(item.title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(item.subtitle,
            style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis)
      ]);
  }
}
