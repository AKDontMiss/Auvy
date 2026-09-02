import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/item_transfer_overlay.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// "Add to playlist" — ONE implementation for the whole app.
///
/// There used to be FIVE: `content_menus`, `player_menu_sheet`, and the
/// swipe-left action on each of search / album / artist pages each built their
/// own. They had drifted apart in every visible way — different titles, artwork
/// sizes, subtitles, some reported duplicates and some silently swallowed them,
/// and only two of the five offered "create a new playlist" at all. Reaching the
/// same feature by a different route gave you a different dialog, which is what
/// made it feel unfinished.
///
/// What this adds over all of them:
///  • The TRACK is in the header. Every old version said only "Add to Playlist",
///    so after a swipe you had to remember which row you swiped.
///  • "New playlist" is the first row, so the empty-library case is no longer a
///    dead end reading "No custom playlists yet."
///  • Playlists that ALREADY hold this track are marked and inert, instead of
///    being tapped and answering "Already in X".
///  • A filter appears once there are enough playlists to need one.
///
/// [toastOrigin] is the tap/swipe position, so the confirmation toast animates
/// out of the row the user actually touched.
void showAddToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  Song song,
  Color themeColor, {
  Offset? toastOrigin,
}) {
  showModalBottomSheet(
    context: context,
    // Root navigator: tab-level sheets render UNDER the mini-player overlay in
    // MainLayout's stack, so the bar covered the sheet's bottom rows.
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _AddToPlaylistSheet(
      song: song,
      themeColor: themeColor,
      toastOrigin: toastOrigin,
    ),
  );
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  final Song song;
  final Color themeColor;
  final Offset? toastOrigin;

  const _AddToPlaylistSheet({
    required this.song,
    required this.themeColor,
    this.toastOrigin,
  });

  @override
  ConsumerState<_AddToPlaylistSheet> createState() =>
      _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  final TextEditingController _filter = TextEditingController();
  String _query = '';

  /// Below this many playlists a filter field costs more height than the
  /// scanning it saves.
  static const int _filterThreshold = 7;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Same signature `addSongToPlaylist` dedupes on (id OR title+artist), so the
  /// tick shown here matches exactly what a tap would do.
  bool _contains(List<Song> songs, Song song) {
    final sig =
        '${song.title.toLowerCase().trim()}|${song.artist.toLowerCase().trim()}';
    return songs.any((s) =>
        s.id == song.id ||
        '${s.title.toLowerCase().trim()}|${s.artist.toLowerCase().trim()}' ==
            sig);
  }

  void _add(String playlistTitle) {
    HapticService.selection();
    final added =
        ref.read(libraryProvider.notifier).addSongToPlaylist(playlistTitle, widget.song);
    // BEFORE the pop: the root overlay outlives this sheet, but its context does
    // not. Only on a real add — a duplicate did not go anywhere.
    if (added) {
      ItemTransferOverlay.toLibrary(context,
          imageUrl: widget.song.image,
          accent: widget.themeColor,
          origin: widget.toastOrigin);
    }
    Navigator.pop(context);
    AnimatedToast.show(
      context,
      text: added ? 'Added to $playlistTitle' : 'Already in $playlistTitle',
      icon: added ? Icons.playlist_add_check_rounded : Icons.info_outline,
      color: widget.themeColor,
      startOffset: widget.toastOrigin,
    );
  }

  Future<void> _createAndAdd() async {
    HapticService.selection();
    final name = await _askForName();
    if (name == null || name.trim().isEmpty) return;
    final title = name.trim();
    final notifier = ref.read(libraryProvider.notifier);
    notifier.addPlaylist(title);
    notifier.addSongToPlaylist(title, widget.song);
    if (!mounted) return;
    ItemTransferOverlay.toLibrary(context,
        imageUrl: widget.song.image,
        accent: widget.themeColor,
        origin: widget.toastOrigin);
    Navigator.pop(context);
    AnimatedToast.show(
      context,
      text: 'Created $title',
      icon: Icons.playlist_add_check_rounded,
      color: widget.themeColor,
      startOffset: widget.toastOrigin,
    );
  }

  Future<String?> _askForName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (dctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('New playlist',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          cursorColor: widget.themeColor,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(dctx, v),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: Text('Create',
                style: TextStyle(
                    color: widget.themeColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      // Disposed after the fade-out — disposing while the dialog is still
      // animating away throws "used after disposed".
    ).whenComplete(() => Future.delayed(
        const Duration(milliseconds: 600), controller.dispose));
  }

  @override
  Widget build(BuildContext context) {
    // watch, not read: creating a playlist from inside this sheet must make it
    // appear in the list underneath.
    final library = ref.watch(libraryProvider);
    final all = library.allItems
        .where((i) =>
            !i.isSystemFolder && i.category == LibraryCategory.playlist)
        .toList();
    final q = _query.trim().toLowerCase();
    final playlists = q.isEmpty
        ? all
        : all.where((p) => p.title.toLowerCase().contains(q)).toList();
    final showFilter = all.length >= _filterThreshold;

    // TWO THINGS WENT WRONG WHEN TYPING IN THE FILTER.
    //
    // 1. THE SHEET RESIZED ON EVERY KEYSTROKE. The Column below is
    //    mainAxisSize.min around a shrinkWrap ListView, so its height was the
    //    height of its CONTENT. Filtering 22 playlists down to two matches
    //    shrank the list, which shrank the Column, which shrank the sheet, so
    //    the whole panel slid down the screen as you typed and took the results
    //    with it.
    //
    //    Once a filter field is on screen the box is pinned to a height that
    //    depends on the keyboard alone, never on how many playlists currently
    //    match. Below the filter threshold there is nothing to type into, so
    //    those sheets stay content-sized rather than gaining dead space.
    //
    // 2. THE RESULTS SAT BEHIND THE KEYBOARD. A modal bottom sheet is anchored
    //    to the bottom of the SCREEN and Flutter does not move it out of the
    //    keyboard's way, so shortening it achieved nothing on its own: you
    //    could see the field you were typing into and not the list you were
    //    filtering. The bottom margin lifts it clear. viewInsets.bottom is the
    //    keyboard height and updates every frame while it animates, so the
    //    sheet rides up with it instead of jumping when it lands.
    //
    // The height is measured against what is left ABOVE the keyboard so that
    // sheet plus keyboard fits the screen rather than overflowing it.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final ceiling = media.size.height * 0.7;
    final usable = media.size.height - keyboard - 24;
    final pinned = ceiling < usable ? ceiling : usable;

    return Container(
      margin: EdgeInsets.only(bottom: keyboard),
      height: showFilter ? pinned : null,
      constraints: BoxConstraints(maxHeight: ceiling),
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grabber and header stay OUTSIDE the scroll view, so a downward drag
          // on either dismisses the sheet instead of being eaten as a scroll
          // overscroll. (Same reason the track menu has no scroll view at all —
          // a Scrollable outranks the sheet's own drag recogniser.)
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 14),
            child: _Grabber(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                AuvyImage(
                    path: widget.song.image,
                    width: 44,
                    height: 44,
                    borderRadius: 9),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('ADD TO PLAYLIST',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.66),
                              fontSize: 10,
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(widget.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (showFilter)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: AuvySearchField(
                controller: _filter,
                hint: 'Find a playlist',
                height: 40,
                radius: 12,
                fontSize: 13.5,
                iconSize: 18,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),

          // New playlist FIRST — it is the answer when nothing in the list fits,
          // and it makes an empty library actionable rather than a dead end.
          _Row(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: widget.themeColor.withOpacity(0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.add_rounded, color: widget.themeColor, size: 24),
            ),
            title: 'New playlist',
            subtitle: 'Start one with this track',
            titleColor: widget.themeColor,
            onTap: _createAndAdd,
          ),

          Divider(
              color: Colors.white.withOpacity(0.06),
              height: 10,
              indent: 20,
              endIndent: 20),

          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 26),
              child: Text(
                q.isEmpty
                    ? 'No playlists yet — create one above.'
                    : 'No playlist matches “$_query”.',
                style: TextStyle(color: Colors.white.withOpacity(0.66)),
                textAlign: TextAlign.center,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                // Only needed while the sheet is content-sized. Inside a pinned
                // box the list already has a bounded height, so measuring every
                // child to work out a height it has been handed is wasted work.
                shrinkWrap: !showFilter,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 12),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final p = playlists[index];
                  final songs = library.playlistSongs[p.title] ?? const <Song>[];
                  final already = _contains(songs, widget.song);
                  return _Row(
                    leading: AuvyImage(
                        path: p.image, width: 44, height: 44, borderRadius: 9),
                    title: p.title,
                    // The count, not the stored subtitle: stored subtitles go
                    // stale ("Playlist • 6 songs" after a 7th was added).
                    subtitle:
                        songs.length == 1 ? '1 song' : '${songs.length} songs',
                    // Already there → shown as done and inert. Tapping it could
                    // only produce "Already in X", which is a worse answer than
                    // simply showing that it's in.
                    trailing: already
                        ? Icon(Icons.check_circle_rounded,
                            color: widget.themeColor, size: 22)
                        : null,
                    dimmed: already,
                    onTap: already ? null : () => _add(p.title),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Color? titleColor;
  final bool dimmed;
  final VoidCallback? onTap;

  const _Row({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.titleColor,
    this.dimmed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.white.withOpacity(0.04),
        highlightColor: Colors.white.withOpacity(0.03),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: titleColor ?? Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.66),
                            fontSize: 12)),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
