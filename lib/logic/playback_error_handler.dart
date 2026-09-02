/// Classifies a playback failure into one line for the transcript.
///
/// What this is AND is NOT
///
/// The string it returns is PRINTED, never shown to the user. So its whole job
/// is to make a failure identifiable in a log, which is exactly what the first
/// version could not do.
class PlaybackErrorHandler {
  /// Whether [error] names a specific, recognised failure.
  ///
  /// WHY 'http' AND 'source' ARE NOT TESTED FOR
  ///
  /// The old classifier read:
  ///
  ///     if (errorStr.contains('404') || errorStr.contains('410') ||
  ///         errorStr.contains('http') || errorStr.contains('source'))
  ///       return "Connection lost. Retrying...";
  ///
  /// Almost every error that reaches here contains one of those two words —
  /// Dart exceptions from the play path quote the stream URL, and media3 says
  /// "Source error" for most IO faults. So that branch absorbed nearly
  /// everything and answered "Connection lost" to all of it, which made the
  /// `format` branch below it effectively DEAD CODE: a decoder failure whose
  /// message mentions the URI never reached it.
  ///
  /// The result was a log line that said the same reassuring thing whatever went
  /// wrong, and sent a reader looking for a network problem that was often not
  /// there. Same failure mode as a warning that fires on a normal outcome: once
  /// it always says one thing, it says nothing.
  ///
  /// Ordered most-specific-first, and every branch tests a phrase that only
  /// appears for that kind of fault.
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
    // A refusal, not an outage — the distinction that took hours to work out
    // during the 2026-08-30 throttle. Worth naming so the next reader does not
    // repeat that.
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

  /// One line naming the failure, its class, and its own text.
  ///
  /// THE EXCEPTION'S OWN TEXT IS INCLUDED, and that is the part the previous
  /// version threw away. A canned phrase cannot be searched for, correlated with
  /// a native log line, or told apart from a different fault with the same
  /// category, and the exception already knows what happened.
  ///
  /// [songId] is carried into the line so a failure can be tied to the track it
  /// belongs to, which matters when a retry lands on a different one.
  String handleError(Object error, String songId) {
    final raw = error.toString();
    final kind = _classify(raw.toLowerCase());
    final where = songId.isEmpty ? '' : ' [$songId]';
    return 'playback failed$where — $kind: ${error.runtimeType}: $raw';
  }

  /// Exponential backoff for retries: 2s, 4s, 8s, 16s, then 16s.
  ///
  /// Clamped at BOTH ends on purpose. A negative attempt would throw on the list
  /// index, and an attempt past the end would too, and the caller passes a
  /// running error count, which is precisely the kind of value that grows past
  /// whatever a table assumed.
  Duration getRetryDelay(int attempt) =>
      Duration(seconds: const [2, 4, 8, 16][attempt.clamp(0, 3)]);
}
