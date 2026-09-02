import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// A resolve for a track the user has skipped must stop, and must not be
/// treated as evidence about anything.
///
/// ── WHAT WENT WRONG ────────────────────────────────
///
/// The stream chain tries five clients and then a signed-in retry, which can
/// run for seconds. Caught on device 2026-09-02:
///
///     21:56:16.801  Skip detected: California Dreamin' (0% played)
///     21:56:18.426  VISIONOS: stream OK          <- the NEXT track, playing
///     21:56:19.061  IOS: URL failed probe        <- still on the OLD track
///     21:56:19.337  every client refused — treating the visitor id as stale
///     21:56:19.337  ERROR: No playable stream resolved for _SjWyd7LxZ8
///
/// Two and a half seconds of requests spent on a track already off screen, and
/// then a SESSION-WIDE verdict — the visitor id marked stale — drawn from its
/// failure. That verdict then applies to the track the user did move to, so an
/// abandoned resolve could degrade a live one. It also logged an ERROR that
/// would surface a failure for a track nobody was looking at.
void main() {
  final client = codeOf('lib/services/catalog_api_client.dart');
  final resolver = codeOf('lib/services/stream_resolver.dart');
  final player = codeOf('lib/logic/player_system.dart');

  group('the chain can be abandoned', () {
    test('getStreamUrl accepts the predicate', () {
      expect(client, contains('bool Function()? isStillWanted'),
          reason: 'Without it the chain cannot know the user moved on.');
    });

    test('it is checked between clients, not just once at the start', () {
      final start = client.indexOf('Future<Map<String, String>?> getStreamUrl(');
      final loop = client.indexOf('for (int ci = 0;', start);
      final check = client.indexOf('if (abandoned()) {', loop);
      expect(loop, greaterThan(-1), reason: 'The per-client loop is gone.');
      expect(check, greaterThan(loop),
          reason: 'The check must sit inside the loop. Checked once up front, '
              'it cannot catch a skip that happens mid-chain — which is the '
              'only time this bug occurs.');
    });

    test('abandoning returns before the visitor id is blamed', () {
      final start = client.indexOf('Future<Map<String, String>?> getStreamUrl(');
      final abandon = client.indexOf('abandoned — the track changed', start);
      final stale = client.indexOf('_visitorStale = true', start);
      expect(abandon, greaterThan(-1), reason: 'The abandon path is gone.');
      expect(stale, greaterThan(abandon),
          reason: '"The user skipped" is not evidence about the visitor id. If '
              'the abandon path can reach _visitorStale, a skip poisons the '
              'next resolve — the original bug.');
      expect(client.substring(abandon, stale), contains('return null'),
          reason: 'Abandoning must return, not break into the tail that draws '
              'conclusions from a failed chain.');
    });
  });

  group('a skip is not a YouTube failure', () {
    test('an abandoned resolve does not trip the circuit breaker', () {
      expect(resolver, contains('if (isStillWanted != null && !isStillWanted()) return null'),
          reason: 'Both "abandoned" and "no playable stream" arrive as null, '
              'and _resolveInner throws StateError on null to trip the '
              'breaker. Treating them alike lets a few quick skips open the '
              'breaker and refuse resolves for tracks never even attempted.');
    });

    test('the throw is still reachable for a genuine failure', () {
      expect(resolver, contains("throw StateError('no playable stream for"),
          reason: 'The breaker must still trip when YouTube really is gating '
              'request after request.');
    });
  });

  group('a skip is not a refusal either', () {
    // Found while verifying the fix above: the abandon fired correctly, and the
    // log still said "streams are resolving again after 1 refusal(s)". The
    // player's own _noStreamStreak was counting the abandoned resolve.
    //
    // That counter has teeth. At _maxNoStreamStreak it sets
    // _resolveCooldownUntilMs, which then suppresses EVERY resolve for an
    // exponentially growing window — so a few fast skips could stop playback
    // from resolving anything at all, which is worse than what it guards.
    test('an abandoned resolve does not increment the streak', () {
      final start = player.indexOf("final url = stream?['url'];");
      expect(start, greaterThan(-1), reason: 'The resolve result check is gone.');
      final guard = player.indexOf('if (currentState.currentSong?.id != videoId) {', start);
      final bump = player.indexOf('_noStreamStreak++', start);
      expect(guard, greaterThan(-1),
          reason: 'Nothing separates "the user skipped" from "every client '
              'refused" any more, so skipping can trip the resolve cooldown.');
      expect(guard, lessThan(bump),
          reason: 'The guard must come BEFORE the increment, or the skip is '
              'counted before it is recognised.');
    });

    test('the streak still counts a genuine refusal', () {
      expect(player, contains('_noStreamStreak++'),
          reason: 'The gated-account backoff depends on this counter still '
              'rising when resolves really are being refused.');
    });
  });

  group('the player supplies the predicate', () {
    test('it compares against the current song', () {
      expect(player, contains('isStillWanted: () => currentState.currentSong?.id == videoId'),
          reason: 'A mid-track re-resolve must stay wanted — there the videoId '
              'being asked about IS the current song — while a skipped track '
              'must not. Comparing ids gives both.');
    });
  });
}
