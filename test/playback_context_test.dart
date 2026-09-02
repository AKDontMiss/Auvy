import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// Who is allowed to forget which collection is playing.
///
/// ── THE RULE ────────────────────────────────────────────────────────────────
///
/// `playSong` clears the stored context when a call names no `contextType` AND
/// looks like a fresh manual start. That is right for tapping a loose track and
/// wrong for every CONTINUATION — a queue advance, a next/prev, a native gapless
/// hand-off — which are the same playlist carrying on and must keep it.
///
/// A continuation that forgets to say so is silently reclassified as a manual
/// start, and the collection is dropped: the home mosaic stops showing the
/// playlist as playing while the player header still names it, because
/// `locationName` is carried forward separately. Two refill paths in
/// player_queue.dart had exactly that shape.
void main() {
  final queue = codeOf('lib/logic/player_queue.dart');
  final playback = codeOf('lib/logic/player_playback.dart');

  group('every continuation declares itself', () {
    test('no playSong call carries locationName forward without a flag', () {
      // The tell: a call that passes `currentState.locationName` is continuing
      // something. If it were a fresh start there would be nothing to carry.
      final offenders = <String>[];
      final re = RegExp(r'playSong\(');
      for (final m in re.allMatches(queue)) {
        var i = m.end;
        var depth = 1;
        while (i < queue.length && depth > 0) {
          if (queue[i] == '(') depth++;
          if (queue[i] == ')') depth--;
          i++;
        }
        final call = queue.substring(m.start, i);
        if (!call.contains('currentState.locationName')) continue;
        final declared = call.contains('viaQueueAdvance: true') ||
            call.contains('isNextOrPrev: true') ||
            call.contains('alreadyPlayingNatively');
        if (!declared) {
          final line = '\n'.allMatches(queue.substring(0, m.start)).length + 1;
          offenders.add('player_queue.dart:$line');
        }
      }
      expect(offenders, isEmpty,
          reason: 'These carry the location forward but do not declare '
              'themselves a continuation, so playSong clears the collection: '
              '${offenders.join(', ')}');
    });

    test('the refill and late-rescue advances are flagged', () {
      // Named specifically because both were found broken and their own comments
      // said they were carrying the context forward while they were not.
      final refill = queue.substring(queue.indexOf('_topUpQueue(force: true)'));
      expect(refill.substring(0, 900).contains('viaQueueAdvance: true'), isTrue,
          reason: 'The post-refill advance is unflagged again.');
      final rescue = queue.substring(queue.indexOf('Late refill landed'));
      expect(rescue.substring(0, 500).contains('viaQueueAdvance: true'), isTrue,
          reason: 'The late-arrival rescue is unflagged again.');
    });
  });

  group('the diagnostic reports what the code does', () {
    test('the (cleared) marker uses the SAME test as clearContext', () {
      // It used a three-condition subset while the assignment clears on five, so
      // it announced a cleared context on advances that preserved one. A false
      // diagnostic is worse than none: it sends the reader after a bug that is
      // not there.
      final marker = playback.substring(playback.indexOf('contextWasCleared ='));
      final decl = marker.substring(0, marker.indexOf(';') + 1);
      for (final cond in [
        'contextType == null',
        'isManual',
        '!isNextOrPrev',
        '!viaQueueAdvance',
        '!alreadyPlayingNatively',
      ]) {
        expect(decl.contains(cond), isTrue,
            reason: 'The (cleared) marker no longer tests "$cond", which '
                'clearContext does — the log and the behaviour have drifted.');
      }
    });

    test('clearContext still tests all five, and the two agree', () {
      final assign = playback.substring(playback.indexOf('clearContext:'));
      final expr = assign.substring(0, assign.indexOf(','));
      // Normalise whitespace so formatting differences do not fail this.
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
      final markerDecl = playback.substring(playback.indexOf('contextWasCleared ='));
      final markerExpr = markerDecl.substring(
          markerDecl.indexOf('=') + 1, markerDecl.indexOf(';'));
      expect(norm(expr.replaceFirst('clearContext:', '')), norm(markerExpr),
          reason: 'clearContext and the (cleared) marker have different '
              'expressions again. They describe the same event and must be the '
              'same test.');
    });
  });
}
