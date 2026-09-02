import 'dart:async';

/// Paces outbound API calls so we never burst YouTube's InnerTube endpoints
/// (bursts trigger HTTP 429 / bot-checks). This is the client-side equivalent
/// of an API-gateway rate limiter.
///
/// It combines two mechanisms:
///  * a **token bucket** that allows a short burst of [burst] calls, and
///  * a **minimum interval** between consecutive calls to smooth sustained load.
///
/// Calls are serialized through an internal chain so ordering is preserved and
/// the pacing is honored even under heavy concurrency.
class RateLimiter {
  RateLimiter({
    this.minInterval = const Duration(milliseconds: 250),
    this.burst = 4,
  }) : _tokens = burst.toDouble();

  final Duration minInterval;
  final int burst;

  double _tokens;
  DateTime _lastRefill = DateTime.now();
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _chain = Future<void>.value();

  /// Runs [action] under the limiter. Returns its result (or rethrows its error)
  /// without breaking the pacing chain for subsequent calls.
  ///
  /// Only the PACING GATE ([_acquire]) is serialized — NOT the action. The old
  /// version chained the whole `await action()` onto `_chain`, so the next
  /// queued call couldn't even start acquiring until the current network request
  /// fully finished: effective concurrency was 1, and a single slow player
  /// resolve stalled search/home/browse app-wide (head-of-line blocking) while
  /// the `burst` token bucket sat unused. Now each caller waits its turn at the
  /// gate (preserving FIFO order + minInterval spacing + the token bucket) and
  /// then runs concurrently with others already admitted.
  Future<T> run<T>(Future<T> Function() action) {
    final gate = _chain.then((_) => _acquire());
    // Keep the chain alive/among callers even if a gate future throws.
    _chain = gate.catchError((_) {});
    return gate.then((_) => action());
  }

  /// The burst used to be dead.
  ///
  /// The old body took a token AND THEN enforced `minInterval` since the last
  /// call unconditionally. The second rule subsumes the first: every call was
  /// spaced 220ms apart whether the bucket was full or empty, so `burst: 5`
  /// changed nothing and the class was an interval timer wearing a token
  /// bucket's name. Cold start makes a handful of catalog calls back to back
  /// (home, library, quick picks) and paid ~220ms of pure pacing for each.
  ///
  /// A token bucket means: go NOW while credit remains, and only smooth out once
  /// it is spent. That is what the doc above always claimed and what this does.
  Future<void> _acquire() async {
    _refill();

    if (_tokens >= 1) {
      _tokens -= 1;
      _lastCall = DateTime.now();
      return; // credit available — no artificial wait
    }

    // Bucket empty: this is sustained load, so smooth it.
    final sinceLast = DateTime.now().difference(_lastCall);
    if (sinceLast < minInterval) {
      await Future<void>.delayed(minInterval - sinceLast);
    }
    _refill();
    // Clamped at -1 so a burst of callers that all arrive on an empty bucket
    // cannot dig an arbitrarily deep hole that takes minutes to refill.
    _tokens = (_tokens - 1).clamp(-1.0, burst.toDouble());
    _lastCall = DateTime.now();
  }

  /// Called when the server pushed back (HTTP 429 / 503).
  ///
  /// Empties the bucket and holds the next call off for [cooldown], so the app
  /// stops sprinting the moment YouTube says slow down instead of continuing at
  /// full pace and collecting more 429s. Without this the limiter had no idea
  /// anything had gone wrong — pacing was open-loop.
  void penalise({Duration cooldown = const Duration(seconds: 2)}) {
    _tokens = 0;
    final until = DateTime.now().add(cooldown);
    // _lastCall in the future is exactly how _acquire expresses "not yet".
    if (until.isAfter(_lastCall)) _lastCall = until;
    _lastRefill = DateTime.now();
  }

  void _refill() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;
    if (elapsedMs <= 0) return;
    final perMs = 1 / minInterval.inMilliseconds; // refill 1 token / minInterval
    _tokens = (_tokens + elapsedMs * perMs).clamp(0, burst.toDouble());
    _lastRefill = now;
  }
}
