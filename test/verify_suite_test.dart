import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'adaptive_bitrate_verify.dart' as adaptive_bitrate;
import 'album_versions_verify.dart' as album_versions;
import 'artist_match_verify.dart' as artist_match;
import 'conform_edition_verify.dart' as conform_edition;
import 'enable_backup_queue_verify.dart' as enable_backup_queue;
import 'library_integrity_verify.dart' as library_integrity;
import 'library_sync_split_verify.dart' as library_sync_split;
import 'on_this_day_verify.dart' as on_this_day;
import 'recognition_history_verify.dart' as recognition_history;
import 'track_refetch_verify.dart' as track_refetch;

/// Runs every `*_verify.dart` file as part of the normal suite.
///
/// ── 103 PASSING TESTS THAT NEVER RAN ─────────────────────────────────────
///
/// `flutter test` collects `test/**_test.dart` and nothing else. Eleven files
/// were named `*_verify.dart`, so the runner silently ignored all of them — and
/// they were healthy the whole time: every one passes when invoked by hand. The
/// suite reported "109 passed" while roughly the same number of checks sat
/// dormant beside it.
///
/// That is worse than having no tests, because the count looked reassuring. It
/// was only noticed when converting `artist_match_verify.dart` added 18 tests
/// and the suite total did not move.
///
/// The intent was never in doubt: `lyrics_live_probe.dart` opens by saying it is
/// "Excluded from the `*_verify.dart` suite on purpose", so the author was
/// treating `*_verify.dart` AS a suite. Only the wiring to the runner was
/// missing.
///
/// AN AGGREGATOR RATHER THAN TEN RENAMES. Every one of these filenames is
/// referenced from a doc comment in the code it covers ("Covered by
/// test/…_verify.dart; keep them in step"), so renaming them would break those
/// pointers — the very links that tell a future reader where a rule is
/// verified. One collected file costs nothing and keeps them all valid.
void main() {
  group('adaptive_bitrate_verify', adaptive_bitrate.main);
  group('album_versions_verify', album_versions.main);
  group('artist_match_verify', artist_match.main);
  group('conform_edition_verify', conform_edition.main);
  group('enable_backup_queue_verify', enable_backup_queue.main);
  group('library_integrity_verify', library_integrity.main);
  group('library_sync_split_verify', library_sync_split.main);
  group('on_this_day_verify', on_this_day.main);
  group('recognition_history_verify', recognition_history.main);
  group('track_refetch_verify', track_refetch.main);

  group('the aggregator cannot fall behind the directory', () {
    /// Files deliberately NOT run by the suite, each with a reason that is about
    /// the file rather than about convenience.
    ///
    /// The two probes talk to the real Worker and the real lyric catalogues, so
    /// including them would make an offline run flaky and slow — their own
    /// headers say so. `romanization_verify.dart` imports no test package and
    /// registers no cases: it is a script that prints, so a group wrapping it
    /// would assert nothing.
    const excluded = <String>{
      'lyrics_live_probe.dart',
      'lyrics_provider_probe.dart',
      'romanization_verify.dart',
    };

    test('every verify file is either wired up or explicitly excluded', () {
      // THIS IS THE PART THAT STOPS THE BUG COMING BACK. Adding a new
      // `*_verify.dart` without adding it above would otherwise recreate exactly
      // the silence this file was written to end — a file full of tests that
      // passes locally and is invisible to the suite.
      final onDisk = Directory('test')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('_verify.dart') || n.endsWith('_probe.dart'))
          .toSet();

      final wired = File('test/verify_suite_test.dart')
          .readAsStringSync()
          .split('\n')
          .where((l) => l.startsWith("import '") && l.contains("_verify.dart'"))
          .map((l) => l.split("'")[1])
          .toSet();

      final unaccounted = onDisk.difference(wired).difference(excluded);
      expect(unaccounted, isEmpty,
          reason: 'These files hold tests that flutter test will never run. '
              'Add an import + group() above, or add them to `excluded` with a '
              'reason: ${unaccounted.join(', ')}');
    });

    test('nothing is excluded that could simply run offline', () {
      // An exclusion is a claim, and the claim should be checkable. The probes
      // must say they are live; the script must genuinely register no tests.
      for (final name in excluded) {
        final src = File('test/$name').readAsStringSync();
        final isLiveProbe = src.contains('LIVE probe');
        final registersNothing = !src.contains('package:flutter_test');
        expect(isLiveProbe || registersNothing, isTrue,
            reason: '$name is excluded from the suite but is neither a declared '
                'LIVE probe nor free of flutter_test. If it can run offline, '
                'wire it up instead of excluding it.');
      }
    });
  });
}
