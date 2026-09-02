import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/mood_shelf.dart';
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// YouTube Music's own mood & genre browser ("Chill", "Commute", "Workout",
/// "Focus", "Party", plus every genre).
///
/// Auvy previously had no genre/mood browsing at all — discovery was search or
/// the home feed. This is the real `FEmusic_moods_and_genres` grid, in YouTube's
/// own category colours, and each category opens its curated playlists.
class MoodsPage extends ConsumerStatefulWidget {
  const MoodsPage({super.key});

  @override
  ConsumerState<MoodsPage> createState() => _MoodsPageState();
}

class _MoodsPageState extends ConsumerState<MoodsPage> {
  List<Map<String, dynamic>>? _categories;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cats = await ref.read(searchServiceProvider).getMoodCategories();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _failed = cats.isEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// YouTube ships an ARGB int; darken it slightly so white text stays readable
  /// on the brighter pastels.
  Color _tileColor(Map<String, dynamic> cat, Color fallback) {
    final raw = cat['color'];
    if (raw is! int) return fallback;
    final c = Color(raw);
    return Color.alphaBlend(Colors.black.withOpacity(0.34), c);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final cats = _categories;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('Moods & genres',
              style: TextStyle(
                  color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
        ),
        body: cats == null && !_failed
            ? const Center(
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))
            : _failed
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              size: 44, color: Colors.white.withOpacity(0.25)),
                          const SizedBox(height: 14),
                          Text("Couldn't load categories",
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.78), fontSize: 15)),
                          const SizedBox(height: 14),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _failed = false;
                                _categories = null;
                              });
                              _load();
                            },
                            child: Text('Retry',
                                style: TextStyle(
                                    color: theme, fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2.1,
                    ),
                    itemCount: cats!.length,
                    itemBuilder: (context, i) {
                      final cat = cats[i];
                      final title = cat['title'].toString();
                      return GestureDetector(
                        onTap: () {
                          HapticService.selection();
                          Navigator.push(
                            context,
                            MainLayout.smoothRoute(_MoodCategoryPage(
                              title: title,
                              browseId: cat['browseId'].toString(),
                              params: (cat['params'] ?? '').toString(),
                            )),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: _tileColor(cat, theme.withOpacity(0.35)),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                height: 1.2),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

/// The playlists inside one mood/genre category.
class _MoodCategoryPage extends ConsumerStatefulWidget {
  final String title;
  final String browseId;
  final String params;
  const _MoodCategoryPage(
      {required this.title, required this.browseId, required this.params});

  @override
  ConsumerState<_MoodCategoryPage> createState() => _MoodCategoryPageState();
}


class _MoodCategoryPageState extends ConsumerState<_MoodCategoryPage> {
  List<MoodShelf>? _shelves;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await ref
        .read(searchServiceProvider)
        .getMoodCategoryShelves(widget.browseId, widget.params);
    if (mounted) setState(() => _shelves = s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final shelves = _shelves;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: shelves == null
            ? const Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white24))
            : shelves.isEmpty
                ? Center(
                    child: Text('Nothing here right now',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 15)),
                  )
                : CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      // A large collapsing title instead of a fixed AppBar: the
                      // category name is the subject of the page, so it gets the
                      // weight, and it yields that height back on scroll.
                      SliverAppBar(
                        backgroundColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        elevation: 0,
                        pinned: true,
                        expandedHeight: 132,
                        leading: IconButton(
                          icon: const Icon(Icons.arrow_back_rounded,
                              color: Colors.white),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        flexibleSpace: FlexibleSpaceBar(
                          titlePadding:
                              const EdgeInsets.fromLTRB(20, 0, 20, 15),
                          expandedTitleScale: 1.7,
                          title: Text(widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                      for (final shelf in shelves)
                        ..._shelfSlivers(shelf, theme),
                      const SliverToBoxAdapter(child: SizedBox(height: 140)),
                    ],
                  ),
      ),
    );
  }

  // One shelf: heading + a VERTICAL grid
  //
  // Deliberately NOT a horizontal rail per shelf (what this page used to be, and
  // what Spotify does). Two problems with rails here:
  //
  //  • They hide most of their contents. A shelf of 20 playlists showed about two
  //    and a half, so reaching the rest meant a long horizontal drag — while the
  //    page itself barely scrolled, because three rails filled the screen.
  //    Vertical space is the axis a phone has plenty of, and scrolling is the
  //    gesture people already expect to use.
  //  • Nested horizontal scrollables inside a vertical one turn every diagonal
  //    drag into a gesture-arena coin flip.
  //
  // A grid shows a whole shelf at a glance, scrolls the way the page scrolls, and
  // gives each tile room for a real cover.
  List<Widget> _shelfSlivers(MoodShelf shelf, Color theme) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
          child: Row(
            children: [
              // Short accent bar keyed to the app theme — the same device Auvy
              // uses to mark a section elsewhere, so this reads as part of the
              // app rather than a generic browse screen.
              Container(
                width: 3,
                height: 17,
                decoration: BoxDecoration(
                  color: theme,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(shelf.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2)),
              ),
              Text('${shelf.items.length}',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            // Cover + two text lines. The tile lays out top-down, so slack lands
            // under the text rather than stretching the cover.
            childAspectRatio: 0.74,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _tile(shelf, shelf.items[i], theme),
            childCount: shelf.items.length,
          ),
        ),
      ),
    ];
  }

  /// "TRACK" / "ALBUM" / "PLAYLIST" pill for a mood-shelf tile.
  ///
  /// WHY A DARK BASE AND NOT AN ACCENT-TINTED ONE. These sit on top of cover
  /// art whose brightness is unknown — a mood shelf mixes dark album sleeves with
  /// blown-out photos. A translucent accent fill (the app's pill idiom elsewhere,
  /// where the background is a known dark panel) turns unreadable over a light
  /// cover. So the base stays dark for contrast and the accent carries the theme
  /// through the border and the icon, which keeps it legible over anything.
  ///
  /// The label is spelled out rather than left as an icon alone: an album disc and
  /// a queue glyph at 11px are not reliably distinguishable, and the whole point
  /// is to know what a tap will do before making it.
  Widget _kindBadge(MoodItem item, Color theme) {
    final (IconData icon, String label) = item.isTrack
        ? (Icons.music_note_rounded, 'TRACK')
        : item.isAlbum
            ? (Icons.album_rounded, 'ALBUM')
            : (Icons.queue_music_rounded, 'PLAYLIST');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.withOpacity(0.55), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: theme),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8.8,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _tile(MoodShelf shelf, MoodItem item, Color theme) {
    return GestureDetector(
      onTap: () {
        HapticService.selection();
        if (item.isTrack) {
          // Queue the shelf's OTHER TRACKS behind it — tracks only, so a mixed
          // shelf can never put a playlist tile into the play queue.
          final queue =
              shelf.items.where((e) => e.isTrack).map((e) => e.song!).toList();
          ref.read(playerProvider.notifier).playSong(
                item.song!,
                newQueue: queue,
                index: queue.indexWhere((s) => s.id == item.id),
                source: 'Moods & genres',
                locationName: shelf.title,
              );
        } else {
          // A playlist/album tile OPENS. The old page could not offer this at
          // all: it had already discarded the collections and flattened one of
          // them into loose tracks, so there was nothing left to navigate to.
          Navigator.push(
            context,
            MainLayout.smoothRoute(PlaylistPage(
              externalId: item.id,
              externalTitle: item.title,
              externalImage: item.image,
              externalSubtitle: item.subtitle,
              isAlbumView: item.isAlbum,
            )),
          );
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(
                    width: c.maxWidth,
                    height: c.maxWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.38),
                            blurRadius: 14,
                            offset: const Offset(0, 6)),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)),
                      child: AuvyImage(
                          path: item.image,
                          width: c.maxWidth,
                          height: c.maxWidth,
                          fit: BoxFit.cover),
                    ),
                  ),
                  // Kind badge. See [_kindBadge]. Shown for EVERY tile now,
                  // tracks included: it used to be `if (!item.isTrack)`, which
                  // left the one kind with different tap behaviour as the only
                  // kind with no label on it.
                  Positioned(left: 8, top: 8, child: _kindBadge(item, theme)),
                  // A track PLAYS on tap while a collection OPENS, so tracks get
                  // the universal play affordance as well as the label. Two
                  // signals for the one distinction that changes what happens.
                  if (item.isTrack)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: theme.withOpacity(0.7), width: 1.1),
                        ),
                        child: Icon(Icons.play_arrow_rounded,
                            size: 16, color: theme),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
        ],
      ),
    );
  }
}
