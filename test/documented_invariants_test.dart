import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// Invariants this codebase states in a comment and, until now, trusted a future
/// editor to honour.
///
/// ── WHY THESE ARE TESTS AND NOT COMMENTS ────────────────────────────────
///
/// Both of the rules below were already written down, in capitals, next to the
/// code they govern. That is not enough, and this project has the proof: a
/// filter carrying the comment *"only exclude when the collection is actually
/// reachable, or its tracks become unreachable from the UI entirely"* had a
/// hard-coded exception added three lines above it, and every downloaded podcast
/// episode became invisible — the toast said saved, the file was on disk, and no
/// screen listed it.
///
/// A comment addresses whoever reads it. A test addresses whoever does not.
void main() {
  group('cross-file constants that must move together', () {
    test('the Listen Together host timeout matches the Firestore rule', () {
      // listen_together_provider says: "The 70 seconds here MUST stay in step
      // with _hostGoneMs … A client that gives up sooner than the rule allows is
      // simply denied and retries; one that gives up later leaves the session
      // leaderless for longer than intended."
      //
      // The rule lives in a .rules file that no Dart compiler reads, so nothing
      // connected the two numbers. This does.
      final dart = File('lib/providers/listen_together_provider.dart')
          .readAsStringSync();
      final rules = File('firestore.rules').readAsStringSync();

      final m = RegExp(r'_hostGoneMs\s*=\s*(\d+)').firstMatch(dart);
      expect(m, isNotNull,
          reason: '_hostGoneMs not found — was it renamed? The Firestore rule '
              'still hard-codes a takeover threshold, so the two have to be '
              'reconciled by hand.');
      final clientMs = m!.group(1)!;

      expect(
        rules.contains(clientMs),
        isTrue,
        reason: 'The client gives up on a silent host after ${clientMs}ms, but '
            'firestore.rules does not mention that number. The rule decides '
            'whether a takeover WRITE is allowed, so if the rule is larger the '
            'client claims and is denied in a loop; if it is smaller, any member '
            'can seize a session from a host that is merely slow. Update both.',
      );
    });

    test('the push-signature version is bumped when the algorithm changes', () {
      // cloud_sync_service says: "WARN: BUMP THIS WHENEVER [_sig] CHANGES. A stored
      // value is only meaningful under the algorithm that produced it, and
      // comparing across algorithms is how a blob gets skipped that should have
      // been uploaded — silent staleness in the backup, which is the worst
      // failure this class has."
      //
      // It has already been got wrong once: v1 used `Object.hash`, which Dart
      // seeds randomly per process, so no signature ever matched after a restart
      // and every launch re-uploaded the whole backup.
      //
      // Pinning the algorithm's TEXT against the version means changing one
      // without the other fails here, with the reason attached.
      final src = File('lib/services/cloud_sync_service.dart').readAsStringSync();

      final sig = RegExp(r'static int _sig\(String s\) =>([^;]+);').firstMatch(src);
      expect(sig, isNotNull, reason: '_sig not found — renamed or reshaped?');
      final body = sig!.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();

      final ver = RegExp(r"_kPushedSigPrefix = 'cloud_pushed_sigs_(v\d+)_'")
          .firstMatch(src);
      expect(ver, isNotNull, reason: '_kPushedSigPrefix not found or reshaped.');

      // The pair recorded when this test was written.
      const knownBody = r'(s.length * 0x1f1f1f1f) ^ s.hashCode';
      const knownVersion = 'v2';

      if (body != knownBody) {
        fail('_sig changed.\n'
            '  was: $knownBody\n'
            '  now: $body\n'
            'Signatures already stored on devices were produced by the OLD '
            'algorithm. Comparing them against the new one silently skips blobs '
            'that need uploading, which leaves a stale cloud backup with no '
            'symptom until a restore.\n'
            'Bump _kPushedSigPrefix (currently ${ver!.group(1)}) so old entries '
            'are ignored, then update knownBody/knownVersion here.');
      }
      expect(ver!.group(1), knownVersion,
          reason: 'The signature version moved but _sig did not. That is '
              'harmless — it only discards good signatures once — but update '
              'knownVersion here so this test keeps meaning something.');
    });
  });

  group('untrusted archives are bounded the same way everywhere', () {
    test('both backup readers carry the same size ceilings', () {
      // Two files read a ZIP the user picked — ForeignBackupReader (another
      // app's .backup) and LibraryExportService (Auvy's own). Both materialise
      // the file two or three times over, so both need a ceiling, and a ceiling
      // on only one of them is the same hole with a smaller entrance.
      //
      // They are one policy about how much an untrusted backup may weigh, and
      // each file says 'change both together' in a comment. This is the part
      // that notices when someone doesn't.
      int ceiling(String path, String name) {
        final src = File(path).readAsStringSync();
        final m = RegExp('$name = (\\d+) \\* 1024 \\* 1024').firstMatch(src);
        expect(m, isNotNull,
            reason: '$name not found in $path — if the guard was removed, an '
                'oversized or zip-bombed backup can OOM the app straight from '
                'the picker.');
        return int.parse(m!.group(1)!);
      }

      final foreignArchive = ceiling(
          'lib/services/foreign_backup_reader.dart', '_maxArchiveBytes');
      final exportArchive = ceiling(
          'lib/services/library_export_service.dart', '_maxArchiveBytes');
      expect(exportArchive, foreignArchive,
          reason: 'The two readers disagree on how large a picked backup may '
              'be. Whichever is larger is the one an attacker uses.');

      final foreignEntry = ceiling(
          'lib/services/foreign_backup_reader.dart', '_maxDatabaseBytes');
      final exportEntry = ceiling(
          'lib/services/library_export_service.dart', '_maxEntryBytes');
      expect(exportEntry, foreignEntry,
          reason: 'The two readers disagree on how large a single decompressed '
              'entry may be — the check that actually stops a zip bomb.');
    });
  });

  group('the Downloads folder cannot hide what nothing else shows', () {
    test('only the reachability check may hide a download', () {
      // The regression this encodes: `if (coll.kind == 'Podcasts') return false;`
      // was added ABOVE the reachability check, so podcast downloads were hidden
      // from the only view that listed them. The fix was structural — one gate,
      // which takes `reachable` and has no early exit — and this keeps it that
      // way.
      final src = File('lib/providers/library_provider.dart').readAsStringSync();
      final gate = RegExp(
        r'static bool _hiddenBecauseReachable\([\s\S]{0,600}?\n  \}',
      ).firstMatch(src);
      expect(gate, isNotNull,
          reason: '_hiddenBecauseReachable not found. It is the single gate that '
              'decides whether a downloaded track may be left out of the '
              'Downloads folder; if it has been replaced, make sure whatever '
              'replaced it also cannot hide a track without proving the user can '
              'reach it elsewhere.');

      final body = gate!.group(0)!;
      // Exactly one `true` may be returned, and it must be the reachability
      // answer. A `kind ==` comparison here is the shape of the original bug.
      expect(body.contains('kind =='), isFalse,
          reason: 'The gate is special-casing a download KIND. That is how '
              'podcast downloads became invisible: a kind was excluded on the '
              'assumption another screen listed it, and none did. Hiding must '
              'depend only on whether the collection is reachable.');
      expect(body.contains('reachable.contains'), isTrue,
          reason: 'The gate no longer consults `reachable`, so it can hide a '
              'download the user has no other way to find.');
    });
  });

  group('derived state stays out of the persisted library', () {
    // library_provider drops the Cached folder from what it writes, because
    // AudioCacheManager already persists that index and refreshCachedFolder
    // rebuilds the list from it right after every load. Storing it as well
    // cost 102 whole-blob writes in one day: each auto-cache or eviction
    // changed the song list AND the row's own count-bearing subtitle, so the
    // byte-identical guard could never fire.
    //
    // A future editor restoring `state.playlistSongs` wholesale would bring
    // all of that back, and nothing on screen would look different — which is
    // exactly the kind of regression a comment does not survive.
    final source =
        File('lib/providers/library_provider.dart').readAsStringSync();
    final saveBody = source.substring(source.indexOf('Future<void> _saveToDisk'));

    test('the write filters the derived folder out of playlistSongs', () {
      final data = saveBody.substring(0, saveBody.indexOf('final nowHasContent'));
      expect(data.contains("e.key != derivedFolder"), isTrue,
          reason: 'The persisted playlistSongs no longer excludes the Cached '
              'folder, so every auto-cached track rewrites the whole library '
              'blob again.');
      expect(data.contains('state.playlistSongs.map('), isFalse,
          reason: 'playlistSongs is being persisted wholesale again — that is '
              'the shape that included the derived Cached list.');
    });

    test('the rows the loader rebuilds are stored without live values', () {
      // The load path removes Cached / Downloads / Liked Playlists and
      // inserts freshly-built rows, so anything stored for them is written
      // and never read — while their subtitle (a count) and dateAdded (now)
      // changed the blob constantly.
      final load = source.substring(0, source.indexOf('Future<void> _saveToDisk'));
      expect(
          load.contains(
              'allItems.removeWhere((item) => item.title == "Cached" || '
              'item.title == "Downloads" || item.title == "Liked Playlists")'),
          isTrue,
          reason: 'The loader no longer discards these three rows, so the save '
              'path must stop zeroing them — the two halves have to agree on '
              'which rows are rebuilt.');
      expect(saveBody.contains('rebuiltRows'), isTrue,
          reason: 'The save path stores the live subtitle/dateAdded of rows '
              'the loader throws away, which churns the blob for values no '
              'reader ever sees.');
    });
  });

  group('every Dart channel call has a native handler', () {
    // ── THIS CLASS OF BUG HAS BITTEN TWICE, BOTH TIMES SILENTLY ────────────
    //
    // A `MethodChannel.invokeMethod('x')` with no native handler for `x` throws
    // MissingPluginException — and every call site here wraps that in
    // `catch (_) {}`, correctly, because a missing Activity (the headless
    // audio_service boot) must not crash anything. The cost is that a typo, a
    // wrong channel, or a method nobody ever implemented is INDISTINGUISHABLE
    // from "no window to flag right now".
    //
    //   • `keepScreenOn` was invoked on the PLAYER channel, which has no window
    //     handler. The setting did nothing at all, and the toggle looked fine.
    //   • `releaseAlarmScreen` was never implemented natively at all, under a doc
    //     comment describing it as what "keeps the rest of the app off a locked
    //     phone". It survived only because it had no callers.
    //
    // Neither was findable at runtime. Both are trivially findable here.
    //
    // MATCHED ON THE METHOD NAME ANYWHERE IN KOTLIN, not per channel. A
    // per-channel check would be stricter and needs real parsing to know which
    // `when` block belongs to which channel; name-presence still catches the
    // whole "nobody implemented this" family, which is both of the above.
    test('no invokeMethod name is missing from the native side', () {
      final dartNames = <String>{};
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        for (final m in RegExp(r"""invokeMethod(?:<[^>]*>)?\(\s*'([^']+)'""")
            .allMatches(src)) {
          dartNames.add(m.group(1)!);
        }
      }
      expect(dartNames, isNotEmpty,
          reason: 'Found no invokeMethod calls at all — the pattern broke, so '
              'this test is no longer checking anything.');

      final kotlin = Directory('android/app/src/main/kotlin/com/auvy/app')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'))
          .map((f) => f.readAsStringSync())
          .join('\n');

      // Both dispatch styles are in use: `"name" ->` inside a `when`, and
      // `if (call.method == "name")`. Looking for the quoted name covers each.
      final missing = dartNames.where((n) => !kotlin.contains('"$n"')).toList()
        ..sort();

      expect(missing, isEmpty,
          reason: 'These Dart calls have no native handler, so they fail with '
              'MissingPluginException and are swallowed by the catch at the call '
              'site — a feature that silently does nothing:\n'
              '${missing.join('\n')}');
    });
  });

  group('the session cookie IV must be random PER ENCRYPTION', () {
    // THE BUG THIS GUARDS ACTUALLY HAPPENED, and it logged people out.
    //
    // The v1 format used `IV.fromLength(16)`. That reads like a zero IV and is
    // not: in encrypt 5.x it is random PER PROCESS. So a blob encrypted in one
    // launch could not be decrypted in the next — the IV was gone with the
    // process that made it. The symptom was a session that survived until the
    // app was restarted, which is the hardest kind of auth bug to attribute.
    //
    // v2 stores a freshly-random IV alongside the ciphertext
    // ("v2:<iv_b64>:<cipher_b64>"), so a blob decrypts forever.
    //
    // Tested by reading the source rather than round-tripping, because
    // encryption here needs the AES key out of flutter_secure_storage — mocking
    // the platform channel would test the mock. What can go wrong is the choice
    // of IV constructor, and that is visible in the text.
    final src =
        File('lib/logic/session_cookie_manager.dart').readAsStringSync();

    /// CODE ONLY — the file's own comment explains the v1 bug and therefore
    /// contains the very text this checks for, so a naive `src.contains` fails on
    /// the explanation rather than on a regression. See
    /// helpers/source_text.dart for why that shape keeps biting.
    final code = codeOf('lib/logic/session_cookie_manager.dart');

    test('fromLength is never used to build an IV', () {
      expect(code.contains('IV.fromLength'), isFalse,
          reason: 'IV.fromLength is random per PROCESS in encrypt 5.x, so any '
              'blob written with it becomes undecryptable at the next launch. '
              'Use IV.fromSecureRandom and store the IV with the ciphertext.');
    });

    test('a fresh secure-random IV is generated and stored with the payload',
        () {
      expect(src.contains('IV.fromSecureRandom(16)'), isTrue,
          reason: 'The per-encryption random IV is gone.');
      expect(src.contains("'v2:\${iv.base64}:\${cipher.base64}'"), isTrue,
          reason: 'The IV is no longer written alongside the ciphertext, so '
              'nothing can decrypt the blob later.');
    });

    test('decryption refuses a payload that is not v2', () {
      // A legacy blob must take the documented salvage path rather than being
      // fed to the v2 parser, which would read the wrong bytes as an IV.
      final fn = src.substring(src.indexOf('Future<String> _decryptString('));
      final body = fn.substring(0, fn.indexOf('\n  }'));
      expect(body.contains("startsWith('v2:')"), isTrue,
          reason: 'The version check is gone; a legacy blob would be parsed as '
              'v2 and silently mis-decrypted.');
      // Base64 contains no colon, so the FIRST colon after the prefix is the
      // separator. lastIndexOf would still work today but breaks the moment the
      // format grows a third field.
      expect(body.contains("indexOf(':', 3)"), isTrue,
          reason: 'The separator search changed shape — check it still finds '
              'the boundary between the IV and the ciphertext.');
    });
  });
}
