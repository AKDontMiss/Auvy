import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/services/haptic_service.dart';

/// Shared chrome for the two browse hubs, Live Radio and Podcasts, so they stay
/// the same screen with different contents. Each hub still owns its data, its rows
/// and what its chips do: radio groups by country and filters by genre; podcasts
/// group by genre and use the chips to jump between sections.
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

  /// Shown in the header when something is expanded; kept out of the search row so
  /// both hubs' search fields are the same width.
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
          // top: false, with the status-bar inset added to the header's padding instead, so
          // the header's accent gradient runs continuously behind the status bar without a
          // seam.
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

/// A fixed header, not a SliverAppBar: the list below is a
/// ScrollablePositionedList (the A–Z rail addresses sections by index), which
/// can't live in a CustomScrollView, and a collapsing header would resize the
/// rail's track mid-drag.
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
            tooltip: 'Back',
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

/// The one "nothing to show" box for the browse hubs and their pages (empty,
/// failed with a retry). A box, never a sliver.
class BrowseHubStatus extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const BrowseHubStatus({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
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
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                child: Text(actionLabel!, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
