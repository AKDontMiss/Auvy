/// Turns a playback failure into one log line. The text is logged, never shown
/// to the user.
class PlaybackErrorHandler {
  /// Classifies [error] by phrases specific to each kind of fault, most specific
  /// first. Broad words like 'http' or 'source' appear in almost every error, so
  /// they are not used.
  static String _classify(String e) {
    if (e.contains('failed host lookup') ||
        e.contains('no address associated') ||
        e.contains('network is unreachable') ||
        e.contains('socketexception')) {
      return 'no network';
    }
    if (e.contains('timeout') || e.contains('timedout')) {
      return 'timed out';
    }
    // A refusal (403/401/login required), not an outage.
    if (e.contains('403') || e.contains('401') || e.contains('login_required')) {
      return 'refused by the server';
    }
    if (e.contains('404') || e.contains('410')) {
      return 'stream gone (expired url)';
    }
    if (e.contains('unsupported') ||
        e.contains('decoding_format') ||
        e.contains('decoder')) {
      return 'audio the decoder will not take';
    }
    if (e.contains('no playable stream') ||
        e.contains('no fresh stream')) {
      return 'nothing resolved for this track';
    }
    return 'unrecognised';
  }

  /// One line naming the failure class and including the exception's own text,
  /// plus [songId] so the failure can be tied to its track.
  String handleError(Object error, String songId) {
    final raw = error.toString();
    final kind = _classify(raw.toLowerCase());
    final where = songId.isEmpty ? '' : ' [$songId]';
    return 'playback failed$where — $kind: ${error.runtimeType}: $raw';
  }

  /// Exponential backoff: 2s, 4s, 8s, 16s, then 16s. Clamped at both ends, since
  /// the caller passes a running error count.
  Duration getRetryDelay(int attempt) =>
      Duration(seconds: const [2, 4, 8, 16][attempt.clamp(0, 3)]);
}
