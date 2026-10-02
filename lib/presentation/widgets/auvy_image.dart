import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/core/image_cache_manager.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/core/utils/container_path_resolver.dart';

/// Memoised `File.existsSync()`. The local-file branches below run in `build`,
/// and a blocking stat per visible tile per rebuild causes scroll jank. Only
/// positive results are cached (a missing file may appear moments later); a cached
/// positive that later disappears is handled by every Image.file's `errorBuilder`,
/// which falls back to the placeholder. [invalidate] is for delete paths.
class _FileExistsCache {
  static final Set<String> _present = {};

  static bool check(String path) {
    if (_present.contains(path)) return true;
    final ok = File(path).existsSync();
    if (ok) {
      // Bound it. Artwork paths are few, but audio-cache paths accumulate over a
      // long session and this must never become a leak.
      if (_present.length > 500) _present.clear();
      _present.add(path);
    }
    return ok;
  }

  static void invalidate(String path) => _present.remove(path);
}

/// Forget a memoised "this file exists" result — call after deleting a file whose
/// path may still be rendered (see [_FileExistsCache]).
void auvyImageForgetFile(String path) => _FileExistsCache.invalidate(path);

/// Art that has painted at least one frame.
///
/// Flutter resets its frame number on every image stream change, regardless of
/// `gaplessPlayback` (which only keeps the old image). So when a provider changes
/// (e.g. a track's cover becomes a local file after caching), `frameBuilder` gets
/// `frame == null` while a good frame is still being painted, and showing the
/// placeholder then would flicker. This tracks, per element, whether a frame is
/// currently held.
///
/// Per element rather than a shared set of painted paths: a fresh Image elsewhere
/// holds no frame even if the same path painted before, and must still show its
/// placeholder.
class _GaplessArt extends StatefulWidget {
  final ImageProvider provider;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget Function() placeholder;
  final VoidCallback onError;

  /// A SHARPER source, loaded alongside [provider] and swapped in only once it
  /// has actually decoded.
  ///
  /// [provider] is always the variant that is known to exist, so something is on
  /// screen immediately; this one is an enhancement whose absence costs nothing.
  /// See [_GaplessArtState._probeUpgrade] for why the order matters so much.
  final ImageProvider? upgradeProvider;

  const _GaplessArt({
    required this.provider,
    required this.width,
    required this.height,
    required this.fit,
    required this.placeholder,
    required this.onError,
    this.upgradeProvider,
  });

  @override
  State<_GaplessArt> createState() => _GaplessArtState();
}

class _GaplessArtState extends State<_GaplessArt> {
  /// Has THIS element ever painted a frame? Only then is there something for
  /// gaplessPlayback to retain, and only then may the placeholder be skipped.
  bool _hasPainted = false;

  /// True once the sharper variant has actually decoded and can replace the
  /// reliable one. Until then the reliable one is what is on screen.
  bool _upgraded = false;

  ImageStream? _probeStream;
  ImageStreamListener? _probeListener;

  @override
  void initState() {
    super.initState();
    _probeUpgrade();
  }

  @override
  void didUpdateWidget(_GaplessArt old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider ||
        old.upgradeProvider != widget.upgradeProvider) {
      _dropProbe();
      _upgraded = false;
      _probeUpgrade();
    }
  }

  /// Loads the sharper variant next to the reliable one and swaps only on success,
  /// so sharpness is never on the critical path: `maxresdefault` doesn't exist for
  /// many videos, and requesting it first meant a 404 and a retry before anything
  /// showed.
  void _probeUpgrade() {
    final up = widget.upgradeProvider;
    if (up == null) return;
    final stream = up.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, sync) {
        if (mounted && !_upgraded) setState(() => _upgraded = true);
      },
      // Absent sharper variant → keep what is already showing. Swallowed on
      // purpose: this is an enhancement, and its failure is not an error.
      onError: (_, __) {},
    );
    _probeStream = stream;
    _probeListener = listener;
    stream.addListener(listener);
  }

  void _dropProbe() {
    final s = _probeStream, l = _probeListener;
    if (s != null && l != null) s.removeListener(l);
    _probeStream = null;
    _probeListener = null;
  }

  @override
  void dispose() {
    _dropProbe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: (_upgraded && widget.upgradeProvider != null)
          ? widget.upgradeProvider!
          : widget.provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
        if (frame != null || wasSynchronouslyLoaded) {
          // Written directly, NOT through setState: this runs during build and
          // the value is only ever read on a LATER build.
          _hasPainted = true;
          return child;
        }
        // Mid-swap on an element that is already showing something → render the
        // retained frame rather than painting over it.
        if (_hasPainted) return child;
        return widget.placeholder();
      },
      // No retry ladder here any more — [provider] is the variant that exists,
      // so reaching this means the art is genuinely unavailable rather than the
      // sharp variant being missing.
      errorBuilder: (_, __, ___) {
        widget.onError();
        return widget.placeholder();
      },
    );
  }
}

class AuvyImage extends ConsumerWidget {
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;

  /// Explicit decode width (px) that overrides the layout-derived decode size. For
  /// when display size and useful decode size differ, e.g. the full-screen blurred
  /// background: its box is unbounded (so it would decode at full resolution), but
  /// the blur removes the detail, so ~360 px looks identical and cuts decode and
  /// texture upload cost about 10× (upload re-runs whenever Android trims the image
  /// cache).
  final int? decodeWidth;

  const AuvyImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.decodeWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
          // Scaled by the user's cover-art roundness. Applied HERE so every
          // artwork surface inherits it from one place — see
          // ListeningPolicy.artworkRoundness for why it is a multiplier.
          ListeningPolicy.roundArtwork(borderRadius)),
      // No LayoutBuilder here. Deriving the decode size from the layout saves memory,
      // but wrapping every dimensionless AuvyImage in one adds an element level and made
      // artwork flash the placeholder whenever a list rebuilt. If retried, the Image
      // element must survive rebuilds; passing explicit width/height at the call sites
      // that matter (starting with the player cover) gets the same saving safely.
      child: _buildImage(context, ref),
    );
  }

 Widget _buildImage(BuildContext context, WidgetRef ref, {double? fromLayout}) {
    if (path.isEmpty) {
      return _buildPlaceholder();
    }

    // Normalize path: Convert file:// URI to a raw platform path
    String localPath = path;
    if (path.startsWith('file://')) {
      try {
        localPath = Uri.parse(path).toFilePath();
      } catch (e) {
        localPath = path.replaceFirst('file://', '');
      }
    }

    // Local Assets. Kept as its own widget because an asset path never changes
    // provider mid-life, so it can't hit the swap problem described below.
    if (path.startsWith('assets/')) {
      return Image.asset(
        path,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    // Decode on a SINGLE axis so the source's aspect ratio is preserved. Passing
    // BOTH width+height resizes to exactly WxH, which squashes non-square art
    // (e.g. a 16:9 artist thumbnail crammed into a square tile). One axis keeps
    // the ratio; BoxFit.cover crops evenly.
    // What the CALLER declared. This one, and only this one — is allowed to
    // rewrite the CDN url.
    final int? declaredPx = decodeWidth ??
        _decodeDim(width, height, MediaQuery.of(context).devicePixelRatio);
    // What will actually be painted, falling back to the layout box when the caller
    // declared nothing (so the player cover, sized by an AspectRatio, doesn't decode
    // at full source size). Decode only: not passed to _sizeParamForBox, since that
    // would change which URL is requested for callers that never asked for a size.
    final int? decodePx = declaredPx ??
        _decodeDim(fromLayout, null, MediaQuery.of(context).devicePixelRatio);

    // Which SOURCE to paint. Everything below only picks an ImageProvider — it
    // deliberately does NOT return different widgets per branch. See the
    // single Image at the end for why that matters.
    ImageProvider? provider;
    String? fileToInvalidate;
    // Set only for a surface that explicitly asked for a big decode, and only
    // when a sharper variant actually exists. See where it is assigned and
    // _GaplessArt.upgradeProvider.
    ImageProvider? upgradeSource;

    // 1. Persistent Local File (absolute paths or the cache folder)
    if (localPath.startsWith('/') || localPath.contains('audio_cache')) {
      if (!_FileExistsCache.check(localPath)) {
        final rebased = ContainerPathResolver.rebaseIfNeeded(localPath);
        if (rebased != localPath && _FileExistsCache.check(rebased)) {
          localPath = rebased;
        } else {
          return _buildPlaceholder();
        }
      }
      provider = FileImage(File(localPath));
      fileToInvalidate = localPath;
    } else {
      // 2. Network, possibly already mirrored on disk. Select only this bool, so a
      // connectivity change doesn't rebuild every image. shouldLoadHighResImages
      // accounts for both connection type and the Data Saver setting.
      final bool allowHighRes =
          ref.watch(connectivityProvider.select((c) => c.shouldLoadHighResImages));
      final String quality = allowHighRes ? 'medium' : 'low';
      // The decode size is also the right download size (see _sizeParamForBox), so the
      // URL asks the CDN for roughly what will be painted. Maxres is opted into by the
      // caller, never inferred from a derived size (see _ytimgVariantForBox): only the
      // player cover passes a large `decodeWidth`; the blurred backdrop passes ~360.
      final bool wantsMaxres = (decodeWidth ?? 0) >= 600;
      // The primary URL never asks for maxres (allowMaxres: false), so what loads first
      // always exists; the sharp variant is requested separately as an upgrade below.
      final String optimizedUrl = _sizeParamForBox(
          _ytimgVariantForBox(_getOptimizedImageUrl(path, quality), declaredPx),
          declaredPx,
          allowHighRes);

      // verifyExists: false — the very next line runs the same check through
      // _FileExistsCache, which memoises it. Letting the lookup stat as well
      // meant two synchronous filesystem calls per cover per build, one of them
      // never cached.
      final String? localResolvedPath =
          AudioCacheManager().getLocalPathFromUrl(path, verifyExists: false);
      if (localResolvedPath != null && _FileExistsCache.check(localResolvedPath)) {
        provider = FileImage(File(localResolvedPath));
        fileToInvalidate = localResolvedPath;
      } else {
        provider = CachedNetworkImageProvider(
          optimizedUrl,
          cacheManager: CustomImageCacheManager(),
        );
        // The sharper variant, offered as an UPGRADE rather than a requirement.
        //
        // Only for a surface that explicitly asked for a big decode (the player
        // cover), and only when it would actually be sharper than what is
        // already loading, so tiles carry no extra url at all. If it does not
        // exist, nothing happens and the reliable one stays on screen.
        final String upgradeUrl = _sizeParamForBox(
            _ytimgVariantForBox(_getOptimizedImageUrl(path, quality), declaredPx,
                allowMaxres: true),
            declaredPx,
            allowHighRes);
        if (wantsMaxres && upgradeUrl != optimizedUrl) {
          upgradeSource = CachedNetworkImageProvider(
            upgradeUrl,
            cacheManager: CustomImageCacheManager(),
          );
        }
      }
    }

    // One Image widget for every source; don't split this back into `Image.file` vs
    // `CachedNetworkImage`. A piece of art's source changes while on screen (a
    // streamed track's cover gets written to disk when it's cached), and switching
    // widget types would tear down the element and decode from scratch, flashing the
    // placeholder. Same widget type with a changed provider reuses the element, and
    // `gaplessPlayback` holds the last frame until the new one is ready.
    return _GaplessArt(
      provider: ResizeImage.resizeIfNeeded(decodePx, null, provider),
      upgradeProvider: upgradeSource == null
          ? null
          : ResizeImage.resizeIfNeeded(decodePx, null, upgradeSource),
      // double.infinity is allowed here; null lets an unbounded box size itself
      // naturally.
      width: (width != null && width!.isFinite) ? width : null,
      height: (height != null && height!.isFinite) ? height : null,
      fit: fit,
      placeholder: _buildPlaceholder,
      // Required, not optional: the existence check above is memoised, so a file
      // deleted after its first successful stat would otherwise throw an error
      // box. Invalidating means the NEXT build re-stats and falls through to the
      // network URL for art that has one, instead of trusting a dead positive.
      onError: () {
        if (fileToInvalidate != null) _FileExistsCache.invalidate(fileToInvalidate);
      },
    );
  }

  // A single decode dimension (the larger known box side × pixel ratio), applied to
  // one axis only so the image keeps its aspect ratio (two axes would stretch
  // non-square art); BoxFit.cover then crops evenly. Null for infinite or unknown
  // sizes, so unbounded slots don't throw.
  int? _decodeDim(double? w, double? h, double ratio) {
    final bool vw = w != null && w.isFinite && w > 0;
    final bool vh = h != null && h.isFinite && h > 0;
    double? base;
    if (vw && vh) {
      base = w > h ? w : h;
    } else if (vw) {
      base = w;
    } else if (vh) {
      base = h;
    }
    if (base == null) return null;
    return (base * ratio).round();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[900],
      child: const Icon(Icons.music_note, color: Colors.white24),
    );
  }

  /// Rewrites a Google CDN size parameter (`=s800`, `=w544-h544-l90-rj`) down to what
  /// this widget will actually paint. Album and playlist art from
  /// `googleusercontent.com` is stamped `=s1200` at ingestion
  /// (`SearchService.getHighResImage()`), so without this a small grid tile would
  /// download a large image; `memCacheWidth` only caps the decode, not the transfer.
  ///
  /// Sizes snap to a ladder rather than exact widths, so the CDN and disk cache share
  /// entries across layouts, and a slightly larger request stays sharp if the same
  /// art is shown a little bigger. The ladder goes up to 1200, enough for the player
  /// cover on a ~1080 px-wide screen; the smallest rung at least the box size is
  /// used, so small rows stay small. Untouched when the target is unknown, so this
  /// never lowers resolution below what's needed.
  static const List<int> _sizeLadder = [
    64, 128, 192, 256, 384, 512, 720, 960, 1200,
  ];

  /// The exact URL the player page cover will request for [path], so it can be
  /// warmed ahead of time (see player_smart's preload); list tiles request smaller
  /// sizes, which are different cache entries. It reuses the widget's own helpers so
  /// the string matches exactly; if the widget's URL construction changes, this must
  /// change with it.
  static String playerArtUrl(String path, {required bool allowHighRes}) {
    if (path.isEmpty || !path.startsWith('http')) return '';
    const int declaredPx = 720; // player_page passes decodeWidth: 720
    final helper = const AuvyImage(path: '');
    return helper._sizeParamForBox(
        _ytimgVariantForBox(
            helper._getOptimizedImageUrl(path, allowHighRes ? 'medium' : 'low'),
            declaredPx),
        declaredPx,
        allowHighRes);
  }

  String _sizeParamForBox(String url, int? targetPx, bool allowHighRes) {
    if (targetPx == null || targetPx <= 0) return url;
    if (!url.contains('googleusercontent.com') && !url.contains('ggpht.com')) {
      return url;
    }
    final match = RegExp(r'=[wsh]\d+(-[a-z0-9]+)*$').firstMatch(url);
    if (match == null) return url;

    // Snap up to the ladder (never smaller than the box). On Data Saver, take the rung
    // below the ideal. No extra padding before snapping, which only ever pushed
    // requests up a whole rung.
    final want = targetPx;
    var chosen = _sizeLadder.firstWhere((s) => s >= want,
        orElse: () => _sizeLadder.last);
    if (!allowHighRes) {
      final i = _sizeLadder.indexOf(chosen);
      if (i > 0) chosen = _sizeLadder[i - 1];
    }
    return '${url.substring(0, match.start)}=s$chosen';
  }

  /// Picks the `i.ytimg.com` filename variant that matches the box, as
  /// [_sizeParamForBox] does for the `=sNNN` parameter, so small tiles fetch small
  /// files and only the big cover pays for a big one. maxresdefault is only
  /// requested where allowed (the player cover), with a fallback: [_GaplessArt]
  /// retries once at `hqdefault` (always present) before showing a placeholder.
  static String _ytimgVariantForBox(String url, int? targetPx,
      {bool allowMaxres = false}) {
    if (!url.contains('ytimg.com')) return url;
    // Unknown box → leave it alone rather than guess downward.
    if (targetPx == null || targetPx <= 0) return url;
    // 120 / 320 / 480 / 1280 are the pixel widths of the four variants. Maxres is
    // gated on [allowMaxres], not on size: on high-density screens ordinary grid
    // tiles exceed 480 physical px, and fetching 1280×720 covers for every tile
    // multiplied data use several times over. Only the player cover opts in.
    final want = targetPx <= 120
        ? 'default'
        : (targetPx <= 320
            ? 'mqdefault'
            : ((targetPx <= 480 || !allowMaxres)
                ? 'hqdefault'
                : 'maxresdefault'));
    // Match the whole filename, never a suffix: every variant name ends in
    // `default.jpg` (`mqdefault.jpg` = `mq` + `default.jpg`), so a plain substring
    // replace would produce broken names like `mqhqdefault.jpg`. The optional prefix
    // group anchors at the start of the filename, so each variant is rewritten once.
    return url.replaceAllMapped(
      RegExp(r'(?:maxres|sd|hq|mq)?default\.jpg'),
      (_) => '$want.jpg',
    );
  }

  String _getOptimizedImageUrl(String url, String quality) {
    // YouTube thumbnails
    if (url.contains('ytimg.com') || url.contains('googleusercontent.com')) {
      switch (quality) {
        case 'low':
          // Use smallest thumbnail (saves ~90% bandwidth)
          return url.replaceAll('maxresdefault', 'default')
                    .replaceAll('hqdefault', 'default')
                    .replaceAll('mqdefault', 'default')
                    .replaceAll('sddefault', 'default');
        case 'medium':
          // Use medium quality (saves ~60% bandwidth)
          return url.replaceAll('maxresdefault', 'mqdefault')
                    .replaceAll('hqdefault', 'mqdefault')
                    .replaceAll('sddefault', 'mqdefault');
        case 'high':
        default:
          // Use hqdefault (NOT maxres, saves ~30% bandwidth)
          return url.replaceAll('maxresdefault', 'hqdefault')
                    .replaceAll('default', 'hqdefault')
                    .replaceAll('mqdefault', 'hqdefault');
      }
    }
    
    // Spotify images.
    if (url.contains('i.scdn.co')) {
      switch (quality) {
        case 'low':
          return url.replaceAll('/640x640/', '/64x64/')
                    .replaceAll('/640/', '/64/')
                    .replaceAll('/300x300/', '/64x64/')
                    .replaceAll('/300/', '/64/');
        case 'medium':
          return url.replaceAll('/640x640/', '/300x300/')
                    .replaceAll('/640/', '/300/');
        case 'high':
        default:
          // Don't use 640, use 300 instead (good enough for mobile)
          return url.replaceAll('/640x640/', '/300x300/')
                    .replaceAll('/640/', '/300/');
      }
    }
    
    // Deezer images
    if (url.contains('deezer') || url.contains('dzcdn')) {
      switch (quality) {
        case 'low':
          return url.replaceAll('cover_xl', 'cover_small')
                    .replaceAll('cover_big', 'cover_small')
                    .replaceAll('cover_medium', 'cover_small')
                    .replaceAll('picture_xl', 'picture_small')
                    .replaceAll('picture_big', 'picture_small')
                    .replaceAll('picture_medium', 'picture_small');
        case 'medium':
          return url.replaceAll('cover_xl', 'cover_medium')
                    .replaceAll('cover_big', 'cover_medium')
                    .replaceAll('picture_xl', 'picture_medium')
                    .replaceAll('picture_big', 'picture_medium');
        case 'high':
        default:
          // Use medium instead of XL (sufficient for mobile)
          return url.replaceAll('cover_xl', 'cover_big')
                    .replaceAll('picture_xl', 'picture_big');
      }
    }
    
    return url;
  }
}