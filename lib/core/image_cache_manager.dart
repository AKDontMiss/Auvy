import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:auvy/services/http_pool.dart';

/// Counts image downloads for the diagnostics log.
///
/// Images load through the cache manager's own file service, so they need their
/// own counter. [repeats] counts URLs downloaded more than once this session; a
/// high number means the disk cache is evicting art that is still in use.
class _CountingFileService extends FileService {
  final FileService _inner;
  _CountingFileService(this._inner);

  static int fetches = 0;
  static int repeats = 0;

  /// Fetches whose response did not declare a size.
  static int unsized = 0;
  // Bounded, so the diagnostic cannot grow without limit.
  static final Set<String> _seen = {};

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final response = await _inner.get(url, headers: headers);
    fetches++;
    if (_seen.length > 4000) _seen.clear();
    if (!_seen.add(url)) repeats++;
    if ((response.contentLength ?? 0) <= 0) unsized++;
    // Logged every 25 fetches rather than per image. Byte totals come from the
    // data-usage tracker (these fetches go through the tracked client); this counter
    // reports fetch and repeat counts, which that tracker cannot see.
    if (fetches % 25 == 0) {
      print('images: $fetches fetched, $repeats REPEATS'
          '${unsized > 0 ? ', $unsized unsized' : ''}'
          ' — bytes are on Storage & data (artwork)');
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
      // Sized for a whole browsing session. The cache evicts by object count and one
      // cover can be stored at several sizes, so a small limit evicts art that is
      // still on screen and re-downloads it on scroll-back. 2500 covers is a couple of
      // hundred MB at most, and old entries are still pruned by `stalePeriod`.
      maxNrOfCacheObjects: 2500,
      repo: JsonCacheInfoRepository(databaseName: key),
      // Uses the app's shared, tracked HTTP client, so image bytes show up in the
      // Storage & data screen and reuse pooled connections.
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