import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:auvy/presentation/widgets/alphabet_rail.dart';
import 'package:auvy/services/haptic_service.dart';

/// One collapsible section: a title, a count, and however many rows.
///
/// [items] may be empty while a lazily-loaded section is still fetching —
/// [loading] says which of the two it is, so an empty section can read
/// "nothing here" instead of spinning forever.
class BrowseGroup {
  final String key;
  final String title;
  final String? subtitle;
  final int count;
  final List<Widget> Function() buildItems;
  final bool loading;

  /// Force which rail letter this group sits under. Used for buckets that are
  /// not really names — "Unknown" is not a country beginning with U.
  final String? letter;

  const BrowseGroup({
    required this.key,
    required this.title,
    required this.count,
    required this.buildItems,
    this.subtitle,
    this.loading = false,
    this.letter,
  });
}

/// An A–Z browsable list of collapsible sections.
///
/// Shared by the radio hub (grouped by country) and the podcast hub (grouped by
/// genre) so the two behave identically — the same expand gesture, the same
/// scrubber, the same section chrome.
///
/// Why a flat index list rather than nested ListViews
/// The alphabet rail has to JUMP to a section, which means the section header
/// needs an addressable scroll index. `ScrollablePositionedList` indexes by
/// item, so headers and rows are flattened into one sequence and a
/// `key → index` map is rebuilt each pass. Nesting a ListView per section would
/// make every section build all of its children whether or not it is open.
class GroupedBrowseView extends StatefulWidget {
  final List<BrowseGroup> groups;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;
  final Color accent;

  /// Rendered above the first section and scrolls with it.
  final Widget? header;

  const GroupedBrowseView({
    super.key,
    required this.groups,
    required this.expanded,
    required this.onToggle,
    required this.accent,
    this.header,
  });

  @override
  State<GroupedBrowseView> createState() => _GroupedBrowseViewState();
}

class _GroupedBrowseViewState extends State<GroupedBrowseView> {
  final ItemScrollController _isc = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  String? _activeLetter;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_syncLetter);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_syncLetter);
    super.dispose();
  }

  /// Keep the rail's highlight on whatever section is at the top of the
  /// viewport, so the scrubber reflects where you are without being dragged.
  void _syncLetter() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    final first = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<ItemPosition?>(null, (best, p) =>
            best == null || p.itemLeadingEdge < best.itemLeadingEdge ? p : best);
    if (first == null) return;
    final letter = _letterForIndex(first.index);
    if (letter != null && letter != _activeLetter) {
      setState(() => _activeLetter = letter);
    }
  }

  // Rebuilt on every build so it can never drift from what is on screen.
  final Map<String, int> _headerIndexFor = {};
  final Map<String, String> _titleForLetter = {};
  final Map<int, String> _letterAtIndex = {};

  String? _letterForIndex(int index) {
    int best = -1;
    String? letter;
    for (final entry in _letterAtIndex.entries) {
      if (entry.key <= index && entry.key > best) {
        best = entry.key;
        letter = entry.value;
      }
    }
    return letter;
  }

  static String _initial(String s) {
    final t = s.trim();
    if (t.isEmpty) return '#';
    final c = t[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(c) ? c : '#';
  }

  @override
  Widget build(BuildContext context) {
    // Flatten
    final List<Widget> flat = [];
    _headerIndexFor.clear();
    _letterAtIndex.clear();
    _titleForLetter.clear();
    final List<String> letters = [];

    if (widget.header != null) flat.add(widget.header!);

    for (final g in widget.groups) {
      final letter = g.letter ?? _initial(g.title);
      // Deduped across the WHOLE rail, not just against the previous entry: a
      // trailing bucket ("Unknown") would otherwise re-add a letter that
      // already appeared earlier, and the rail showed U twice.
      if (!letters.contains(letter)) {
        letters.add(letter);
        _letterAtIndex[flat.length] = letter;
      }
      _headerIndexFor[letter] ??= flat.length;
      _titleForLetter[letter] ??= g.title;
      final bool open = widget.expanded.contains(g.key);
      flat.add(_SectionHeader(
        title: g.title,
        subtitle: g.subtitle,
        count: g.count,
        open: open,
        accent: widget.accent,
        onTap: () {
          HapticService.selection();
          widget.onToggle(g.key);
        },
      ));
      if (open) {
        if (g.loading) {
          flat.add(const _SectionSpinner());
        } else {
          final items = g.buildItems();
          if (items.isEmpty) {
            flat.add(const _SectionEmpty());
          } else {
            flat.addAll(items);
          }
        }
      }
    }

    return Stack(
      // The rail bubble paints to the LEFT of the rail, outside its box.
      clipBehavior: Clip.none,
      children: [
        ScrollablePositionedList.builder(
          itemScrollController: _isc,
          itemPositionsListener: _positions,
          physics: const BouncingScrollPhysics(),
          // Explicit: the list is rebuilt when data arrives and again whenever a
          // section opens, and "wherever it happened to be" is not an opening
          // position for a browse page.
          initialScrollIndex: 0,
          // THE BIG BOTTOM PAD IS WHAT STOPS THE RAIL "JUMPING BACK".
          //
          // jumpTo puts the target header at the top of the viewport, but a
          // list can only scroll to its maximum extent, so the last few sections
          // could not reach the top and the page visibly settled somewhere else
          // than where the finger asked for. Padding the tail by most of a
          // screen means EVERY section, including the last, can actually be
          // scrolled to the top, so the scrubber lands where it says it will.
          //
          // The right inset keeps content clear of the rail; the rest covers the
          // mini player and the nav bar.
          padding: EdgeInsets.only(
            right: 34,
            bottom: MediaQuery.of(context).size.height * 0.72,
          ),
          itemCount: flat.length,
          itemBuilder: (context, i) => flat[i],
        ),
        Positioned(
          // Was bottom: 190, which stopped the rail two-thirds of the way down
          // and squeezed every letter into the top of the edge. 118 clears the
          // mini player and the nav bar and nothing else, so the track runs
          // almost the full height and the letters get real space between them.
          top: 4,
          bottom: 118,
          right: 2,
          // Matches AlphabetRail._railWidth — at 32 the rail was being handed
          // two pixels less than it lays out for.
          width: 34,
          child: AlphabetRail(
            letters: letters,
            active: _activeLetter,
            accent: widget.accent,
            labelFor: (l) => _titleForLetter[l] ?? l,
            onLetter: (l) {
              final idx = _headerIndexFor[l];
              if (idx == null || !_isc.isAttached) return;
              // jumpTo, not scrollTo: while a finger is dragging the rail the
              // target changes many times a second, and animating each hop
              // would queue animations that fight each other.
              _isc.jumpTo(index: idx, alignment: 0.0);
            },
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int count;
  final bool open;
  final Color accent;
  final VoidCallback onTap;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.open,
    required this.accent,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: open ? accent.withOpacity(0.18) : Colors.white.withOpacity(0.05),
            ),
          ),
        ),
        child: Row(
          children: [
            // A thin accent bar marks the open section without shouting.
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 3,
              height: open ? 22 : 0,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: open ? 12 : 0,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: open ? Colors.white : Colors.white.withOpacity(0.88),
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (count > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: open ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white.withOpacity(open ? 0.7 : 0.35),
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionSpinner extends StatelessWidget {
  const _SectionSpinner();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(36, 14, 20, 18),
        child: Text(
          'Nothing here right now.',
          style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13),
        ),
      );
}
