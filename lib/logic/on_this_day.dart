import 'package:auvy/data/dummy_data.dart';

/// A song whose FIRST play falls on today's date in an earlier year.
class Anniversary {
  const Anniversary({
    required this.song,
    required this.yearsAgo,
    required this.firstPlayed,
  });

  final Song song;

  /// Whole years between [firstPlayed] and today. 1 means "a year ago today".
  final int yearsAgo;
  final DateTime firstPlayed;

  /// "A year ago today" / "3 years ago today".
  String get label =>
      yearsAgo == 1 ? 'A year ago today' : '$yearsAgo years ago today';
}

/// Songs first played on today's date in an earlier year.
///
/// Uses data the app already keeps and backs up (`intel_first_timestamps` and
/// `intel_metadata`), so it needs no network. Keys off the first play, which
/// never changes, rather than the most recent. [now] is a parameter for testing.
List<Anniversary> anniversariesFor({
  required Map<String, int> firstPlayTimestamps,
  required Map<String, Song> trackMetadata,
  required DateTime now,
  /// Widen to "around this time" when the exact date finds nothing; 0 means exact
  /// day only.
  int windowDays = 0,
  int limit = 25,
}) {
  final out = <Anniversary>[];

  firstPlayTimestamps.forEach((id, ms) {
    if (ms <= 0) return;
    final song = trackMetadata[id];
    // No metadata, nothing to show.
    if (song == null) return;

    final first = DateTime.fromMillisecondsSinceEpoch(ms);

    // Check last year, this year and next year for the nearest match, so dates
    // around New Year still work (a 31 December first play, checked on 1 January).
    DateTime? nearest;
    int? nearestDiff;
    for (final y in [now.year - 1, now.year, now.year + 1]) {
      final candidate = _sameDayThisYear(first, y);
      if (candidate == null) continue; // 29 Feb in a non-leap year
      final d = _dayDifference(candidate, now);
      if (nearestDiff == null || d.abs() < nearestDiff.abs()) {
        nearestDiff = d;
        nearest = candidate;
      }
    }
    if (nearest == null || nearestDiff == null) return;
    if (nearestDiff.abs() > windowDays) return;

    // Counted by calendar years, not by dividing milliseconds (leap years).
    final yearsAgo = nearest.year - first.year;
    // Anything under a year is not an anniversary.
    if (yearsAgo < 1) return;

    out.add(Anniversary(song: song, yearsAgo: yearsAgo, firstPlayed: first));
  });

  // Nearest first, so a truncated list keeps the most recent memories.
  out.sort((a, b) {
    final byYears = a.yearsAgo.compareTo(b.yearsAgo);
    if (byYears != 0) return byYears;
    return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// [original]'s month and day in [year], or null if that date doesn't exist
/// (29 February in a non-leap year).
DateTime? _sameDayThisYear(DateTime original, int year) {
  if (original.month == 2 && original.day == 29 && !_isLeapYear(year)) {
    return null;
  }
  return DateTime(year, original.month, original.day);
}

bool _isLeapYear(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// Whole days between two dates, ignoring the time of day, so daylight-saving
/// changes don't shift the result.
int _dayDifference(DateTime a, DateTime b) {
  final da = DateTime(a.year, a.month, a.day);
  final db = DateTime(b.year, b.month, b.day);
  return db.difference(da).inDays;
}
