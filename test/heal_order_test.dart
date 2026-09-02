import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The ORDER of the recovery branches, which is the whole of three bugs.
///
/// ── WHY ORDER, AND WHY SOURCE TEXT ──────────────────────────────────────────
///
/// Each fix here is a branch moved or guarded, not a value changed, so what needs
/// protecting is the sequence. `handleStreamLeaseExpiration` lives on a Riverpod
/// notifier that owns an ExoPlayer and a method channel; standing one up would
/// test the harness. `documented_invariants_test.dart` and `day3_fixes_test.dart`
/// take the same approach for the same reason.
///
/// `codeOf` throughout, never `readAsStringSync`: every one of these branches is
/// EXPLAINED in a comment that names the other branch, so a raw scan would match
/// the prose rather than the code. See helpers/source_text.dart.
void main() {
  final smart = codeOf('lib/logic/player_smart.dart');
  final system = codeOf('lib/logic/player_system.dart');

  /// Just the body of [_healFromLocalCopy], bounded at BOTH ends.
  ///
  /// The end anchor is code, not the doc comment above the next method: codeOf
  /// strips comments, so anchoring on prose silently yields -1 and every
  /// substring below throws a RangeError instead of failing with a reason.
  final helper = smart.substring(
      smart.indexOf('_healFromLocalCopy('),
      smart.indexOf('Future<void> handleStreamLeaseExpiration('));

  group('a complete local copy outranks every network branch', () {
    test('the cache heal is attempted BEFORE the offline deferral', () {
      // THE BUG: the offline branch returns, so a fully-cached track could never
      // reach the cache-first heal while offline. The network drops mid-track,
      // the auto-cache has already written the whole file, and the heal holds for
      // a reconnect the audio does not need.
      final local = smart.indexOf('_healFromLocalCopy(');
      final offline = smart.indexOf('hasInternet');
      expect(local, greaterThan(-1), reason: 'The local-copy heal is gone.');
      expect(offline, greaterThan(-1),
          reason: 'The offline check is gone — find it and re-establish the '
              'order this test exists to protect.');
      expect(local, lessThan(offline),
          reason: 'The offline deferral now runs first, so a track sitting '
              'complete on disk waits for a reconnect it does not need.');
    });

    test('the stall watchdog checks the cache before arming the 12s floor', () {
      final cached = system.indexOf('getCachedPath(stalledSong.id)');
      final floor = system.indexOf('Timer(const Duration(seconds: 12)');
      expect(cached, greaterThan(-1),
          reason: 'The stall path no longer consults the cache, so a cached '
              'track pays the full 3s grace + 12s floor in silence.');
      expect(floor, greaterThan(-1), reason: 'The recovery floor is gone.');
      expect(cached, lessThan(floor),
          reason: 'The floor is armed before the cache is consulted.');
    });

    test('a radio stream is never asked for a cache path', () {
      // getCachedPath on an http pseudo-id is meaningless, and the index would
      // never hold one — but asking still costs a lookup on every fault.
      expect(smart.contains("song.id.startsWith('http')"), isTrue);
      expect(system.contains("stalledSong.id.startsWith('http')"), isTrue);
    });
  });

  group('the local heal can give up', () {
    test('it counts attempts in its own counter, not _healCount', () {
      // _healCount is RESET by a successful local swap, which is correct when the
      // swap works and fatal when it does not: the file fails, heals again, and
      // the counter that would stop it is wiped every pass. Six landed in 184ms.
      expect(smart.contains('_localHealCount'), isTrue,
          reason: 'The separate local-heal counter is gone, so the give-up is '
              'back to being reset by its own success path.');
      final give = helper.indexOf('_localHealCount >= _kMaxLocalHeals');
      expect(give, greaterThan(-1),
          reason: 'Nothing caps the local heal any more.');
    });

    test('the reset is GUARDED by the song id and a time window', () {
      // The unguarded version of this exact pattern is what made the pinned
      // format give-up unreachable in player_system.dart. A reset that fires on
      // every call is the same bug wearing different names.
      final guard = helper.indexOf('_localHealSongId != song.id ||');
      final reset = helper.indexOf('_localHealCount = 0');
      expect(guard, greaterThan(-1),
          reason: 'The local-heal counter is reset unconditionally, so the cap '
              'is unreachable — the count can never pass 1.');
      expect(guard, lessThan(reset),
          reason: 'The reset runs before its guard.');
      expect(helper.contains('_kLocalHealWindow.inMilliseconds'), isTrue,
          reason: 'The window that lets a genuinely fresh fault start over is '
              'gone, so one bad file condemns the copy for the session.');
    });

    test('giving up FALLS THROUGH rather than stopping playback', () {
      // The point of distrusting the file is to let the resolve path try, not to
      // strand the track. The helper must answer false, and the caller must carry
      // on when it does.
      expect(helper.contains('return false;'), isTrue,
          reason: 'The give-up no longer reports "not handled", so the caller '
              'cannot know to resolve a stream instead.');
      expect(smart.contains('if (await _healFromLocalCopy('), isTrue,
          reason: 'The caller no longer branches on the result.');
    });

    test('a successful swap still clears the NETWORK heal counters', () {
      // Progress is real progress: the track is playing from disk, so the
      // no-progress and network-hold counts must not carry into the next fault.
      final upTo = helper.substring(0, helper.indexOf('return true;'));
      for (final f in ['_healCount = 0', '_healNetHoldCount = 0']) {
        expect(upTo.contains(f), isTrue,
            reason: '$f is no longer cleared by a successful local heal.');
      }
    });

    test('it resumes at the interruption point, not 0:00', () {
      // Between playTrack (prepare → position 0) and the seek-back the engine
      // reports 0. Reading that as the real position is the "song restarted
      // itself" glitch, and the network path already corrects for it.
      final upTo = helper.substring(0, helper.indexOf('return true;'));
      expect(upTo.contains('_healLastPosition'), isTrue,
          reason: 'The local heal no longer applies the position-0 correction, '
              'so a fault caught mid-heal restarts the track.');
      expect(upTo.contains('NativeAudioEngine.seek(at)'), isTrue,
          reason: 'The heal no longer seeks back at all.');
    });
  });

  group('the offline hold is still there for a track that needs it', () {
    test('an UNCACHED track offline still holds and arms a retry', () {
      // The hoist must not have removed the deferral — only demoted it below the
      // case that does not need a network.
      final offline = smart.substring(smart.indexOf('hasInternet'),
          smart.indexOf('Duration interruptionPoint ='));
      expect(offline.contains('_pendingNetworkRetry'), isTrue,
          reason: 'The offline path no longer arms the reconnect retry.');
      expect(offline.contains('invalidateAllStreams'), isTrue,
          reason: 'The reconnect no longer drops URLs bound to the dead path.');
    });
  });
}
