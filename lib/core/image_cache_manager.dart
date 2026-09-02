import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:auvy/services/http_pool.dart';

/// Counts image downloads, because nothing else does.
///
/// IMAGE TRAFFIC WAS INVISIBLE — TO THE LOG AND TO THE APP'S OWN DATA SCREEN.
/// `CachedNetworkImage` fetches through the CacheManager's own `HttpFileService`,
/// not through the tracked [HttpPool] client, so image bytes appear in neither
/// place. That is why three rounds of measurement could narrow the browsing cost
/// (821 → 545 MB/h) without ever identifying it: the largest consumer left no
/// trace anywhere.
///
/// [repeats] is the decisive number. A repeat means this session downloaded a url
/// it had ALREADY downloaded — i.e. the disk cache evicted something still in
/// use. Many repeats means eviction thrash; near-zero repeats means the volume is
/// genuinely new art and the fix belongs in how much is requested, not in caching.
class _CountingFileService extends FileService {
  final FileService _inner;
  _CountingFileService(this._inner);

  static int fetches = 0;
  static int repeats = 0;
  static int bytes = 0;
  // Bounded: this is a diagnostic, and it must not become the leak it measures.
  static final Set<String> _seen = {};

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final response = await _inner.get(url, headers: headers);
    fetches++;
    if (_seen.length > 4000) _seen.clear();
    if (!_seen.add(url)) repeats++;
    final len = response.contentLength ?? 0;
    if (len > 0) bytes += len;
    // Summarised, not one line per cover — enough to attribute a browsing
    // session without drowning the log it shares with playback.
    if (fetches % 25 == 0) {
      print('images: $fetches fetched, $repeats REPEATS, '
          '~${(bytes / 1024 / 1024).toStringAsFixed(1)} MB');
    }
    return response;
  }
}

class CustomImageCacheManager extends CacheManager {
  static const key = 'auvyImageCache';
  
  static final CustomImageCacheManager _instance = CustomImageCacheManager._();
  factory CustomImageCacheManager() => _instance;
  
  CustomImageCacheManager._() : super(
    Config(
      key,
      stalePeriod: const Duration(days: 30),
      // 600 WAS TOO SMALL TO HOLD ONE BROWSING SESSION, AND THAT COSTS DATA
      // Continuously rather than once.
      //
      // flutter_cache_manager evicts by OBJECT COUNT, and the app stores several
      // SIZE VARIANTS of the same artwork under different urls (`=s192` for a
      // row, `=s512` for a card, `=s720` for a hero), so one cover can occupy
      // three or four slots. A 300-track playlist plus a couple of grids passes
      // 600 easily, and then the cache starts evicting art the user is still
      // scrolling through. Scroll down, it evicts; scroll back, it downloads
      // again. Measured: 8 minutes of pure browsing cost 89–112 MB (~641–821
      // MB/h) against 15 MB for 11 minutes of listening. Nothing in the code
      // reads as wrong at any single call site; the cache simply never holds.
      //
      // 2500 objects at a typical 30–120 KB per cover is a bounded couple of
      // hundred MB worst case, still pruned by `stalePeriod`, and it lets a
      // session actually settle instead of re-fetching itself.
      maxNrOfCacheObjects: 2500,
      repo: JsonCacheInfoRepository(databaseName: key),
      // Through the app's tracked client, NOT a private one.
      //
      // A bare HttpFileService makes its own http.Client, which bypasses
      // DataTrackingHttpClient, so every cover ever downloaded was invisible to
      // the Storage & data screen, and that screen was under-reporting the app's
      // LARGEST consumer. Handing it the pool's client makes those bytes land in
      // the 'artwork' bucket where they belong, and reuses the pooled connection
      // instead of opening a second one.
      //
      // Still wrapped in the counter as well: the counter answers "how many
      // fetches, and how many were REPEATS", which is a different question from
      // "how many bytes" and the one that catches cache thrash.
      fileService: _CountingFileService(
          HttpFileService(httpClient: HttpPool().getClient())),
    ),
  );
  
  Future<void> preloadImage(String url) async {
    if (url.isEmpty || !url.startsWith('http')) return;
    try {
      await downloadFile(url);
    } catch (e) {
      print('WARN: Image preload failed: $url');
    }
  }

}