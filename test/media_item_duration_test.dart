import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// The media notification must get a duration in the same frame as the track.
///
/// ── WHAT WENT WRONG ────────────────────────────────
///
/// playSong resets PlayerState.duration to zero, and the native engine only
/// reports the real one on its first position tick — about two seconds later.
/// Until then the published MediaItem carried `duration: null`, and a MediaItem
/// with no duration is exactly what makes Android drop the seek bar and the
/// timestamps from the media notification.
///
/// broadcastState() does patch the duration in once the tick lands, but the
/// panel does not re-lay-out a seek bar it has already drawn without one, so
/// the controls stayed bare for the rest of the track.
///
/// Reproduced with `adb shell input keyevent 87`: the session went
/// `metadata: size=9` and then `size=10` two seconds later, while the
/// notification showed neither bar nor clock the whole time. An in-app skip
/// looked fine only because the player page draws its own bar from PlayerState
/// and never consults the media session — which is why this went unnoticed.
///
/// Song.duration is the catalogue's `m:ss` label and is already known for every
/// queued track, so the fallback costs nothing and needs no network.
void main() {
  final player = codeOf('lib/logic/player_system.dart');

  group('a skip publishes a real duration immediately', () {
    test('the media item does not hardcode the engine-only duration', () {
      expect(player, isNot(contains('duration: currentState.duration != Duration.zero ? currentState.duration : null')),
          reason: 'Back to publishing null until the first position tick. That '
              'is the missing seek bar: metadata goes out at size=9.');
    });

    test('_updateMediaItem uses the fallback', () {
      final start = player.indexOf('void _updateMediaItem(Song song) {');
      expect(start, greaterThan(-1), reason: '_updateMediaItem is gone.');
      final body = player.substring(start, player.indexOf('handler.setCurrentMediaItem(', start));
      expect(body, contains('duration: _mediaItemDuration(song, currentState.duration)'),
          reason: 'The first publish after a skip is the one the notification '
              'lays out from, so it is the one that needs a duration.');
    });

    test('the artwork re-publish uses it too', () {
      final start = player.indexOf('void _upgradeCurrentArtwork(');
      expect(start, greaterThan(-1), reason: '_upgradeCurrentArtwork is gone.');
      final body = player.substring(start, start + 900);
      expect(body, contains('_mediaItemDuration(song, currentState.duration)'),
          reason: 'This re-publish can land before the first tick, so a null '
              'duration here would undo a seek bar that was already showing.');
    });
  });

  group('the fallback parses a time label, not anything', () {
    test('it prefers the engine when the engine has an answer', () {
      expect(player, contains('if (fromEngine > Duration.zero) return fromEngine'),
          reason: 'The measured duration must win over the catalogue label — '
              'the label is rounded to whole seconds and can disagree.');
    });

    test('it rejects anything that is not m:ss or h:mm:ss', () {
      expect(player, contains('if (parts.length < 2 || parts.length > 3) return null'),
          reason: 'Without a shape check, a label like "Live" or "" parses to '
              'zero and publishes a wrong duration — a seek bar that lies '
              'about the track is worse than none.');
    });

    test('zero and unparseable both yield null, never Duration.zero', () {
      final start = player.indexOf('Duration? _mediaItemDuration(');
      expect(start, greaterThan(-1), reason: '_mediaItemDuration is gone.');
      final body = player.substring(start, player.indexOf('void _updateMediaItem(', start));
      expect(body, contains('seconds > 0 ? Duration(seconds: seconds) : null'),
          reason: 'setCurrentMediaItem substitutes 24h for live radio only when '
              'it sees null. Duration.zero would defeat that.');
      expect(body, contains('if (v == null || v < 0) return null'),
          reason: 'A non-numeric segment must abandon the parse, not count as '
              'zero and shift the real digits into the wrong place.');
    });
  });
}
