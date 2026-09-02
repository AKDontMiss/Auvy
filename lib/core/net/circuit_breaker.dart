import 'dart:async';

enum CircuitState { closed, open, halfOpen }

/// Stops the app from hammering a failing dependency (e.g. stream resolution).
///
/// Flow: after [failureThreshold] consecutive failures the breaker **opens** and
/// rejects calls instantly for [cooldown]. Once the cooldown elapses it goes
/// **half-open** and lets a single probe through: success → **closed** (normal),
/// failure → **open** again. This prevents pointless retry storms when YouTube
/// is rate-limiting or a video is unplayable.
class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 4,
    this.cooldown = const Duration(seconds: 30),
    this.name = 'circuit',
  });

  final int failureThreshold;
  final Duration cooldown;
  final String name;

  CircuitState _state = CircuitState.closed;
  int _failures = 0;
  DateTime? _openedAt;

  CircuitState get state => _state;
  bool get isOpen => _state == CircuitState.open && !_cooldownElapsed;

  bool get _cooldownElapsed =>
      _openedAt != null && DateTime.now().difference(_openedAt!) >= cooldown;

  /// Runs [action] unless the circuit is open and still cooling down. When the
  /// circuit is open, [onOpen] is invoked if provided, otherwise a
  /// [CircuitOpenException] is thrown.
  Future<T> run<T>(Future<T> Function() action, {T Function()? onOpen}) async {
    if (_state == CircuitState.open) {
      if (_cooldownElapsed) {
        _state = CircuitState.halfOpen;
      } else if (onOpen != null) {
        return onOpen();
      } else {
        throw CircuitOpenException(name);
      }
    }

    try {
      final result = await action();
      _onSuccess();
      return result;
    } catch (_) {
      _onFailure();
      rethrow;
    }
  }

  void _onSuccess() {
    _failures = 0;
    _state = CircuitState.closed;
    _openedAt = null;
  }

  void _onFailure() {
    _failures++;
    if (_state == CircuitState.halfOpen || _failures >= failureThreshold) {
      _state = CircuitState.open;
      _openedAt = DateTime.now();
    }
  }

  void reset() {
    _failures = 0;
    _state = CircuitState.closed;
    _openedAt = null;
  }
}

class CircuitOpenException implements Exception {
  CircuitOpenException(this.name);
  final String name;
  @override
  String toString() => 'CircuitOpenException($name): circuit is open';
}
