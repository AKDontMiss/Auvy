import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/on_this_day.dart';

/// Pins the date arithmetic in [anniversariesFor]. Every case here is one I got
/// wrong or nearly wrong while writing it: the New Year boundary, leap days, and
/// "today" counting as its own anniversary.
Song _song(String id, String title) =>
    Song(id: id, title: title, artist: 'A', image: '', audioUrl: '');

int _ms(int y, int m, int d) => DateTime(y, m, d, 12).millisecondsSinceEpoch;

void main() {
  final meta = {
    'a': _song('a', 'Alpha'),
    'b': _song('b', 'Bravo'),
    'c': _song('c', 'Charlie'),
    'leap': _song('leap', 'Leap'),
  };

  test('exact same date in an earlier year is an anniversary', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2024, 8, 13)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
    );
    expect(r.length, 1);
    expect(r.first.yearsAgo, 2);
    expect(r.first.label, '2 years ago today');
  });

  test('a play from today is NOT an anniversary', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2026, 8, 13)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
    );
    expect(r, isEmpty);
  });

  test('under a year is not an anniversary even on the same day', () {
    // Same month/day would match, but it is only months old.
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2026, 8, 13)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
      windowDays: 5,
    );
    expect(r, isEmpty);
  });

  test('a different date is excluded when the window is exact', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2024, 8, 12)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
    );
    expect(r, isEmpty);
  });

  test('window admits nearby dates', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2024, 8, 12)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
      windowDays: 3,
    );
    expect(r.length, 1);
    expect(r.first.yearsAgo, 2);
  });

  test('NEW YEAR BOUNDARY: 31 Dec seen on 1 Jan still matches', () {
    // The bug this pins: placing the anniversary only in now.year compares
    // 31 Dec 2026 against 1 Jan 2026 — 364 days — and drops it.
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': _ms(2024, 12, 31)},
      trackMetadata: meta,
      now: DateTime(2026, 1, 1),
      windowDays: 3,
    );
    expect(r.length, 1);
    // 31 Dec 2025 is the nearest anniversary to 1 Jan 2026 → one year on.
    expect(r.first.yearsAgo, 1);
  });

  test('LEAP DAY: 29 Feb has no anniversary in a non-leap year', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'leap': _ms(2024, 2, 29)},
      trackMetadata: meta,
      now: DateTime(2026, 2, 28),
    );
    expect(r, isEmpty, reason: '29 Feb must not slide onto 28 Feb');
  });

  test('LEAP DAY: 29 Feb matches in the next leap year', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'leap': _ms(2024, 2, 29)},
      trackMetadata: meta,
      now: DateTime(2028, 2, 29),
    );
    expect(r.length, 1);
    expect(r.first.yearsAgo, 4);
  });

  test('nearest anniversary sorts first, and limit truncates', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {
        'a': _ms(2018, 8, 13), // 8 years
        'b': _ms(2025, 8, 13), // 1 year
        'c': _ms(2022, 8, 13), // 4 years
      },
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
      limit: 2,
    );
    expect(r.length, 2);
    expect(r[0].yearsAgo, 1);
    expect(r[1].yearsAgo, 4);
  });

  test('ids without metadata are skipped, not rendered blank', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'ghost': _ms(2024, 8, 13)},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
    );
    expect(r, isEmpty);
  });

  test('a zero/absent timestamp is ignored', () {
    final r = anniversariesFor(
      firstPlayTimestamps: {'a': 0},
      trackMetadata: meta,
      now: DateTime(2026, 8, 13),
    );
    expect(r, isEmpty);
  });
}
