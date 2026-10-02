import 'dart:async';

/// Paces outbound calls to YouTube's InnerTube API, since bursts trigger HTTP 429
/// and bot checks.
///
/// Combines a token bucket (up to [burst] calls may go immediately) with a
/// minimum interval once the bucket is empty. Callers are admitted in order.
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

  /// Runs [action] under the limiter and returns its result (or rethrows).
  ///
  /// Only admission is serialised: once admitted, calls run concurrently, so one
  /// slow request does not hold up the others.
  Future<T> run<T>(Future<T> Function() action) {
    final gate = _chain.then((_) => _acquire());
    // Keep the chain alive even if a gate future throws.
    _chain = gate.catchError((_) {});
    return gate.then((_) => action());
  }

  /// Waits for permission to make one call: immediately while tokens remain,
  /// otherwise spaced by [minInterval].
  Future<void> _acquire() async {
    _refill();

    if (_tokens >= 1) {
      _tokens -= 1;
      _lastCall = DateTime.now();
      return; // credit available — no artificial wait
    }

    // Bucket empty: sustained load, so space the calls out.
    final sinceLast = DateTime.now().difference(_lastCall);
    if (sinceLast < minInterval) {
      await Future<void>.delayed(minInterval - sinceLast);
    }
    _refill();
    // Clamped at -1 so many callers arriving at once cannot dig a deep deficit.
    _tokens = (_tokens - 1).clamp(-1.0, burst.toDouble());
    _lastCall = DateTime.now();
  }

  /// Called when the server pushes back (HTTP 429 / 503): empties the bucket and
  /// holds the next call off for [cooldown].
  void penalise({Duration cooldown = const Duration(seconds: 2)}) {
    _tokens = 0;
    final until = DateTime.now().add(cooldown);
    // A `_lastCall` in the future is how [_acquire] expresses "not yet".
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
