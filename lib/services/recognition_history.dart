import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One past identification.
class RecognitionEntry {
  final String title;
  final String artist;
  final String? coverArtUrl;
  final DateTime at;

  const RecognitionEntry({
    required this.title,
    required this.artist,
    required this.at,
    this.coverArtUrl,
  });

  Map<String, dynamic> toJson() => {
        't': title,
        'a': artist,
        if (coverArtUrl != null) 'c': coverArtUrl,
        'ms': at.millisecondsSinceEpoch,
      };

  /// Unknown keys are ignored, so entries written by the earlier build (which
  /// carried `l`/`s` for on-device matches) still load after that path was
  /// removed — no migration needed.
  static RecognitionEntry? fromJson(Map<String, dynamic> j) {
    final title = j['t'] as String?;
    if (title == null || title.isEmpty) return null;
    return RecognitionEntry(
      title: title,
      artist: j['a'] as String? ?? '',
      coverArtUrl: j['c'] as String?,
      at: DateTime.fromMillisecondsSinceEpoch((j['ms'] as num?)?.toInt() ?? 0),
    );
  }
}

/// A log of what Auvy has identified, so a song recognised in a shop isn't lost
/// the moment the sheet closes — the single most common frustration with
/// recognition features.
///
/// Stored as one JSON blob in prefs rather than in sqflite: it's capped at
/// [_maxEntries], so it stays a few KB, and a table would be more machinery than
/// the data warrants.
class RecognitionHistory {
  const RecognitionHistory._();

  static const String _key = 'auvy_recognition_history';

  /// Enough to be useful, small enough to keep the blob trivial. Oldest entries
  /// drop off the end.
  static const int _maxEntries = 100;

  static Future<List<RecognitionEntry>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(RecognitionEntry.fromJson)
          .whereType<RecognitionEntry>()
          .toList();
    } catch (_) {
      // Corrupt blob: report empty rather than breaking the screen. The next
      // successful add overwrites it.
      return const [];
    }
  }

  /// How close together two identifications of the same track count as one
  /// event. Long enough to absorb a double-tap or a second try on the same
  /// chorus; far shorter than any gap that means "I heard this again".
  static const Duration _sameEventWindow = Duration(minutes: 2);

  /// Prepends [entry], newest first.
  ///
  /// RE-IDENTIFYING A TRACK USED TO ERASE THE EARLIER ENTRY OUTRIGHT. Any
  /// repeat of whatever sat at the top replaced it, with no regard for when —
  /// so hearing the same song in a café on Tuesday and again on Friday left one
  /// row, dated Friday. The Tuesday encounter was gone.
  ///
  /// That is the wrong trade for this list specifically. Everything else in the
  /// app can be re-derived by using it again; a recognition records a MOMENT that
  /// has passed, and the timestamp is most of the value. Deleting one to avoid a
  /// visual duplicate destroys the only copy.
  ///
  /// Collapsing is now limited to repeats inside [_sameEventWindow], which is
  /// what the original rule was actually reaching for — the user pressing twice
  /// on one song, not the same song encountered twice in a week.
  static Future<void> add(RecognitionEntry entry) async {
    try {
      final entries = List<RecognitionEntry>.from(await load());
      if (entries.isNotEmpty &&
          entries.first.title == entry.title &&
          entries.first.artist == entry.artist &&
          entry.at.difference(entries.first.at).abs() < _sameEventWindow) {
        entries.removeAt(0);
      }
      entries.insert(0, entry);
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {
      // Never let bookkeeping break a successful identification.
    }
  }

  /// Merge a batch in — used when importing another player's backup.
  ///
  /// ONE read and ONE write for the whole batch: calling [add] a hundred times
  /// would decode and re-encode the ledger a hundred times. Entries already
  /// present (same title, artist and instant) are skipped rather than doubled,
  /// and the merged list is sorted newest-first and capped exactly as [add]
  /// leaves it, so nothing downstream can tell the difference.
  static Future<void> addAll(List<RecognitionEntry> incoming) async {
    if (incoming.isEmpty) return;
    try {
      final entries = List<RecognitionEntry>.from(await load());
      final seen = <String>{
        for (final e in entries)
          '${e.title}|${e.artist}|${e.at.millisecondsSinceEpoch}',
      };
      for (final e in incoming) {
        if (e.title.isEmpty) continue;
        if (!seen.add('${e.title}|${e.artist}|${e.at.millisecondsSinceEpoch}')) {
          continue;
        }
        entries.add(e);
      }
      entries.sort((a, b) => b.at.compareTo(a.at));
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {
      // An import that cannot write this ledger still imported the library.
    }
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }
}
