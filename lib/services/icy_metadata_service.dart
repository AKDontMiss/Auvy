import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Holds metadata extracted from an Icecast/Shoutcast internet radio stream.
class IcyMetadata {
  final String? stationName;
  final String? streamTitle;
  final String? genre;
  final String? description;
  final String? bitrate;

  const IcyMetadata({
    this.stationName,
    this.streamTitle,
    this.genre,
    this.description,
    this.bitrate,
  });

  bool get isEmpty =>
      (stationName == null || stationName!.isEmpty) &&
      (streamTitle == null || streamTitle!.isEmpty) &&
      (genre == null || genre!.isEmpty) &&
      (description == null || description!.isEmpty) &&
      (bitrate == null || bitrate!.isEmpty);
}

/// Safe, leak-free extractor for live ICY radio stream metadata.
///
/// Features:
/// - Connects with a strict 3-second timeout.
/// - Requests headers and audio bytes only up to the first metadata interval (`icy-metaint`).
/// - ALWAYS forcefully closes the socket (`client.close(force: true)`) and cancels the stream
///   subscription in a `finally` block to prevent lingering sockets or CPU/battery leaks.
/// - In-memory cache with 45-second TTL per URL to avoid redundant network hits.
class IcyMetadataService {
  static final Map<String, (DateTime timestamp, IcyMetadata data)> _cache = {};
  static final Set<String> _inFlight = {};

  /// The on-air title, or null when the station isn't playing a track.
  ///
  /// ICY `StreamTitle` is free text, and broadcast automation (Triton Digital,
  /// iHeart) fills it with ad and sweeper data instead of a song, e.g.:
  ///
  ///     - text="24-7 News Into Break Sweep 5" song_spot="T" spotInstanceId="-1"
  ///       length="00:00:08" MediaBaseId="" TAID="0" cartcutId="" …
  ///     - text="Spot Block End" length="00:00:00" show="" digitalAds=""
  ///
  /// A real title is `Artist - Title` without attribute assignments, so:
  ///
  ///   1. Strip every `key="value"` pair (stations often append `StreamUrl="…"` to
  ///      a real title, so "contains `=\"`" alone isn't the test).
  ///   2. Refuse if a marker that only ever means "not music" was present.
  ///   3. Refuse if nothing track-like is left. The caller then shows the readable
  ///      schedule, which is right for an ad break.
  static String? sanitizeStreamTitle(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;

    // Only ever automation markers. `song_spot` classifies a commercial slot and
    // `cartcutId` is a playout-system cart number — neither exists on a song.
    const nonMusic = [
      'song_spot=',
      'spotInstanceId=',
      'cartcutId=',
      'spEventID=',
      'MediaBaseId=',
      'amgArtworkURL=',
      'Spot Block',
      'digitalAds=',
    ];
    final lower = s.toLowerCase();
    final flagged = nonMusic.any((m) => lower.contains(m.toLowerCase()));

    // Drop every attribute pair, quoted or bare.
    s = s.replaceAll(RegExp(r'''[A-Za-z_][\w-]*\s*=\s*("[^"]*"|'[^']*'|\S*)'''), ' ');
    // What automation leaves behind: the empty "artist - title" placeholder,
    // stray quotes, and collapsed whitespace.
    s = s.replaceAll(RegExp(r'["’“”]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[\s\-–—|/·:]+|[\s\-–—|/·:]+$'), '').trim();

    if (flagged || s.isEmpty) {
      print('ICY title rejected (${flagged ? "automation marker" : "nothing left after stripping attributes"}): '
          '"${raw.length > 90 ? '${raw.substring(0, 90)}…' : raw}"');
      return null;
    }
    if (s != raw.trim()) {
      print('ICY title cleaned: "$s"');
    }
    return s;
  }

  /// Directly updates cached metadata from the native ExoPlayer stream listener.
  /// This requires ZERO HTTP requests and ensures the playing stream is never interrupted.
  static void updateLiveMetadata(
    String streamUrl, {
    String? streamTitle,
    String? stationName,
    String? genre,
    String? bitrate,
    String? description,
  }) {
    final cleanUrl = streamUrl.trim();
    if (cleanUrl.isEmpty) return;
    final prev = _cache[cleanUrl]?.$2;
    // Sanitised here, at the single native entry point, so the notification and
    // all three schedule call sites share one rule.
    //
    // A rejected title keeps the previous one rather than blanking: an ad break
    // interrupts a song briefly, and holding the last real track reads better than
    // flickering to empty. The schedule card falls back to the programme when there
    // has never been a real title.
    final cleanedTitle = sanitizeStreamTitle(streamTitle);
    final updated = IcyMetadata(
      streamTitle: (cleanedTitle != null && cleanedTitle.isNotEmpty) ? cleanedTitle : prev?.streamTitle,
      stationName: (stationName != null && stationName.isNotEmpty) ? stationName : prev?.stationName,
      genre: (genre != null && genre.isNotEmpty) ? genre : prev?.genre,
      bitrate: (bitrate != null && bitrate.isNotEmpty) ? bitrate : prev?.bitrate,
      description: (description != null && description.isNotEmpty) ? description : prev?.description,
    );
    _cache[cleanUrl] = (DateTime.now(), updated);
  }

  static Future<IcyMetadata?> fetchMetadata(
    String streamUrl, {
    bool isCurrentlyPlaying = false,
  }) async {
    final cleanUrl = streamUrl.trim();
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      return null;
    }

    final now = DateTime.now();
    final cached = _cache[cleanUrl];
    if (cached != null && now.difference(cached.$1).inSeconds < 120) {
      return cached.$2;
    }

    // If this station is playing, never open a second connection to the same
    // stream: single-connection Shoutcast/Icecast servers drop the player's socket
    // when a second connection from the same IP arrives, causing an audible
    // glitch.
    if (isCurrentlyPlaying) {
      return cached?.$2;
    }

    if (_inFlight.contains(cleanUrl)) {
      return cached?.$2;
    }

    _inFlight.add(cleanUrl);

    HttpClient? client;
    StreamSubscription<List<int>>? sub;

    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final uri = Uri.parse(cleanUrl);
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      req.headers.set('Icy-MetaData', '1');
      req.headers.set('User-Agent', 'Auvy/1.0');

      final res = await req.close().timeout(const Duration(seconds: 4));

      final stationName = res.headers.value('icy-name');
      final genre = res.headers.value('icy-genre');
      final desc = res.headers.value('icy-description');
      final br = res.headers.value('icy-br');
      final metaIntStr = res.headers.value('icy-metaint');
      final metaInt = metaIntStr != null ? int.tryParse(metaIntStr) : null;

      String? streamTitle;

      if (metaInt != null && metaInt > 0 && metaInt < 65536) {
        final completer = Completer<String?>();
        final buffer = <int>[];

        sub = res.listen(
          (chunk) {
            buffer.addAll(chunk);
            if (buffer.length >= metaInt + 1) {
              final metaLength = buffer[metaInt] * 16;
              if (metaLength > 0 && buffer.length >= metaInt + 1 + metaLength) {
                final metaBytes =
                    buffer.sublist(metaInt + 1, metaInt + 1 + metaLength);
                final metaText = utf8.decode(metaBytes, allowMalformed: true);
                final match =
                    RegExp(r"StreamTitle='([^']*)'").firstMatch(metaText);
                if (!completer.isCompleted) {
                  completer.complete(match?.group(1));
                }
              } else if (metaLength == 0 && !completer.isCompleted) {
                completer.complete(null);
              }
            }
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete(null);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete(null);
          },
          cancelOnError: true,
        );

        streamTitle = await completer.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
      }

      final metadata = IcyMetadata(
        stationName: stationName?.trim(),
        // Same rule as the native path. This branch only runs for a station
        // that is NOT currently playing, but it reads the identical field from
        // the identical servers, so it gets the identical filter — one of them
        // being lenient is how the junk would come back.
        streamTitle: sanitizeStreamTitle(streamTitle),
        genre: genre?.trim(),
        description: desc?.trim(),
        bitrate: br?.trim(),
      );

      _cache[cleanUrl] = (now, metadata);
      return metadata;
    } catch (_) {
      return null;
    } finally {
      _inFlight.remove(cleanUrl);
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  /// Get cached metadata immediately if available.
  static IcyMetadata? getCached(String streamUrl) {
    final cached = _cache[streamUrl.trim()];
    if (cached != null && DateTime.now().difference(cached.$1).inSeconds < 60) {
      return cached.$2;
    }
    return null;
  }

  /// Invalidate cache for a specific stream URL so fresh metadata is fetched.
  static void invalidate(String streamUrl) {
    _cache.remove(streamUrl.trim());
  }
}
