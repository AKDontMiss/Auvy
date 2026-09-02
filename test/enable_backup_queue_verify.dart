// Guards the fix for a REAL DATA-LOSS BUG.
//
// What happened: enableCloudBackup was given a guard that COALESCED — a second
// caller received the first call's future. That is wrong whenever the result
// depends on state that changes between the calls, and here it does:
//
//   1. an app whose data had just been cleared starts, finds no saved account,
//      and fires registerAccountFromSession(), which reaches enableCloudBackup
//      while the YouTube identity is still unresolved → returns false
//      ("no identity yet — deferring sync");
//   2. the user finishes logging in and calls enableCloudBackup again;
//   3. the shared future handed back that stale FALSE, so no restore ever ran and
//      the user was shown ONBOARDING as a brand-new user — with their cloud
//      backup sitting there, untouched.
//
// The fix QUEUES instead: each caller waits for the previous attempt, then makes
// its own against current state. This file pins both halves of that contract, and
// mirrors the chain from account_provider.dart exactly (the real method cannot be
// called here — it reaches Firebase and the Worker).
//
// Run: flutter test test/enable_backup_queue_verify.dart
import 'package:flutter_test/flutter_test.dart';

/// Mirrors AccountNotifier.enableCloudBackup / _enableAfter.
class QueuedEnable {
  Future<bool>? _chain;

  /// Stands in for the mutable state the real method reads (a YouTube identity
  /// that only exists after login).
  bool identityAvailable = false;

  int attempts = 0;
  int concurrentPeak = 0;
  int _live = 0;

  Future<bool> _body() async {
    _live++;
    if (_live > concurrentPeak) concurrentPeak = _live;
    attempts++;
    // Reads state at RUN time, not call time — the whole point.
    final result = identityAvailable;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _live--;
    return result;
  }

  Future<bool> enable() {
    final previous = _chain;
    late Future<bool> next;
    next = _after(previous).whenComplete(() {
      if (identical(_chain, next)) _chain = null;
    });
    _chain = next;
    return next;
  }

  Future<bool> _after(Future<bool>? previous) async {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    return _body();
  }
}

void main() {
  test('a later caller is NOT given an earlier caller\'s stale answer', () async {
    final q = QueuedEnable();

    // Call 1: startup, before login — no identity yet.
    final first = q.enable();

    // Call 2: login completes while call 1 is still in flight. THIS is the
    // sequence that lost the user's library.
    q.identityAvailable = true;
    final second = q.enable();

    expect(await first, isFalse, reason: 'ran before the identity existed');
    expect(await second, isTrue,
        reason: 'must make its OWN attempt after login, not reuse the false');
    expect(q.attempts, 2, reason: 'both callers attempted');
  });

  test('attempts never overlap', () async {
    final q = QueuedEnable()..identityAvailable = true;
    await Future.wait([q.enable(), q.enable(), q.enable()]);
    expect(q.concurrentPeak, 1,
        reason: 'overlapping restores are what the guard exists to prevent');
    expect(q.attempts, 3);
  });

  test('a failed attempt does not block the next one', () async {
    final q = _FailingFirst();
    final first = q.enable();
    await expectLater(first, throwsA(isA<StateError>()));
    q.identityAvailable = true;
    expect(await q.enable(), isTrue);
  });

  test('the chain clears once settled, so later calls still run', () async {
    final q = QueuedEnable()..identityAvailable = true;
    await q.enable();
    await q.enable();
    expect(q.attempts, 2);
    expect(q.concurrentPeak, 1);
  });
}

/// First attempt throws; the queue must still let the next one through.
class _FailingFirst extends QueuedEnable {
  bool _thrown = false;

  @override
  Future<bool> _body() async {
    if (!_thrown) {
      _thrown = true;
      throw StateError('worker unreachable');
    }
    return super._body();
  }
}
