/// Where Auvy's backend lives, supplied at BUILD time.
///
/// Why this is NOT a constant in the source
///
/// Auvy is GPL-3.0, so the source is public and anyone may clone, build and run
/// it. That is the licence working as intended and is not something to prevent —
/// GPL §1 requires the corresponding source to be sufficient to build the work,
/// and crippling it would breach the licence.
///
/// What it does NOT require is handing over the operator's infrastructure. The
/// Worker host used to be hardcoded in four files, which meant a clone built
/// straight out of the box pointed at the UPSTREAM Worker: spending its request
/// quota, querying through its Last.fm key, reading covers with its GitHub token,
/// and queueing sign-ins against its approval list. None of that is source, and
/// none of it should be inherited by a fork.
///
/// So the host arrives as a `--dart-define` and there is NO working default. A
/// fork must stand up its own Worker (see server/c1-auth-worker) and pass its
/// host. That is both the honest reading of the licence and better engineering:
/// the backend is now configuration rather than a compiled-in assumption.
///
/// THE DEFAULT IS DELIBERATELY UNRESOLVABLE, NOT EMPTY. An empty string would
/// produce `https:///lastfm` and a pile of confusing parse failures; a fake host
/// fails DNS immediately and [isConfigured] can be checked to say so plainly.
///
/// Build with:
///   flutter build apk --release \
///     --dart-define=AUVY_WORKER_HOST=your-worker.workers.dev \
///     --dart-define=AUVY_YT_CLIENT_ID=...apps.googleusercontent.com
///
/// `tool/build_release.ps1` reads both from `.env` and passes them, so the
/// upstream build needs no arguments.
library;

class BackendConfig {
  BackendConfig._();

  /// Sentinel host. Reaching the network with this means the build was made
  /// without configuration — it fails fast rather than silently borrowing
  /// someone else's backend.
  static const String unconfiguredHost = 'worker-not-configured.invalid';

  /// The Cloudflare Worker host, without scheme or trailing slash.
  ///
  /// `.invalid` is reserved by RFC 2606 precisely so it can never resolve, which
  /// makes a misconfigured build obvious instead of intermittently odd.
  static const String workerHost = String.fromEnvironment(
    'AUVY_WORKER_HOST',
    defaultValue: unconfiguredHost,
  );

  /// `https://<workerHost>` — the base every Worker call is built from.
  static String get workerBase => 'https://$workerHost';

  /// Google OAuth client id for the optional "Connect YouTube Music" import.
  ///
  /// A client id is not a secret (it travels in the authorisation URL, and the
  /// flow is PKCE-protected. See AccountNotifier), but it IDENTIFIES the
  /// upstream's Google Cloud project. A fork authenticating through it would be
  /// making requests that appear to come from that project, and would be bound by
  /// its consent screen and quotas. So it is configuration too.
  ///
  /// Empty is a valid state: the import is optional, and an empty id simply
  /// disables it rather than failing at runtime.
  static const String youtubeClientId = String.fromEnvironment(
    'AUVY_YT_CLIENT_ID',
    defaultValue: '',
  );

  /// False when this build has no backend, so callers can say why rather than
  /// surfacing a DNS error.
  static bool get isConfigured => workerHost != unconfiguredHost;

  /// One line for a diagnostic or an error screen. Never includes a secret,
  /// because there is none here to include.
  static String describe() => isConfigured
      ? 'backend: $workerHost'
      : 'backend NOT CONFIGURED — build with '
          '--dart-define=AUVY_WORKER_HOST=<your worker host>';
}
