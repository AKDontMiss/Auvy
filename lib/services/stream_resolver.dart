import 'dart:async';

import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/core/cache/lru_cache.dart';
import 'package:auvy/core/net/circuit_breaker.dart';
import 'package:auvy/logic/adaptive_bitrate.dart';

/// The single source of truth for turning a YouTube videoId into a playable
/// audio stream. Everything (foreground playback, prefetch, downloads) goes
/// through here, replacing the old three competing code paths.
///
/// It wraps [CatalogApiClient.getStreamUrl] (ANDROID→IOS, pre-signed URLs) with
/// the on-device resilience layer:
///   * **in-memory cache** — googlevideo URLs stay valid for hours, so we don't
///     re-resolve the same track on replay / seek / prefetch.
///   * **request de-duplication** — concurrent requests for the same id share
///     one network call.
///   * **circuit breaker** — when YouTube starts gating us, stop hammering and
///     fail fast for a short cooldown instead of retry-storming.
class StreamResolver {
  StreamResolver._();
  static final StreamResolver _instance = StreamResolver._();
  factory StreamResolver() => _instance;

  final CatalogApiClient _innerTube = CatalogApiClient();

  // googlevideo URLs carry an `expire` ~6h out; cache a little under that.
  final LruCache<String, Map<String, String>> _cache =
      LruCache<String, Map<String, String>>(maxEntries: 256, defaultTtl: const Duration(hours: 5));

  final Map<String, Future<Map<String, String>?>> _pending = {};

  final CircuitBreaker _breaker = CircuitBreaker(
    name: 'stream',
    failureThreshold: 5,
    cooldown: const Duration(seconds: 20),
  );

  bool _isVideoId(String id) => id.length == 11 && !id.contains('/') && !id.startsWith('http');

  /// Resolve a videoId to `{url, userAgent, mimeType, bitrate, contentLength,
  /// videoId, source}` or null. Cached + de-duplicated + breaker-guarded.
  ///
  /// [lowQuality] selects a lower-bitrate audio format (data-saver). The cache
  /// key is quality-aware (`id:lq` vs `id`) so a track resolved at one quality
  /// isn't served at that quality forever when the network/data-saver changes.
  ///
  /// [preferMp4] asks for AAC-in-MP4 instead of the better-sounding Opus, so the
  /// file can carry tags and cover art. Downloads set it; playback must not.
  Future<Map<String, String>?> resolve(String videoId, {bool lowQuality = false, int clientStartIndex = 0, int maxBitrate = 0, bool preferMp4 = false}) async {
    if (!_isVideoId(videoId)) return null;

    final cacheKey = _keyFor(videoId, lowQuality, maxBitrate, preferMp4);

    final cached = _cache.get(cacheKey);
    if (cached != null) return cached;

    final inflight = _pending[cacheKey];
    if (inflight != null) return inflight;

    final future = _resolveInner(videoId, lowQuality, clientStartIndex, maxBitrate, preferMp4);
    _pending[cacheKey] = future;
    try {
      final result = await future;
      if (result != null) _cache.put(cacheKey, result);
      return result;
    } finally {
      _pending.remove(cacheKey);
    }
  }

  /// The key must include the ceiling, OR adaptive quality is a one-way door.
  ///
  /// The cache was keyed on the id (plus a data-saver suffix). With a ceiling
  /// that moves, a track first resolved during a bad patch would be served from
  /// cache at that low bitrate for the rest of the cache's life — the network
  /// recovers, the ladder climbs back, and this track alone stays quiet. Naming
  /// the ceiling in the key makes each quality its own entry.
  ///
  /// THE SAME REASONING APPLIES TO [preferMp4], AND MORE SHARPLY: an MP4
  /// resolve and an Opus resolve are two DIFFERENT CONTAINERS, not two bitrates
  /// of one thing. Sharing a key would let a download hand its AAC url to
  /// playback, or the reverse — a cache entry describing bytes that are not the
  /// bytes behind the url. That is the shape of the stall that once looked like a
  /// mid-track 403 for no reason, so each container gets its own entry.
  String _keyFor(String videoId, bool lowQuality, int maxBitrate, bool preferMp4) {
    final lq = lowQuality ? ':lq' : '';
    final cap = maxBitrate > 0 ? ':b$maxBitrate' : '';
    final mp4 = preferMp4 ? ':mp4' : '';
    return '$videoId$lq$cap$mp4';
  }

  Future<Map<String, String>?> _resolveInner(String videoId, bool lowQuality, int clientStartIndex, int maxBitrate, bool preferMp4) async {
    try {
      return await _breaker.run<Map<String, String>?>(() async {
        final res = await _innerTube.getStreamUrl(videoId, lowQuality: lowQuality, clientStartIndex: clientStartIndex, maxBitrate: maxBitrate, preferMp4: preferMp4);
        if (res == null) {
          // Treat "no playable stream" as a failure so the breaker can trip
          // when YouTube is gating many requests in a row.
          throw StateError('no playable stream for $videoId');
        }
        return res;
      }, onOpen: () => null);
    } catch (_) {
      return null;
    }
  }

  /// Drop a cached URL (e.g. after a 403 mid-playback) so the next request
  /// re-resolves a fresh one.
  ///
  /// EVERY VARIANT, NOT JUST TWO. This used to clear `id` and `id:lq`, which
  /// was complete when those were the only two keys a track could have. With an
  /// adaptive ceiling in the key there are now one per rung, and a half-cleared
  /// invalidate leaves a dead URL cached under a ceiling the ladder will come
  /// back to — a 403 that "returns" minutes later for no visible reason.
  ///
  /// Enumerated rather than prefix-scanned because the ladder is a short, fixed
  /// list; keeping it exhaustive is the point, so it is derived from
  /// [kBitrateLadder] and cannot drift if a rung is added.
  void invalidate(String videoId) {
    for (final lq in const [false, true]) {
      for (final cap in kBitrateLadder) {
        // Both containers, for the same reason the ladder is enumerated: a
        // half-cleared invalidate leaves a dead url cached under a key the app
        // will come back to.
        for (final mp4 in const [false, true]) {
          _cache.remove(_keyFor(videoId, lq, cap, mp4));
        }
      }
    }
  }

  /// What was actually resolved for [videoId], or null if nothing is cached.
  ///
  /// Read-only and network-free — it never triggers a resolve, so a caller that
  /// only wants to DESCRIBE the stream (codec, bitrate) cannot accidentally cause
  /// one. Returns the first cached variant found across the key space, which is
  /// the stream in use unless the ladder moved since.
  Map<String, String>? peekResolved(String videoId) {
    if (!_isVideoId(videoId)) return null;
    for (final mp4 in const [false, true]) {
      for (final lq in const [false, true]) {
        for (final cap in kBitrateLadder) {
          final hit = _cache.get(_keyFor(videoId, lq, cap, mp4));
          if (hit != null) return hit;
        }
      }
    }
    return null;
  }

  void clear() => _cache.clear();

  CircuitState get circuitState => _breaker.state;
}
