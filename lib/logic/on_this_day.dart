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

/// "You found this a year ago today."
///
/// Runs on data we already keep: `intel_first_timestamps` (id → first play in
/// epoch ms) plus `intel_metadata` (id → Song). Both are already in the cloud
/// backup, so this needs no network call, works offline, and comes back after a
/// reinstall.
///
/// It keys off the FIRST play, not the most recent one. A last-played date just
/// records when you happened to open the app, and it gets overwritten every
/// time you listen. First play doesn't change.
///
/// [now] is a parameter rather than DateTime.now() so the date arithmetic can be
/// tested without waiting for the calendar to cooperate.
List<Anniversary> anniversariesFor({
  required Map<String, int> firstPlayTimestamps,
  required Map<String, Song> trackMetadata,
  required DateTime now,
  /// Widen to "around this time" when the exact date has nothing in it. Leave at
  /// 0 for exact-day only, which reads as a memory rather than a statistic.
  int windowDays = 0,
  int limit = 25,
}) {
  final out = <Anniversary>[];

  firstPlayTimestamps.forEach((id, ms) {
    if (ms <= 0) return;
    final song = trackMetadata[id];
    // No metadata, nothing to render. An id on its own is not a song.
    if (song == null) return;

    final first = DateTime.fromMillisecondsSinceEpoch(ms);

    // Check the neighbouring years too, not just this one.
    //
    // Placing the anniversary in `now.year` alone breaks over New Year. On
    // 1 January a song first played on 31 December gets compared against
    // 31 December eleven months away, and dropped. Trying year-1, year and
    // year+1 and keeping whichever lands closest to today sidesteps it.
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

    // Counted off the calendar, not by dividing milliseconds. A flat 365 days
    // drifts by one every leap year, and an anniversary that lands a day out
    // looks broken.
    final yearsAgo = nearest.year - first.year;
    // "Today" is not an anniversary, and neither is anything under a year.
    if (yearsAgo < 1) return;

    out.add(Anniversary(song: song, yearsAgo: yearsAgo, firstPlayed: first));
  });

  // Nearest first. One year ago is a memory, eight years ago is trivia, so if
  // the list gets truncated it should be the trivia that goes.
  out.sort((a, b) {
    final byYears = a.yearsAgo.compareTo(b.yearsAgo);
    if (byYears != 0) return byYears;
    return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// [original]'s month and day placed in [year], or null if that date doesn't
/// exist there. In practice that means 29 February outside a leap year.
///
/// Null rather than sliding to the 28th or to 1 March. A leap-day song simply
/// has no anniversary in a non-leap year, and picking one for it would be wrong
/// three years in four.
DateTime? _sameDayThisYear(DateTime original, int year) {
  if (original.month == 2 && original.day == 29 && !_isLeapYear(year)) {
    return null;
  }
  return DateTime(year, original.month, original.day);
}

bool _isLeapYear(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// Whole days from [a] to [b], comparing DATES only.
///
/// Built from a date-only DateTime rather than subtracting the originals,
/// because a Duration between two wall-clock instants is 23 or 25 hours across a
/// daylight-saving change, so "the same date" would come out as ±1 day twice a
/// year.
int _dayDifference(DateTime a, DateTime b) {
  final da = DateTime(a.year, a.month, a.day);
  final db = DateTime(b.year, b.month, b.day);
  return db.difference(da).inDays;
}
