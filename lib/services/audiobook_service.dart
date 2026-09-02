import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/updater_service.dart' show UpdaterService;

/// Free, public-domain audiobooks.
///
/// Why these sources
///
/// LibriVox is the catalogue: volunteers record works whose copyright has
/// expired and release the recordings into the PUBLIC DOMAIN. That is what makes
/// this section possible at all — there is no licence to negotiate and nothing is
/// being redistributed against its terms, which is not true of any commercial
/// audiobook source.
///
/// The Internet Archive hosts the audio LibriVox produces, and serves two jobs
/// here: it is where the per-chapter files come from, and it is the FALLBACK
/// catalogue when librivox.org itself is unreachable (a small volunteer-run site
/// that does go down). Its `collection:librivoxaudio` is the same body of work.
///
/// Worker first, direct always possible
///
/// Same shape as [RadioService]: browse and search results are IDENTICAL for
/// every user, so fetching them per device sends the same bytes many times from a
/// volunteer service. The Worker caches them at the edge, which means thousands of
/// listeners cost LibriVox a handful of requests instead of thousands.
///
/// The direct path is deliberately kept. Routing through the Worker makes it a
/// single point of failure, and a misdeployed route should not take audiobooks
/// down — that is exactly what happened to /covers once.
///
/// AND WHY THIS IS NOT THE /itunes MISTAKE. An `/itunes` route was built,
/// measured and REMOVED (see worker.js) because Apple throttles by source IP, so
/// every user behind one Cloudflare egress IP read as a single hammering client —
/// 429 after about five requests. The difference here is the cache: these
/// responses are long-lived and shared, so the origin sees a trickle rather than a
/// flood. If LibriVox ever does start refusing the Worker's IP, the fallback below
/// is already the answer and nothing needs redesigning.
class AudiobookService {
  static const Duration _timeout = Duration(seconds: 12);

  static const String _archiveSearch = 'https://archive.org/advancedsearch.php';

  /// Small in-memory cache so paging back and forth, or re-opening a book, does
  /// not re-fetch. Session-scoped on purpose: a catalogue this size is not worth
  /// persisting, and a stale one would be worse than a second request.
  ///
  /// AND BOUNDED. "Session-scoped" is not a bound — a session is however
  /// long the app stays alive, which on Android is days. A chapter list can run
  /// to a hundred entries for one book, so browsing is enough to accumulate
  /// thousands of objects that nothing will ever ask for again. Both are
  /// oldest-first, since the page being read is the one just inserted.
  static const int _maxCachedLists = 40;
  static const int _maxCachedBooks = 24;
  static final Map<String, List<Audiobook>> _listCache = {};
  static final Map<String, List<AudiobookChapter>> _chapterCache = {};

  static http.Client get _http => HttpPool().getClient();

  /// GET an Archive search through the Worker, falling back to direct.
  ///
  /// The worker still earns its place, it just proxies a different host now.
  ///
  /// The popular and genre lists are IDENTICAL for every user — nobody gets a
  /// personalised "most-downloaded audiobooks", so fetching them per device
  /// sends the same bytes many times. Cached at the edge, thousands of listeners
  /// cost archive.org a handful of requests.
  ///
  /// The direct path is deliberately kept: routing through the Worker makes it a
  /// single point of failure, and a misdeployed route should not take audiobooks
  /// down, which is exactly what happened to /covers once.
  static Future<String?> _fetchSearch(String query) async {
    try {
      final res = await _http.get(
        Uri.parse('https://${UpdaterService.updateHost}/audiobooks'
            '?q=${Uri.encodeQueryComponent(query)}'),
        headers: const {'User-Agent': 'Auvy/1.0'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
    } catch (_) {
      // Fall through to direct. See above.
    }
    try {
      final res = await _http.get(
        Uri.parse('$_archiveSearch?$query'),
        headers: const {'User-Agent': 'Auvy/1.0'},
      ).timeout(_timeout);
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
      print('Archive returned ${res.statusCode}');
    } catch (e) {
      print('Archive request failed: $e');
    }
    return null;
  }

  // The archive is the catalogue now, NOT just the fallback
  //
  // MEASURED REASONS, all three of which were real complaints:
  //
  // 1. THE BOOKS WERE OBSCURE. Browse used LibriVox's `sort_order=catalog_date`,
  //    which is "whatever a volunteer finished most recently" — Letters of Two
  //    Brides, Monte-Cristo's Daughter. Nobody opens an audiobook app looking for
  //    those. The Archive exposes a `downloads` count, and sorting by it returns
  //    what people actually listen to:
  //
  //      Art of War · Alice in Wonderland · Tom Sawyer · Sherlock Holmes ·
  //      Moby Dick · Huckleberry Finn · Pride and Prejudice · Dracula
  //
  // 2. EVERY FILTER TAP COST 77 KB. A 40-book LibriVox page is 77,118 bytes,
  //    because each entry carries a full HTML description and section list.
  //    The same information from the Archive, with only the fields the list
  //    renders, is 2,824 bytes for 20 — about 27x less per tap, and the page is
  //    half the size as well.
  //
  // 3. GENRES NOW FILTER PROPERLY. `subject:` searches the same taxonomy and,
  //    combined with the popularity sort, leads with the recognisable book:
  //    Science Fiction → The Time Machine; Horror → Frankenstein; Poetry → The
  //    Odyssey.
  //
  // AND THE JUNK FILTER IS NOT OPTIONAL. `collection:librivoxaudio` contains
  // items that are not books — cover-art dumps and packaging artefacts named
  // "Thumbs 12" and "LibrivoxCDCoverArt35", and by download count they rank
  // among the top ten. Requiring a `creator` and `mediatype:audio` removes them
  // (21,773 → 21,532 items, so ~241 non-books) and leaves every row a real book
  // with a real author.
  static const String _base =
      'collection:librivoxaudio AND creator:[* TO *] AND mediatype:audio';

  /// One page is 20, not 40. A phone screen shows about six rows, so 40 was
  /// mostly data fetched for rows nobody scrolled to, and the next page costs
  /// one small request if they do.
  static const int _pageSize = 20;

  /// The most-listened books — the default browse view.
  static Future<List<Audiobook>> popular({int page = 1}) =>
      _archive(_base, cacheKey: 'popular:$page', page: page);

  /// Kept so a caller wanting genuinely new additions still can, but it is no
  /// longer what the page opens on. See the note above.
  static Future<List<Audiobook>> latest({int page = 1}) =>
      _archive(_base, cacheKey: 'latest:$page', page: page, sort: '-publicdate');

  /// One genre, most-listened first.
  static Future<List<Audiobook>> byGenre(String genre, {int page = 1}) =>
      _archive('$_base AND subject:("${_clean(genre)}")',
          cacheKey: 'genre:$genre:$page', page: page);

  /// Search by title or author.
  ///
  /// Scoped to `title:` and `creator:` on purpose: an unscoped full-text query
  /// matches descriptions, and "war and peace" then returned Edward III. Ranked
  /// by relevance rather than downloads — someone who typed a title wants THAT
  /// book, not the most popular thing that mentions it.
  static Future<List<Audiobook>> search(String rawQuery, {int page = 1}) {
    final q = _clean(rawQuery.trim());
    if (q.isEmpty) return Future.value(const []);
    return _archive(
      '$_base AND (title:("$q") OR creator:("$q"))',
      // Lower-cased so "Austen", " austen " and "austen" are one cache entry and
      // one origin request rather than three.
      cacheKey: 'search:${q.toLowerCase()}:$page',
      page: page,
      sort: null,
    );
  }

  /// Double quotes delimit a phrase and a backslash escapes, so either would
  /// break the query. Stripped rather than escaped: no real title or genre needs
  /// them to be found, and a malformed query returns nothing with no clue why.
  static String _clean(String s) =>
      s.replaceAll('"', ' ').replaceAll(r'\', ' ').trim();

  static Future<List<Audiobook>> _archive(
    String query, {
    required String cacheKey,
    int page = 1,
    String? sort = '-downloads',
  }) async {
    final hit = _listCache[cacheKey];
    if (hit != null) return hit;

    // The query string, built once so the Worker and the direct path send an
    // identical one — that is what makes the edge cache key stable.
    final qs = 'q=${Uri.encodeQueryComponent(query)}'
        '&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=downloads'
        '&fl[]=runtime&fl[]=language'
        '${sort == null ? '' : '&sort[]=${Uri.encodeQueryComponent(sort)}'}'
        '&rows=$_pageSize&page=$page&output=json';
    final body = await _fetchSearch(qs);
    if (body == null) return const [];
    final books = await compute(_parseArchive, body);
    if (books.isNotEmpty) {
      _listCache[cacheKey] = books;
      while (_listCache.length > _maxCachedLists) {
        _listCache.remove(_listCache.keys.first);
      }
    }
    return books;
  }

  /// The playable chapters of [book], newest-first order preserved from the item.
  ///
  /// Read from the Archive item's own metadata rather than LibriVox's section
  /// list: the files are there, the durations are exact, and it works for books
  /// that only exist in the Archive fallback.
  static Future<List<AudiobookChapter>> chaptersFor(Audiobook book) async {
    if (book.archiveId.isEmpty) return const [];
    final hit = _chapterCache[book.archiveId];
    if (hit != null) return hit;
    try {
      final res = await _http
          .get(Uri.parse('https://archive.org/metadata/${book.archiveId}'),
              headers: const {'User-Agent': 'Auvy/1.0'})
          .timeout(_timeout);
      if (res.statusCode != 200) {
        print('Archive metadata returned ${res.statusCode} for ${book.archiveId}');
        return const [];
      }
      final chapters = await compute(_parseChapters, res.body);
      if (chapters.isNotEmpty) {
        _chapterCache[book.archiveId] = chapters;
        while (_chapterCache.length > _maxCachedBooks) {
          _chapterCache.remove(_chapterCache.keys.first);
        }
      }
      return chapters;
    } catch (e) {
      print('Chapter list failed for ${book.archiveId}: $e');
      return const [];
    }
  }

  /// Chosen by measurement, NOT by copying librivox's taxonomy.
  ///
  /// The first version used LibriVox's own genre names, and most of them return
  /// nothing from the Archive's `subject:` index — a chip that leads to an empty
  /// page reads as a broken app. Measured, with the item count and the top hit:
  ///
  ///   Horror & Supernatural →    0      Horror     →  264  (Frankenstein)
  ///   Crime & Mystery       →    2      Mystery    →  867  (Sherlock Holmes)
  ///   Action & Adventure    →   10      Adventure  → 1139  (Sherlock Holmes)
  ///   Humorous Fiction      →    5      Fiction    → 3057  (Alice in Wonderland)
  ///
  /// Every term below was verified to return results AND to lead with a
  /// recognisable book, which is the actual test — a genre full of obscurities is
  /// no better than an empty one. Re-run that check before adding more.
  static const List<String> genres = [
    'Fiction',       // 3057 — Alice in Wonderland
    'Poetry',        // 2738 — The Odyssey
    'History',       // 1442 — Alexander the Great
    'Children',      // 1173 — Alice in Wonderland, Peter Pan
    'Romance',       // 1150 — Pride and Prejudice
    'Adventure',     // 1139 — Sherlock Holmes
    'Philosophy',    // 1098 — Beyond Good and Evil
    'Mystery',       //  867 — Sherlock Holmes
    'Science',       //  787 — The Invisible Man
    'Biography',     //  369 — The Story of My Life
    'Fantasy',       //  350 — Peter Pan
    'Drama',         //  333 — Romeo and Juliet
    'Horror',        //  264 — Frankenstein
    'Classics',      //   93 — The Odyssey, Tom Sawyer
  ];

  static void clearCache() {
    _listCache.clear();
    _chapterCache.clear();
  }
}

List<Audiobook> _parseArchive(String body) {
  try {
    final decoded = jsonDecode(body);
    final resp = (decoded is Map) ? decoded["response"] : null;
    final docs = (resp is Map) ? resp["docs"] : null;
    if (docs is! List) return const [];
    final out = <Audiobook>[];
    for (final d in docs) {
      if (d is! Map) continue;
      final book = Audiobook.fromArchive(Map<String, dynamic>.from(d));
      if (book != null) out.add(book);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

List<AudiobookChapter> _parseChapters(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final files = decoded['files'];
    if (files is! List) return const [];
    // `server` + `dir` build the direct file URL. Using them rather than the
    // /download/ redirect saves a hop per chapter and, more importantly, gives
    // ExoPlayer a URL that supports range requests, which is what seeking within
    // a fifty-minute chapter needs.
    final server = (decoded['server'] ?? 'archive.org').toString();
    final dir = (decoded['dir'] ?? '').toString();

    final out = <AudiobookChapter>[];
    for (final f in files) {
      if (f is! Map) continue;
      final name = (f['name'] ?? '').toString();
      final format = (f['format'] ?? '').toString().toLowerCase();
      // 64kbps MP3 is the format LibriVox always produces and the smallest that
      // is pleasant for speech. Preferring one format also stops the same chapter
      // appearing three times (the Archive keeps several encodings per item).
      final isPreferred = format.contains('64kbps mp3') ||
          (format.contains('mp3') && name.toLowerCase().contains('_64kb'));
      if (!isPreferred) continue;
      final secs = _fileLength(f['length']);
      out.add(AudiobookChapter(
        title: _chapterTitle(f, name),
        streamUrl: 'https://$server$dir/${Uri.encodeComponent(name)}',
        duration: secs,
        index: out.length,
      ));
    }

    // Nothing matched the preferred format — take any MP3 rather than showing an
    // empty book.
    if (out.isEmpty) {
      for (final f in files) {
        if (f is! Map) continue;
        final name = (f['name'] ?? '').toString();
        if (!name.toLowerCase().endsWith('.mp3')) continue;
        final secs = _fileLength(f['length']);
        out.add(AudiobookChapter(
          title: _chapterTitle(f, name),
          streamUrl: 'https://$server$dir/${Uri.encodeComponent(name)}',
          duration: secs,
          index: out.length,
        ));
      }
    }

    // File order in the metadata is not guaranteed to be reading order; the
    // filenames carry the sequence, so sort by them.
    out.sort((a, b) => a.streamUrl.compareTo(b.streamUrl));
    return [
      for (var i = 0; i < out.length; i++)
        AudiobookChapter(
          title: out[i].title,
          streamUrl: out[i].streamUrl,
          duration: out[i].duration,
          index: i,
        )
    ];
  } catch (_) {
    return const [];
  }
}

/// The Archive reports a file length either as SECONDS ("1582.5") or as a
/// clock string ("26:22", occasionally "1:26:22").
///
/// VERIFIED AGAINST A REAL ITEM. `double.tryParse` alone returned 0 for every
/// LibriVox chapter, because the value is `26:22`, so every duration would have
/// rendered as missing while looking like a styling problem rather than a parse
/// one.
Duration _fileLength(Object? raw) {
  final s = (raw ?? "").toString().trim();
  if (s.isEmpty) return Duration.zero;
  final plain = double.tryParse(s);
  if (plain != null) return Duration(seconds: plain.round());
  final parts = s.split(":");
  if (parts.isEmpty || parts.length > 3) return Duration.zero;
  var secs = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p.trim());
    if (v == null) return Duration.zero;
    secs = secs * 60 + v;
  }
  return Duration(seconds: secs.round());
}

String _chapterTitle(Map f, String fileName) {
  final t = (f['title'] ?? '').toString().trim();
  if (t.isNotEmpty) return t;
  // Fall back to a readable form of the filename: "dickens_chapter_03_64kb.mp3"
  // reads far worse than "Chapter 03".
  var s = fileName.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'_64kb$', caseSensitive: false), '');
  s = s.replaceAll('_', ' ').trim();
  return s.isEmpty ? fileName : s;
}
