import 'dart:convert';
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
    // Self-cleaning: expired entries used to be left in SharedPreferences
    // FOREVER (getters return null past TTL but never removed the keys), so
    // every artist/album page ever visited grew the prefs file, which is
    // loaded whole into memory on app start — without bound. One background
    // sweep per session keeps it flat.
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
        // with 'album_' and legacy 'album_tracks_' keys are swept along).
        if (!key.startsWith('artist_') && !key.startsWith('album_')) continue;
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
      await prefs.setString(_homeDataKey, jsonEncode(data));
      await prefs.setInt(_homeTimestampKey, DateTime.now().millisecondsSinceEpoch);
      print(" Home page data cached");
    } catch (e) {
      print("ERROR: Failed to cache home data: $e");
    }
  }
  
  /// Get cached home page data if valid
  /// [allowStale] — serve the cache even when it is past its TTL or from a
  /// previous day. Set when the device is OFFLINE. Same idea as
  /// [getCachedArtistData].
  ///
  /// Both freshness rules below return null, and a null cache sends the home
  /// provider off to the NETWORK. Offline that fetch fails, so the feed rendered
  /// empty apart from the recents mosaic, which is local state, not cache, and
  /// is exactly why the mosaic was the one thing that still appeared. Throwing
  /// away readable content in order to go and fetch nothing is the worst of both
  /// outcomes; stale beats blank.
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
      
      final dataStr = prefs.getString(_homeDataKey);
      if (dataStr == null) return null;
      
      print(" Using cached home data (${cacheAgeDuration.inDays} days old)");
      return jsonDecode(dataStr) as Map<String, dynamic>;
    } catch (e) {
      print("ERROR: Failed to load cached home data: $e");
      return null;
    }
  }
  
  /// Check if cache is still valid
  Future<bool> isHomeDataValid() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_homeTimestampKey);
    
    if (timestamp == null) return false;
    
    final cacheAge = DateTime.now().millisecondsSinceEpoch - timestamp;
    return Duration(milliseconds: cacheAge) <= _homeValidDuration;
  }
  
  /// Force clear home cache
  Future<void> clearHomeCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_homeDataKey);
    await prefs.remove(_homeTimestampKey);
    print("Home cache cleared");
  }
  
  /// Cache key for one artist's page data.
  ///
  /// THE VERSION IS PART OF THE KEY BECAUSE THIS CACHE STORES A *CLASSIFIED*
  /// Result, NOT a raw response.
  ///
  /// ArtistData holds albums / singles / liveAlbums as already-sorted lists, so a
  /// change to how SearchService sorts releases into those buckets does NOT take
  /// effect for any artist already cached — the TTL is three days, so a fix looks
  /// like it did nothing for three days on exactly the artists the user visits
  /// most. That happened with the `contains('live')` fix: "Alive" stayed filed
  /// under Live performances after the code no longer put it there.
  ///
  /// Bumping this version retires every old entry at once. **Bump it whenever the
  /// shape or the classification of ArtistData changes** — it costs one refetch
  /// per artist and nothing else.
  static const String _artistSchema = 'v2';

  static String artistCacheKey(String artistId) => 'artist_${_artistSchema}_$artistId';

  /// Cache artist page data
  Future<void> cacheArtistData(String artistId, ArtistData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(artistCacheKey(artistId), jsonEncode(data.toJson()));
      await prefs.setInt('${artistCacheKey(artistId)}_timestamp', DateTime.now().millisecondsSinceEpoch);
      print(" Artist data cached for $artistId");
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

  Future<void> clearArtistCache(String artistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(artistCacheKey(artistId));
    await prefs.remove('${artistCacheKey(artistId)}_timestamp');
    print("Artist cache cleared for $artistId");
  }
  
  /// Cache album page data
  Future<void> cacheAlbumData(String albumId, Album album) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('album_$albumId', jsonEncode(album.toMap()));
      await prefs.setInt('album_${albumId}_timestamp', DateTime.now().millisecondsSinceEpoch);
      print(" Album data cached for $albumId");
    } catch (e) {
      print("ERROR: Failed to cache album data: $e");
    }
  }
  
  /// Get cached album data. [allowStale]: see [getCachedArtistData].
  Future<Album?> getCachedAlbumData(String albumId, {bool allowStale = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('album_${albumId}_timestamp');

      if (timestamp == null) return null;

      final cacheAge = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - timestamp);
      if (!allowStale && cacheAge > _cacheValidDuration) return null;
      
      final dataStr = prefs.getString('album_$albumId');
      if (dataStr == null) return null;
      
      return Album.fromMap(jsonDecode(dataStr));
    } catch (e) {
      print("ERROR: Failed to load cached album data: $e");
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

  // v2: album track lists cached before the audio-only-prune/continuation fix
  // are TRUNCATED; a new key prefix orphans them so every album refetches full.
  //
  // v3: entries cached before the cover-art fix hold the WRONG ARTWORK. Album
  // rows used to keep their own thumbnail when they had one, so a track that
  // exists on more than one edition stored whichever cover its row referenced —
  // a video thumbnail, or the other edition's sleeve. The tracklist now stamps
  // the opened album's cover on every row, but a fix in the fetch path is
  // invisible while a cached list is served INSTEAD of fetching: the artwork
  // stays wrong until the entry expires. Orphaning them makes it take effect on
  // the next open.
  static const String _albumTracksPrefix = 'album_tracks_v3_';

  /// Cache album tracks
  Future<void> cacheAlbumTracks(String albumId, List<Song> tracks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tracksJson = tracks.map((s) => s.toMap()).toList();
      await prefs.setString('$_albumTracksPrefix$albumId', jsonEncode(tracksJson));
      await prefs.setInt('$_albumTracksPrefix${albumId}_timestamp', DateTime.now().millisecondsSinceEpoch);
      print(" Album tracks cached for $albumId");
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

  // Secondary page sections
  //
  // This is why a page came back half-cached.
  //
  // A screen is not one fetch, it is several, and only the main one was ever
  // written to disk. The album page cached its TRACKLIST for three days but
  // "Other versions" lived solely in CatalogApiClient's in-memory map behind a
  // 30-minute TTL; artist pages cached ArtistData for three days while the
  // artist IMAGE was memory-only. Both of those die with the process. So
  // reopening a page showed the big list instantly from disk and made the
  // smaller sections spin again — the parts of one screen expiring on different
  // clocks, which reads as the page being half loaded.
  //
  // These generic helpers give any secondary section the SAME persistence and
  // the SAME TTL as its page's main content, so a page comes back whole.
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

  /// Clear specific album cache
  Future<void> clearAlbumCache(String albumId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_albumTracksPrefix$albumId');
    await prefs.remove('$_albumTracksPrefix${albumId}_timestamp');
    // Pre-v2 leftovers from before the truncation fix.
    await prefs.remove('album_tracks_$albumId');
    await prefs.remove('album_tracks_${albumId}_timestamp');
    await prefs.remove('album_$albumId');
    await prefs.remove('album_${albumId}_timestamp');
    print("Album cache fully cleared for $albumId");
  }
  
}