import 'dart:async';
import 'dart:io' show gzip;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;

/// How much network the app has used, split by what it was for.
///
/// Wraps the shared HTTP client so every request is counted where it happens.
/// Categories come from the request host and path; podcast enclosures are
/// recognised by file extension (see [DataTrackingHttpClient.looksLikeMediaFile])
/// since they come from arbitrary hosts.
///
/// For the Storage/Data screen, not billing: these are bytes the app requested,
/// not exactly what the radio carried.

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
    // No periodic report: the counters are passive ([trackRequest] adds to them
    // as requests happen), and the Storage & data screen reads them when open.
  }

  
  /// Adds the audio the native player downloaded, which Dart never sees (ExoPlayer
  /// on Android, AuvyStreamLoader's URLSession on iOS). Without it the largest
  /// category would be missing from the screen.
  ///
  /// Each call drains only what's new, so it can be called as often as needed.
  /// Failures are silent, so an older native side without the method leaves the
  /// screen as it was.
  Future<void> syncNativeAudioBytes() async {
    try {
      final n = await const MethodChannel('com.auvy.app/native_player')
          .invokeMethod<int>('drainAudioBytes');
      if (n != null && n > 0) {
        trackRequest(n, category: 'audio_stream', endpoint: '/player');
      }
    } catch (_) {
      // Older native side, or no player yet. Nothing to report is not an error.
    }
  }

  void trackRequest(int bytes, {String category = 'other', String? endpoint}) {
    final newByCategory = Map<String, int>.from(state.bytesByCategory);
    newByCategory[category] = (newByCategory[category] ?? 0) + bytes;

    state = state.copyWith(
      totalBytes: state.totalBytes + bytes,
      requestCount: state.requestCount + 1,
      bytesByCategory: newByCategory,
    );

    // Log unusually large requests with their endpoint, so heavy fetches can be
    // found from a log alone. Bulk media categories get thresholds that match what
    // they normally weigh (a song is several MB), so normal tracks stay quiet while
    // misfiled or absurd sizes still show up.
    const int kLargeRequest = 1024 * 1024;
    const int kLargeMedia = 12 * 1024 * 1024;
    const bulkMedia = {'audio_stream', 'podcast', 'audiobooks'};
    final limit = bulkMedia.contains(category) ? kLargeMedia : kLargeRequest;
    if (bytes > limit) {
      print("WARN: LARGE REQUEST: ${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB [$category]${endpoint != null ? ' $endpoint' : ''}");
    }

    // A per-category summary every 25th request: nothing when idle, and stripped
    // with other prints in release builds. Traffic that bypasses the tracker can't
    // show up as a missing number, only as a plausible-looking total, so this is how
    // to confirm new traffic is being counted.
    if (state.requestCount % 25 == 0) {
      final parts = state.bytesByCategory.entries
          .map((e) =>
              '${e.key} ${(e.value / (1024 * 1024)).toStringAsFixed(2)}MB')
          .join(' · ');
      print('data: ${state.requestCount} req, '
          '${state.totalMB} MB total — $parts');
    }
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

  /// Nullable because of timing: the notifier is a Riverpod object and can't exist
  /// until the widget tree does (`attachDataTracker` runs from main_layout a few
  /// seconds into launch). Bytes seen before then are held in [_pendingBytes] and
  /// flushed by [attachTracker], so launch traffic is counted too.
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

  /// Bytes held for [category] before a notifier was attached.
  ///
  /// Exposed for the accounting test: what this client counts is the thing
  /// under test, and it is invisible from the response it returns.
  @visibleForTesting
  int? debugPendingBytesFor(String category) => _pendingBytes[category];

  /// Every held byte, whatever bucket it landed in. The accounting test cares
  /// how much was counted, not how it was filed — and a loopback test URL is
  /// categorised as audio_stream because the categoriser matches 127.0.0.1.
  @visibleForTesting
  int get debugPendingTotal =>
      _pendingBytes.values.fold(0, (a, b) => a + b);

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
    // Ordered most specific first. Audio streams come from googlevideo.com
    // /videoplayback, matched by path and host before the generic YouTube rule,
    // which would otherwise file them as metadata.
    if (url.contains('videoplayback') ||
        url.contains('googlevideo.com') ||
        url.contains('127.0.0.1') ||
        url.contains('stream')) {
      category = 'audio_stream';
    } else if (url.contains('ytimg.com') ||
        url.contains('googleusercontent.com') ||
        url.contains('ggpht.com') ||
        url.contains('scdn.co')) {
      // Cover art from the image CDNs. Image fetches are routed through this client
      // (see CustomImageCacheManager) and matched by host, since their URLs contain
      // none of the words the later rules look for.
      category = 'artwork';
    } else if (url.contains('archive.org') || url.contains('/audiobooks')) {
      // Audiobook chapters, covers and the catalogue. `/audiobooks` is the Worker
      // route that proxies archive.org, so it's matched along with the archive host.
      // Its own bucket so book listening shows separately from music.
      category = 'audiobooks';
    } else if (looksLikeMediaFile(request.url.path)) {
      // Podcast audio, matched by the path's file extension because enclosures are
      // served from whatever host the show uses. Path only, so a tracking parameter
      // mentioning mp3 doesn't count. Its own bucket so podcasts show separately from
      // music.
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
    
    // Count what crossed the socket, not the decoded body. The default dart:io
    // client inflates gzip responses automatically, which overstates compressible
    // metadata about 9x (data_usage_accounting_test.dart checks the wire size). The pool turns
    // off auto-inflation; this counts the raw body, then inflates here and drops the
    // header so nothing inflates twice. Callers still get plain bytes.
    int responseBytes = 0;
    final encoding =
        (response.headers['content-encoding'] ?? '').toLowerCase().trim();
    final isGzipped = encoding == 'gzip';

    Stream<List<int>> counted = response.stream.transform(
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
    );
    if (isGzipped) counted = gzip.decoder.bind(counted);

    final outHeaders = Map<String, String>.from(response.headers);
    if (isGzipped) {
      outHeaders.remove('content-encoding');
      // The wire length no longer describes the bytes the caller will read.
      outHeaders.remove('content-length');
    }

    final newResponse = http.StreamedResponse(
      counted,
      response.statusCode,
      headers: outHeaders,
      contentLength: isGzipped ? null : response.contentLength,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
      request: response.request,
    );
    
    return newResponse;
  }
}