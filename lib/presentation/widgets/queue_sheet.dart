import 'package:auvy/services/listening_policy.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/providers/density_provider.dart';

// Easter Egg Provider: Toggling this makes the equalizer rainbow!
final hypeModeProvider = StateProvider<bool>((ref) => false);

// Fixed row metrics — the initial auto-scroll offset math depends on these.
const double _kTileHeight = 64.0;
const double _kHeaderHeight = 44.0;
const double _kSheetRadius = 28.0;

/// Where a row's visible card sits inside its 64px slot.
///
/// SHARED ON PURPOSE. [_buildTrackTile] lays the card out with this, and
/// [_buildProxyDecorator] paints the drag highlight with it. They were separate
/// literals before, and the highlight was drawn on the row's outer bounds while
/// the card was inset 12px, which is exactly why reordering looked misaligned.
/// One source means they cannot disagree again.
///
/// NOW A FUNCTION, NOT A CONSTANT. These rows are hand-built rather than
/// ListTiles, so the `visualDensity` funnel in main.dart could never reach them
/// — the queue was one of the lists that visibly ignored Appearance → Lists.
/// Both callers read it at build time, so both still agree.
EdgeInsets get _kTileInset => EdgeInsets.symmetric(
    horizontal: 12, vertical: 2 + densityNow.rowVerticalPadding / 2);

class QueueSheet extends ConsumerStatefulWidget {
  /// The DraggableScrollableSheet's controller, when hosted in one.
  ///
  /// This is what makes drag-to-expand work, AND it is easy to get wrong.
  /// A DraggableScrollableSheet only knows the gesture is "scroll the list"
  /// rather than "resize the sheet" because the list it contains is driven by
  /// the controller the sheet handed out. An earlier version wrapped this widget
  /// in a DraggableScrollableSheet but left the list on its OWN controller, so
  /// the sheet never received the scroll notifications and dragging did nothing
  ///, which is why it was replaced by a fixed FractionallySizedBox. Passing the
  /// controller through is the actual fix.
  ///
  /// Null when hosted at a fixed height; the sheet then owns a private
  /// controller (and is responsible for disposing it. See [dispose]).
  final ScrollController? scrollController;

  /// The host DraggableScrollableSheet's extent controller, if any.
  ///
  /// Needed because the HEADER is not part of the scrollable, so the sheet's
  /// built-in gesture handling cannot see drags that start on it. Without this
  /// the header is a dead zone: it cannot pull the sheet up, and its old
  /// drag-down handler dismissed the whole sheet on the first 12px rather than
  /// collapsing it.
  final DraggableScrollableController? sheetController;

  /// The height the sheet opens at, and the middle snap point.
  static const double collapsedSize = 0.62;

  /// Drag below this and releasing dismisses instead of snapping back.
  static const double minSize = 0.4;

  const QueueSheet({super.key, this.scrollController, this.sheetController});

  @override
  ConsumerState<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<QueueSheet> {
  Timer? _undoTimer;
  /// Only non-null when NOBODY passed a controller in. Disposing a controller
  /// owned by the host DraggableScrollableSheet would tear down a scrollable
  /// that outlives this widget.
  ScrollController? _ownedController;
  bool _hasScrolledToCurrent = false;
  // One-shot guard: drag events keep arriving during the sheet's exit
  // animation — a second pop here would dismiss the PLAYER underneath too.
  bool _dismissing = false;

  ScrollController get _scrollController =>
      widget.scrollController ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _undoTimer?.cancel();
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentSong   = ref.watch(playerProvider.select((ps) => ps.currentSong));
    final userQueue     = ref.watch(playerProvider.select((ps) => ps.userQueue));
    final contextQueue  = ref.watch(playerProvider.select((ps) => ps.contextQueue));
    final autoplayQueue = ref.watch(playerProvider.select((ps) => ps.autoplayQueue));
    final queue         = ref.watch(playerProvider.select((ps) => ps.queue));
    final isShuffle     = ref.watch(playerProvider.select((ps) => ps.isShuffle));
    final history       = ref.watch(playerProvider.select((ps) => ps.history));
    final contextTitle  = ref.watch(playerProvider.select((ps) => ps.contextTitle));
    final isPlaying     = ref.watch(playerProvider.select((ps) => ps.isPlaying));

    final notifier = ref.read(playerProvider.notifier);
    final themeColor = ref.watch(themeProvider);
    final lastRemoved = ref.watch(lastRemovedItemProvider);

    ref.listen(lastRemovedItemProvider, (previous, next) {
      _undoTimer?.cancel();
      if (next != null) {
        _undoTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            ref.read(lastRemovedItemProvider.notifier).state = null;
          }
        });
      }
    });

    final List<Map<String, dynamic>> displayItems = [];
    int upcomingCount = 0;
    if (currentSong != null) {
      final currentId = currentSong.id;

      // History (Deduplicated, older first)
      final seenIds = <String>{currentId};
      final distinctHistory = <Song>[];
      for (final song in history) {
        if (!seenIds.contains(song.id)) {
          seenIds.add(song.id);
          distinctHistory.add(song);
        }
      }

      final historyItems = distinctHistory.take(15).toList().reversed.toList();
      if (historyItems.isNotEmpty) {
        displayItems.add({'item': "Recently Played", 'realIdx': -1, 'zone': 'header'});
        for (final song in historyItems) {
          displayItems.add({'item': song, 'realIdx': -2, 'zone': 'history'});
        }
      }

      // ── Current track — ALWAYS shown (it used to hide when history was
      // empty, so a fresh session's queue sheet had no "Now Playing" row). ──
      displayItems.add({'item': "Now Playing", 'realIdx': -1, 'zone': 'header'});
      displayItems.add({'item': currentSong, 'realIdx': -3, 'zone': 'current'});

      // Upcoming
      final safeUser    = userQueue.where((s) => s.id != currentId).toList();
      final safeContext = contextQueue.where((s) => s.id != currentId).toList();
      final safeAuto    = autoplayQueue.where((s) => s.id != currentId).toList();
      upcomingCount = safeUser.length + safeContext.length + safeAuto.length;

      if (safeUser.isNotEmpty) {
        displayItems.add({'item': "Next in Queue", 'realIdx': -1, 'zone': 'header'});
        for (final s in safeUser) {
          displayItems.add({'item': s, 'realIdx': queue.indexOf(s), 'zone': 'upcoming'});
        }
      }
      if (safeContext.isNotEmpty) {
        displayItems.add({'item': contextTitle ?? "Playing From", 'realIdx': -1, 'zone': 'header'});
        for (final s in safeContext) {
          displayItems.add({'item': s, 'realIdx': queue.indexOf(s), 'zone': 'upcoming'});
        }
      }
      if (safeAuto.isNotEmpty) {
        displayItems.add({'item': "Autoplay", 'realIdx': -1, 'zone': 'header'});
        for (final s in safeAuto) {
          displayItems.add({'item': s, 'realIdx': queue.indexOf(s), 'zone': 'upcoming'});
        }
      }
    }

    // Auto-Scroll to Current Song
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasScrolledToCurrent && _scrollController.hasClients) {
        double offset = 0;
        for (var item in displayItems) {
          if (item['zone'] == 'current') break;
          offset += item['zone'] == 'header' ? _kHeaderHeight : _kTileHeight;
        }
        // Land with the current track's header just below the sheet header.
        offset = (offset - _kHeaderHeight).clamp(0.0, double.infinity);
        if (offset > 0 && _scrollController.position.maxScrollExtent > 0) {
          _scrollController.jumpTo(
              offset.clamp(0.0, _scrollController.position.maxScrollExtent));
        }
        _hasScrolledToCurrent = true;
      }
    });

    // The sheet clips EVERYTHING (backdrop included) to its rounded top —
    // DynamicBackground paints a full-bleed square backdrop, and unclipped its
    // corners poked out past the rounded sheet as a dark "block" at the top.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(_kSheetRadius)),
      child: DynamicBackground(
        // Floats above a page, so it must paint its own backdrop rather than
        // pass through to the page behind it.
        force: true,
        child: Container(
          // Single flat tint keeps text readable over the blurred artwork —
          // no BackdropFilter here (see DynamicBackground for why).
          color: Colors.black.withOpacity(0.65),
          child: Column(
            children: [
              _buildHeader(context, ref, upcomingCount, isShuffle, themeColor, lastRemoved),
              Divider(height: 1, thickness: 1, color: Colors.white.withOpacity(0.06)),
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: _scrollController,
                  padding: const EdgeInsets.only(bottom: 120, top: 4),
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) =>
                      _buildProxyDecorator(child, index, animation, themeColor),

                  //"NOW PLAYING" IS A FLOOR, NOT A ROW YOU CAN CROSS.
                  //
                  // Recently Played, the Now Playing header, the current track
                  // and the section dividers are all FIXED: none of them can be
                  // dragged (no handle), and nothing can be dropped above them.
                  // Drag a track up from the bottom of the queue and it stops at
                  // the top of what is still upcoming — it becomes the next track
                  // to play — instead of being filed into history or on top of the
                  // song currently playing, neither of which means anything.
                  //
                  // IT ALSO FIXES A NEGATIVE INDEX REACHING THE QUEUE. Rows
                  // carry sentinel realIdx values: −1 header, −2 history, −3
                  // current. The old code special-cased ONLY −1, so dropping onto
                  // a history row or the current track passed −2 / −3 straight
                  // through as the destination and called reorderQueue() with a
                  // negative index. Every target below is a real queue position,
                  // because only realIdx >= 0 is ever considered.
                  onReorder: (oldIdx, newIdx) {
                    final int fromIdx = displayItems[oldIdx]['realIdx'] as int;
                    // Fixed rows aren't draggable, so this is belt-and-braces.
                    if (fromIdx < 0) return;

                    // The first still-upcoming row — the floor for any move.
                    int firstUpcoming = queue.length;
                    for (final d in displayItems) {
                      final r = d['realIdx'] as int;
                      if (r >= 0) {
                        firstUpcoming = r;
                        break;
                      }
                    }

                    // Resolve the drop position to a real queue index by scanning
                    // FORWARD past any fixed row. Falling off the end means "last".
                    int targetIdx = queue.length;
                    for (int i = newIdx; i < displayItems.length; i++) {
                      final r = displayItems[i]['realIdx'] as int;
                      if (r >= 0) {
                        targetIdx = r;
                        break;
                      }
                    }

                    // Dropped into the played / now-playing region: attach to the
                    // top of the upcoming list.
                    if (targetIdx < firstUpcoming) targetIdx = firstUpcoming;

                    if (fromIdx != targetIdx) {
                      // A listener is editing the SHARED queue, so it goes to the
                      // host — by TRACK, not by index: the mirror is a bounded,
                      // current-first view of the host's full queue, so the same
                      // number means a different song on each device.
                      final moved = queue[fromIdx];
                      // The track it should land after: the row above the drop
                      // point, or null when it goes to the very top.
                      // The track currently sitting at the destination; null
                      // means "past the end". The host resolves it in its own
                      // queue, so a downward drag needs no ±1 correction here.
                      final dest = (targetIdx >= 0 && targetIdx < queue.length)
                          ? queue[targetIdx]
                          : null;
                      if (!ref
                          .read(listenTogetherProvider.notifier)
                          .requestQueueMove(moved, dest)) {
                        notifier.reorderQueue(fromIdx, targetIdx);
                      }
                    }
                  },

                  itemCount: displayItems.length,
                  itemBuilder: (context, index) {
                    final data    = displayItems[index];
                    final item    = data['item'];
                    final int realIdx = data['realIdx'] as int;
                    final String zone = data['zone'] as String? ?? 'upcoming';

                    if (item is String) {
                      // The per-section Autoplay ↻ was removed — the persistent
                      // refresh in the sheet HEADER (beside shuffle) replaces it,
                      // so there's no duplicate and it works even when empty.
                      return _buildSectionHeader(item, themeColor,
                          key: ValueKey('header_${item}_$index'),
                          highlight: item == "Now Playing");
                    }

                    final song = item as Song;
                    final bool isCurrent = zone == 'current';
                    final bool isHistory = zone == 'history';

                    // Non-draggable items (history, current)
                    if (realIdx < 0) {
                      final tile = _buildTrackTile(
                        song: song,
                        themeColor: themeColor,
                        isCurrent: isCurrent,
                        isHistory: isHistory,
                        isPlaying: isPlaying,
                        onTap: isCurrent
                            ? null
                            : () {
                                if (ref
                                    .read(listenTogetherProvider.notifier)
                                    .requestPlayTrack(song)) {
                                  return;
                                }
                                notifier.playSong(song, source: "Queue");
                              },
                      );
                      // HISTORY rows are swipeable: → View Album, ← re-Queue (add
                      // the already-played track back to the queue). The CURRENT
                      // track stays non-swipeable. buildDefaultDragHandles is
                      // false, so a Dismissible here is naturally NOT draggable.
                      if (isHistory) {
                        Widget swipeBg(Alignment a, IconData ic, Color c, String label) =>
                            Container(
                              color: c.withOpacity(0.15),
                              alignment: a,
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(ic, color: c, size: 22),
                                const SizedBox(width: 8),
                                Text(label,
                                    style: TextStyle(
                                        color: c, fontWeight: FontWeight.w700, fontSize: 13)),
                              ]),
                            );
                        return Dismissible(
                          key: ValueKey('hist_${song.id}_$index'),
                          direction: DismissDirection.horizontal,
                          confirmDismiss: (dir) async {
                            if (dir == DismissDirection.startToEnd) {
                              // → View Album (same as the upcoming tile).
                              HapticService.light();
                              final album = ContentMenus.buildAlbumForSong(song);
                              final rootNav = Navigator.of(context, rootNavigator: true);
                              Navigator.pop(context);
                              if (AppNavigation.isPlayerOpen) {
                                rootNav.popUntil((route) =>
                                    route.settings.name != AppNavigation.playerRouteName);
                              }
                              AppNavigation.pushOnActiveTab(
                                AlbumPage(
                                    album: album,
                                    artistName: song.artist,
                                    fallbackTrack: song),
                                name: AppNavigation.albumTag(album),
                              );
                            } else {
                              // ← re-Queue the played track.
                              HapticService.medium();
                              // A played track re-queued from history is a SHARED queue edit; done
                              // locally it landed in a queue nobody else had.
                              final lt = ref.read(listenTogetherProvider.notifier);
                              final added = lt.requestQueueAdd(song)
                                  ? true
                                  : notifier.toggleQueue(song);
                              AnimatedToast.show(context,
                                  text: added ? "Added to queue" : "Removed from queue",
                                  icon: added
                                      ? Icons.queue_music
                                      : Icons.remove_circle_outline,
                                  color: themeColor);
                            }
                            return false; // never actually dismiss a history row
                          },
                          background: swipeBg(Alignment.centerLeft,
                              Icons.album_rounded, themeColor, "View Album"),
                          secondaryBackground: swipeBg(Alignment.centerRight,
                              Icons.queue_music_rounded, const Color(0xFFFFD740), "Queue"),
                          child: tile,
                        );
                      }
                      return ReorderableDragStartListener(
                        key: ValueKey('${zone}_${song.id}_$index'),
                        index: index,
                        enabled: false,
                        child: tile,
                      );
                    }

                    // Draggable upcoming items
                    return _QueueItemTile(
                      key: ValueKey('queued_${song.id}_${song.hashCode}'),
                      index: realIdx,
                      displayIndex: index,
                      song: song,
                      themeColor: themeColor,
                    );
                  },
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrackTile({
    required Song song,
    required Color themeColor,
    required bool isCurrent,
    required bool isHistory,
    required bool isPlaying,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      height: _kTileHeight,
      child: Padding(
        // The SAME inset the drag highlight uses. See _kTileInset.
        padding: _kTileInset,
        child: Material(
          color: isCurrent ? themeColor.withOpacity(0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  // Scaled with density: padding alone cannot shorten a row whose
                  // cover is taller than the space you are trying to save.
                  SizedBox(
                    width: densityNow.artwork(44),
                    height: densityNow.artwork(44),
                    child: Stack(children: [
                      AuvyImage(
                          path: song.image,
                          width: densityNow.artwork(44),
                          height: densityNow.artwork(44),
                          borderRadius: 9),
                      if (isCurrent)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.45),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Center(
                              child: isPlaying
                                  ? const _AnimatedEqualizer()
                                  : Icon(Icons.pause_rounded, color: themeColor, size: 20),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(song.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent
                                  ? themeColor
                                  : Colors.white.withOpacity(isHistory ? 0.60 : 0.95),
                              fontSize: 15,
                              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                            )),
                        SizedBox(height: densityNow.lineGap),
                        Row(
                          children: [
                            // Marks a row SMART SHUFFLE added, not one the user
                            // queued. Without it the two are indistinguishable, so
                            // an unfamiliar track reads as a bug rather than as a
                            // suggestion, which is why Spotify badges its own
                            // Smart Shuffle insertions.
                            Consumer(builder: (context, ref, _) {
                              final injected = ref.watch(
                                  smartShuffleInjectedProvider
                                      .select((s) => s.contains(song.id)));
                              if (!injected) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(Icons.auto_awesome_rounded,
                                    size: 12,
                                    color: themeColor.withOpacity(
                                        isHistory ? 0.45 : 0.85)),
                              );
                            }),
                            Flexible(
                              child: ExplicitArtistLine(
                                  isExplicit: song.isExplicit == true,
                                  text: song.displayArtist,
                                  badgeSize: 12,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(isHistory ? 0.35 : 0.5),
                                      fontSize: 12.5)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isHistory)
                    Icon(Icons.history_rounded, size: 15, color: Colors.white.withOpacity(0.25)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, int upcomingCount,
      bool isShuffle, Color themeColor, RemovedQueueItem? lastRemoved) {
    final showUndo = lastRemoved != null &&
        DateTime.now().difference(lastRemoved.timestamp).inSeconds < 3;
    final isSmartShuffle = ref.watch(smartShuffleModeProvider);

    // Dragging the header RESIZES the sheet, and only dismisses if you pull it
    // well down. The header sits outside the scrollable, so the host
    // DraggableScrollableSheet cannot see these drags on its own — without the
    // handoff below the header could not pull the sheet up at all, and its old
    // handler popped the whole sheet on the first 12px of downward movement.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        final sheet = widget.sheetController;
        if (sheet == null) {
          // Fixed-height host (no draggable sheet): keep the old behaviour.
          if (!_dismissing && (details.primaryDelta ?? 0) > 12) {
            _dismissing = true;
            Navigator.pop(context);
          }
          return;
        }
        if (_dismissing || !sheet.isAttached) return;
        // Extent is a FRACTION of screen height, so convert the pixel delta.
        // Upward drag is a negative delta and should grow the sheet.
        final h = MediaQuery.of(context).size.height;
        if (h <= 0) return;
        final next = sheet.size - ((details.primaryDelta ?? 0) / h);
        // Allowed a little below minSize so a downward pull feels continuous
        // rather than hitting a wall before the dismiss threshold.
        sheet.jumpTo(next.clamp(QueueSheet.minSize * 0.75, 1.0));
      },
      onVerticalDragEnd: (details) {
        final sheet = widget.sheetController;
        if (sheet == null || _dismissing || !sheet.isAttached) return;
        final size = sheet.size;
        // A firm downward flick dismisses regardless of where it ended, which is
        // how a sheet is normally thrown away.
        final flungDown = (details.primaryVelocity ?? 0) > 700;
        if (flungDown || size < QueueSheet.minSize) {
          _dismissing = true;
          Navigator.pop(context);
          return;
        }
        // Otherwise settle on whichever of the two useful heights is closer.
        final target =
            (size - QueueSheet.collapsedSize).abs() < (size - 1.0).abs()
                ? QueueSheet.collapsedSize
                : 1.0;
        sheet.animateTo(target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
        child: Column(
          children: [
            // Tapping the grabber toggles collapsed ↔ full. Cheap discoverable
            // shortcut for the drag, and the only way to expand the sheet
            // without a gesture. The hit target is padded well past the 4px bar
            // so it is actually reachable.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final sheet = widget.sheetController;
                if (sheet == null || !sheet.isAttached) return;
                HapticService.light();
                final expanded = sheet.size > (QueueSheet.collapsedSize + 1.0) / 2;
                sheet.animateTo(
                  expanded ? QueueSheet.collapsedSize : 1.0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 40),
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.22),
                      borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Queue",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4)),
                      const SizedBox(height: 2),
                      Text(
                        upcomingCount == 1 ? "1 track up next" : "$upcomingCount tracks up next",
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: showUndo
                      ? Padding(
                          key: const ValueKey('undo_button'),
                          padding: const EdgeInsets.only(right: 8),
                          child: _HeaderPill(
                            icon: Icons.undo_rounded,
                            label: "Undo",
                            color: themeColor,
                            filled: true,
                            onTap: () {
                              HapticService.light();
                              // A listener's undo puts the track back into the SHARED queue: undoing
                              // locally would restore it on this device only, and the next mirror
                              // would take it straight back out again.
                              final lt = ref.read(listenTogetherProvider.notifier);
                              if (lt.requestQueueAdd(lastRemoved.song, playNext: true)) {
                                ref.read(lastRemovedItemProvider.notifier).state = null;
                              } else {
                                ref.read(playerProvider.notifier).undoRemoveFromQueue();
                              }
                            },
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('no_undo')),
                ),
                // Shuffle cycles: off → shuffle → smart shuffle.
                _HeaderIcon(
                  icon: isSmartShuffle ? Icons.auto_awesome_rounded : Icons.shuffle_rounded,
                  active: isShuffle || isSmartShuffle,
                  activeColor: themeColor,
                  onTap: () {
                    HapticService.light();
                    ref.read(playerProvider.notifier).cycleShuffleMode();
                  },
                ),
                const SizedBox(width: 6),
                // ALWAYS-available radio top-up: regenerate autoplay from the
                // current track even after the queue was fully cleared (the
                // per-section ↻ disappears with the Autoplay section, leaving no
                // way to reload from here). Highlights while a refresh is running.
                Consumer(builder: (context, ref, _) {
                  final refreshing = ref.watch(autoplayRefreshingProvider);
                  return _HeaderIcon(
                    icon: Icons.refresh_rounded,
                    active: false,
                    busy: refreshing,
                    activeColor: themeColor,
                    onTap: () async {
                      if (refreshing) return;
                      HapticService.medium();
                      // Awaited AND confirmed, because it looked broken.
                      //
                      // This was fire-and-forget. The refresh works — the log
                      // shows it repopulating 15 tracks on every press, but it
                      // finishes in ~20ms on a warm radio cache, so the spinner
                      // flashes for a frame, and the new tracks are appended
                      // AFTER the context queue (62 entries in the reported case)
                      // where they are far off screen. Nothing observable changed,
                      // so it read as a dead button and got pressed four times in
                      // fourteen seconds.
                      //
                      // Saying what happened is the fix: the work was never the
                      // problem, the silence was.
                      final before = ref.read(playerProvider).autoplayQueue.length;
                      // Refreshing locally regenerated this device's suggestions only, and the
                      // host's next mirror overwrote them — refresh appeared to work for the
                      // host and do nothing for a listener.
                      if (!ref.read(listenTogetherProvider.notifier).requestQueueRefresh()) {
                        await ref.read(playerProvider.notifier).refreshAutoplay();
                      }
                      if (!context.mounted) return;
                      final added =
                          ref.read(playerProvider).autoplayQueue.length;
                      AnimatedToast.show(
                        context,
                        text: added > 0
                            ? 'Queued $added more like this'
                            : (before > 0
                                ? 'Nothing new found right now'
                                : 'Could not reach YouTube Music'),
                        icon: added > 0
                            ? Icons.playlist_add_check_rounded
                            : Icons.refresh_rounded,
                        color: added > 0 ? themeColor : Colors.orange,
                      );
                    },
                  );
                }),
                if (upcomingCount > 0) ...[
                  const SizedBox(width: 6),
                  _HeaderPill(
                    icon: Icons.clear_all_rounded,
                    label: "Clear",
                    color: Colors.white70,
                    onTap: () {
                      HapticService.medium();
                      if (!ref.read(listenTogetherProvider.notifier).requestQueueClear()) {
                        ref.read(playerProvider.notifier).clearAllQueue();
                      }
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String label, Color themeColor,
      {Key? key, bool highlight = false, Widget? trailing}) {
    return Container(
      key: key,
      height: _kHeaderHeight,
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                color: highlight ? themeColor : Colors.white.withOpacity(0.66),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              )),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: Colors.white.withOpacity(0.06), height: 1)),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
        ],
      ),
    );
  }

  /// The lifted-tile look while reordering.
  ///
  /// It must be drawn at the tile's own inset, under the tile.
  ///
  /// A queue row is a 64px SizedBox whose visible card is inset
  /// `horizontal: 12, vertical: 2` at radius 14 (see [_buildTrackTile]). The old
  /// decorator wrapped the row and painted its highlight on the OUTER bounds, so
  /// the panel ran 12px wider on each side than the card it was meant to
  /// highlight and its corners curved on a different line — the "misaligned /
  /// misformed" look. `Transform.scale(1.03)` then inflated it further, past the
  /// list's own padding.
  ///
  /// So: the same inset and the same radius, painted BEHIND the row via a Stack.
  /// Wrapping the child in another Padding would have shifted the row inward by a
  /// further 12px the moment you lifted it, which reads as a jump.
  Widget _buildProxyDecorator(
      Widget child, int index, Animation<double> animation, Color themeColor) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, animChild) {
        final t = Curves.easeOut.transform(animation.value);
        return Transform.scale(
          // Deliberately small. At 1.02 a ~360px row grows ~3.6px per side,
          // which stays INSIDE the 12px inset, so the lifted card still cannot
          // touch the sheet edge.
          scale: 1 + (0.02 * t),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: _kTileInset,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      // Top-lit: brighter along the top edge, so the card reads
                      // as physically picked up rather than just tinted.
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          themeColor.withOpacity(0.20 * t),
                          themeColor.withOpacity(0.10 * t),
                        ],
                      ),
                      border: Border.all(
                        color: themeColor.withOpacity(0.45 * t),
                        width: 1,
                      ),
                      boxShadow: [
                        // Depth.
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45 * t),
                          blurRadius: 20 * t,
                          offset: Offset(0, 7 * t),
                        ),
                        // Accent bloom, matching the player's other lifted
                        // surfaces. Negative spread keeps it a glow behind the
                        // card rather than a halo around the whole row.
                        BoxShadow(
                          color: themeColor.withOpacity(0.22 * t),
                          blurRadius: 26 * t,
                          spreadRadius: -8,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              animChild!,
            ],
          ),
        );
      },
      child: child,
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  /// Replace the glyph with a spinner and stop responding to taps.
  ///
  /// A TINT ALONE WAS NOT READABLE AS "WORKING". The refresh button passed
  /// `active: refreshing`, which only shifted the circle's fill, and since the
  /// work can finish in ~20ms, that shift came and went inside one frame. The
  /// button looked inert, so it got pressed again and again. A spinner is
  /// unmistakable, and refreshAutoplay now holds its busy flag long enough
  /// (550ms floor) for this to actually be seen.
  final bool busy;

  const _HeaderIcon({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final lit = active || busy;
    return GestureDetector(
      // Swallow taps while busy so a second press cannot re-enter the work. The
      // caller also guards, but the button should not even look tappable here.
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: lit ? activeColor.withOpacity(0.18) : Colors.white.withOpacity(0.07),
          shape: BoxShape.circle,
          // A ring while busy, so the state reads even at a glance on a dark sheet.
          border: busy
              ? Border.all(color: activeColor.withOpacity(0.55), width: 1.2)
              : null,
        ),
        child: busy
            ? Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: activeColor),
                ),
              )
            : Icon(icon, size: 19, color: lit ? activeColor : Colors.white70),
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  final VoidCallback onTap;
  const _HeaderPill({required this.icon, required this.label, required this.color, this.filled = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: filled ? color.withOpacity(0.16) : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: filled ? color : Colors.white70),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: filled ? color : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _QueueItemTile extends ConsumerWidget {
  final int index;
  final int displayIndex;
  final Song song;
  final Color themeColor;

  const _QueueItemTile({super.key, required this.index, required this.displayIndex, required this.song, required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheManager = AudioCacheManager();
    final isDownloaded = cacheManager.isExplicitlyDownloaded(song.id);
    // Show the audio cover + clean title for un-played video rows in the queue.
    final display = conformedForDisplay(ref, song);

    return SizedBox(
      height: _kTileHeight,
      child: Dismissible(
        key: ValueKey('dismiss_${song.id}_$displayIndex'),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            HapticService.light();
            // Shared album resolution — handles missing/blank albumId by
            // resolving the album by NAME (or opening as a single).
            final album = ContentMenus.buildAlbumForSong(song);

            final rootNav = Navigator.of(context, rootNavigator: true);
            Navigator.pop(context); // close the queue sheet
            if (AppNavigation.isPlayerOpen) {
              // Close the PlayerPage (and ONLY it) when it's actually open.
              rootNav.popUntil((route) =>
                  route.settings.name != AppNavigation.playerRouteName);
            }

            AppNavigation.pushOnActiveTab(
              AlbumPage(album: album, artistName: song.artist, fallbackTrack: song),
              name: AppNavigation.albumTag(album),
            );
            return false;
          }
          return true;
        },
        onDismissed: (_) {
          HapticService.medium();
          if (!ref
              .read(listenTogetherProvider.notifier)
              .requestQueueRemove(song)) {
            ref.read(playerProvider.notifier).removeFromQueue(index);
          }
        },
        background: _buildSwipeAction(Alignment.centerLeft, Icons.album_rounded, themeColor, "View Album"),
        secondaryBackground: _buildSwipeAction(Alignment.centerRight, Icons.delete_outline_rounded, Colors.redAccent, "Remove"),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: () {
                if (ref
                    .read(listenTogetherProvider.notifier)
                    .requestQueueJump(song)) {
                  return;
                }
                ref.read(playerProvider.notifier).jumpToQueueIndex(index);
              },
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    AuvyImage(path: display.image, width: 44, height: 44, borderRadius: 9),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(display.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.95),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (isDownloaded) ...[
                                Icon(Icons.download_done_rounded, size: 13, color: themeColor.withOpacity(0.7)),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(song.displayArtist,
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // A generous grab target so reordering is easy.
                    ReorderableDragStartListener(
                      index: displayIndex,
                      child: Container(
                        width: 40, height: 56,
                        alignment: Alignment.center,
                        color: Colors.transparent,
                        child: Icon(Icons.drag_handle_rounded,
                            color: Colors.white.withOpacity(0.3), size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeAction(Alignment alignment, IconData icon, Color color, String label) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignment,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _AnimatedEqualizer extends ConsumerStatefulWidget {
  const _AnimatedEqualizer();

  @override
  ConsumerState<_AnimatedEqualizer> createState() => _AnimatedEqualizerState();
}

class _AnimatedEqualizerState extends ConsumerState<_AnimatedEqualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500)
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHype = ref.watch(hypeModeProvider);
    final themeColor = ref.watch(themeProvider);

    // RepaintBoundary: these bars animate at 60fps the whole time the sheet is
    // open — contain the repaint to just the bars.
    return RepaintBoundary(
      child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            double value = (i == 1) ? _controller.value : (1 - _controller.value);

            final Color barColor = isHype
              ? HSVColor.fromAHSV(
                  1.0,
                  (DateTime.now().millisecondsSinceEpoch / 10) % 360,
                  1.0,
                  1.0
                ).toColor()
              : themeColor;

            return Container(
              width: 3.5,
              height: 6 + (value * 12),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(2)
              ),
            );
          },
        );
      }),
      ),
    );
  }
}
