import 'package:auvy/providers/artist_image_provider.dart';
import 'package:auvy/presentation/widgets/item_transfer_overlay.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:auvy/logic/library_integrity.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/library_provider.dart';
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
import 'package:auvy/presentation/widgets/link_import_sheet.dart';


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
  if (title == kWeeklyDiscoveryTitle) return "assets/images/weekly_discovery_$suffix.webp";

  // Followed artists / followed podcasts.
  //
  // "Your Artists" is the folder's old name. The title is stored in the library
  // data, so installs that haven't run the rename migration yet still have it;
  // keep matching it so their tile doesn't go blank.
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
  

  // Opens the account side panel from the avatar (top-left). Settings lives
  // here rather than as a header icon, and opens full-screen on the root
  // navigator so it never gets stuck as a Library-tab sub-page.
  void _showAccountMenu(BuildContext context) {
    HapticService.selection();

    // A side panel anchored to the left edge (the avatar's side), 50% of the
    // screen width and capped at 232px, so the library stays visible behind it
    // and tapping outside clearly dismisses it.
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
  /// Rows are label-only; the group headers (You / App / Tools) give the context
  /// a subtitle would, which keeps the labels short enough for a narrow panel.
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

                // You: account-level places for looking back at your own listening.
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

                // Tools: quick utilities that are otherwise slow to reach (sleep timer,
                // alarm, recognition history).
                groupLabel('Tools'),
                // Opens the sleep timer sheet directly. While a timer is armed the row
                // shows the stop time in the accent colour instead of the plain label.
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
                // Wake-up alarm (this is its only entry point; Settings no longer has it).
                // Shows the armed time in the label, like the sleep timer above.
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
                // There is intentionally no "enable screen audio" row: the recognition tile
                // records from the microphone, so there is nothing to set up in advance.
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

                // Appearance, Privacy and About are opened only from here (Settings keeps the
                // switches). Account settings live in Settings → Account.

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
                    // Read the notifier BEFORE closing the panel: the pop below disposes this
                    // widget, and using `ref` afterwards throws, which would abort the logout.
                    // Same reason rootNav is captured above.
                    final accountNotifier = ref.read(accountProvider.notifier);
                    Navigator.pop(ctx); // close the panel

                    // Ask for confirmation first; signing out wipes downloads and requires
                    // signing in again to undo.
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

  /// Sign-out confirmation dialog. Names the account and explains what is lost
  /// (downloads and cached audio) and what comes back on sign-in (library,
  /// playlists and history, from the cloud backup).
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

  /// The running-import strip, or nothing at all when none is running.
  ///
  /// Its own widget watching its own slice, so the count climbing does not
  /// rebuild the whole library list underneath it — an import matches several
  /// tracks a second, and the list it is about to add to is the most expensive
  /// thing on this screen.
  Widget _importBanner(Color accent) {
    return Consumer(builder: (context, r, _) {
      final p = r.watch(libraryProvider.select((s) => s.linkImport));
      if (p == null) return const SizedBox.shrink();
      final counting = p.isCounting;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.24)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: accent,
                  // Indeterminate until the total is known (the source playlist is still
                  // being read), so the ring doesn't look stuck at zero.
                  value: p.fraction,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      counting
                          ? 'Reading the playlist…'
                          : 'Importing ${p.done} of ${p.total}',
                      style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700),
                    ),
                    if (!counting && p.name.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.60),
                            fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

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
    // Position-free row keys — see [_libraryRowKeys]. Block mode derives its own
    // inside _gridSection, where the zone's items are what it is handed.
    final pinnedKeys = _libraryRowKeys('pinned', pinnedItems);
    final unpinnedKeys = _libraryRowKeys('unpinned', unpinnedItems);

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
        // Progress strip for a playlist import that keeps running after its sheet
        // is closed. Rendered only while an import is running.
        SliverToBoxAdapter(child: _importBanner(themeColor)),

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
                  Semantics(
                    label: libState.isGrid ? 'Switch to list view' : 'Switch to block view',
                    button: true,
                    child: GestureDetector(
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
                  ),
                ],
              ),
            ),
          ),
      ],
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: libState.isGrid
            // Grid mode: pin and reorder.
            //
            // Grids can't swipe or use SliverReorderableList, so each tile gets a pin
            // button, and long-press-and-drag onto another tile reorders (built from
            // LongPressDraggable + DragTarget). Reordering stays within the pinned or
            // unpinned zone and reuses reorderLibraryItems(isPinned:), so a drag never
            // changes a tile's pinned state.
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
                        key: ValueKey(pinnedKeys[index]),
                        index: index,
                        child: _SwipeableLibraryTile(
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
                        key: ValueKey(unpinnedKeys[index]),
                        index: index,
                        child: _SwipeableLibraryTile(
                          item: item,
                          suffix: suffix,
                          onTap: () => _handleItemTap(context, item, ref),
                          onPin: () => notifier.togglePin(item),
                          onDelete: (pos) => _showDeleteConfirmation(context, item, notifier, pos),
                        ),
                      );
                    },
                  ),
                  // Bottom gap sized to clear the nav bar and mini-player.
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
        tooltip: 'Clear search',
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

  // Header: profile avatar on the left, actions as quiet icons on the right.
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


    return Row(
      key: const ValueKey('defaultHeader'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final account = ref.watch(accountProvider);
            return Semantics(
              label: 'Account',
              button: true,
              child: GestureDetector(
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
        // A generic link-plus glyph: the action imports from a pasted link, and a
        // brand logo would imply a partnership that doesn't exist.
        action(Icons.add_link_rounded, 'Import from a link',
            () => showLinkImportSheet(context)),
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

    // Optimistic delete with an Undo toast: the item disappears immediately, and
    // downloaded files are only wiped from disk once the undo window closes.
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
      builder: (context) {
        void create() {
          if (controller.text.isEmpty) return;
          _dismissKeyboard();
          notifier.addPlaylist(controller.text);
          Navigator.pop(context);
        }

        return AlertDialog(
          // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
          title: const Text("Create Playlist",
              style: TextStyle(color: Colors.white)),
          // Pressing Enter creates the playlist; the key and the button share the
          // same `create` function.
          content: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
                hintText: "Playlist Name",
                hintStyle: TextStyle(color: Colors.white54)),
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => create(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            TextButton(
                onPressed: create,
                child: Text("Create", style: TextStyle(color: themeColor))),
          ],
        );
      },
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
      // Followed podcasts are stored in likedAlbums too (recordType 'podcast');
      // filter them out so this folder only lists albums, matching its count.
      items = libState.likedAlbums.where((a) => a.recordType != 'podcast').toList();
    } else if (type == 'podcast') {
      items = libState.likedAlbums.where((a) => a.recordType == 'podcast').toList();
    } else if (type == 'playlist_liked') {
      items = libState.likedPlaylists;
    }

    return DynamicBackground(child: Scaffold(
      // Transparent so the shared DynamicBackground shows through.
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
              tooltip: 'Rescan folder',
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
                // Album badges: a tick when every track is an explicit download, a bolt
                // when every track is at least cached, nothing when the album is only liked.
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

              // Artists show their official channel picture once it resolves. The stored
              // image (whatever was on screen when the artist was followed, often a track
              // thumbnail) is shown until then. Lookups are memoised per name for the
              // session (see artistImageProvider).
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
                    // Artists are circles (radius is half the 52px tile); other covers get
                    // rounded corners. AuvyImage scales the radius by the roundness setting.
                    AuvyImage(
                        path: artworkPath,
                        width: 52,
                        height: 52,
                        borderRadius: type == 'artist' ? 26 : 22),
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
                    // Followed podcasts are Album objects with recordType 'podcast', so they
                    // need their own branch; without it the tap matched nothing. Opens the live
                    // episode sheet, the same as tapping the show in the library grid.
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
  final LibraryItem item;
  final String suffix;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final Function(Offset) onDelete;

  // No `key`: the reorderable wrapper at the call site carries it, so one here
  // would never be given a value.
  //
  // No `index` either. It was passed in and never read — the row identifies
  // itself by title (the swipe tile's own id), and taking a position it does
  // not use is what invites a position back into the key.
  const _SwipeableLibraryTile({
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
        // Swipe actions: the left pill pins/unpins, the right pill removes.
        //
        // Library rows are playlists, albums and folders rather than tracks, so the
        // queue action never applies here and the left side is free for pin. Remove
        // is red and labelled; system folders pass null to disable it.
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
                    borderRadius: item.isCircle ? (densityNow.artwork(54) / 2) : 25),
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

  @override
  Widget build(BuildContext context) =>
      AuvyPill(label: label, selected: isSelected, onTap: onTap);
}

/// Per-row widget keys for one zone of the library, in list or block mode.
///
/// Keys must not include the row's position: if they did, every row shifted
/// by a drop would get a new key, and Flutter would rebuild it instead of
/// moving it (killing the move animation and flashing the list).
///
/// Keyed on zone + category + title, which is how a library entry is
/// identified elsewhere. A numeric suffix is added only when two entries
/// genuinely share a category and title, since duplicate keys are an error.
List<String> _libraryRowKeys(String zone, List<LibraryItem> items) {
  final seen = <String, int>{};
  final keys = <String>[];
  for (final item in items) {
    final base = '${zone}_${item.category.name}_${item.title}';
    final n = seen.update(base, (v) => v + 1, ifAbsent: () => 0);
    keys.add(n == 0 ? base : '$base#$n');
  }
  return keys;
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
  // Tiles are keyed by identity, and the reverse map lets the sliver find a
  // tile by key, so a reorder moves tiles instead of rebuilding every tile
  // after the drop point (and re-running their cover lookups).
  final keys = _libraryRowKeys(isPinnedZone ? 'pinned' : 'unpinned', items);
  final slotOfKey = <String, int>{
    for (var i = 0; i < keys.length; i++) keys[i]: i,
  };
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
        findChildIndexCallback: (key) =>
            slotOfKey[(key as ValueKey<String>).value],
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
          // System folders can be dragged and accept drops too: they can't be pinned,
          // but they can be reordered, the same as in list mode. reorderLibraryItems
          // only permutes `allItems`, so nothing downstream special-cases them.

          // DragTarget accepts the index being dragged and hands both to the
          // same reorder call list mode uses.
          return DragTarget<int>(
            key: ValueKey(keys[index]),
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
                      child: Semantics(
                        label: item.isPinned ? 'Unpin' : 'Pin',
                        button: true,
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
