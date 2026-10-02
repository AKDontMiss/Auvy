import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';

class PageCacheService {
  static const String _homeDataKey = 'cached_home_data';
  static const String _homeTimestampKey = 'cached_home_timestamp';
  // Home recommendations must stay fresh (a 15-day TTL was freezing stale/wrong
  // content on screen). Album/artist pages are far more static, so they can live
  // longer on disk.
  static const Duration _homeValidDuration = Duration(hours: 6);
  static const Duration _cacheValidDuration = Duration(days: 3);

  static bool _purgeScheduled = false;

  PageCacheService() {
    // Remove expired entries once per session. Getters ignore entries past their
    // TTL, but the keys stayed in SharedPreferences, which is loaded whole at every
    // launch.
    if (!_purgeScheduled) {
      _purgeScheduled = true;
      Future(purgeExpired);
    }
  }

  /// Remove every page-cache entry past its TTL (artist/album/track lists).
  Future<void> purgeExpired() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAge = _cacheValidDuration.inMilliseconds;
      int removed = 0;
      for (final key in prefs.getKeys().toList()) {
        if (!key.endsWith('_timestamp')) continue;
        // Only THIS service's key families ('album_tracks_v2_…' also starts
        // with 'album_' and legacy 'album_tracks_' keys are swept along, as
        // well as secondary page sections).
        if (!key.startsWith('artist_') &&
            !key.startsWith('album_') &&
            !key.startsWith(_sectionPrefix)) continue;
        final ts = prefs.getInt(key);
        if (ts == null || now - ts > maxAge) {
          await prefs.remove(key);
          await prefs.remove(key.substring(0, key.length - '_timestamp'.length));
          removed++;
        }
      }
      if (removed > 0) print('Page cache: purged $removed expired entr${removed == 1 ? 'y' : 'ies'}');
    } catch (_) {}
  }
  
  /// Cache home page data
  Future<void> cacheHomeData(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _writeHomeFile(jsonEncode(data));
      await prefs.setInt(_homeTimestampKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.remove(_homeDataKey); // the pre-file copy, if any
      print("Home page data cached");
    } catch (e) {
      print("ERROR: Failed to cache home data: $e");
    }
  }
  
  /// Cached home page data if still valid. [allowStale] serves it even past its
  /// TTL or from a previous day; set when offline (like [getCachedArtistData]),
  /// because offline a cache miss would go to the network and fail, leaving the
  /// home feed empty. Stale beats blank.
  Future<Map<String, dynamic>?> getCachedHomeData({bool allowStale = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt(_homeTimestampKey);
      
      if (timestamp == null) return null;
      
      final cacheAge = DateTime.now().millisecondsSinceEpoch - timestamp;
      final cacheAgeDuration = Duration(milliseconds: cacheAge);

      if (!allowStale && cacheAgeDuration > _homeValidDuration) {
        print("Home cache expired (${cacheAgeDuration.inHours} hours old)");
        return null;
      }

      // DAILY ROTATION (Discover-Weekly style): regenerate the home feed once the
      // local CALENDAR DAY changes, so "Mixed for you" mutates every day while
      // staying stable within a day. (The multi-day TTL above still caps it.)
      final cachedDay = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final now = DateTime.now();
      if (!allowStale &&
          (cachedDay.year != now.year ||
              cachedDay.month != now.month ||
              cachedDay.day != now.day)) {
        print("Home cache is from a previous day — regenerating for daily rotation");
        return null;
      }
      
      final dataStr = await _readHomeFile(prefs);
      if (dataStr == null) return null;
      
      print("Using cached home data (${cacheAgeDuration.inDays} days old)");
      return jsonDecode(dataStr) as Map<String, dynamic>;
    } catch (e) {
      print("ERROR: Failed to load cached home data: $e");
      return null;
    }
  }
  
  
  /// Force clear home cache
  Future<void> clearHomeCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_homeDataKey);
    await prefs.remove(_homeTimestampKey);
    final f = await _homeFile();
    if (f != null && f.existsSync()) f.deleteSync();
    print("Home cache cleared");
  }

  // The home feed lives in a file, not SharedPreferences. At ~200 KB it was the
  // largest value in prefs, and prefs are loaded whole at startup and rewritten
  // whole on every change, so every small settings save re-wrote the feed too.
  // The timestamp stays in prefs; it's tiny and read on its own.
  //
  // Stored in Application Support, not Documents, which is visible in the iOS
  // Files app and this is a personalised feed. The account-switch wipe calls
  // [clearHomeCache], since clearing prefs keys alone would leave this file.
  static const String _homeFileName = 'home_feed_cache.json';

  static Future<File?> _homeFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/$_homeFileName');
    } catch (_) {
      return null;
    }
  }

  /// Atomic: a crash mid-write leaves the previous feed, not half of one.
  static Future<void> _writeHomeFile(String json) async {
    final f = await _homeFile();
    if (f == null) return;
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(f.path);
  }

  /// The feed, from the file — or, once, from the pre-file prefs copy, which
  /// is moved across so an offline first launch after updating still has it.
  static Future<String?> _readHomeFile(SharedPreferences prefs) async {
    final f = await _homeFile();
    if (f != null && f.existsSync()) {
      try {
        return await f.readAsString();
      } catch (_) {}
    }
    final legacy = prefs.getString(_homeDataKey);
    if (legacy != null) {
      try {
        await _writeHomeFile(legacy);
        await prefs.remove(_homeDataKey);
      } catch (_) {}
    }
    return legacy;
  }
  
  /// Cache key for one artist's page data. Versioned because the cache stores
  /// already-classified results (albums / singles / live albums as sorted lists),
  /// so a change to how SearchService classifies releases wouldn't show for cached
  /// artists until the 3-day TTL expired. Bump the version whenever the shape or
  /// classification of ArtistData changes; it costs one refetch per artist.
  static const String _artistSchema = 'v2';

  static String artistCacheKey(String artistId) => 'artist_${_artistSchema}_$artistId';

  /// Cache artist page data
  Future<void> cacheArtistData(String artistId, ArtistData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(artistCacheKey(artistId), jsonEncode(data.toJson()));
      await prefs.setInt('${artistCacheKey(artistId)}_timestamp', DateTime.now().millisecondsSinceEpoch);
      print("Artist data cached for $artistId");
    } catch (e) {
      print("ERROR: Failed to cache artist data: $e");
    }
  }
  
  /// Get cached artist data. [allowStale] serves entries past their TTL —
  /// used offline / after a failed fetch, where stale beats an error screen.
  Future<ArtistData?> getCachedArtistData(String artistId, {bool allowStale = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('${artistCacheKey(artistId)}_timestamp');

      if (timestamp == null) return null;

      final cacheAge = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - timestamp);
      if (!allowStale && cacheAge > _cacheValidDuration) return null;

      final dataStr = prefs.getString(artistCacheKey(artistId));
      if (dataStr == null) return null;
      
      return ArtistData.fromJson(jsonDecode(dataStr));
    } catch (e) {
      print("ERROR: Failed to load cached artist data: $e");
      return null;
    }
  }

  
  
  
  /// Get cache age for display
  Future<Duration?> getCacheAge(String key) async {
    final prefs = await SharedPreferences.getInstance();
    int? timestamp = prefs.getInt('${key}_timestamp') ?? prefs.getInt(key);
    if (timestamp == null) return null;
    return Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - timestamp);
  }

  // v2 retired track lists cached before the continuation fix (they were
  // truncated). v3 retires entries cached before the cover-art fix, when a track
  // on several editions could store another edition's cover. Cached lists are
  // served instead of fetching, so fixes only show once old entries are gone.
  static const String _albumTracksPrefix = 'album_tracks_v3_';

  /// Cache album tracks
  Future<void> cacheAlbumTracks(String albumId, List<Song> tracks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tracksJson = tracks.map((s) => s.toMap()).toList();
      await prefs.setString('$_albumTracksPrefix$albumId', jsonEncode(tracksJson));
      await prefs.setInt('$_albumTracksPrefix${albumId}_timestamp', DateTime.now().millisecondsSinceEpoch);
      print("Album tracks cached for $albumId");
    } catch (e) {
      print("ERROR: Failed to cache album tracks: $e");
    }
  }

  /// Get cached album tracks. [allowStale]: see [getCachedArtistData].
  Future<List<Song>?> getCachedAlbumTracks(String albumId, {bool allowStale = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('$_albumTracksPrefix${albumId}_timestamp');

      if (timestamp == null) return null;

      final cacheAge = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - timestamp);
      if (!allowStale && cacheAge > _cacheValidDuration) return null;

      final dataStr = prefs.getString('$_albumTracksPrefix$albumId');
      if (dataStr == null) return null;

      final List<dynamic> tracksJson = jsonDecode(dataStr);
      return tracksJson.map((json) => Song.fromMap(json)).toList();
    } catch (e) {
      print("ERROR: Failed to load cached album tracks: $e");
      return null;
    }
  }

  // Secondary page sections. A page is several fetches, and only the main one used
  // to be saved to disk (e.g. an album's "Other versions" and an artist's image
  // were memory-only), so a reopened page showed its main list instantly while
  // the rest reloaded. These helpers give secondary sections the same persistence
  // and TTL as the page's main content.
  static const String _sectionPrefix = 'page_section_v1_';

  /// Persist a decoded-JSON section under [key] (e.g. 'album_versions:`<id>`').
  Future<void> cacheSection(String key, Object jsonValue) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_sectionPrefix$key', jsonEncode(jsonValue));
      await prefs.setInt(
          '$_sectionPrefix${key}_timestamp', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      print("ERROR: Failed to cache section $key: $e");
    }
  }

  /// Read a section back, or null when absent/expired. [allowStale]: see
  /// [getCachedArtistData] — offline, something stale beats a guaranteed miss.
  Future<Object?> getCachedSection(String key, {bool allowStale = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('$_sectionPrefix${key}_timestamp');
      if (timestamp == null) return null;
      final age =
          Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - timestamp);
      if (!allowStale && age > _cacheValidDuration) return null;
      final raw = prefs.getString('$_sectionPrefix$key');
      if (raw == null) return null;
      return jsonDecode(raw);
    } catch (e) {
      print("ERROR: Failed to load section $key: $e");
      return null;
    }
  }

  /// Clear all cached artist, album, page section, and home page data.
  Future<void> clearAllPageCaches() async {
    try {
      await clearHomeCache();
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith('artist_') ||
            key.startsWith('album_') ||
            key.startsWith(_sectionPrefix)) {
          await prefs.remove(key);
        }
      }
      print("Page cache: all page caches cleared");
    } catch (e) {
      print("ERROR: Failed to clear all page caches: $e");
    }
  }
}