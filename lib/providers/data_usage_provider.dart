import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;

/// How much network the app has used, split by what it was spent on.
///
/// Wraps the shared HTTP client so every request is counted once, at the point it
/// actually happens, rather than estimated at call sites. Categories come from
/// the request PATH. See [DataTrackingHttpClient.looksLikeMediaFile] for why a
/// podcast enclosure has to be recognised by its file extension: podcast audio
/// comes from whatever host the show is hosted on, so a host-based rule filed the
/// single largest category as "other".
///
/// The numbers are for the user's Storage/Data screen, not for billing — they
/// count bytes this app requested, which is not the same as bytes the radio
/// carried.

class DataUsageStats {
  final int totalBytes;
  final int requestCount;
  final DateTime startTime;
  final Map<String, int> bytesByCategory; // e.g., "search", "stream", "lyrics"
  
  DataUsageStats({
    this.totalBytes = 0,
    this.requestCount = 0,
    DateTime? startTime,
    Map<String, int>? bytesByCategory,
  }) : startTime = startTime ?? DateTime.now(),
       bytesByCategory = bytesByCategory ?? {};
  
  DataUsageStats copyWith({
    int? totalBytes,
    int? requestCount,
    DateTime? startTime,
    Map<String, int>? bytesByCategory,
  }) {
    return DataUsageStats(
      totalBytes: totalBytes ?? this.totalBytes,
      requestCount: requestCount ?? this.requestCount,
      startTime: startTime ?? this.startTime,
      bytesByCategory: bytesByCategory ?? this.bytesByCategory,
    );
  }
  
  String get totalMB => (totalBytes / (1024 * 1024)).toStringAsFixed(2);
  String get averagePerRequest => requestCount > 0 
      ? ((totalBytes / requestCount) / 1024).toStringAsFixed(1) 
      : "0";
  
  Duration get runningTime => DateTime.now().difference(startTime);
  String get ratePerMinute => runningTime.inMinutes > 0
      ? ((totalBytes / runningTime.inMinutes) / (1024 * 1024)).toStringAsFixed(2)
      : "0.00";
}

class DataUsageNotifier extends StateNotifier<DataUsageStats> {
  Timer? _periodicLogger;
  static DataUsageNotifier? _instance; // ADD THIS
  
  DataUsageNotifier() : super(DataUsageStats()) {
    // Prevent multiple instances
    if (_instance != null) {
      print("WARN: DataUsageNotifier already exists, reusing instance");
      return;
    }
    _instance = this;
    // NO PERIODIC REPORT. This used to start a one-minute Timer that ran for
    // the entire session and printed a fifteen-line breakdown every tick — a
    // wakeup, a pile of string formatting and log I/O every sixty seconds,
    // forever, including fully idle in the background, in release builds.
    //
    // The counters below are PASSIVE: [trackRequest] adds to them as requests
    // happen and costs nothing when nothing is happening. The Storage & data
    // screen reads them when it is open, which is the only time anyone is
    // looking, and [printStats] is still here to be called deliberately.
  }

  /// Prints the breakdown once, on demand.
  void printStats() => _printStats();
  
  void trackRequest(int bytes, {String category = 'other', String? endpoint}) {
    final newByCategory = Map<String, int>.from(state.bytesByCategory);
    newByCategory[category] = (newByCategory[category] ?? 0) + bytes;

    state = state.copyWith(
      totalBytes: state.totalBytes + bytes,
      requestCount: state.requestCount + 1,
      bytesByCategory: newByCategory,
    );

    // Immediate log for large requests. The endpoint pinpoints WHICH call ships
    // multi-MB payloads (bytes here are decompressed body size, not wire size)
    // so heavy fetch sites can be found from a log alone.
    //
    // A track is supposed to be 3mb
    //
    // The threshold was a flat 1MB for every category, so a perfectly ordinary
    // song download tripped it several times per track:
    //
    // LARGE REQUEST: 3.43 MB [audio_stream] /videoplayback
    // LARGE REQUEST: 2.88 MB [audio_stream] /videoplayback
    //
    // Nothing is wrong there — that is what audio weighs. A warning that fires on
    // the most normal event in a music player is the same fault as "Content:
    // Clean" or ".env not found": it teaches the reader to skip the warning
    // lines, and then the real one goes past unread.
    //
    // THE WARNING ITSELF IS KEPT, because it has already earned its place: the
    // note further down records it catching audio MIScategorised as metadata
    // ("3.92 MB [youtube_metadata] /videoplayback"), which is exactly the kind of
    // thing it exists for. Bulk-media categories simply get a threshold that
    // matches what they legitimately weigh, so an absurd one still shows while a
    // normal track says nothing.
    const int kLargeRequest = 1024 * 1024;
    const int kLargeMedia = 12 * 1024 * 1024;
    const bulkMedia = {'audio_stream', 'podcast', 'audiobooks'};
    final limit = bulkMedia.contains(category) ? kLargeMedia : kLargeRequest;
    if (bytes > limit) {
      print("WARN: LARGE REQUEST: ${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB [$category]${endpoint != null ? ' $endpoint' : ''}");
    }

    // A periodic summary that costs nothing when nothing happens
    //
    // Counted, not timed — the deliberate absence of a Timer above still holds.
    // This fires on every 25th tracked request, so an idle app prints nothing at
    // all, and it is stripped with every other print in a release build.
    //
    // It exists because a blind spot in THIS tracker is invisible by
    // construction: traffic that never reaches trackRequest cannot show up as a
    // missing number, only as a total that looks plausible. Artwork was
    // undercounted that way for months (46.6 MB in 8 minutes), and catalog
    // traffic — search, browse, home, next, every player POST — was too, until
    // CatalogApiClient was routed through HttpPool. A per-category line is the
    // only way to see that the fix actually took.
    if (state.requestCount % 25 == 0) {
      final parts = state.bytesByCategory.entries
          .map((e) =>
              '${e.key} ${(e.value / (1024 * 1024)).toStringAsFixed(2)}MB')
          .join(' · ');
      print('data: ${state.requestCount} req, '
          '${state.totalMB} MB total — $parts');
    }
  }
  
  void _printStats() {
    if (state.requestCount == 0) return; // Don't print if no data
    
    print("\n═══════════════════════════════════════════════");
    print("DATA USAGE REPORT (Last ${state.runningTime.inMinutes} min)");
    print("═══════════════════════════════════════════════");
    print("Total Data: ${state.totalMB} MB");
    print("Requests: ${state.requestCount}");
    print("Avg/Request: ${state.averagePerRequest} KB");
    print("Rate: ${state.ratePerMinute} MB/min");
    print("───────────────────────────────────────────────");
    print("Breakdown by Category:");
    state.bytesByCategory.forEach((category, bytes) {
      final mb = (bytes / (1024 * 1024)).toStringAsFixed(2);
      final percent = ((bytes / state.totalBytes) * 100).toStringAsFixed(1);
      print("$category: $mb MB ($percent%)");
    });
    print("═══════════════════════════════════════════════\n");
  }
  
  void reset() {
    state = DataUsageStats();
    print("Data usage stats reset");
  }
  
  @override
  void dispose() {
    _periodicLogger?.cancel();
    _instance = null; // CLEAR INSTANCE
    super.dispose();
  }
}

final dataUsageProvider = StateNotifierProvider<DataUsageNotifier, DataUsageStats>(
  (ref) => DataUsageNotifier(),
);

// Wrapper client that tracks data
class DataTrackingHttpClient extends http.BaseClient {
  final http.Client _inner;

  /// NULLABLE, AND NOT BECAUSE IT IS OPTIONAL — BECAUSE OF WHEN IT ARRIVES.
  ///
  /// The notifier is a Riverpod object, so it cannot exist until the widget tree
  /// does: `attachDataTracker` runs from main_layout, ~4 seconds into launch on a
  /// real device. Everything before that — the access check, the cloud restore's
  /// worker call, the first home fetch — went through the unwrapped client and
  /// was never counted. Measured: `verifyAccess` at 22:31:53.7, tracker attached
  /// at 22:31:57.5.
  ///
  /// So the wrapper is installed from the START and simply has nowhere to report
  /// yet. Bytes seen before the notifier lands are held in [_pendingBytes] and
  /// flushed by [attachTracker], which is what makes the launch window count.
  DataUsageNotifier? _tracker;

  /// Category → bytes seen before a notifier existed.
  final Map<String, int> _pendingBytes = {};
  int _pendingRequests = 0;

  DataTrackingHttpClient(this._inner, [this._tracker]);

  /// Hand the wrapper its notifier and flush whatever it saw before that.
  void attachTracker(DataUsageNotifier tracker) {
    _tracker = tracker;
    if (_pendingBytes.isEmpty) return;
    final held = Map<String, int>.from(_pendingBytes);
    final heldRequests = _pendingRequests;
    _pendingBytes.clear();
    _pendingRequests = 0;
    held.forEach((category, bytes) => tracker.trackRequest(bytes, category: category));
    print('data: flushed $heldRequests pre-launch request(s) '
        '(${held.keys.join(", ")}) into the tracker');
  }

  void _record(int bytes, String category, String? endpoint) {
    final tracker = _tracker;
    if (tracker != null) {
      tracker.trackRequest(bytes, category: category, endpoint: endpoint);
      return;
    }
    _pendingBytes[category] = (_pendingBytes[category] ?? 0) + bytes;
    _pendingRequests++;
  }

  /// Whether a url PATH names a downloadable media file.
  ///
  /// Deliberately extension-based: it is the only signal shared by podcast
  /// enclosures across every hosting provider. Checked against the path alone,
  /// so query parameters cannot trip it.
  @visibleForTesting
  static bool looksLikeMediaFile(String path) {
    final p = path.toLowerCase();
    for (final ext in const [
      '.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.flac', '.wav', '.mp4'
    ]) {
      if (p.endsWith(ext)) return true;
    }
    return false;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    
    // Track request size (headers + body estimate)
    final requestSize = request.contentLength ?? 0;
    
    // Determine category from URL
    String category = 'other';
    final url = request.url.toString().toLowerCase();
    // Artwork first, AND it is the biggest category there is.
    //
    // Ordered most-specific first, AND the audio stream comes before anything
    // That merely mentions YouTube.
    //
    // THE BUG THIS FIXES. The audio itself is served from googlevideo.com
    // /videoplayback, which matched none of the earlier branches and fell through
    // to the generic `youtube` test, so the single largest consumer of the user's
    // data was filed as "metadata". Caught in the device log:
    //
    // LARGE REQUEST: 3.92 MB [youtube_metadata] /videoplayback
    //
    // Nearly four megabytes of one track's audio, attributed to metadata. The
    // Data & Storage screen exists to answer "where is my data going", and it was
    // giving the wrong answer for the biggest item — while looking plausible,
    // which is worse than looking broken.
    //
    // `contains('stream')` was the intended test and never fired: no googlevideo
    // URL contains that word. The path and the host are what identify audio.
    if (url.contains('videoplayback') ||
        url.contains('googlevideo.com') ||
        url.contains('127.0.0.1') ||
        url.contains('stream')) {
      category = 'audio_stream';
    } else if (url.contains('ytimg.com') ||
        url.contains('googleusercontent.com') ||
        url.contains('ggpht.com') ||
        url.contains('scdn.co')) {
      // Cover art used to be counted NOWHERE: CachedNetworkImage fetches through
      // the cache manager's own file service, which bypassed this client entirely,
      // so the "Total Data Used" figure in Settings omitted the app's largest
      // consumer. Measured on device: 46.6 MB of images in 8 minutes of browsing
      // while the reported total moved by a fraction of that. Image fetches are
      // now routed through here (see CustomImageCacheManager) and land in their
      // own bucket, so the screen shows a number that means something.
      //
      // Matched on the CDN hosts rather than a path, because none of these urls
      // contain the words the branches below look for — ytimg and
      // googleusercontent would otherwise have fallen through to 'other'.
      category = 'artwork';
    } else if (url.contains('archive.org') || url.contains('/audiobooks')) {
      // Audiobook chapters, covers, and the catalogue itself. The `/audiobooks`
      // path is the Worker route: it proxies archive.org, so matching only the
      // archive host filed the catalogue JSON under "other" — a small amount of
      // data in the wrong bucket is still a screen that answers the question
      // wrongly, which is the whole complaint this ordering exists to fix.
      //
      // Their own bucket rather than audio_stream: a listener deciding whether to
      // keep downloading books wants to see that separately from music.
      category = 'audiobooks';
    } else if (looksLikeMediaFile(request.url.path)) {
      // PODCAST AUDIO WAS THE LARGEST THING IN "OTHER".
      //
      // THE BUG THIS FIXES. Every branch above names a host Auvy talks to, and
      // podcast enclosures are served from wherever the show happens to be
      // hosted — Simplecast, Megaphone, Patreon, an author's own box. There is
      // no host list to write, so hours of episode audio fell to 'other', which
      // reached 12.22 MB in one day of the 2026-08-30 transcript and was by then
      // the biggest category on the screen with the least meaning.
      //
      // Matched on the PATH's file extension rather than the host, because that
      // is the one thing every enclosure has in common. On the path and not the
      // whole url, so a tracking parameter that happens to mention mp3 does not
      // count. Its own bucket rather than audio_stream for the same reason
      // audiobooks has one: someone asking where their data went wants podcasts
      // told apart from music.
      category = 'podcast';
    } else if (url.contains('lrclib') || url.contains('lyrics')) {
      category = 'lyrics';
    } else if (url.contains('search') ||
        url.contains('deezer') ||
        url.contains('spotify')) {
      category = 'search';
    } else if (url.contains('youtube')) {
      category = 'youtube_metadata';
    }
    
    // Track response size
    int responseBytes = 0;
    final newResponse = http.StreamedResponse(
      response.stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            responseBytes += data.length;
            sink.add(data);
          },
          handleDone: (sink) {
            // Through [_record], so a response that completes before the
            // notifier exists is held rather than dropped.
            _record(requestSize + responseBytes, category, request.url.path);
            sink.close();
          },
        ),
      ),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
      request: response.request,
    );
    
    return newResponse;
  }
}