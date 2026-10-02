import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/core/image_cache_manager.dart';

/// Local files for media-notification artwork.
///
/// The app's image cache and Android's notification each fetch artwork on their
/// own, so a cover shown in the app can be missing from the notification. Some
/// system surfaces (such as Samsung's Now Bar) read only the first update, so the
/// art has to be there from the start.
///
/// Passing a `file://` URI solves this: Android reads the file immediately while
/// building the notification. This class turns a cover URL into a local path,
/// reusing the file the app's image cache already downloaded.
class MediaArtworkCache {
  MediaArtworkCache._();

  /// URL → local path. Filled by [warm]; read synchronously when building a
  /// MediaItem.
  static final Map<String, String> _resolved = {};

  /// URLs being fetched, so concurrent requests for one cover share one download.
  static final Map<String, Future<String?>> _inFlight = {};

  /// Bounded; only covers near the current queue position are needed.
  static const int _maxEntries = 120;

  /// The local file for [url] if it is already on disk, else null. Synchronous
  /// because the MediaItem is built in non-async code.
  static String? localPath(String url) {
    final path = _resolved[url];
    if (path == null) return null;
    // The file may have been deleted by cache eviction; a dead path would be worse
    // than the network URL.
    final file = File(path);
    if (file.existsSync() && file.lengthSync() > 0) return path;
    if (file.existsSync()) {
      try {
        file.deleteSync();
        print('MediaArtworkCache: purged 0-byte corrupted artwork file at $path');
      } catch (_) {}
    }
    _resolved.remove(url);
    return null;
  }

  /// Makes sure [url] is on disk and remembers where. Returns the path, or null if
  /// it cannot be fetched. Repeat calls are cheap and concurrent calls share one
  /// download.
  ///
  /// Uses [CustomImageCacheManager], the store the app's images and the next-track
  /// preload write to (and audio_service loads artwork through), so a cover the app
  /// has already fetched at the same URL is a disk lookup rather than a second
  /// download.
  static Future<String?> warm(String url) async {
    if (url.isEmpty || !url.startsWith('http')) return null;
    final existing = localPath(url);
    if (existing != null) return existing;
    final inFlightFuture = _inFlight[url];
    if (inFlightFuture != null) {
      print('MediaArtworkCache: coalescing concurrent warm for $url');
      return inFlightFuture;
    }

    final future = _warmInternal(url);
    _inFlight[url] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(url);
    }
  }

  static Future<String?> _warmInternal(String url) async {
    try {
      final cm = CustomImageCacheManager();
      // Check the cache first so a hit never touches the network.
      FileInfo? info = await cm.getFileFromCache(url);
      info ??= await cm.downloadFile(url);
      final path = info.file.path;
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) {
        if (file.existsSync()) {
          try {
            await file.delete();
            print('MediaArtworkCache: purged 0-byte downloaded file at $path');
          } catch (_) {}
        }
        return null;
      }
      if (_resolved.length >= _maxEntries) {
        _resolved.remove(_resolved.keys.first);
      }
      _resolved[url] = path;
      print('MediaArtworkCache: warm complete for $url -> $path (${file.lengthSync()} bytes)');
      return path;
    } catch (_) {
      // A failed cover is not worth surfacing; the caller falls back to the URL.
      return null;
    }
  }

  /// Empties the default store once. Covers were kept there before they moved to
  /// the app's store, and nothing reads them now.
  static Future<void> dropLegacyStore() async {
    const flag = 'auvy_artwork_legacy_store_dropped';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(flag) == true) return;
      await DefaultCacheManager().emptyCache();
      await prefs.setBool(flag, true);
      print('MediaArtworkCache: emptied the old artwork store');
    } catch (_) {
      // Retried next launch; the files are in a cache directory either way.
    }
  }

  /// Forget one cached URL.
  static void evict(String url) {
    if (_resolved.remove(url) != null) {
      print('MediaArtworkCache: evicted $url');
    }
  }

  /// Forget all cached entries.
  static void clear() {
    _resolved.clear();
    print('MediaArtworkCache: cleared all cached artwork paths');
  }

  /// Pre-fetches covers for upcoming tracks, so their first notification update
  /// has art (autoplay picks are often never displayed before they play).
  static Future<void> warmAll(Iterable<String> urls) async {
    // Fetched in parallel; cache hits cost nothing and duplicate URLs share one
    // download.
    await Future.wait(urls.take(4).map(warm));
  }
}
