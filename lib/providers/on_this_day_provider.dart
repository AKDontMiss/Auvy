import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/on_this_day.dart';
import 'package:auvy/providers/intelligence_provider.dart';

/// The "On this day" shelf: songs whose FIRST play fell on today's date in an
/// earlier year, plus the subtitle describing how exactly they matched.
class OnThisDayShelf {
  const OnThisDayShelf({required this.songs, required this.subtitle});

  static const empty = OnThisDayShelf(songs: [], subtitle: '');

  final List<Song> songs;

  /// Honest about the match. "A year ago today" and "Around this time last
  /// year" are different claims, and a shelf that says the first while meaning
  /// the second is the kind of small lie that makes the whole feature feel
  /// approximate.
  final String subtitle;

  bool get isEmpty => songs.isEmpty;
}

/// Tries the exact date first ("a year ago today") and widens only when that's
/// empty, with the subtitle changing to match. The shelf is empty, not
/// approximate, when even the widest window finds nothing (e.g. under a year of
/// history).
///
/// Memo key: the calendar day plus the number of known first-plays. An
/// anniversary needs at least a year, so a play recorded today can never create
/// one; the answer only changes at midnight or when a restore brings different
/// first-plays. This avoids re-scanning on every play (play counts live in the
/// same watched state).
String? _memoKey;
OnThisDayShelf? _memo;

final onThisDayProvider = Provider<OnThisDayShelf>((ref) {
  final firstPlays =
      ref.watch(intelligenceProvider.select((s) => s.firstPlayTimestamps));
  if (firstPlays.isEmpty) return OnThisDayShelf.empty;

  final now = DateTime.now();
  final key = '${now.year}-${now.month}-${now.day}:${firstPlays.length}';
  final cached = _memo;
  if (cached != null && _memoKey == key) return cached;

  final intel = ref.read(intelligenceProvider);
  // (window in days, subtitle) — narrowest first.
  const attempts = <(int, String)>[
    (0, 'You first heard these today, years back'),
    (3, 'Around this time last year'),
    (10, 'Around this time in years past'),
  ];

  for (final (window, subtitle) in attempts) {
    final found = anniversariesFor(
      firstPlayTimestamps: firstPlays,
      trackMetadata: intel.trackMetadata,
      now: now,
      windowDays: window,
      limit: 20,
    );
    if (found.isEmpty) continue;
    // An exact match can name the interval precisely, because every entry
    // shares today's date; a widened one cannot, so it stays general.
    final label = window == 0 && found.every((a) => a.yearsAgo == found.first.yearsAgo)
        ? found.first.label
        : subtitle;
    final shelf = OnThisDayShelf(
      songs: found.map((a) => a.song).toList(),
      subtitle: label,
    );
    _memoKey = key;
    _memo = shelf;
    return shelf;
  }
  // Caching the EMPTY answer matters most: with no anniversaries the loop runs
  // all three windows, so the miss is the expensive path, and it is also the
  // common one for anyone with under a year of history.
  _memoKey = key;
  _memo = OnThisDayShelf.empty;
  return OnThisDayShelf.empty;
});
