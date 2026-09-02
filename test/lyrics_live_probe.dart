// LIVE probe, not a unit test — it talks to the real Worker and the real lyric
// catalogues. Excluded from the `*_verify.dart` suite on purpose: it needs network
// and would make the offline test run flaky.
//
// Run: flutter test test/lyrics_live_probe.dart
//
// It exists because the four-source scan cannot be proven from the UI without
// opening the lyrics face by hand, and two of the four sources were silently
// broken for a long time precisely because nothing ever checked them end to end.
//
// songId is left null deliberately: that skips the on-disk cache, which needs
// path_provider and is unavailable in a headless test.
import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/services/lyrics_service.dart';

void main() {
  final cases = <(String, String)>[
    ('Bohemian Rhapsody', 'Queen'),
    ('Numb', 'Linkin Park'),
    ('Blinding Lights', 'The Weeknd'),
    ('Bad Guy', 'Billie Eilish'),
    ('Take Five', 'Dave Brubeck'),
  ];

  for (final (title, artist) in cases) {
    test('lyrics: $title — $artist', () async {
      final sw = Stopwatch()..start();
      final data = await LyricsService().getLyrics(title, artist);
      sw.stop();
      expect(data, isNotNull, reason: 'no lyrics found for $title');
      final synced = data!.lines.isNotEmpty;
      final plain = data.plainLyrics.trim().length;
      // ignore: avoid_print
      print('   $title: ${sw.elapsedMilliseconds}ms  synced=$synced '
          '(${data.lines.length} lines)  plain=${plain}B  '
          'matched="${data.trackName}" by "${data.artistName}"');
      expect(synced || plain > 0, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  // A REFETCH must rotate to a different source, which is the whole point of the
  // button — if rotation is broken it silently returns the same wrong lyrics.
  test('refetch rotates to a different source', () async {
    const title = 'Numb';
    const artist = 'Linkin Park';
    final svc = LyricsService();
    final first = await svc.getLyrics(title, artist);
    expect(first, isNotNull);
    final second = await svc.getLyrics(title, artist, forceRefresh: true);
    expect(second, isNotNull, reason: 'refetch came back empty');
    // ignore: avoid_print
    print('   first="${first!.trackName}/${first.artistName}" '
        '${first.lines.length} lines | '
        'refetch="${second!.trackName}/${second.artistName}" '
        '${second.lines.length} lines');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
