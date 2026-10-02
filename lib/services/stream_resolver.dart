import 'dart:async';

import 'package:auvy/services/catalog_api_client.dart';
import 'package:auvy/core/cache/lru_cache.dart';
import 'package:auvy/core/net/circuit_breaker.dart';
import 'package:auvy/logic/adaptive_bitrate.dart';

/// The single path from a YouTube video id to a playable audio stream, used by
/// playback, prefetch and downloads.
///
/// Wraps [CatalogApiClient.getStreamUrl] with:
///   * an in-memory cache: stream URLs stay valid for hours, so replay, seek and
///     prefetch don't resolve again.
///   * request de-duplication: concurrent requests for the same key share one
///     network call.
///   * a circuit breaker: when YouTube starts refusing, fail fast for a short
///     cooldown instead of retrying in a storm.
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

  /// Resolves a video id to `{url, userAgent, mimeType, bitrate, contentLength,
  /// videoId, source}` or null. Cached, de-duplicated and breaker-guarded.
  ///
  /// [lowQuality] selects a lower-bitrate format (data saver). [preferMp4] asks
  /// for AAC-in-MP4 so the file can carry tags; downloads set it, playback must
  /// not. Both are part of the cache key (see [_keyFor]).
  ///
  /// [isStillWanted] lets a caller abandon the resolve part-way (the player passes
  /// "is this still the current track"). Only the caller that started a resolve
  /// can abandon it; a later caller with the same key joins the in-flight future.
  /// Playback and cache warming rarely share a key (playback passes a bitrate
  /// ceiling), and if one gets abandoned the other simply resolves again later.
  Future<Map<String, String>?> resolve(String videoId, {bool lowQuality = false, int clientStartIndex = 0, int maxBitrate = 0, bool preferMp4 = false, bool Function()? isStillWanted}) async {
    if (!_isVideoId(videoId)) return null;

    final cacheKey = _keyFor(videoId, lowQuality, maxBitrate, preferMp4);

    final cached = _cache.get(cacheKey);
    if (cached != null) return cached;

    final inflight = _pending[cacheKey];
    if (inflight != null) return inflight;

    final future = _resolveInner(videoId, lowQuality, clientStartIndex, maxBitrate, preferMp4, isStillWanted);
    _pending[cacheKey] = future;
    try {
      final result = await future;
      if (result != null) _cache.put(cacheKey, result);
      return result;
    } finally {
      _pending.remove(cacheKey);
    }
  }

  /// The key includes the bitrate ceiling, or a track first resolved during a bad
  /// patch would be served at that low bitrate from cache after the network
  /// recovers. [preferMp4] is in the key too: MP4 and Opus are different
  /// containers, and sharing an entry could hand playback a download's URL (or the
  /// reverse) with bytes that don't match the entry.
  String _keyFor(String videoId, bool lowQuality, int maxBitrate, bool preferMp4) {
    final lq = lowQuality ? ':lq' : '';
    final cap = maxBitrate > 0 ? ':b$maxBitrate' : '';
    final mp4 = preferMp4 ? ':mp4' : '';
    return '$videoId$lq$cap$mp4';
  }

  Future<Map<String, String>?> _resolveInner(String videoId, bool lowQuality, int clientStartIndex, int maxBitrate, bool preferMp4, [bool Function()? isStillWanted]) async {
    try {
      return await _breaker.run<Map<String, String>?>(() async {
        final res = await _innerTube.getStreamUrl(videoId, lowQuality: lowQuality, clientStartIndex: clientStartIndex, maxBitrate: maxBitrate, preferMp4: preferMp4, isStillWanted: isStillWanted);
        if (res == null) {
          // A skip isn't a YouTube failure and must not trip the breaker; otherwise a few
          // quick skips could make it refuse resolves for new tracks.
          if (isStillWanted != null && !isStillWanted()) return null;
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

  /// Drops every cached URL for [videoId] (e.g. after a 403 mid-playback) so the
  /// next request resolves a fresh one. Every variant: the ceiling is part of the
  /// key, so there is one entry per ladder rung, derived from [kBitrateLadder] so
  /// the list can't fall out of date.
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
