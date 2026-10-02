/// Picking up on one device where another left off.
///
/// Every backup push carries what that device is playing: the song, what comes
/// next, the position and whether it was still playing. Another device on the
/// same account that opens while idle takes it, paused, so one tap carries on:
/// at the same position if the other device had paused, or as far along as the
/// time since would have taken it if it was still playing.
///
/// Pure logic; the player applies it and the cloud sync carries it.
library;

import 'package:auvy/services/search_service.dart' show SearchService;

/// Longest gap that is still caught up by walking the queue. Past it, the other
/// device has surely stopped, so the song is taken where it was, not guessed at.
const Duration kHandoffCatchUpLimit = Duration(hours: 6);

/// A handoff older than this is not offered at all.
const Duration kHandoffMaxAge = Duration(days: 7);

class PlaybackHandoff {
  /// The pushing device's sync id (one per account and device).
  final String device;

  /// Its name, for the "picked up from" message.
  final String deviceName;

  /// When the snapshot was taken (epoch ms).
  final int atMs;

  /// Whether it was playing at [atMs]. A paused device is taken at [positionMs].
  final bool playing;
  final int positionMs;

  /// The current song's real length from the sending device's player, for
  /// songs whose catalogue label is missing. 0 when unknown.
  final int durationMs;

  /// `Song.toMap()` of the current song, then of what comes next.
  final Map<String, dynamic> song;
  final List<Map<String, dynamic>> next;

  final String source;
  final String location;
  final String contextTitle;
  final String? contextId;
  final String? contextType;

  /// How much of the queue travels: enough to carry on for a couple of hours
  /// without making every push heavy. Autoplay refills after it as usual.
  static const int maxNext = 40;

  const PlaybackHandoff({
    required this.device,
    required this.deviceName,
    required this.atMs,
    required this.playing,
    required this.positionMs,
    this.durationMs = 0,
    required this.song,
    this.next = const [],
    this.source = '',
    this.location = '',
    this.contextTitle = '',
    this.contextId,
    this.contextType,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'device': device,
        'name': deviceName,
        'at': atMs,
        'playing': playing,
        'pos': positionMs,
        if (durationMs > 0) 'dur': durationMs,
        'song': song,
        'next': next.take(maxNext).toList(),
        'source': source,
        'location': location,
        'ctxTitle': contextTitle,
        'ctxId': ?contextId,
        'ctxType': ?contextType,
      };

  /// Null for anything unreadable: a handoff is a convenience, never worth an
  /// error.
  static PlaybackHandoff? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final song = raw['song'];
      final at = raw['at'];
      if (song is! Map || at is! int) return null;
      return PlaybackHandoff(
        device: (raw['device'] ?? '').toString(),
        deviceName: (raw['name'] ?? '').toString(),
        atMs: at,
        playing: raw['playing'] == true,
        positionMs: raw['pos'] is int ? raw['pos'] as int : 0,
        durationMs: raw['dur'] is int ? raw['dur'] as int : 0,
        song: Map<String, dynamic>.from(song),
        next: [
          for (final s in (raw['next'] as List? ?? const []))
            if (s is Map) Map<String, dynamic>.from(s),
        ],
        source: (raw['source'] ?? '').toString(),
        location: (raw['location'] ?? '').toString(),
        contextTitle: (raw['ctxTitle'] ?? '').toString(),
        contextId: raw['ctxId']?.toString(),
        contextType: raw['ctxType']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Whether this device should take [h]. Only when it is idle, the handoff came
/// from another device, and that device played more recently than this one.
bool shouldAdoptHandoff(
  PlaybackHandoff h, {
  required String thisDevice,
  required bool localPlaying,
  required bool inListenTogether,
  required int? localLastPlaybackMs,
  required int nowMs,
}) {
  if (h.device.isEmpty || h.device == thisDevice) return false;
  if (localPlaying || inListenTogether) return false;
  if (localLastPlaybackMs != null && localLastPlaybackMs >= h.atMs) return false;
  if (nowMs - h.atMs > kHandoffMaxAge.inMilliseconds) return false;
  return true;
}

/// Where to pick up: an index into `[song, ...next]` and the position in it.
///
/// A device that was still playing has moved on by the time since [h.atMs], so
/// the queue is walked by each song's length (for the current song, the sending
/// player's own figure when the label is missing). A song whose length is still
/// unknown stops the walk without guessing a position in it: where it was if it
/// is the current song, its start otherwise (seen on device: a song with no
/// label was taken 552 s into a 207 s track). The end of what travelled is the
/// other limit: the other device went on into autoplay this one can't see, so
/// its last known song is the closest guess.
({int index, int positionMs}) handoffTarget(PlaybackHandoff h, int nowMs) {
  final elapsed = nowMs - h.atMs;
  if (!h.playing || elapsed <= 0 || elapsed > kHandoffCatchUpLimit.inMilliseconds) {
    return (index: 0, positionMs: h.positionMs);
  }
  final songs = [h.song, ...h.next];
  var pos = h.positionMs + elapsed;
  for (var i = 0; i < songs.length; i++) {
    var ms = SearchService.parseDurationSeconds(
            (songs[i]['duration'] ?? '').toString()) *
        1000;
    if (ms <= 0 && i == 0) ms = h.durationMs;
    if (ms <= 0) return (index: i, positionMs: i == 0 ? h.positionMs : 0);
    if (pos < ms) return (index: i, positionMs: pos);
    pos -= ms;
  }
  return (index: songs.length - 1, positionMs: 0);
}
