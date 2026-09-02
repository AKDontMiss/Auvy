import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/core/image_cache_manager.dart';
import 'package:auvy/services/listening_policy.dart';

/// Memoised `File.existsSync()`.
///
/// The local-file branches below run inside `build`, and `existsSync` is a
/// BLOCKING filesystem stat on the UI thread. Scrolling a list of downloaded or
/// cached tracks re-statted every visible tile on every rebuild, which is exactly
/// the kind of per-frame sync I/O that shows up as scroll jank.
///
/// Only POSITIVE results are cached: a "missing" file may legitimately appear
/// moments later (a download finishing, an artwork override being written), so a
/// negative must stay re-checkable. A cached positive that later disappears is
/// handled by the `errorBuilder` on every Image.file — it degrades to the
/// placeholder instead of an error box, so a stale positive can't paint broken.
///
/// [invalidate] exists for the delete paths: dropping the entry means the next
/// build re-stats instead of trusting a positive for a file we just removed.
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

/// Art that has successfully painted at least one frame.
///
///`gaplessPlayback` KEEPS THE OLD IMAGE — BUT `frameBuilder` IS TOLD
/// Otherwise, AND that is the cover-art glitch.
///
/// Flutter's `_ImageState._updateSourceStream` resets `_frameNumber = null` on
/// EVERY stream change, unconditionally. That reset is NOT gated on
/// `gaplessPlayback` — the flag only decides whether `_imageInfo` is dropped. So
/// the instant a provider swaps, the builder is handed `frame == null` while a
/// perfectly good frame is still being held and painted, and the old code covered
/// it with the grey placeholder.
///
/// Which is the reported "mini-player glitches the first time I pause a new
/// track", with the Home tile flickering alongside it because both surfaces swap
/// at the same moment. Captured on device:
///
///   10:37:29.323  promoteFromPlayCache HZbsLxL7GeM → 3835036 bytes (0 network)
///   10:37:29.475 Cache update detected, refreshing library…
///   10:37:31.832  isPlaying=false        ← the pause: first rebuild after
///
/// Promoting a track into the cache mirrors its cover to disk, so
/// `getLocalPathFromUrl` starts answering and the provider becomes a `FileImage`.
/// Once per track, on the first rebuild after — exactly as described.
///
/// Why this is per-element state AND NOT a shared set of paths.
///
/// This was first written as a global "this art has painted once" set, and that
/// BLANKED artwork outright: a fresh Image on another page holds NO frame, but
/// the path had painted elsewhere, so the builder returned the child and
/// rendered nothing — not even the placeholder. Reported as "cover art is not
/// loading, I am not even getting the empty template" on the album page.
///
/// Whether a frame is currently being HELD is a property of one element, so only
/// that element may answer it.
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

  /// Load the sharper variant BESIDE the reliable one, and swap only on success.
  ///
  /// THE SHARP VARIANT MUST NEVER BE ON THE CRITICAL PATH. Asking for
  /// `maxresdefault` FIRST meant the common case was: request it, get a 404 (it
  /// does not exist for many videos), wait a frame, then request the variant that
  /// always exists. That produced exactly the reported behaviour — sometimes
  /// instant, sometimes slow, sometimes nothing at all if the retry lost its
  /// element. Sharpness was made a gamble on every render.
  ///
  /// Probing alongside inverts it: what is on screen is always the variant that
  /// exists, and the sharper one replaces it silently if and when it arrives. A
  /// miss costs nothing visible, because nothing was waiting on it.
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

  /// Explicit decode width (px) that OVERRIDES the layout-derived decode size.
  /// Use it when the display size and the useful decode size differ — most
  /// notably the full-screen BLURRED background: it fills an infinite box (so
  /// the layout-derived decode is null → full-res), but the blur destroys all
  /// detail, so decoding at ~360px is visually identical while cutting the
  /// decode + GPU-texture-upload cost ~10×. That upload is what re-runs (and
  /// hitches) every time Android trims the image cache on background/idle.
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
      // NO LayoutBuilder HERE — it was tried and REVERTED.
      //
      // Deriving the decode size from the layout box saves real memory (the
      // player cover otherwise decodes at full source, ~5.8MB of ARGB, and
      // dumpsys showed 194MB of GPU textures). But wrapping every
      // dimensionless AuvyImage in a LayoutBuilder adds an element level and
      // defers the child to layout, and on device that showed up as artwork
      // flashing the grey placeholder whenever a list rebuilt — searching a
      // page made every cover blink. A memory win is not worth artwork that
      // visibly breaks.
      //
      // If this is retried: the fix has to preserve the Image ELEMENT across
      // rebuilds. Passing explicit width/height at the call sites that matter
      // (starting with the player cover) gets the same saving with none of
      // this risk.
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
    // What will actually be painted. Falls back to the box the layout gave us
    // when the caller declared nothing, which is how the player cover (no width,
    // no height, sized by an AspectRatio) stops decoding at full source size.
    //
    // DECODE ONLY — deliberately NOT fed to _sizeParamForBox. The size also
    // rewrites the requested CDN url, and widening that to callers who never
    // asked for a size changes which url is fetched for images that had always
    // worked. Shrinking the DECODE of a downloaded image cannot fail; asking a
    // CDN for a different size can. Memory win, no network behaviour change.
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
      if (!_FileExistsCache.check(localPath)) return _buildPlaceholder();
      provider = FileImage(File(localPath));
      fileToInvalidate = localPath;
    } else {
      // 2. Network, possibly already mirrored on disk.
      //
      // Select ONLY this bool: reading the whole ConnectivityState object rebuilt
      // every image on any connectivity change. shouldLoadHighResImages folds in
      // BOTH the connection type and the user's Data Saver setting — the old
      // isWifi-only check kept fetching medium-res art on WiFi even with Data
      // Saver set to "Always".
      final bool allowHighRes =
          ref.watch(connectivityProvider.select((c) => c.shouldLoadHighResImages));
      final String quality = allowHighRes ? 'medium' : 'low';
      // The decode size is ALSO the right download size, so the URL asks the CDN
      // for roughly what will actually be painted. See _sizeParamForBox.
      // Sharpness is opted INTO by the caller, never inferred from a derived
      // size. See _ytimgVariantForBox. `decodeWidth` is only ever passed
      // deliberately, and only the player cover passes a big one (720); the
      // blurred backdrop passes ~360 and so stays on the cheap rung, which is
      // right because blur destroys the detail anyway.
      final bool wantsMaxres = (decodeWidth ?? 0) >= 600;
      // THE PRIMARY URL NEVER ASKS FOR maxres. It is built with
      // allowMaxres:false so what loads first is always a variant that exists;
      // the sharp one is requested separately as an UPGRADE below. Asking for it
      // here made every player cover a coin-flip between instant, slow (404 then
      // retry) and blank.
      final String optimizedUrl = _sizeParamForBox(
          _ytimgVariantForBox(_getOptimizedImageUrl(path, quality), declaredPx),
          declaredPx,
          allowHighRes);

      final String? localResolvedPath =
          AudioCacheManager().getLocalPathFromUrl(path);
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

    // ONE Image widget for every source — do not split this back into
    // `Image.file` vs `CachedNetworkImage` branches.
    //
    // The source for a given piece of art CHANGES WHILE IT IS ON SCREEN: a
    // streaming track gets promoted into the cache mid-playback, which writes its
    // cover to disk, so `getLocalPathFromUrl` starts returning a path that was
    // null a moment ago. When the two branches were different widget TYPES,
    // Flutter could not reconcile them — it tore down the network image element
    // and mounted a fresh file one, which decoded from scratch and painted the
    // placeholder for a frame.
    //
    // That is the mini-player "cover flickers the first time I pause a new track"
    // bug: pausing was simply the first rebuild after the file appeared, which is
    // why it fired once per track and never again. Same widget type + a changed
    // provider reuses the element, and `gaplessPlayback` holds the last decoded
    // frame until the new one is ready, so the swap is invisible.
    return _GaplessArt(
      provider: ResizeImage.resizeIfNeeded(decodePx, null, provider),
      upgradeProvider: upgradeSource == null
          ? null
          : ResizeImage.resizeIfNeeded(decodePx, null, upgradeSource),
      // double.infinity is a legal constraint here, but the old network branch
      // nulled it so an unbounded box could size itself naturally — keep that.
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

  // A single decode dimension (the LARGER known box side × pixel ratio) applied
  // to ONE axis only. Passing just one axis to the decoder preserves the image's
  // aspect ratio — both axes force an exact WxH resize that stretches non-square
  // art (the "artists look squished" bug). BoxFit.cover then crops evenly.
  // Returns null for infinite/unknown dimensions so unbounded slots don't throw.
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

  /// Rewrite a Google CDN **size parameter** (`=s800`, `=w544-h544-l90-rj`) down
  /// to what this widget will actually paint.
  ///
  /// WHY: `_getOptimizedImageUrl` below only rewrites the `*default` FILENAME
  /// form (`i.ytimg.com/vi/<id>/maxresdefault.jpg`). Album and playlist art comes
  /// from `googleusercontent.com` with a `=sNNN` parameter instead, and
  /// `SearchService.getHighResImage()` stamps **`=s800`** on all of it. So a
  /// 170px grid tile was downloading an 800x800 image — about 22x the pixels it
  /// can show. `memCacheWidth` caps the DECODE, not the transfer, so those bytes
  /// were still crossing the network before anything appeared on screen. That is
  /// the "covers take a while" cost, and it applied to every list in the app.
  ///
  /// Sizes are snapped to a LADDER rather than passed through exactly. Two
  /// reasons: the CDN (and our own disk cache) key on the URL, so arbitrary
  /// per-tile widths would fragment into a separate download per layout instead
  /// of one shared entry; and a request slightly larger than the box keeps the
  /// image sharp when the same art is later shown a little bigger.
  ///
  /// Untouched when the target is unknown (`null` — an unbounded box, e.g. the
  /// full-screen blurred backdrop, which passes `decodeWidth` explicitly), so
  /// this can never make an image LOWER resolution than it needs.
  static const List<int> _sizeLadder = [64, 128, 192, 256, 384, 512, 720];

  /// The exact url the PLAYER PAGE cover will request for [path].
  ///
  /// Exists so the player cover can be warmed, AND it must stay exact.
  ///
  /// Every surface asks the CDN for roughly what it will paint, so a list tile
  /// fetches `=s192`/`mqdefault` while the player fetches the 720 variant. Those
  /// are DIFFERENT CACHE ENTRIES: opening the player for a track whose art you
  /// have scrolled past twenty times was still a cold download, which is the
  /// "cover art loads slowly on the player page, as if something is inhibiting
  /// it" report. Nothing was inhibiting it — it had simply never been fetched.
  ///
  /// The fix is to warm this url when a track is staged (see player_smart's
  /// preload). That only works if the string matches byte for byte, which is why
  /// this reuses the same two helpers the widget itself uses rather than
  /// re-deriving anything. If the widget's url construction changes, this MUST
  /// change with it or the warming silently fetches something nobody displays —
  /// wasted data, which is worse than the slow paint it was meant to fix.
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

    // Snap up to the ladder. On Data Saver, take the rung BELOW the ideal.
    //
    // NO 15% OVERSHOOT — IT BOUGHT NOTHING AND COST A WHOLE RUNG.
    //
    // This asked for `targetPx * 1.15` "so scaling stays clean", but the result
    // is then snapped UP to the next ladder rung anyway, so the padding only ever
    // decided which rung. A 494 px tile wanted 568 and therefore fetched `=s720`
    // instead of `=s512` — roughly double the bytes for an image that is painted
    // at 494 either way, and a THIRD distinct url for the same artwork, which
    // fragments the disk cache that is already evicting too eagerly.
    //
    // Snapping up from the true size still guarantees the request is never
    // smaller than the box, which is the only thing the padding was protecting.
    final want = targetPx;
    var chosen = _sizeLadder.firstWhere((s) => s >= want,
        orElse: () => _sizeLadder.last);
    if (!allowHighRes) {
      final i = _sizeLadder.indexOf(chosen);
      if (i > 0) chosen = _sizeLadder[i - 1];
    }
    return '${url.substring(0, match.start)}=s$chosen';
  }

  /// Pick the `i.ytimg.com` **filename variant** that matches the box, the same
  /// way [_sizeParamForBox] matches the `=sNNN` parameter for CDN art.
  ///
  /// The quality buckets ignored the box entirely, AND that cost real sharpness.
  /// `_sizeParamForBox` only rewrites `googleusercontent`/`ggpht` urls, so for a
  /// YouTube thumbnail the low/medium/high bucket was the whole decision, and the
  /// player cover asks for `medium`, i.e. **mqdefault at 320x180**, then upscales
  /// it into a near-1080px square. A grid tile and a full-screen cover were being
  /// served the same 320px image: too soft for one, and no cheaper for the other.
  ///
  /// Sizing it properly is what makes storage track what is actually shown —
  /// small tiles keep the small file, and only the big cover pays for a big one.
  ///
  /// maxresdefault IS ASKED FOR ONLY WHERE IT ACTUALLY SHOWS, AND ONLY WITH A
  /// Fallback behind it.
  ///
  /// It was previously capped at `hqdefault` (480×360) everywhere, because
  /// `maxres` genuinely does not exist for many videos and 404s into a grey
  /// placeholder. But that ceiling made the near-fullscreen PLAYER cover a 480px
  /// image upscaled onto a ~1080px box — visibly soft, and no cheaper for the
  /// tiles that never wanted it. Frugal in the wrong place is not optimisation.
  ///
  /// So the rung follows the box, up to maxres for a genuinely large surface, and
  /// the 404 risk is handled where it belongs: [_GaplessArt] retries once at
  /// `hqdefault` (which is always present) before showing a placeholder. Quality
  /// where it is visible, no extra bytes for tiles, and no reliability cost.
  static String _ytimgVariantForBox(String url, int? targetPx,
      {bool allowMaxres = false}) {
    if (!url.contains('ytimg.com')) return url;
    // Unknown box → leave it alone rather than guess downward.
    if (targetPx == null || targetPx <= 0) return url;
    // 120 / 320 / 480 / 1280 are the pixel widths of the four variants.
    //
    // maxres IS GATED ON [allowMaxres], NOT ON SIZE — AND THAT DISTINCTION IS
    // WORTH 10× THE APP'S DATA USE.
    //
    // It was first gated on `targetPx > 480`, which sounds like "only big
    // surfaces". It is not: this phone reports 420 dpi, so the pixel ratio is
    // ~2.6 and an ordinary GRID TILE of ~190 logical px lands at ~500 — over the
    // line. Album grids and home shelves therefore started pulling 1280×720
    // covers instead of 480×360, roughly 5× the bytes per tile, and decoding
    // those is what made a long list feel locked while scrolling.
    //
    // Measured: 8 minutes of browsing with NO playback cost 112 MB (~821 MB/h),
    // against 15 MB for 11 minutes of actual listening. Images are invisible in
    // the log, which is why it took a byte counter to see it at all.
    //
    // A derived size cannot express "this is the one surface where sharpness is
    // worth it". An explicit opt-in can, and only the player cover asks.
    final want = targetPx <= 120
        ? 'default'
        : (targetPx <= 320
            ? 'mqdefault'
            : ((targetPx <= 480 || !allowMaxres)
                ? 'hqdefault'
                : 'maxresdefault'));
    // Match the whole filename, never a suffix of it.
    //
    // Replacing `'default.jpg'` first looks harmless and is not: EVERY variant
    // name ENDS with it. `mqdefault.jpg` is `mq` + `default.jpg`, so a substring
    // replace turned it into `mqhqdefault.jpg` — a url that 404s into a grey
    // placeholder. Urls that happened to be plain `default.jpg` still worked,
    // which is what "some load, some don't" looked like.
    //
    // The optional prefix group anchors the match at the start of the real
    // filename, so each of default / mqdefault / hqdefault / sddefault /
    // maxresdefault is rewritten exactly once, as a whole.
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
    
    // Spotify images
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