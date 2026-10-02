/// A small ring of notable events that is kept even in release builds.
///
/// main.dart drops every print() in release builds unless
/// `--dart-define=AUVY_DEBUG_LOG=true` is set, and the diagnostics export is
/// otherwise a snapshot of current state. So important decisions are also
/// recorded here, which lets "export diagnostics" from a normal build explain how
/// things got that way. The cost is a bounded list of short strings, with no I/O.
///
/// What belongs here: decisions and outcomes, not ticks. The ring holds 300
/// entries, so anything per frame, per position sample or per line would push
/// everything else out. Ask: would this line answer "why did it do that?"
/// tomorrow? Which lyrics source won and whether it was version-checked, yes;
/// where the playhead is twice a second, no.
///
/// Memory only: writing it to disk would need its own size limit, account-switch
/// wipe and privacy review. It's materialised when the user asks for an export.
class EventLog {
  EventLog._();

  /// Bounded so a long session cannot grow it without limit. Roughly an hour of
  /// ordinary listening at a handful of events per track.
  static const int _cap = 300;
  static final List<String> _entries = <String>[];

  /// Wall-clock start, so the relative stamps below can be read back as times.
  static final DateTime _startedAt = DateTime.now();

  static void add(String message) {
    if (message.isEmpty) return;
    final now = DateTime.now();
    final t = now.difference(_startedAt);
    final stamp = '${t.inMinutes.toString().padLeft(3, '0')}:'
        '${(t.inSeconds % 60).toString().padLeft(2, '0')}.'
        '${(t.inMilliseconds % 1000).toString().padLeft(3, '0')}';
    _entries.add('$stamp  $message');
    // Trimmed from the FRONT: the newest events are the ones worth keeping when
    // something has just gone wrong.
    if (_entries.length > _cap) {
      _entries.removeRange(0, _entries.length - _cap);
    }
  }

  /// Newest last, ready to append to the diagnostics export.
  static List<String> get entries => List.unmodifiable(_entries);

  static DateTime get startedAt => _startedAt;

  /// Cleared on an account wipe: these lines can name titles and identities,
  /// and none of that belongs to the next account.
  static void clear() => _entries.clear();
}

/// Record a decision AND print it.
///
/// One call rather than two so the two can never drift apart — a line that is
/// printed during development but missing from a user's export is the failure
/// this whole file exists to prevent. `print` is dropped by the release zone
/// handler; [EventLog] is not.
void logEvent(String message) {
  EventLog.add(message);
  // Unconditional on purpose: the zone handler in main.dart already decides
  // whether a release build forwards this, so gating it again here would only
  // add a second place for the two paths to disagree.
  // ignore: avoid_print
  print(message);
}
