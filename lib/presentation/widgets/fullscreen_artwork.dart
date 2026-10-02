import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/haptic_service.dart';

/// Shows [path] full screen, pinch-zoomable, at the sharpest variant the CDN has.
///
/// A separate viewer because list and header tiles request small CDN sizes (that's
/// what keeps browsing cheap), so a full-screen view needs a bigger URL.
/// `decodeWidth: 1080` is the request: AuvyImage treats ≥ 600 as "wants maxres",
/// shows the reliable variant first (usually already cached) and upgrades to the
/// sharp one if it exists.
///
/// No Hero animation: the two images are different URLs, and a Hero would
/// cross-fade between different bitmaps mid-flight.
Future<void> showFullScreenArtwork(
  BuildContext context, {
  required String path,
  String? caption,
}) {
  if (path.isEmpty) return Future.value();
  HapticService.medium();
  // Logged once per open, so a soft picture can be told apart from an image that
  // simply has no sharp variant.
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

class _FullScreenArtworkState extends State<_FullScreenArtwork>
    with SingleTickerProviderStateMixin {
  final TransformationController _zoom = TransformationController();

  /// Drives the double-tap zoom so it eases instead of snapping.
  late final AnimationController _zoomAnim;
  Animation<Matrix4>? _zoomTween;

  /// Where the last double-tap landed, so zooming goes to what was tapped rather
  /// than the centre.
  Offset? _doubleTapAt;

  /// How far a double-tap zooms. Short of [maxScale] on purpose: it is the
  /// "look closer" step, and pinch is still there for the rest.
  static const double _doubleTapScale = 2.5;

  /// True while zoomed in. Swipe-to-close and tap-to-close stand down then, so
  /// panning a magnified image doesn't close the viewer.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
    _zoomAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(() {
        final t = _zoomTween;
        if (t != null) _zoom.value = t.value;
      });
  }

  /// Ease the transform to [target].
  void _animateZoomTo(Matrix4 target) {
    _zoomTween = Matrix4Tween(begin: _zoom.value, end: target).animate(
      CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic),
    );
    _zoomAnim.forward(from: 0);
  }

  /// Double-tap: in at the point touched, or all the way back out.
  void _handleDoubleTap() {
    if (_zoomed) {
      _animateZoomTo(Matrix4.identity());
      return;
    }
    final at = _doubleTapAt;
    if (at == null) {
      _animateZoomTo(Matrix4.identity()..scale(_doubleTapScale));
      return;
    }
    // Scale about the tapped point: translate it to the origin, scale, and the
    // translation below is what keeps it under the finger.
    _animateZoomTo(Matrix4.identity()
      ..translate(-at.dx * (_doubleTapScale - 1), -at.dy * (_doubleTapScale - 1))
      ..scale(_doubleTapScale));
  }

  void _onZoom() {
    final z = _zoom.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _zoomAnim.dispose();
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
              // Double-tap to zoom (pinch works too). onDoubleTap carries no position, so this
              // records it for zooming to the tapped point.
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: _handleDoubleTap,
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
                // Up to 6x: the image is fetched at maxres and decoded at 1080, so there's real
                // detail beyond 4x.
                maxScale: 6,
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
