import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:auvy/providers/data_usage_provider.dart';

/// The pooled client, for call sites that would otherwise use the package's
/// one-shot `http.get` / `http.post`.
///
/// EVERY `http.get(...)` BUILDS AND DISCARDS A WHOLE CLIENT. The top-level
/// functions in `package:http` create a client, make one request and close it —
/// so each call pays a fresh TCP + TLS handshake instead of reusing a warm
/// connection, and none of the bytes reach [DataTrackingHttpClient], which only
/// sees what goes through this pool.
///
/// Measured on this codebase: 33 such calls, including the Worker access check on
/// every launch and the ENTIRE Spotify import path — one call per page of a
/// playlist plus one per unmatched track, so a 900-track import performed
/// hundreds of separate handshakes and reported zero bytes in Settings.
///
/// `pooledClient.get(...)` is a drop-in for `http.get(...)`: same signature, same
/// semantics, minus the per-call socket. Do NOT close it — it is shared for the
/// process lifetime by design.
http.Client get pooledClient => HttpPool().getClient();

class HttpPool {
  static final HttpPool _instance = HttpPool._internal();
  factory HttpPool() => _instance;
  
  /// Wrapped from the start, NOT swapped later.
  ///
  /// This used to begin as a plain client and be REPLACED by the tracking wrapper
  /// when the UI called [attachDataTracker] — about four seconds into launch on a
  /// real device, because the notifier is a Riverpod object that cannot exist
  /// before the widget tree. Everything in that window went uncounted: the access
  /// check, the cloud restore's worker call, the first catalog fetches. Measured:
  /// `verifyAccess` at 22:31:53.7, tracker attached at 22:31:57.5.
  ///
  /// Now the wrapper is the client from construction and simply has no notifier
  /// yet; it holds what it sees and flushes on attach (see
  /// DataTrackingHttpClient). Replacing the reference is also gone, which removes
  /// the trap that anything caching `getClient()` in a `static final` captured the
  /// pre-attach client forever.
  final DataTrackingHttpClient _sharedClient;
  final String _sessionUserAgent;
  bool _isTrackerAttached = false;

  HttpPool._internal()
      : _sharedClient = DataTrackingHttpClient(http.Client()),
        _sessionUserAgent = _getRandomUserAgent();

  /// Called from the UI once Riverpod is ready. Idempotent.
  void attachDataTracker(DataUsageNotifier notifier) {
    if (!_isTrackerAttached) {
      _sharedClient.attachTracker(notifier);
      _isTrackerAttached = true;
      print(" Network Data Tracker successfully attached to HttpPool!");
    }
  }

  static String _getRandomUserAgent() {
    final userAgents = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
    ];
    return userAgents[Random().nextInt(userAgents.length)];
  }

  http.Client getClient() => _sharedClient;

  Map<String, String> getHeaders() {
    return {
      'User-Agent': _sessionUserAgent,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.5',
      'Connection': 'keep-alive',
    };
  }
}