import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Local files for media-notification artwork.
///
/// Why the notification loses art the player page is already showing
///
/// There are TWO independent artwork caches on the device and they do not share
/// anything:
///
///   • The Flutter side. `AuvyImage` draws through `CachedNetworkImageProvider`,
///     so every cover the app has ever displayed is already a FILE on disk,
///     managed by flutter_cache_manager.
///   • The native side. audio_service hands `MediaItem.artUri` to Android, and
///     for an `http(s)` URI Android fetches and decodes it ITSELF, into its own
///     cache, on its own schedule.
///
/// So a cover can be on screen in the player and simultaneously absent from the
/// notification, which is exactly the reported symptom, and why it "fixes
/// itself" when you skip away and come back (by then the native side has its own
/// copy).
///
/// The visible failure is that the FIRST metadata publish carries no bitmap:
///
///     MediaControlPanel: bindArtworkAndColors no artwork      <- publish
///     MediaControlPanel: bindArtworkAndColors no artwork
///     MediaControlPanel: bindArtworkAndColors update artwork  <- ~15ms later
///     NowBarItemManager: title = Photograph album art = null  <- read the null
///
/// The notification panel recovers on the second publish. Samsung's Now Bar and
/// the AOD widget read the first one and cache the null, so they stay blank for
/// the whole track. Nothing here is a race we can win by retrying — the art has
/// to be present in the FIRST publish.
///
/// THE FIX IS A `file://` URI, NOT A FASTER DOWNLOAD. Android resolves a file
/// URI synchronously while it builds the notification, so the bitmap is in the
/// first publish and there is no window for anything to cache a null. This class
/// exists to turn a cover URL into that path, reusing the file the Flutter side
/// already downloaded rather than fetching the image a second time.
class MediaArtworkCache {
  MediaArtworkCache._();

  /// url -> on-disk path. Populated by [warm]; read synchronously by callers
  /// building a MediaItem, which cannot await.
  static final Map<String, String> _resolved = {};

  /// URLs currently being fetched, so N calls for one cover do one download.
  static final Set<String> _inFlight = {};

  /// Bounded so a long session cannot grow this without limit. Covers are keyed
  /// by URL and a queue only ever needs the nearby ones.
  static const int _maxEntries = 120;

  /// The local file for [url] if it is ALREADY on disk, else null.
  ///
  /// Deliberately synchronous: the MediaItem is built in a non-async path, and
  /// an await there would delay the notification for every track — trading a
  /// missing cover for a late one.
  static String? localPath(String url) {
    final path = _resolved[url];
    if (path == null) return null;
    // A cache eviction (or the OS clearing app cache) can delete the file while
    // the map still points at it. A stale path would publish an artUri that
    // resolves to nothing, which is worse than publishing the network URL.
    if (File(path).existsSync()) return path;
    _resolved.remove(url);
    return null;
  }

  /// Ensure [url] is on disk and remember where.
  ///
  /// Returns the path, or null if it could not be fetched. Cheap to call
  /// repeatedly: a hit returns immediately and concurrent calls for the same URL
  /// collapse into one download.
  ///
  /// Uses `DefaultCacheManager`, which is the SAME store cached_network_image
  /// writes to, so for any cover the app has displayed this is a disk lookup
  /// with no network at all.
  static Future<String?> warm(String url) async {
    if (url.isEmpty || !url.startsWith('http')) return null;
    final existing = localPath(url);
    if (existing != null) return existing;
    if (_inFlight.contains(url)) return null;
    _inFlight.add(url);
    try {
      final cm = DefaultCacheManager();
      // Check the cache before asking for the file: getSingleFile would also
      // return a cached entry, but this way a cache HIT never touches the
      // network stack even to validate.
      FileInfo? info = await cm.getFileFromCache(url);
      info ??= await cm.downloadFile(url);
      final path = info.file.path;
      if (!File(path).existsSync()) return null;
      if (_resolved.length >= _maxEntries) {
        _resolved.remove(_resolved.keys.first);
      }
      _resolved[url] = path;
      return path;
    } catch (_) {
      // A cover that will not download is not an error worth surfacing: the
      // caller falls back to the network URI and Android may still get it.
      return null;
    } finally {
      _inFlight.remove(url);
    }
  }

  /// Pre-fetch covers for tracks about to play, so their FIRST publish has art.
  ///
  /// Without this the very next track is guaranteed to publish artless if the
  /// user has never seen its cover — the common case for autoplay/radio picks,
  /// whose Song.image is populated but never displayed before playback starts.
  static Future<void> warmAll(Iterable<String> urls) async {
    // TOGETHER, NOT ONE AFTER ANOTHER. These four covers have nothing to do
    // with each other, and the whole point of this class is that the art is
    // present in the FIRST metadata publish, so the fourth waiting behind three
    // downloads is working against its own purpose. Same bytes either way; a
    // cache hit costs no network at all, and `_inFlight` already collapses
    // concurrent calls for one url into a single download.
    await Future.wait(urls.take(4).map(warm));
  }
}
