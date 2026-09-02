import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/services/haptic_service.dart';

/// The shared chrome for Auvy's two browse hubs — Live Radio and Podcasts.
///
/// ONE WIDGET ON PURPOSE. Both hubs were built from the same sketch and then
/// edited separately, so they drifted: byte-identical headers duplicated in two
/// files, a collapse-all button on radio only, a filter row on radio only, and
/// two different "nothing here" boxes (`_StatusBox` vs `_StatusSliver`). They
/// are supposed to read as the same screen with different contents, and the only
/// way that survives future edits is for the chrome to exist ONCE.
///
/// What each hub still owns: its data, its rows, and what its chips do. Radio
/// groups by country and filters by genre; podcasts group by genre and use the
/// chips to jump between sections. Same frame, different picture.
class BrowseHubScaffold extends StatelessWidget {
  /// Big title — "Live Radio", "Podcasts".
  final String title;

  /// One quiet line under it. This is where a hub says how much it holds
  /// ("218 countries") so an unopened list of collapsed rows still reads as
  /// substantial rather than empty.
  final String? subtitle;

  /// Pull-to-refresh for whatever the hub's directory is.
  final Future<void> Function() onRefresh;

  /// The search pill. Built by the hub because each owns its controller and
  /// query provider, but sized and padded identically by the row below.
  final Widget searchField;

  /// The horizontal chip row. Both hubs pass one so the vertical rhythm matches;
  /// pass null only if a hub genuinely has nothing to put there.
  final Widget? chips;

  /// The list itself.
  final Widget body;

  /// Shown in the header when there is something expanded to close. Kept OUT of
  /// the search row — radio used to put it there, which made its search field
  /// narrower than the podcast one for no reason a user could see.
  final VoidCallback? onCollapseAll;
  final bool canCollapse;

  final Color accent;

  const BrowseHubScaffold({
    super.key,
    required this.title,
    required this.onRefresh,
    required this.searchField,
    required this.body,
    required this.accent,
    this.subtitle,
    this.chips,
    this.onCollapseAll,
    this.canCollapse = false,
  });

  @override
  Widget build(BuildContext context) {
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: RefreshIndicator(
          onRefresh: onRefresh,
          edgeOffset: 110,
          color: accent,
          backgroundColor: const Color(0xFF1A1A1E),
          // top: FALSE, and the inset moved into the header's padding.
          //
          // With top:true the SafeArea clipped the header's accent gradient to
          // start BELOW the status bar, leaving a visible tinted band with a hard
          // seam along the top, which reads as a panel sitting over the page
          // rather than part of it, and is what made Radio and Podcasts look
          // different from every other page.
          //
          // The gradient now runs to the very top edge and fades down, continuous
          // behind the status bar. The reason top:true was added in the first place
          // — a plain Column does not inset for the status bar the way a
          // SliverAppBar did, so the title sat on the clock — still holds, so
          // _Header adds MediaQuery's top inset to its own padding instead.
          child: SafeArea(
            top: false,
            bottom: false,
            child: Column(
              children: [
                _Header(
                  title: title,
                  subtitle: subtitle,
                  accent: accent,
                  onCollapseAll: onCollapseAll,
                  canCollapse: canCollapse,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                  child: searchField,
                ),
                if (chips != null) SizedBox(height: 52, child: chips),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fixed, not a SliverAppBar.
///
/// The list below is a ScrollablePositionedList — the A–Z rail addresses
/// sections by index, which is not a sliver and cannot live in a
/// CustomScrollView. A stable header suits a scrubbed list anyway: the rail runs
/// the full height, and a header collapsing under it would resize the track
/// while you drag it.
class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color accent;
  final VoidCallback? onCollapseAll;
  final bool canCollapse;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onCollapseAll,
    required this.canCollapse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // The status-bar inset lives HERE, not in a SafeArea above. See the note
      // in BrowseHubScaffold. This keeps the title clear of the clock while
      // letting the gradient behind it reach the top of the screen.
      padding: EdgeInsets.fromLTRB(
          4, 4 + MediaQuery.paddingOf(context).top, 12, 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withOpacity(0.18), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 24,
                    letterSpacing: -0.5,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onCollapseAll != null)
            _CollapseAllButton(
              enabled: canCollapse,
              accent: accent,
              onTap: onCollapseAll!,
            ),
        ],
      ),
    );
  }
}

/// Close every open section.
///
/// A sectioned list of 200 countries is easy to open and tedious to tidy — after
/// a few taps the page is a wall and the A–Z rail is scrubbing past expanded
/// blocks. Disabled (not hidden) when nothing is open, so the control does not
/// appear and disappear as you browse.
class _CollapseAllButton extends StatelessWidget {
  final bool enabled;
  final Color accent;
  final VoidCallback onTap;

  const _CollapseAllButton({
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.32,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: enabled
              ? () {
                  HapticService.selection();
                  onTap();
                }
              : null,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.unfold_less_rounded,
                    size: 16, color: enabled ? accent : Colors.white54),
                const SizedBox(width: 5),
                const Text('Collapse',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one "nothing to show" box, for both hubs.
///
/// Replaces a `_StatusBox` in one file and a `_StatusSliver` in the other that
/// said the same thing at different sizes. Box-based, never a sliver — both hubs
/// put this inside a Column, and a sliver there throws
/// `RenderFlex expected a child of type RenderBox`, which is the red flash both
/// pages used to show while loading.
class BrowseHubStatus extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const BrowseHubStatus({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.white.withOpacity(0.22)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
