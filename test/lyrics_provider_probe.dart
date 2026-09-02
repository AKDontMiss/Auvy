// LIVE probe of each lyrics PROVIDER in isolation.
//
// Why separate from lyrics_live_probe: the full scan short-circuits as soon as a
// confidently-correct candidate arrives (lrclib usually scores 105), so a winning
// scan proves nothing about the other three sources. NetEase and KuGou were BOTH
// silently returning nothing for a long time — NetEase because `/api/search/get/web`
// answers non-CN callers with an AES blob instead of JSON, KuGou because the
// access key is spelled `accesskey` on both ends — and each failure was swallowed
// by a catch-all, so the app looked fine while running on half its sources.
//
// This asserts each provider individually, so that cannot happen again unnoticed.
import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/services/lyrics_service.dart';

void main() {
  final providers = <String, LyricsProvider>{
    'lrclib': LrcLibProvider(),
    'netease': NetEaseProvider(),
    'kugou': KuGouProvider(),
    'lyrics.ovh': LyricsOvhProvider(),
  };

  // Big, universally-catalogued track so a miss means the provider is broken
  // rather than the song being obscure.
  const title = 'bohemian rhapsody';
  const artist = 'queen';

  providers.forEach((name, p) {
    test('provider $name returns usable lyrics', () async {
      final sw = Stopwatch()..start();
      final d = await p.fetchLyrics(title, artist);
      sw.stop();
      expect(d, isNotNull, reason: '$name returned null — provider is broken');
      final synced = d!.lines.length;
      final plain = d.plainLyrics.trim().length;
      // ignore: avoid_print
      print('   $name: ${sw.elapsedMilliseconds}ms  synced=$synced lines  '
          'plain=${plain}B  matched="${d.trackName}" / "${d.artistName}"');
      expect(synced > 0 || plain > 0, isTrue,
          reason: '$name returned an empty result');
    }, timeout: const Timeout(Duration(seconds: 45)));
  });

  test('netease and kugou both return TIMED lyrics, not just plain text', () async {
    for (final name in ['netease', 'kugou']) {
      final d = await providers[name]!.fetchLyrics(title, artist);
      expect(d, isNotNull, reason: '$name null');
      expect(d!.lines.length, greaterThan(0),
          reason: '$name returned no synced lines — the LRC did not parse');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
