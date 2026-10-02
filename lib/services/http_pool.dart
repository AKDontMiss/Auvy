
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:io' show HttpClient;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:auvy/providers/data_usage_provider.dart';
import 'package:auvy/core/net/app_token.dart';
import 'package:auvy/core/backend_config.dart';

/// The pooled client, for call sites that would otherwise use the package's
/// one-shot `http.get` / `http.post`. Those create and close a whole client per
/// call (a fresh TCP + TLS handshake each time), and their traffic bypasses
/// [DataTrackingHttpClient]. `pooledClient.get(...)` is a drop-in replacement.
/// Don't close it; it's shared for the life of the process.
http.Client get pooledClient => HttpPool().getClient();

class HttpPool {
  static final HttpPool _instance = HttpPool._internal();
  factory HttpPool() => _instance;
  
  /// Wrapped in the tracking client from the start, so requests made before the
  /// UI attaches the data tracker (the launch access check, the cloud restore,
  /// the first catalogue fetches) are counted too; the wrapper holds its counts
  /// and flushes them on attach. The reference never changes, so a cached
  /// `getClient()` is always the tracked client.
  final DataTrackingHttpClient _sharedClient;
  bool _isTrackerAttached = false;

  HttpPool._internal()
      : _sharedClient = DataTrackingHttpClient(IOClient(
          // autoUncompress OFF so the tracker can see the COMPRESSED body and
          // report the data actually used. DataTrackingHttpClient inflates it
          // again straight afterwards, so every caller still receives plain
          // bytes — see the note there for the 9.4x measurement that prompted
          // this.
          HttpClient()..autoUncompress = false,
        ));

  /// Called from the UI once Riverpod is ready. Idempotent.
  void attachDataTracker(DataUsageNotifier notifier) {
    if (!_isTrackerAttached) {
      _sharedClient.attachTracker(notifier);
      _isTrackerAttached = true;
      print("Network Data Tracker successfully attached to HttpPool!");
    }
  }

  /// The token wrapper sits OUTSIDE the data tracker, so bytes are still
  /// counted exactly as before and the header is added before they are.
  late final http.Client _tokenClient = _WorkerTokenClient(_sharedClient);

  http.Client getClient() => _tokenClient;

  /// The pool's own tracking client, for tests: a test that builds its own client
  /// proves the tracker works, not that this pool uses it.
  @visibleForTesting
  DataTrackingHttpClient get trackingClientForTest => _sharedClient;

  /// The token wrapper around an arbitrary client, for tests.
  ///
  /// Exposed because the rule it enforces — Worker yes, everyone else no — is
  /// a SECURITY boundary, and one that is invisible at every call site. A test
  /// has to be able to see what actually went onto the wire.
  @visibleForTesting
  static http.Client wrapForTest(http.Client inner) => _WorkerTokenClient(inner);

  /// The host the wrapper matches on, so a test asserts against the real value
  /// rather than restating it.
  @visibleForTesting
  static String get workerHostForTest => BackendConfig.workerHost;

}

/// Attaches the gate token to Worker requests and to nothing else.
///
/// Matching on the host avoids two failures: forgetting to send the token (it
/// once lived in a helper nothing called, so it was never sent), and sending it
/// too widely (this client also talks to YouTube, Last.fm and image hosts, which
/// must not receive an identifier for this install).
class _WorkerTokenClient extends http.BaseClient {
  _WorkerTokenClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Exact host match, not `contains`: a substring test would also match a
    // hostile lookalike that merely ENDS with the Worker's name.
    if (request.url.host == BackendConfig.workerHost) {
      request.headers.addAll(AuvyAppToken.header);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}