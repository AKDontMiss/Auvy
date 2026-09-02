import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// A control must not claim something it did not do.
///
/// ── THE BUG THAT NAMED THIS FILE ────────────────────────────────────────────
///
/// The playlist page's queue toggle showed "Removed from Queue" and called
/// NOTHING. There was no bulk-remove method to call, so the branch was left with
/// only the toast in it: the tracks stayed queued while the UI said they had
/// gone. Reported as "it says removed from queue but it doesnt".
///
/// That is the worst class of bug in a player, because the user's own senses
/// disagree with the app and there is nothing to retry — so it gets its own file
/// rather than a group inside another one.
void main() {
  final playlist = codeOf('lib/presentation/pages/playlist_page.dart');
  final queue = codeOf('lib/logic/player_queue.dart');

  group('the queue toggle does what it says', () {
    test('the remove branch actually removes', () {
      expect(playlist.contains('removeListFromQueue(filteredTracks)'), isTrue,
          reason: 'The remove branch is back to showing a toast with no '
              'removal behind it.');
    });

    test('the toast is chosen from the RESULT, not from the intent', () {
      // The count is the whole point: "Removed 12" and "nothing was queued" are
      // different truths, and the old code could not tell them apart because it
      // never asked.
      // indexOf FROM the start offset. Searching from 0 finds an earlier
      // `} else {` than the window opens at, which throws a RangeError instead
      // of failing with a reason — the same trap as anchoring on a doc comment.
      final start = playlist.indexOf('final removed =');
      final onTap = playlist.substring(start, playlist.indexOf('} else {', start));
      expect(onTap.contains('removed > 0'), isTrue,
          reason: 'The toast no longer branches on how many were removed, so it '
              'can claim a removal that did not happen.');
    });

    test('the ADD branch is honest too', () {
      // The mirror of the original bug: tapping when the playlist is ALREADY
      // fully queued adds nothing (every track is de-duped away) and used to say
      // "Added to Queue" regardless.
      expect(playlist.contains('await notifier.addListToQueue(filteredTracks)'),
          isTrue,
          reason: 'The add is fire-and-forget again, so the caller cannot know '
              'whether anything was added.');
      expect(playlist.contains('Already in your queue'), isTrue,
          reason: 'The nothing-was-added case has no honest message.');
      // THE ORDERING IS THE INVARIANT, not the literal assignment.
      //
      // Setting `_isQueued = true` is correct here — added tracks and
      // already-present tracks both mean "this playlist is queued". What was
      // wrong was doing it BEFORE the call, which is how the original
      // `setState(...); if (_isQueued) add...` claimed a result it had not asked
      // for yet. An earlier version of this test banned the assignment itself
      // and so failed on the corrected code.
      final tap = playlist.substring(playlist.indexOf('onTap: () async {'));
      final call = tap.indexOf('await notifier.addListToQueue');
      final flag = tap.indexOf('_isQueued = true');
      expect(call, greaterThan(-1), reason: 'The add is not awaited.');
      expect(flag, greaterThan(call),
          reason: 'The button marks itself queued before the add has been '
              'awaited, which is the original lie.');
    });

    test('addListToQueue reports a count rather than void', () {
      expect(queue.contains('Future<int> addListToQueue('), isTrue,
          reason: 'It is `void ... async` again — unawaitable AND unreadable, '
              'which is what let the caller claim an add that never happened.');
    });

    test('removeListFromQueue reports a count rather than void', () {
      expect(queue.contains('Future<int> removeListFromQueue('), isTrue,
          reason: 'It returns void again, so no caller can tell the truth about '
              'what happened.');
    });

    test('it matches by SIGNATURE as well as id', () {
      // The queued copy can be a different-id twin of the row on screen (the
      // audio-only swap of a video), and an id-only removal misses exactly the
      // entry the user is looking at — which would be the same lie again.
      final body = queue.substring(queue.indexOf('Future<int> removeListFromQueue('),
          queue.indexOf('Future<void> clearAllQueue('));
      expect(body.contains('sigs.contains(sig(s))'), isTrue,
          reason: 'Signature matching is gone, so a twin-id copy survives a '
              '"removed" toast.');
      expect(body.contains('currentState.currentSong!'), isTrue,
          reason: 'The rebuilt queue no longer preserves the playing track.');
    });
  });

  group('shuffling a playlist does not depend on leftover state', () {
    test('the list handed to playSong is already shuffled', () {
      expect(playlist.contains('List<Song>.from(filteredTracks)..shuffle()'), isTrue,
          reason: 'The queue passed to playSong is in playlist order again. '
              'toggleShuffle only reorders the queue that exists WHEN IT RUNS, '
              'and playSong then replaces it — so the shuffle is discarded.');
    });

    test('shuffle is SET, not toggled', () {
      expect(playlist.contains('player.setShuffle(true)'), isTrue,
          reason: 'Back to a toggle, whose result depends on the previous '
              'state — the "sometimes it shuffles" report.');
      expect(playlist.contains('if (!isShuffleOn) player.toggleShuffle()'), isFalse,
          reason: 'The conditional toggle is back.');
    });

    test('setShuffle is idempotent', () {
      final body = queue.substring(queue.indexOf('void setShuffle(bool on)'),
          queue.indexOf('void toggleShuffle()'));
      expect(body.contains('if (currentState.isShuffle == on) return;'), isTrue,
          reason: 'setShuffle can now flip a state that was already correct.');
    });

    test('the starting track is drawn from a real shuffle', () {
      // `DateTime.now().millisecond % length` cannot reach past index 999, and it
      // is not a random draw — it is a clock reading.
      expect(playlist.contains('millisecond % filteredTracks.length'), isFalse,
          reason: 'The clock-as-RNG is back: it can never pick past track 1000 '
              'and it is not uniform.');
    });
  });

  group('the artist shelf tap uses ONE prefix table', () {
    final home = codeOf('lib/presentation/pages/home_page.dart');

    test('the tap strips prefixes via the shared table', () {
      expect(home.contains('_bareSectionTitle(section.title)'), isTrue,
          reason: 'The tap handler has its own idea of the prefixes again. '
              'home_provider titles artist shelves "For You: <name>", which the '
              'old hand-rolled strip missed — so EVERY artist tap searched for '
              'the literal prefix and reported "Artist not found".');
      expect(home.contains('.replaceAll("More from ", "")'), isFalse,
          reason: 'The second, incomplete copy of the rule is back.');
    });

    test('every title format home_provider emits is in the table', () {
      // The table is only correct if it covers what the provider actually
      // produces. Read the provider and check each prefix it can title a shelf
      // with is one the tap handler knows how to strip.
      final provider = codeOf('lib/providers/home_provider.dart');
      for (final prefix in ['For You: ', 'Best of ']) {
        expect(provider.contains('"$prefix\$'), isTrue,
            reason: 'home_provider no longer emits "$prefix…" — if a format was '
                'renamed, _kSectionPrefixes must follow.');
        expect(home.contains("'$prefix'"), isTrue,
            reason: '"$prefix" is emitted by home_provider but missing from '
                '_kSectionPrefixes, so tapping that shelf cannot resolve.');
      }
    });

    test('the failure names the query and what came back', () {
      expect(home.contains('matched '), isTrue,
          reason: 'The failure log is gone. "Artist not found" alone cannot '
              'distinguish an unknown title format from an empty search from a '
              'genuine mismatch, which is why the prefix bug lasted.');
    });
  });

  test('no toast claims ANY action with nothing behind it', () {
    // A crude sweep for the shape, not a parser: a success-shaped message whose
    // surrounding lines contain no call that could have caused it. Two known-good
    // sites are listed by name — a clipboard write and a real removal loop — so
    // this fails on a NEW one rather than on the existing ones.
    const knownHonest = {
      'Track ID copied', // Clipboard.setData immediately above
      '\$n removed', // a removeSongFromPlaylist loop immediately above
    };
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (!RegExp(r'AnimatedToast|showSnackBar|SnackBar\(').hasMatch(l)) continue;
        // Every word that CLAIMS something happened, not just removals — the add
        // branch of the very same button turned out to be lying too.
        if (!RegExp(r'\b(Added|Saved|Removed|Deleted|Cleared|Downloaded|Copied|'
                r'Exported|Imported|Restored|Updated|Unfollowed|Followed|'
                r'Subscribed|Blocked|Approved|Sent|Applied|Enabled|Disabled)\b')
            .hasMatch(l)) {
          continue;
        }
        if (knownHonest.any(l.contains)) continue;
        final window = lines
            .sublist((i - 10).clamp(0, lines.length), (i + 4).clamp(0, lines.length))
            .join(' ');
        final acted = RegExp(
                r'\.notifier|await |ref\.read|Service\.|\.instance\.|Clipboard\.|'
                r'Navigator\.|setState|\.then\(|Provider\)')
            .hasMatch(window);
        if (!acted) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'These say something was removed with no call nearby that could '
            'have removed it: ${offenders.join(', ')}');
  });
}
