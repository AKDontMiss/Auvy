import 'package:flutter/material.dart';

/// Full-page loading skeletons for the album and artist pages.
///
/// Why NOT just a spinner
///
/// Both pages open INSTANTLY from the player (tap the title or the artist) with
/// only the little the player already knows — a name, sometimes a cover. The
/// tracks, the discography and the artist header arrive over the network. Until
/// they did, the page showed a centred CircularProgressIndicator in 50-60px of
/// padding: the layout jumped from a spinner to a full list, and there was no
/// hint of what was coming.
///
/// A skeleton answers a different question. It says "this page has a list of
/// tracks and it is on its way", holds the space the real content will take, and
/// makes the arrival a fill rather than a jump.
///
/// One controller, NOT one per box
///
/// The existing [SkeletonLoader] owns an AnimationController per instance, which
/// is fine for the one or two boxes each of its callers uses. A page skeleton is
/// fifteen to twenty boxes, and that many repeating controllers means that many
/// tickers driving that many rebuilds every frame, all showing the same sweep.
///
/// [Shimmer] hosts a single controller and hands the phase down through an
/// InheritedWidget; [ShimmerBox] reads it and paints. One ticker per page, and
/// every box stays in step, which also looks better, because independent
/// controllers drift apart and the page shimmers raggedly.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The AnimatedBuilder sits ABOVE the inherited widget so the phase change
    // rebuilds only _ShimmerScope's dependents — the boxes, and not the layout
    // around them.
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => _ShimmerScope(phase: _c.value, child: child!),
      child: widget.child,
    );
  }
}

/// [Shimmer] only while [active], so no ticker runs once the data has landed.
///
/// A header contains both real text and placeholder bars at different moments,
/// and wrapping it permanently in a [Shimmer] would leave a repeating controller
/// running for the whole life of every album page — for an effect that is only
/// visible during the first second.
class MaybeShimmer extends StatelessWidget {
  const MaybeShimmer({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      active ? Shimmer(child: child) : child;
}

class _ShimmerScope extends InheritedWidget {
  const _ShimmerScope({required this.phase, required super.child});

  final double phase;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.phase ?? 0;

  @override
  bool updateShouldNotify(_ShimmerScope old) => old.phase != phase;
}

/// One shimmering placeholder block. Must sit under a [Shimmer].
///
/// Outside one it renders as a flat matte box rather than throwing — a skeleton
/// is decoration, and a missing ancestor should not be able to crash a page that
/// is already having trouble loading.
class ShimmerBox extends StatelessWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 8,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final phase = _ShimmerScope.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        shape: shape,
        borderRadius: shape == BoxShape.circle ? null : BorderRadius.circular(radius),
        // Same matte palette as SkeletonLoader, so a page using both does not
        // show two different greys.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [Color(0xFF222222), Color(0xFF333333), Color(0xFF222222)],
          stops: [
            (phase - 0.3).clamp(0.0, 1.0),
            phase,
            (phase + 0.3).clamp(0.0, 1.0),
          ],
        ),
      ),
    );
  }
}

/// A track row: artwork square, title line, artist line.
///
/// Widths alternate so the block reads as a list of DIFFERENT titles rather than
/// a striped pattern — a uniform skeleton looks like a loading bar, not content.
class _TrackRowSkeleton extends StatelessWidget {
  const _TrackRowSkeleton({required this.seed});

  final int seed;

  @override
  Widget build(BuildContext context) {
    const widths = [0.62, 0.44, 0.55, 0.38, 0.5];
    final w = MediaQuery.sizeOf(context).width;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          const ShimmerBox(width: 48, height: 48, radius: 8),
          const SizedBox(width: 13),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShimmerBox(width: w * widths[seed % widths.length], height: 13),
              const SizedBox(height: 8),
              ShimmerBox(width: w * (widths[(seed + 2) % widths.length] * 0.6), height: 11),
            ],
          ),
        ],
      ),
    );
  }
}

/// The album page's track list, while it loads.
///
/// A sliver rather than a box, because it replaces a sliver in that page's
/// CustomScrollView — returning a boxed widget there would need a wrapper at
/// every call site.
class AlbumTracksSkeleton extends StatelessWidget {
  const AlbumTracksSkeleton({super.key, this.rows = 8});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Shimmer(
        child: Column(
          children: [
            const SizedBox(height: 6),
            for (var i = 0; i < rows; i++) _TrackRowSkeleton(seed: i),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// The artist page's body, while it loads: a row of round album/single tiles
/// over a short list of top tracks — the shape the real page settles into.
class ArtistBodySkeleton extends StatelessWidget {
  const ArtistBodySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Shimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 18, 16, 12),
              child: ShimmerBox(width: 120, height: 15),
            ),
            SizedBox(
              height: 172,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // The skeleton must not be draggable: it is not content, and a
                // scroll that goes nowhere reads as the page being broken.
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, _) => const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerBox(width: 126, height: 126, radius: 12),
                    SizedBox(height: 10),
                    ShimmerBox(width: 96, height: 11),
                    SizedBox(height: 7),
                    ShimmerBox(width: 62, height: 9),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 22, 16, 8),
              child: ShimmerBox(width: 96, height: 15),
            ),
            for (var i = 0; i < 5; i++) _TrackRowSkeleton(seed: i),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
