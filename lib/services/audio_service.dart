// lib/services/audio_service.dart
//
// Thin orchestration layer over [StreamResolver]. This used to be a ~370-line
// file with a SoundCloud fallback, a 13-client rotation, JS cipher decoding and
// bespoke retry/cooldown maps. All of that is gone: streaming now flows through
// the single proven ANDROID→IOS path, with caching / de-dup / circuit-breaking
// handled by [StreamResolver]. The public surface used by callers
// (`getStreamWithFallback`, `markVideoAsFailed`, `dispose`) is preserved.

import 'package:auvy/services/stream_resolver.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/core/native_audio_engine.dart';

class AudioService {
  final StreamResolver _resolver = StreamResolver();
  final SearchService _search = SearchService();

  bool _isVideoId(String id) =>
      id.length == 11 && !id.startsWith('http') && !id.contains('/');

  /// Resolve a track to a directly-playable stream.
  ///
  ///   * If [id] is already a YouTube videoId, resolve it directly.
  ///   * Otherwise (e.g. ids imported from Spotify/Deezer) find the closest
  ///     YouTube Music match by title+artist, then resolve that.
  ///
  /// Returns `{url, user_agent, userAgent, mimeType, bitrate, ...}` or null.
  Future<Map<String, String>?> getStreamWithFallback(
    String id,
    String title,
    String artist, {
    int maxRetries = 3,
    bool prioritizeExplicit = true,
    bool? knownExplicitStatus,
    bool lowQuality = false,
    int clientStartIndex = 0,
    /// Adaptive ceiling in bps (0 = uncapped). See adaptive_bitrate.dart.
    int maxBitrate = 0,
    /// Ask for AAC-in-MP4 rather than the better-sounding Opus, so the bytes can
    /// hold tags and cover art. For DOWNLOADS ONLY — playback leaves it false and
    /// keeps the higher-quality codec.
    bool preferMp4 = false,

    /// Asked between clients whether this resolve is still worth finishing.
    /// Playback passes "is this still the current track" so a skip abandons the
    /// chain instead of spending the remaining clients — and a signed-in retry —
    /// on a track already off screen, then drawing session-wide conclusions from
    /// its failure. Background work (cache warming, downloads) leaves it null:
    /// nothing there is waiting on the user's attention.
    bool Function()? isStillWanted,
  }) async {
    // DIRECT URLs: podcast episode audio (RSS enclosure .mp3) and live radio
    // streams already ARE the playable URL — their id IS an http(s) URL. They
    // must NOT go through YouTube resolution (which rejected them and then
    // searched YouTube for the title, failed, and returned null — the reason
    // podcasts and radio "didn't work"). Hand the URL straight to the player.
    if (id.startsWith('http://') || id.startsWith('https://')) {
      // A real UA, not '' — the native layer sets the header verbatim and some
      // icecast/podcast CDNs reject requests with a blank User-Agent.
      return {
        'url': id,
        'user_agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        'source': 'direct',
      };
    }

    if (_isVideoId(id)) {
      final res = await _resolver.resolve(id, lowQuality: lowQuality, clientStartIndex: clientStartIndex, maxBitrate: maxBitrate, preferMp4: preferMp4, isStillWanted: isStillWanted);
      if (res != null) return _withUa(res);
    }

    if (title.trim().isNotEmpty) {
      final vid = await _findBestVideoId(title, artist);
      if (vid != null) {
        final res = await _resolver.resolve(vid, lowQuality: lowQuality, clientStartIndex: clientStartIndex, maxBitrate: maxBitrate, preferMp4: preferMp4, isStillWanted: isStillWanted);
        if (res != null) return _withUa({...res, 'videoId': vid});
      }
    }
    return null;
  }

  Future<String?> _findBestVideoId(String title, String artist) async {
    try {
      final query = artist.trim().isNotEmpty ? '$title $artist' : title;
      final songs = await _search.search(query, 'track');
      if (songs.isEmpty) return null;

      // YouTube Music already returns by relevance; prefer the first hit whose
      // title contains the (paren-stripped) target title.
      final needle = title.toLowerCase().split('(').first.trim();
      for (final s in songs) {
        if (s.id.length == 11 && s.title.toLowerCase().contains(needle)) return s.id;
      }
      final firstYt = songs.firstWhere((s) => s.id.length == 11, orElse: () => songs.first);
      return firstYt.id.length == 11 ? firstYt.id : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _withUa(Map<String, String> res) => {
        ...res,
        'user_agent': res['userAgent'] ?? res['user_agent'] ?? '',
      };

  /// Drop a cached URL after a playback failure so the next attempt re-resolves.
  void markVideoAsFailed(String videoId) => _resolver.invalidate(videoId);
  void invalidateMemoryCache(String videoId) => _resolver.invalidate(videoId);
  void invalidateMemoryCacheEntries() {}

  /// Drop EVERY cached stream URL. googlevideo URLs are bound to the IP they
  /// were resolved from, so after a WiFi<->mobile switch all of them 403 —
  /// re-resolving fresh beats burning heal attempts on dead URLs.
  void invalidateAllStreams() {
    _resolver.clear();
    // CRITICAL: since the native ResolvingDataSource refactor, the URLs that
    // actually drive playback live in the NATIVE songUrlCache — clearing only the
    // Dart resolver here was a no-op for playback, so after a WiFi<->mobile switch
    // the native side kept serving the dead IP-bound URL → playback "acted
    // offline" and got stuck. Drop the native cache too so the next fetch
    // re-resolves fresh on the new network.
    NativeAudioEngine.clearUrlCache();
  }

  void dispose() {}
}
