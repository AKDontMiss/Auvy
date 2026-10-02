import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/interactive_pressable.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/services/haptic_service.dart';

/// The pieces the browse hubs (Podcasts, Audiobooks, Live Radio) are built
/// from, so the three read as one design: section titles, horizontal rails of
/// covers, and a grid of category tiles.

/// A section title, with "See all" when the rail is a preview of a longer list.
class HubTitle extends StatelessWidget {
  final String text;
  final VoidCallback? onSeeAll;
  final Color? accent;
  const HubTitle(this.text, {super.key, this.onSeeAll, this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, onSeeAll == null ? 20 : 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: () {
                HapticService.selection();
                onSeeAll!();
              },
              child: Text('See all',
                  style: TextStyle(
                      color: accent ?? Colors.white70, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// One tile in a [HubRail].
class HubRailItem {
  final Widget art;
  final String title;
  final String subtitle;

  /// A coloured dot on the cover (something new).
  final bool dot;

  /// A chart position badge.
  final int? rank;

  /// The subtitle in the accent colour (a chapter in progress, say).
  final bool highlight;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const HubRailItem({
    required this.art,
    required this.title,
    required this.onTap,
    this.subtitle = '',
    this.dot = false,
    this.rank,
    this.highlight = false,
    this.onLongPress,
  });
}

/// Square artwork for a rail or a row: an image path, rounded.
Widget hubArt(String path, {double size = 112, double radius = 12}) =>
    AuvyImage(path: path, width: size, height: size, borderRadius: radius, decodeWidth: (size * 2.2).round());

/// A titled horizontal row of covers. Built lazily, so a long rail costs only
/// what is on screen.
class HubRail extends StatelessWidget {
  final String title;
  final List<HubRailItem> items;
  final Color accent;
  final VoidCallback? onSeeAll;
  final double size;
  const HubRail({
    super.key,
    required this.title,
    required this.items,
    required this.accent,
    this.onSeeAll,
    this.size = 112,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HubTitle(title, onSeeAll: onSeeAll, accent: accent),
        SizedBox(
          height: size + 58,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => _RailTile(item: items[i], accent: accent, size: size),
          ),
        ),
      ],
    );
  }
}

class _RailTile extends StatelessWidget {
  final HubRailItem item;
  final Color accent;
  final double size;
  const _RailTile({required this.item, required this.accent, required this.size});

  @override
  Widget build(BuildContext context) {
    return InteractivePressable(
      scaleDown: 0.95,
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        HapticService.light();
        item.onTap();
      },
      onLongPress: item.onLongPress,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(width: size, height: size, child: item.art),
                if (item.rank != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(8)),
                      child: Text('${item.rank}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ),
                if (item.dot)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(item.title,
                maxLines: item.subtitle.isEmpty ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
            if (item.subtitle.isNotEmpty)
              Text(item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: item.highlight ? accent : Colors.white54, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// A rail-shaped placeholder while a rail's list loads.
class HubRailSkeleton extends StatelessWidget {
  final String title;
  final double size;
  const HubRailSkeleton({super.key, required this.title, this.size = 112});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HubTitle(title),
        SizedBox(
          height: size + 58,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 4,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLoader(width: size, height: size, borderRadius: 12),
                const SizedBox(height: 8),
                SkeletonLoader(width: size * 0.8, height: 11, borderRadius: 5),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Rows of placeholder art and text while a list loads. Shrink-wrapped and
/// not scrollable, so it sits in a page body or above other content alike.
class HubRowsSkeleton extends StatelessWidget {
  final int rows;
  final double art;
  const HubRowsSkeleton({super.key, this.rows = 8, this.art = 52});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      itemCount: rows,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            SkeletonLoader(width: art, height: art, borderRadius: 10),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLoader(width: 180, height: 12, borderRadius: 6),
                  SizedBox(height: 7),
                  SkeletonLoader(width: 100, height: 10, borderRadius: 5),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One category tile. Its look comes from its content: [preview] loads a few
/// cover images from inside the category (the top shows, books or playlists),
/// shown fanned on the tile; [color] is the category's own colour where the
/// catalogue gives one, else one derived from its name. [more] draws it plain
/// with an arrow ("All categories").
class HubTile {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Future<List<String>> Function()? preview;

  /// Names the preview in the session cache: the same label can be a podcast
  /// category and a book genre ("Fiction"), with different covers.
  final String? previewKey;
  final bool more;
  const HubTile(this.label, this.onTap,
      {this.color, this.preview, this.previewKey, this.more = false});
}

/// A stable colour for a name, so a category keeps its colour across visits
/// without a hand-made palette.
Color colorForName(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.5, 0.42).toColor();
}

/// A grid of category tiles, as a sliver (the hubs are CustomScrollViews).
class HubCategoryGrid extends StatelessWidget {
  final List<HubTile> tiles;
  final double aspectRatio;
  const HubCategoryGrid({super.key, required this.tiles, this.aspectRatio = 2.2});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: aspectRatio,
        children: [for (final t in tiles) HubCategoryTile(tile: t)],
      ),
    );
  }
}

/// One tile: a gradient in its colour, its label, and up to two covers from
/// inside it. Previews are fetched once per session (built lazily, so only the
/// tiles scrolled to cost anything).
class HubCategoryTile extends StatefulWidget {
  final HubTile tile;
  const HubCategoryTile({super.key, required this.tile});

  static final Map<String, Future<List<String>>> _previews = {};

  @override
  State<HubCategoryTile> createState() => _HubCategoryTileState();
}

class _HubCategoryTileState extends State<HubCategoryTile> {
  Future<List<String>>? _preview;

  @override
  void initState() {
    super.initState();
    final t = widget.tile;
    if (t.preview != null && !t.more) {
      _preview = HubCategoryTile._previews.putIfAbsent(
          t.previewKey ?? t.label, () => t.preview!().catchError((_) => const <String>[]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    final plain = tile.more;
    final t = plain ? Colors.white : (tile.color ?? colorForName(tile.label));
    return InteractivePressable(
      scaleDown: 0.96,
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        HapticService.light();
        tile.onTap();
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [t.withValues(alpha: plain ? 0.10 : 0.6), t.withValues(alpha: plain ? 0.04 : 0.2)],
            ),
            border: Border.all(color: t.withValues(alpha: 0.25)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: LayoutBuilder(builder: (context, box) {
            final art = (box.maxHeight * 0.62).clamp(32.0, 84.0);
            return Stack(
              children: [
                if (_preview != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: FutureBuilder<List<String>>(
                      future: _preview,
                      builder: (_, snap) {
                        final images = (snap.data ?? const <String>[]).where((u) => u.isNotEmpty).take(2).toList();
                        if (images.isEmpty) return const SizedBox.shrink();
                        return SizedBox(
                          width: art + (images.length - 1) * art * 0.45,
                          height: art,
                          child: Stack(
                            children: [
                              for (final (i, url) in images.reversed.indexed)
                                Positioned(
                                  right: i * art * 0.45,
                                  child: Transform.rotate(
                                    angle: i == 0 ? 0.12 : -0.08,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6),
                                        ],
                                      ),
                                      child: hubArt(url, size: art, radius: 8),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(tile.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800,
                                shadows: [Shadow(color: Colors.black54, blurRadius: 6)])),
                      ),
                      if (plain)
                        const Icon(Icons.chevron_right_rounded, color: Colors.white54, size: 20),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// A plain page (back button, title, a quiet line under it) for a "See all"
/// list or a category.
class HubListPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? background;
  const HubListPage({super.key, required this.title, required this.body, this.subtitle, this.background});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            if (subtitle != null)
              Text(subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Colors.white54, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
      body: body,
    );
  }
}
