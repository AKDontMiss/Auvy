import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every backed-up preference must sit in the typed list that matches how the
/// app actually writes it.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
///
/// CloudSyncService groups keys by TYPE (_stringKeys, _boolKeys, _intKeys,
/// _doubleKeys, _stringListKeys) and casts each group accordingly. Put a key in
/// the wrong group and the cast throws, the backup catches it, logs a warning,
/// and moves on — so the setting simply never syncs. Nothing fails, nothing is
/// reported to the user, and the only evidence is a line in a diagnostics export
/// that nobody reads.
///
/// It has now happened three times. Two are recorded in that file's own
/// comments (`auvy_lyrics_centered` and `auvy_romanize_as_main` were bools sat
/// in _doubleKeys; `auvy_romanize_scripts` is a string list that was there too).
/// The third was caught in the 2026-09-01 device log:
///
///   WARN: backup: skipping "auvy_romanize_kana_system" — wrong type list?
///   (type 'String' is not a subtype of type `List<dynamic>?` in type cast)
///
/// 210 warnings in one day — three keys x 70 backups — all silently doing
/// nothing. They had been filed next to `auvy_romanize_scripts`, which reads as
/// the obvious home for anything romanization-shaped and is the wrong one: that
/// key is a `List<String>`, these are plain Strings.
///
/// The lists are grouped by type, so the temptation to group by FEATURE is what
/// keeps causing this. This test removes the temptation by checking the pairing
/// mechanically.
void main() {
  /// prefs.setX(...) → the CloudSyncService list that key belongs in.
  const setterToList = {
    'setString': '_stringKeys',
    'setBool': '_boolKeys',
    'setInt': '_intKeys',
    'setDouble': '_doubleKeys',
    'setStringList': '_stringListKeys',
  };

  late final Map<String, Set<String>> lists;
  late final Set<String> allBackedUp;

  setUpAll(() {
    final sync = File('lib/services/cloud_sync_service.dart').readAsStringSync();
    lists = {};
    for (final name in setterToList.values.toSet()) {
      final start = sync.indexOf('static const List<String> $name = [');
      expect(start, greaterThan(-1), reason: '$name is gone from CloudSyncService.');
      final end = sync.indexOf('];', start);
      final body = sync
          .substring(start, end)
          .split('\n')
          // Keys quoted inside a comment are prose, not entries. Both kinds of
          // comment matter: an earlier version of this scan counted them and
          // reported four duplicates that did not exist.
          .map((l) => l.replaceAll(RegExp(r'//.*$'), ''))
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      lists[name] = RegExp("'([A-Za-z0-9_:.]+)'")
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet();
    }
    allBackedUp = lists.values.expand((s) => s).toSet();
  });

  test('no key appears in two typed lists', () {
    final seen = <String, String>{};
    final clashes = <String>[];
    lists.forEach((listName, keys) {
      for (final k in keys) {
        if (seen.containsKey(k)) clashes.add('$k: ${seen[k]} and $listName');
        seen[k] = listName;
      }
    });
    expect(clashes, isEmpty,
        reason: 'A key in two lists is read back with two different casts; '
            'one of them throws.\n${clashes.join('\n')}');
  });

  test('every backed-up key is written with the matching setter', () {
    // Walk the whole app rather than a named list of files: a new settings
    // screen with its own notifier is exactly the case that would slip past.
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    final problems = <String>[];
    // A key can legitimately be written more than once; only a MISMATCH matters.
    for (final file in sources) {
      final src = file.readAsStringSync();
      if (!src.contains('prefs.set')) continue;

      // Resolve `static const String kFoo = 'auvy_foo';` so a setter written
      // against the constant can be checked too — which is the normal style
      // here, and the style the broken keys used.
      final consts = <String, String>{};
      for (final m in RegExp(
              r"static const String (\w+)\s*=\s*'([A-Za-z0-9_:.]+)'")
          .allMatches(src)) {
        consts[m.group(1)!] = m.group(2)!;
      }

      for (final m
          in RegExp(r'prefs\.(set\w+)\(\s*([^,\s]+)\s*,').allMatches(src)) {
        final setter = m.group(1)!;
        final expectedList = setterToList[setter];
        if (expectedList == null) continue; // setStringList handled; others n/a

        var raw = m.group(2)!;
        String? key;
        final literal = RegExp(r"^'([A-Za-z0-9_:.]+)'$").firstMatch(raw);
        if (literal != null) {
          key = literal.group(1);
        } else {
          key = consts[raw.replaceAll(RegExp(r'^\w+\.'), '')];
        }
        if (key == null) continue; // computed key — nothing to check

        // Only keys that are actually backed up are in scope. A local-only
        // preference is free to live anywhere.
        if (!allBackedUp.contains(key)) continue;

        if (!lists[expectedList]!.contains(key)) {
          final actual = lists.entries
              .firstWhere((e) => e.value.contains(key))
              .key;
          problems.add(
              "'$key' is written with $setter (${file.path.split(RegExp(r'[\\/]')).last}) "
              'but sits in $actual, not $expectedList');
        }
      }
    }

    expect(problems, isEmpty,
        reason: 'A key in the wrong typed list is skipped at backup time with a '
            'warning and no other symptom — the setting silently never syncs:\n'
            '${problems.join('\n')}');
  });

  test('the three romanization standards are strings, and filed as strings', () {
    // The specific regression, pinned by name. They are single enum names, not
    // the LIST that auvy_romanize_scripts stores, and sitting next to it is what
    // broke them.
    for (final k in const [
      'auvy_romanize_kana_system',
      'auvy_romanize_hangul_system',
      'auvy_romanize_cyrillic_system',
    ]) {
      expect(lists['_stringKeys']!.contains(k), isTrue,
          reason: '$k must be in _stringKeys.');
      expect(lists['_stringListKeys']!.contains(k), isFalse,
          reason: '$k is back in _stringListKeys, where the cast throws.');
    }
    // The genuine list, still a list.
    expect(lists['_stringListKeys']!.contains('auvy_romanize_scripts'), isTrue);
  });
}
