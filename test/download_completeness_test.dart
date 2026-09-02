import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/logic/audio_cache_manager.dart';

/// ── WHY THIS FUNCTION IS WORTH A TEST ────────────────────────────────────
///
/// It decides whether a finished download is registered as a cached track, and
/// its previous rule was a FLOOR — "more than a megabyte" — rather than a
/// comparison. A four-megabyte track truncated at two megabytes by a dropped
/// connection cleared that bar and was recorded as complete, after which every
/// play from cache stopped early and nothing ever re-downloaded it, because the
/// index said the file was already whole.
///
/// Nothing downstream could catch that: the zero-byte guards test `> 0`, and a
/// truncated file is not zero. So this one comparison is the only thing standing
/// between a dropped connection and a permanently broken cached track.
void main() {
  group('downloadLooksComplete', () {
    test('a full-length file is complete', () {
      expect(
        AudioCacheManager.downloadLooksComplete('t', 4000000, 4000000, null),
        isTrue,
      );
    });

    test('more than declared is still complete', () {
      // A 206 response can legitimately deliver the whole file when the range
      // covers it; being over is never a reason to reject.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 4000064, 4000000, null),
        isTrue,
      );
    });

    test('WARN: a TRUNCATED file is not complete, even well over the old floor', () {
      // The exact shape of the bug: comfortably past 1MB, and less than half the
      // track. This is what used to be accepted.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 2000000, 4000000, null),
        isFalse,
      );
    });

    test('a tiny shortfall is a tolerated TAIL, not a truncation', () {
      // THIS CASE CHANGED, AND THE DEVICE IS WHY.
      //
      // The first version of this rule demanded the exact length, and within
      // minutes it refused a real 27.6 MB podcast episode that arrived 7 KB
      // short — 0.025%, about half a second of audio. The host declared
      // marginally more than it sent. Refusing that meant the episode did not
      // cache at all, which is a worse outcome than losing half a second of it.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 3999999, 4000000, null),
        isTrue,
      );
      // The shape actually observed: 27671KB of 27678KB.
      expect(
        AudioCacheManager.downloadLooksComplete(
            't', 27671 * 1024, 27678 * 1024, null),
        isTrue,
      );
    });

    test('a shortfall past 0.5% is still a truncation', () {
      // 100KB of 4MB is 2.5% — well past a declared-length quirk.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 3900000, 4000000, null),
        isFalse,
      );
    });

    test('the tolerance is capped in absolute terms too', () {
      // 300KB short of 200MB is only 0.15% — inside the proportional bound —
      // but 300KB of missing audio is minutes, not a tail. The absolute cap is
      // what stops the allowance growing silly on a large file.
      expect(
        AudioCacheManager.downloadLooksComplete(
            't', 200 * 1024 * 1024 - 300 * 1024, 200 * 1024 * 1024, null),
        isFalse,
      );
      // Just inside the 128KB cap, and inside 0.5%, so accepted.
      expect(
        AudioCacheManager.downloadLooksComplete(
            't', 200 * 1024 * 1024 - 100 * 1024, 200 * 1024 * 1024, null),
        isTrue,
      );
    });

    test('the URL clen is used when the response declares no length', () {
      // googlevideo URLs carry the exact length as `clen=`, and this method's
      // caller already parses it to bound its Range request — so a response
      // without content-length is still checkable.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 4000000, 0, '4000000'),
        isTrue,
      );
      expect(
        AudioCacheManager.downloadLooksComplete('t', 2000000, 0, '4000000'),
        isFalse,
      );
    });

    test('with no length known at all, the old floor is the fallback', () {
      // Nothing to compare against. Accepting anything would be worse than the
      // floor, so the floor stays — but only here.
      expect(
        AudioCacheManager.downloadLooksComplete('t', 2000000, 0, null),
        isTrue,
      );
      expect(
        AudioCacheManager.downloadLooksComplete('t', 500000, 0, null),
        isFalse,
      );
    });

    test('a zero-byte file is never complete, by any route', () {
      expect(AudioCacheManager.downloadLooksComplete('t', 0, 4000000, null), isFalse);
      expect(AudioCacheManager.downloadLooksComplete('t', 0, 0, '4000000'), isFalse);
      expect(AudioCacheManager.downloadLooksComplete('t', 0, 0, null), isFalse);
    });
  });
}
