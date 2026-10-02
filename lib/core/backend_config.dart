/// Where Auvy's backend lives, supplied at build time.
///
/// The source is public (GPL-3.0), but the backend is the operator's own. So the
/// Worker host is passed as a `--dart-define` and there is no working default: a
/// build made without it cannot reach anyone else's server, and a fork runs its
/// own backend (the Worker is not part of the source release).
///
/// Build with:
///   flutter build apk --release \
///     --dart-define=AUVY_WORKER_HOST=your-worker.workers.dev
///
/// The build scripts in tool/ read it from `.env`.
library;

class BackendConfig {
  BackendConfig._();

  /// Placeholder host used when no Worker was configured; it fails fast.
  static const String unconfiguredHost = 'worker-not-configured.invalid';

  /// The Cloudflare Worker host, without scheme or trailing slash. The `.invalid`
  /// top-level domain is reserved and never resolves, so a misconfigured build fails
  /// immediately.
  static const String workerHost = String.fromEnvironment(
    'AUVY_WORKER_HOST',
    defaultValue: unconfiguredHost,
  );

  /// `https://<workerHost>` — the base every Worker call is built from.
  static String get workerBase => 'https://$workerHost';

  /// False when this build has no backend configured.
  static bool get isConfigured => workerHost != unconfiguredHost;

  /// One line for diagnostics or an error screen. Contains no secrets.
  static String describe() => isConfigured
      ? 'backend: $workerHost'
      : 'backend NOT CONFIGURED — build with '
          '--dart-define=AUVY_WORKER_HOST=<your worker host>';
}
