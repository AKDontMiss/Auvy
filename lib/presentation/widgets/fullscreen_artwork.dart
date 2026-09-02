import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/haptic_service.dart';

/// Show [path] filling the screen, pinch-zoomable, at the sharpest variant the
/// CDN has.
///
/// Why a separate viewer AND NOT a bigger tile
///
/// An artist portrait renders at 164px and an album cover at a few hundred, so
/// both request a matching rung off the CDN size ladder — that is the whole
/// point of [AuvyImage]'s sizing, and it is why browsing is cheap. Neither has
/// the pixels to fill a screen, so showing one large means asking for a
/// different, bigger url; there is no way to get there by scaling what is
/// already on screen.
///
///`decodeWidth: 1080` IS THE REQUEST, NOT JUST A DECODE HINT. AuvyImage
/// treats anything >= 600 as "this surface wants maxres" and then loads the
/// reliable variant FIRST, offering the sharp one as an upgrade behind it. So a
/// portrait appears immediately at the size the tile already had cached and
/// sharpens a moment later, and if the sharp variant does not exist (many
/// images have no maxres), nothing happens and the reliable one simply stays.
/// That is why this asks for a big decode rather than constructing a url itself.
///
/// Deliberately NOT a Hero animation: the tile's image and this one are
/// different urls, so a Hero would cross-fade between two different bitmaps
/// mid-flight. A plain fade is honest about what is happening.
Future<void> showFullScreenArtwork(
  BuildContext context, {
  required String path,
  String? caption,
}) {
  if (path.isEmpty) return Future.value();
  HapticService.medium();
  // Said once per open, because "the picture looked soft" is otherwise
  // impossible to tell apart from "the sharp variant does not exist for this
  // image", and only one of those is a bug.
  print('full-screen artwork: ${caption ?? "(untitled)"} — requesting the '
      'maxres upgrade behind ${path.split('/').take(4).join('/')}…');
  return showGeneralDialog<void>(
    context: context,
    // Opaque rather than a translucent scrim: this is a viewer, and letting the
    // page beneath show through a zoomed portrait is just visual noise.
    barrierColor: Colors.black,
    barrierDismissible: true,
    barrierLabel: caption ?? 'Artwork',
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => _FullScreenArtwork(path: path, caption: caption),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _FullScreenArtwork extends StatefulWidget {
  final String path;
  final String? caption;
  const _FullScreenArtwork({required this.path, this.caption});

  @override
  State<_FullScreenArtwork> createState() => _FullScreenArtworkState();
}

class _FullScreenArtworkState extends State<_FullScreenArtwork> {
  final TransformationController _zoom = TransformationController();

  /// True while the image is zoomed in.
  ///
  /// THE DISMISS GESTURES MUST STAND DOWN WHEN ZOOMED. A pan across a
  /// magnified portrait is a drag, and treating it as a swipe-to-close means the
  /// viewer shuts the moment someone looks closely, which is the one thing they
  /// opened it to do. Tap-to-close goes too: at that point a tap is far more
  /// likely to be a mis-tap while panning.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  void _onZoom() {
    final z = _zoom.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _zoom.removeListener(_onZoom);
    _zoom.dispose();
    super.dispose();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _zoomed ? null : _close,
              // Swipe down to dismiss, the same gesture that closes the player.
              // Threshold on VELOCITY rather than distance so it cannot fire
              // from the tail of a slow pan.
              onVerticalDragEnd: _zoomed
                  ? null
                  : (d) {
                      if ((d.primaryVelocity ?? 0) > 320) _close();
                    },
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: AuvyImage(
                    path: widget.path,
                    // Contain, not cover: a portrait must not be cropped to the
                    // screen's aspect — seeing the whole picture is the point.
                    fit: BoxFit.contain,
                    width: media.size.width,
                    height: media.size.height,
                    // See the note on showFullScreenArtwork: >= 600 is what asks
                    // for the maxres upgrade.
                    decodeWidth: 1080,
                  ),
                ),
              ),
            ),
          ),
          if (widget.caption != null && widget.caption!.trim().isNotEmpty)
            Positioned(
              left: 24,
              right: 24,
              bottom: media.padding.bottom + 28,
              child: IgnorePointer(
                child: Text(
                  widget.caption!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.82),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    // The caption sits over the image itself, which can be light
                    // — a shadow keeps it readable without a bar across the art.
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            top: media.padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              // Always available, even zoomed, so there is one way out that
              // never depends on getting a gesture right.
              onPressed: _close,
              tooltip: 'Close',
            ),
          ),
        ],
      ),
    );
  }
}
