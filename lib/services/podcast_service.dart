import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import '../data/podcast_model.dart';
import 'package:auvy/services/updater_service.dart' show UpdaterService;
import 'package:auvy/logic/stall_watchdog.dart';
import 'package:auvy/services/http_pool.dart';

/// What [parseRssEpisodes] needs, in one sendable object.
///
/// The show's name and artwork travel as plain strings rather than the
/// `PodcastShow` itself: the isolate only needs those two fields, and sending the
/// smallest thing that works keeps the boundary obvious.
class RssParseRequest {
  final String xml;
  final int limit;
  final String podcastName;
  final String imageUrl;
  final String feedUrl;
  const RssParseRequest({
    required this.xml,
    required this.limit,
    required this.podcastName,
    required this.imageUrl,
    this.feedUrl = '',
  });
}

// Compiled once at top level rather than on every feed parse. Top-level (not
// static on the class) because the isolate entry point below is top-level too
// and touches no instance state.
final RegExp _rssItem = RegExp(r'<item>([\s\S]*?)<\/item>', caseSensitive: false);
final RegExp _rssTitle = RegExp(
    r'<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>',
    caseSensitive: false);
final RegExp _rssEnclosure =
    RegExp(r'''<enclosure[^>]+url=["']([^"']+)["']''', caseSensitive: false);
final RegExp _rssPubDate =
    RegExp(r'<pubDate>([\s\S]*?)<\/pubDate>', caseSensitive: false);
final RegExp _rssDuration = RegExp(
    r'<itunes:duration>([\s\S]*?)<\/itunes:duration>',
    caseSensitive: false);
// Show notes (chapters/sponsors get mined from the timestamps inside).
// content:encoded usually carries the full notes; description is the fallback.
// Both are often CDATA-wrapped.
final RegExp _rssContent = RegExp(
    r'<content:encoded>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/content:encoded>',
    caseSensitive: false);
final RegExp _rssDescription = RegExp(
    r'<description>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/description>',
    caseSensitive: false);
// Podcasting 2.0 companion files.
final RegExp _rssTranscript = RegExp(
    r'''<podcast:transcript[^>]+url=["']([^"']+)["'][^>]*>''',
    caseSensitive: false);
final RegExp _rssChapters = RegExp(
    r'''<podcast:chapters[^>]+url=["']([^"']+)["'][^>]*>''',
    caseSensitive: false);
final RegExp _rssItunesImage =
    RegExp(r'''<itunes:image[^>]+href=["']([^"']+)["']''', caseSensitive: false);

/// Parse an RSS feed into episodes. **Runs in a background isolate**. See the
/// note at the call site for why.
///
/// Top-level and public because `compute` can only reach a top-level or static
/// function, and a private one cannot be named from the isolate's entry point.
List<PodcastEpisode> parseRssEpisodes(RssParseRequest req) {
  final episodes = <PodcastEpisode>[];
  for (final match in _rssItem.allMatches(req.xml).take(req.limit)) {
    final itemXml = match.group(1) ?? '';
    final titleMatch = _rssTitle.firstMatch(itemXml);
    final urlMatch = _rssEnclosure.firstMatch(itemXml);
    if (titleMatch == null || urlMatch == null) continue;

    final dateMatch = _rssPubDate.firstMatch(itemXml);
    final durationStr = _rssDuration.firstMatch(itemXml)?.group(1)?.trim() ?? '0:00';
    final notes = _rssContent.firstMatch(itemXml)?.group(1) ??
        _rssDescription.firstMatch(itemXml)?.group(1) ??
        '';

    // Prefer an SRT/VTT transcript when the item offers several formats.
    String transcriptUrl = '';
    for (final t in _rssTranscript.allMatches(itemXml)) {
      final u = t.group(1) ?? '';
      if (transcriptUrl.isEmpty) transcriptUrl = u;
      final tag = t.group(0)!.toLowerCase();
      if (tag.contains('srt') || tag.contains('vtt') || tag.contains('subrip')) {
        transcriptUrl = u;
        break;
      }
    }

    final episodeImageMatch = _rssItunesImage.firstMatch(itemXml);
    final episodeImage = episodeImageMatch?.group(1)?.trim();

    episodes.add(PodcastEpisode(
      title: PodcastService.cleanHtml(titleMatch.group(1) ?? 'Unknown Episode'),
      streamUrl: PodcastService.unwrapTracking(urlMatch.group(1) ?? ''),
      pubDate: dateMatch?.group(1)?.split('00:00:00').first.trim() ?? '',
      podcastName: req.podcastName,
      imageUrl: (episodeImage != null && episodeImage.isNotEmpty)
          ? episodeImage
          : req.imageUrl,
      duration: durationStr,
      description: notes,
      transcriptUrl: transcriptUrl,
      chaptersUrl: _rssChapters.firstMatch(itemXml)?.group(1) ?? '',
      feedUrl: req.feedUrl,
    ));
  }
  return episodes;
}

class PodcastService {
  /// Largest feed this will parse. A feed is untrusted input, so it gets a size
  /// limit like the other untrusted readers (`_maxArchiveBytes`,
  /// `_maxDatabaseBytes`). 8 MB is far above any real feed; a 300-episode show
  /// with full notes is 1-2 MB.
  static const int _maxFeedBytes = 8 * 1024 * 1024;

  /// Redirect wrappers publishers put in front of the real audio URL, e.g.
  /// `chrt.fm/track/ABC/dts.podtrac.com/redirect.mp3/traffic.megaphone.fm/X.mp3`.
  /// Each hop is a redirect that delays playback, tells a third party what you're
  /// listening to, and is one more thing that can fail.
  ///
  /// This does not remove ads: dynamically inserted ads are stitched into the
  /// audio file by the host (megaphone, art19, simplecast, omny). It only removes
  /// the tracking hops and their round trips.
  static final List<RegExp> _trackingPrefixes = [
    RegExp(r'^https?://(?:www\.)?chrt\.fm/track/[^/]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:www\.)?chtbl\.com/track/[^/]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:dts\.|www\.)?podtrac\.com/(?:pts/)?redirect\.[a-z0-9]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:www\.)?pdst\.fm/e/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:www\.)?pscrb\.fm/rss/p/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:[a-z0-9-]+\.)?mgln\.ai/e/[^/]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:www\.)?arttrk\.com/p/[^/]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://verifi\.podscribe\.com/rss/p/(.+)$', caseSensitive: false),
    RegExp(r'^https?://(?:www\.)?claritaspod\.com/measure/(.+)$', caseSensitive: false),
    RegExp(r'^https?://pfx\.vpixl\.com/[^/]+/(.+)$', caseSensitive: false),
    RegExp(r'^https?://prfx\.byspotify\.com/e/(.+)$', caseSensitive: false),
    RegExp(r'^https?://op3\.dev/e/(.+)$', caseSensitive: false),
  ];

  /// Peels off the wrappers; the innermost URL wins. Only hosts on the list above
  /// are unwrapped (never "jump to any embedded http://", which would break
  /// legitimate URLs with one in a query parameter). The inner URL is often
  /// missing its scheme, so one is added back.
  static String unwrapTracking(String raw) {
    var url = raw.trim().replaceAll('&amp;', '&');
    if (url.isEmpty) return url;
    // Wrappers nest, but never deeply. Bounded so a malformed URL that keeps
    // matching itself cannot spin.
    for (var hop = 0; hop < 6; hop++) {
      final before = url;
      for (final re in _trackingPrefixes) {
        final m = re.firstMatch(url);
        if (m != null) {
          url = m.group(1)!.trim();
          break;
        }
      }
      if (url == before) break;
      if (!url.startsWith('http')) url = 'https://$url';
    }
    // A wrapper that peeled down to nothing usable means the pattern was wrong;
    // the original is always playable, so fall back rather than ship a stub.
    return url.length < 12 ? raw.trim() : url;
  }

  /// Apple's podcast genre ids for the browse hub: all 19 top-level categories and
  /// 91 subcategories. Using Apple's own categories means each chart returns what
  /// actually tops that genre, not whatever a keyword search matches.
  ///
  /// Generated from itunes.apple.com/WebObjects/MZStoreServices.woa/ws/genres?id=26.
  /// A wrong id silently returns a different chart, so fetch that endpoint again
  /// to extend this rather than adding ids by hand. Flat on purpose: names are
  /// unique across the tree.
  static const Map<String, int> genreIds = {
    'After Shows': 1562,
    'Alternative Health': 1513,
    'Animation & Manga': 1510,
    'Arts': 1301,
    'Astronomy': 1538,
    'Automotive': 1503,
    'Aviation': 1504,
    'Baseball': 1549,
    'Basketball': 1548,
    'Books': 1482,
    'Buddhism': 1438,
    'Business': 1321,
    'Business News': 1490,
    'Careers': 1410,
    'Chemistry': 1539,
    'Christianity': 1439,
    'Comedy': 1303,
    'Comedy Fiction': 1486,
    'Comedy Interviews': 1496,
    'Courses': 1501,
    'Crafts': 1506,
    'Cricket': 1554,
    'Daily News': 1526,
    'Design': 1402,
    'Documentary': 1543,
    'Drama': 1484,
    'Earth Sciences': 1540,
    'Education': 1304,
    'Education for Kids': 1519,
    'Entertainment News': 1531,
    'Entrepreneurship': 1493,
    'Fantasy Sports': 1560,
    'Fashion & Beauty': 1459,
    'Fiction': 1483,
    'Film History': 1564,
    'Film Interviews': 1565,
    'Film Reviews': 1563,
    'Fitness': 1514,
    'Food': 1306,
    'Football': 1547,
    'Games': 1507,
    'Golf': 1553,
    'Government': 1511,
    'Health & Fitness': 1512,
    'Hinduism': 1463,
    'History': 1487,
    'Hobbies': 1505,
    'Hockey': 1550,
    'Home & Garden': 1508,
    'How To': 1499,
    'Improv': 1495,
    'Investing': 1412,
    'Islam': 1440,
    'Judaism': 1441,
    'Kids & Family': 1305,
    'Language Learning': 1498,
    'Leisure': 1502,
    'Life Sciences': 1541,
    'Management': 1491,
    'Marketing': 1492,
    'Mathematics': 1536,
    'Medicine': 1518,
    'Mental Health': 1517,
    'Music': 1310,
    'Music Commentary': 1523,
    'Music History': 1524,
    'Music Interviews': 1525,
    'Natural Sciences': 1534,
    'Nature': 1537,
    'News': 1489,
    'News Commentary': 1530,
    'Non-Profit': 1494,
    'Nutrition': 1515,
    'Parenting': 1521,
    'Performing Arts': 1405,
    'Personal Journals': 1302,
    'Pets & Animals': 1522,
    'Philosophy': 1443,
    'Physics': 1542,
    'Places & Travel': 1320,
    'Politics': 1527,
    'Relationships': 1544,
    'Religion': 1532,
    'Religion & Spirituality': 1314,
    'Rugby': 1552,
    'Running': 1551,
    'Science': 1533,
    'Science Fiction': 1485,
    'Self-Improvement': 1500,
    'Sexuality': 1516,
    'Soccer': 1546,
    'Social Sciences': 1535,
    'Society & Culture': 1324,
    'Spirituality': 1444,
    'Sports': 1545,
    'Sports News': 1529,
    'Stand-Up': 1497,
    'Stories for Kids': 1520,
    'Swimming': 1558,
    'Tech News': 1528,
    'Technology': 1318,
    'Tennis': 1556,
    'True Crime': 1488,
    'TV & Film': 1309,
    'TV Reviews': 1561,
    'Video Games': 1509,
    'Visual Arts': 1406,
    'Volleyball': 1557,
    'Wilderness': 1559,
    'Wrestling': 1555,
  };

  /// The 19 TOP-LEVEL categories.
  ///
  /// The chip row uses these rather than all 110: chips are for a quick jump
  /// between broad areas, and 110 of them is a horizontal scroll nobody
  /// finishes. The full tree lives in the section list, where the A-Z rail
  /// makes depth navigable.
  static const List<String> topLevelGenres = [
    'Arts',
    'Business',
    'Comedy',
    'Education',
    'Fiction',
    'Government',
    'Health & Fitness',
    'History',
    'Kids & Family',
    'Leisure',
    'Music',
    'News',
    'Religion & Spirituality',
    'Science',
    'Society & Culture',
    'Sports',
    'TV & Film',
    'Technology',
    'True Crime',
  ];

  /// Searches with limit=200, the API's maximum (still one request), so shows that
  /// aren't an exact title match don't fall off the end. `country` matters: the
  /// catalogue differs per storefront. [limit] is lower where only the first
  /// match is wanted (finding a show by its exact name: 200 results is ~160 KB).
  Future<List<PodcastShow>> searchPodcasts(String query,
      {String country = 'US', int limit = 200}) async {
    if (query.isEmpty) return [];
    try {
      final data = await _itunes(Uri.parse(
          'https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}'
          '&media=podcast&limit=$limit&country=$country'));
      if (data != null) {
        final List results = data['results'] ?? [];
        return results
            .map((e) => PodcastShow.fromJson(e))
            .where((s) => s.feedUrl.isNotEmpty)
            .toList();
      }
    } catch (e) {
      print("Podcast search error: $e");
    }
    return [];
  }

  /// The genre chart: Apple's top shows for a category, rather than a keyword
  /// search for the genre name. Two requests: the chart feed gives ids in rank
  /// order, and `lookup` turns them into full records (feed URL, artwork, author).
  Future<List<PodcastShow>> getTopByGenre(String genre,
      // 60 is a browse depth: a genre section is a shortlist of a ranked chart.
      // Finding a specific show is what search (200 results) is for.
      {String country = 'us', int limit = 60}) async {
    final id = genreIds[genre];
    if (id == null) return searchPodcasts(genre);
    try {
      final chart = await _itunes(Uri.parse(
          'https://itunes.apple.com/$country/rss/toppodcasts/limit=$limit/genre=$id/json'));
      if (chart == null) return searchPodcasts(genre);

      final feed = chart['feed'];
      final List entries = (feed?['entry'] as List?) ?? const [];
      final ids = <String>[];
      for (final e in entries) {
        final idAttr = e['id']?['attributes']?['im:id'];
        if (idAttr != null) ids.add(idAttr.toString());
      }
      if (ids.isEmpty) return searchPodcasts(genre);

      // lookup caps the id list per request; chunk to stay well inside it.
      final out = <PodcastShow>[];
      for (var i = 0; i < ids.length; i += 50) {
        final slice = ids.sublist(i, (i + 50).clamp(0, ids.length));
        final look = await _itunes(Uri.parse(
            'https://itunes.apple.com/lookup?id=${slice.join(",")}&entity=podcast'));
        if (look == null) continue;
        final List results = look['results'] ?? const [];
        for (final r in results) {
          final show = PodcastShow.fromJson(r);
          // No feed url means nothing to play — drop it rather than show a
          // tile that dead-ends.
          if (show.feedUrl.isNotEmpty) out.add(show);
        }
      }
      // lookup does not preserve the chart order; restore it.
      final rank = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      out.sort((a, b) =>
          (rank[a.trackId] ?? 1 << 30).compareTo(rank[b.trackId] ?? 1 << 30));
      return out;
    } catch (e) {
      print("Podcast chart error: $e");
      return searchPodcasts(genre);
    }
  }

  /// Apple's overall top shows, as chart entries (name, artist, artwork) without
  /// the feed, which [lookupShow] fetches for the one opened.
  Future<List<ChartShow>> getTopChart({String country = 'us', int limit = 25}) async {
    final chart = await _itunes(Uri.parse(
        'https://itunes.apple.com/$country/rss/toppodcasts/limit=$limit/json'));
    final List entries = (chart?['feed']?['entry'] as List?) ?? const [];
    final out = <ChartShow>[];
    for (final e in entries) {
      final id = e['id']?['attributes']?['im:id']?.toString() ?? '';
      final name = e['im:name']?['label']?.toString() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      final images = (e['im:image'] as List?) ?? const [];
      final image = images.isEmpty ? '' : (images.last['label']?.toString() ?? '');
      out.add(ChartShow(
        id: id,
        name: PodcastService.cleanHtml(name),
        artist: PodcastService.cleanHtml(e['im:artist']?['label']?.toString() ?? ''),
        // The chart's largest image is 170 px; the same URL serves larger.
        image: image.replaceAll(RegExp(r'/\d+x\d+bb\.'), '/600x600bb.'),
      ));
    }
    return out;
  }

  /// The artwork of a category's top few shows, for its tile (one small chart
  /// request, no lookups).
  Future<List<String>> getChartArt(String genre, {String country = 'us', int limit = 3}) async {
    final id = genreIds[genre];
    if (id == null) return const [];
    final chart = await _itunes(Uri.parse(
        'https://itunes.apple.com/$country/rss/toppodcasts/limit=$limit/genre=$id/json'));
    final List entries = (chart?['feed']?['entry'] as List?) ?? const [];
    return [
      for (final e in entries)
        if (((e['im:image'] as List?) ?? const []).isNotEmpty)
          ((e['im:image'] as List).last['label']?.toString() ?? '')
              .replaceAll(RegExp(r'/\d+x\d+bb\.'), '/300x300bb.')
    ];
  }

  /// One show by its catalogue id (a chart entry being opened).
  Future<PodcastShow?> lookupShow(String id) async {
    final look = await _itunes(
        Uri.parse('https://itunes.apple.com/lookup?id=${Uri.encodeQueryComponent(id)}&entity=podcast'));
    final List results = look?['results'] ?? const [];
    for (final r in results) {
      final show = PodcastShow.fromJson(r);
      if (show.feedUrl.isNotEmpty) return show;
    }
    return null;
  }

  /// Episodes via the Worker, which parses the feed and returns slim JSON. Raw
  /// feeds can be many MB (and are re-fetched every few hours); the Worker stops
  /// once it has enough items and returns a small fraction of that, with no large
  /// XML parse on the phone.
  ///
  /// Returns null (not an empty list) when it can't answer, so the caller can tell
  /// "Worker unavailable" from "no episodes" and fall back.
  ///
  /// `_itunes` below: GETs an iTunes directory endpoint directly from the device.
  /// Don't route it through the Worker: Apple throttles by source IP, and behind
  /// one Cloudflare address all users look like one client (search returned 429
  /// after a handful of requests). From phones the traffic is spread over many
  /// IPs. Caching doesn't help, since every cache miss is a throttled request.
  Future<Map<String, dynamic>?> _itunes(
    Uri url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final res = await HttpPool().getClient().get(url).timeout(timeout);
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  Future<List<PodcastEpisode>?> _episodesViaWorker(
      PodcastShow show, int limit) async {
    try {
      final uri = Uri.parse('https://${UpdaterService.updateHost}/podcast'
          '?url=${Uri.encodeQueryComponent(show.feedUrl)}'
          '&limit=${limit.clamp(1, 300)}');
      final res = await HttpPool().getClient().get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (body['episodes'] as List?) ?? const [];
      if (list.isEmpty) return null;
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return PodcastEpisode(
          // The Worker already stripped tags and decoded entities, so no
          // _cleanHtml pass is needed here.
          title: (m['title'] ?? 'Unknown Episode').toString(),
          // Unwrap here too: feeds hand out redirector URLs, and the player wants the
          // real file without the tracking hops.
          streamUrl: unwrapTracking((m['audio'] ?? '').toString()),
          pubDate:
              (m['date'] ?? '').toString().split('00:00:00').first.trim(),
          podcastName: show.collectionName,
          imageUrl: (m['image'] ?? '').toString().isNotEmpty
              ? m['image'].toString()
              : show.artworkUrl,
          duration: (m['duration'] ?? '0:00').toString(),
          description: (m['notes'] ?? m['summary'] ?? '').toString(),
          transcriptUrl: (m['transcript'] ?? '').toString(),
          chaptersUrl: (m['chapters'] ?? '').toString(),
          feedUrl: show.feedUrl,
        );
      }).toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<PodcastEpisode>> getEpisodes(PodcastShow show, {int limit = 1000}) async {
    if (show.feedUrl.isEmpty) return [];

    // Worker first; any failure falls through to the direct parse below, so a
    // broken route can't take podcasts down. The direct path keeps full notes and
    // prefers an SRT/VTT transcript when there are several (the Worker reports only
    // the first).
    final viaWorker = await _episodesViaWorker(show, limit);
    if (viaWorker != null && viaWorker.isNotEmpty) return viaWorker;

    try {
      final cacheBuster = DateTime.now().millisecondsSinceEpoch;
      final separator = show.feedUrl.contains('?') ? '&' : '?';
      final finalUrl = '${show.feedUrl}${separator}_t=$cacheBuster';
      final response = await HttpPool().getClient().get(Uri.parse(finalUrl)).timeout(const Duration(seconds: 15),
              onTimeout: () => http.Response('', 408));
      
      if (response.statusCode != 200) {
        // Name the reason (404, 403, moved, timeout) instead of returning an empty list
        // silently, so these can be told apart from a genuinely empty feed.
        final why = response.statusCode == 408
            ? 'nothing within 15s'
            : 'HTTP ${response.statusCode}';
        print('WARN: feed for "${show.collectionName}" returned $why — '
            'showing no episodes');
        return [];
      }
      {
        final xmlString = response.body;
        // Parsed off the main isolate (via `compute`, like other heavy parses), since a
        // regex pass over a multi-MB feed would freeze the UI. Also size-limited,
        // because a feed is untrusted input; refusing is fine because the Worker path
        // is the normal route and this is the fallback.
        if (xmlString.length > _maxFeedBytes) {
          print('WARN: feed for "${show.collectionName}" is '
              '${xmlString.length ~/ (1024 * 1024)}MB, over the '
              '${_maxFeedBytes ~/ (1024 * 1024)}MB ceiling — refusing to parse '
              'it rather than stalling on it');
          return [];
        }
        final parseStarted = DateTime.now();
        final episodes = await compute(
          parseRssEpisodes,
          RssParseRequest(
            xml: xmlString,
            limit: limit,
            podcastName: show.collectionName,
            imageUrl: show.artworkUrl,
            feedUrl: show.feedUrl,
          ),
        );
        final parseMs = DateTime.now().difference(parseStarted).inMilliseconds;
        StallWatchdog.note('podcast.rssParse', parseMs);
        if (episodes.isEmpty) {
          // 200 with content that yielded nothing is a FORMAT problem, not an
          // empty show — an Atom feed, or an <item> spelling this regex does
          // not match. Same distinction the catalogue parser needed.
          print('WARN: "${show.collectionName}": ${xmlString.length ~/ 1024}KB of feed '
              'parsed to ZERO episodes in ${parseMs}ms — the feed is not empty, '
              'it did not match the RSS shape this parses');
        } else if (parseMs > 300 || xmlString.length > 1024 * 1024) {
          print('"${show.collectionName}": ${episodes.length} episode(s) from '
              '${xmlString.length ~/ 1024}KB in ${parseMs}ms (main isolate)');
        }
        return episodes;
      }
    } catch (e) {
      print("Podcast RSS fetch error: $e");
    }
    return [];
  }

  // RSS titles arrive with raw entities ("Raising a Dog &amp; Mastering…"), so
  // decode them after stripping tags — CDATA already skips encoding, but plain
  // <title> nodes don't.
  /// Static because the RSS parse now runs in a background isolate, and an
  /// isolate entry point can only reach static or top-level code. Nothing in
  /// here ever used instance state.
  static String cleanHtml(String text) {
    var t = text.replaceAll(RegExp(r'<[^>]*>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16);
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        })
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        });
    return t.trim();
  }
}