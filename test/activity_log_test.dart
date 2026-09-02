import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/services/activity_log.dart';

/// The activity log is the ONE place in Auvy where its own diagnostics leave the
/// device on purpose, so redaction is the part that has to be right. These lines
/// are real ones taken from this project's logs.
void main() {
  group('redaction — what must never reach an exported file', () {
    test('a backup identity hash is shortened, not printed whole', () {
      // Straight out of a real session: this names the account.
      const line =
          'Cloud backup PUSHED (v2, backup_ms=1787849246315, 17/26 blob(s) '
          'uploaded) for f406064d6663e6d7024a357f89a14ebe0dd5fdac8ac37fdc42e664f9efd358a4';
      final out = ActivityLog.redact(line);

      expect(out, isNot(contains('f406064d6663e6d7024a357f89a14ebe0dd5fdac8ac37fdc42e664f9efd358a4')));
      // The prefix survives, because telling two accounts apart in a timeline is
      // the only thing a reader needs it for.
      expect(out, contains('f406064d'));
      expect(out, contains('[64 hex]'));
      // Everything that makes the line useful is still there.
      expect(out, contains('Cloud backup PUSHED'));
      expect(out, contains('17/26 blob(s)'));
    });

    test('secrets named as such are removed entirely', () {
      for (final line in const [
        'Authorization: Token abc123def456',
        'api_key=9f8e7d6c5b4a',
        'cookie: SAPISID=AAAAABBBBBCCCCC',
        'secret = hunter2',
        'password: correct-horse-battery',
      ]) {
        final out = ActivityLog.redact(line);
        expect(out, contains('[redacted]'), reason: 'not redacted: $line');
        for (final leak in const [
          'abc123def456',
          '9f8e7d6c5b4a',
          'AAAAABBBBBCCCCC',
          'hunter2',
          'correct-horse-battery',
        ]) {
          expect(out, isNot(contains(leak)), reason: 'leaked $leak from: $line');
        }
      }
    });

    test('a Bearer header is stripped however it is spelled', () {
      expect(ActivityLog.redact('headers: {Bearer ya29.A0ARrdaM_secret}'),
          isNot(contains('ya29.A0ARrdaM_secret')));
      expect(ActivityLog.redact('Token 0123456789abcdef'),
          isNot(contains('0123456789abcdef')));
    });

    test('ordinary diagnostic lines pass through untouched', () {
      // THE OTHER HALF OF THE JOB. Over-redaction would quietly destroy the
      // thing the log exists for — these are the exact shapes that found real
      // bugs today, and every one has to survive verbatim.
      for (final line in const [
        'LT: executed schedule — playing=true at 1786ms (4ms off the instant)',
        'LT guest: drift 286ms → nudge',
        'data: 25 req, 1.91 MB total — artwork 0.19MB · audio_stream 0.00MB',
        'playback stalled — buffering for 8s with no audio',
        'onPlayerError code=ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED msg=Source error',
        'library loaded: 25 row(s), 20 playlist(s) with tracks, 14 liked song(s)',
        'Playing from local cache: hate that i made you love me',
      ]) {
        expect(ActivityLog.redact(line), line, reason: 'mangled: $line');
      }
    });

    test('a short hex id — a video id — is NOT mistaken for a secret', () {
      // Video ids are 11 chars and appear constantly. Losing them would make the
      // timeline unreadable, so the hash rule is deliberately 40+.
      const line = 'Lyrics saved to disk for 9_bTl2vvYQg';
      expect(ActivityLog.redact(line), line);
      const uid = 'enableCloudBackup[C1]: SECURE session uid=219c4e7a54a4…';
      expect(ActivityLog.redact(uid), uid);
    });
  });

  group('timestamp — the thing that makes a transcript a timeline', () {
    test('is millisecond-precise and sortable', () {
      final s = ActivityLog.stamp();
      // MM-DD HH:MM:SS.mmm — the same shape logcat prints, so lines from the two
      // sources can be read side by side.
      expect(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$').hasMatch(s), isTrue,
          reason: 'unexpected stamp: $s');
    });
  });
}
