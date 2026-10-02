import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/updater_service.dart' show UpdaterService;

/// How a browse list is ordered.
enum AudiobookSort {
  /// What people actually listen to (download count).
  popular,

  /// Best rated by listeners, among books with at least a few ratings.
  rated,

  /// Most recently published recordings.
  newest,
}

/// Free, public-domain audiobooks.
///
/// LibriVox volunteers record works whose copyright has expired and release
/// the recordings into the public domain, so nothing is redistributed against
/// its terms. The Internet Archive hosts that audio (`collection:librivoxaudio`,
/// about 21,600 books, 18,900 in English, measured 2026-10-02) and is used for
/// both the catalogue and the chapter files. The Archive's larger "community
/// audiobooks" collection is user uploads, much of it under copyright, so it
/// is not used.
///
/// Worker first, direct always possible: browse and search results are the same
/// for every user, so the Worker caches them at the edge and many listeners cost
/// the volunteer services only a few requests. The direct path stays so a broken
/// route can't take audiobooks down.
class AudiobookService {
  static const Duration _timeout = Duration(seconds: 12);

  static const String _archiveSearch = 'https://archive.org/advancedsearch.php';

  /// Small in-memory caches so paging back or reopening a book doesn't refetch.
  /// Session-only (a stale catalogue would be worse than a second request) but
  /// bounded, since a session can last days and chapter lists can be long.
  /// Oldest entries go first.
  static const int _maxCachedLists = 60;
  static const int _maxCachedBooks = 24;
  static final Map<String, List<Audiobook>> _listCache = {};
  static final Map<String, Audiobook> _bookCache = {};

  static http.Client get _http => HttpPool().getClient();

  /// One page. A phone shows about six rows, and the next page is fetched as
  /// the list nears its end.
  static const int pageSize = 30;

  /// GETs an Archive search through the Worker, falling back to direct.
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

  // The junk filter is required: the collection contains non-books (cover-art
  // dumps like "LibrivoxCDCoverArt35") that rank high by downloads. Requiring a
  // `creator` and `mediatype:audio` removes them.
  static const String _base =
      'collection:librivoxaudio AND creator:[* TO *] AND mediatype:audio';

  /// The catalogue's codes for each language in the filter (items carry either
  /// the ISO code or the name).
  static const Map<String, List<String>> languages = {
    'English': ['eng', 'English'],
    'German': ['ger', 'deu', 'German'],
    'Spanish': ['spa', 'Spanish'],
    'French': ['fre', 'fra', 'French'],
    'Italian': ['ita', 'Italian'],
    'Dutch': ['dut', 'nld', 'Dutch'],
    'Portuguese': ['por', 'Portuguese'],
    'Russian': ['rus', 'Russian'],
    'Chinese': ['chi', 'zho', 'Chinese'],
    'Japanese': ['jpn', 'Japanese'],
    'Latin': ['lat', 'Latin'],
    'Greek': ['gre', 'ell', 'Greek'],
    'Polish': ['pol', 'Polish'],
    'Finnish': ['fin', 'Finnish'],
    'Swedish': ['swe', 'Swedish'],
    'Hebrew': ['heb', 'Hebrew'],
  };

  /// A browse page: [sort], optionally one [genre] and one [language] (null =
  /// every language).
  static Future<List<Audiobook>> browse({
    AudiobookSort sort = AudiobookSort.popular,
    String? genre,
    String? language,
    int page = 1,
  }) {
    final parts = <String>[_base];
    if (genre != null && genre.isNotEmpty) parts.add('subject:("${_clean(genre)}")');
    final codes = languages[language];
    if (codes != null) parts.add('language:(${codes.join(' OR ')})');
    // "Top rated" means rated by enough people that the average says something.
    if (sort == AudiobookSort.rated) parts.add('num_reviews:[3 TO 1000000]');
    return _archive(
      parts.join(' AND '),
      cacheKey: 'browse:${sort.name}:${genre ?? ''}:${language ?? ''}:$page',
      page: page,
      sort: switch (sort) {
        AudiobookSort.popular => '-downloads',
        AudiobookSort.rated => '-avg_rating',
        AudiobookSort.newest => '-publicdate',
      },
    );
  }

  /// Search by title or author. Every word must appear (so "sherlock holmes"
  /// finds the stories, not every Sherlock), in the title or the author, most
  /// listened first: someone who typed "pride" most likely wants the Austen.
  /// Scoped to title and creator on purpose: an unscoped full-text query matches
  /// descriptions, and "war and peace" then returned Edward III.
  static Future<List<Audiobook>> search(String rawQuery, {int page = 1, String? language}) {
    final words = _clean(rawQuery)
        .split(RegExp(r'\s+'))
        // Lower-cased (AND/OR/NOT in capitals are operators) and without a
        // leading "-" (which means NOT).
        .map((w) => w
            .toLowerCase()
            .replaceAll(RegExp(r'[^\p{L}\p{N}\x27-]', unicode: true), '')
            .replaceFirst(RegExp(r'^-+'), ''))
        .where((w) => w.isNotEmpty && !_stopWords.contains(w.toLowerCase()))
        .toList();
    if (words.isEmpty) return Future.value(const []);
    final all = words.join(' AND ');
    final codes = languages[language];
    return _archive(
      '$_base AND (title:($all) OR creator:($all))'
      '${codes == null ? '' : ' AND language:(${codes.join(' OR ')})'}',
      // Lower-cased so "Austen", " austen " and "austen" are one cache entry and
      // one origin request rather than three.
      cacheKey: 'search:${words.join(' ').toLowerCase()}:${language ?? ''}:$page',
      page: page,
    );
  }

  /// Words too common to require ("the", "of"): "the art of war" then means
  /// art AND war.
  static const Set<String> _stopWords = {
    'the', 'a', 'an', 'of', 'and', 'or', 'not', 'to', 'in', 'on', 'by', 'for', 'with',
  };

  /// Everything recorded of one author, most listened first.
  static Future<List<Audiobook>> byAuthor(String author, {int page = 1}) {
    final a = _clean(author);
    if (a.isEmpty) return Future.value(const []);
    return _archive('$_base AND creator:("$a")',
        cacheKey: 'author:${a.toLowerCase()}:$page', page: page);
  }

  /// Double quotes delimit a phrase and a backslash escapes, so either would
  /// break the query. Stripped rather than escaped: no real title or genre needs
  /// them to be found, and a malformed query returns nothing with no clue why.
  static String _clean(String s) =>
      s.replaceAll('"', ' ').replaceAll(r'\', ' ').replaceAll(RegExp(r'[()\[\]{}:^~*?]'), ' ').trim();

  static Future<List<Audiobook>> _archive(
    String query, {
    required String cacheKey,
    int page = 1,
    String? sort = '-downloads',
  }) async {
    final hit = _listCache[cacheKey];
    if (hit != null) return hit;

    // Built once so the Worker and the direct path send an identical string,
    // which is what makes the edge cache key stable.
    final qs = 'q=${Uri.encodeQueryComponent(query)}'
        '&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=downloads'
        '&fl[]=runtime&fl[]=language&fl[]=avg_rating&fl[]=num_reviews'
        '${sort == null ? '' : '&sort[]=${Uri.encodeQueryComponent(sort)}'}'
        '&rows=$pageSize&page=$page&output=json';
    final body = await _fetchSearch(qs);
    if (body == null) throw const AudiobookUnavailable();
    final books = await compute(_parseArchive, body);
    _listCache[cacheKey] = books;
    while (_listCache.length > _maxCachedLists) {
      _listCache.remove(_listCache.keys.first);
    }
    return books;
  }

  /// One book with its description and playable chapters, from the item's own
  /// metadata (one request): the files are there, the durations are exact, and
  /// it works for a book known only by id (a chapter in the queue, a saved book).
  static Future<Audiobook?> details(String id, {Audiobook? listed}) async {
    if (id.isEmpty) return listed;
    final hit = _bookCache[id];
    if (hit != null) return hit;
    try {
      final res = await _http
          .get(Uri.parse('https://archive.org/metadata/$id'),
              headers: const {'User-Agent': 'Auvy/1.0'})
          .timeout(_timeout);
      if (res.statusCode != 200) {
        print('Archive metadata returned ${res.statusCode} for $id');
        return listed;
      }
      final parsed = await compute(_parseItem, (id, res.body));
      if (parsed == null) return listed;
      // A listing knows the rating; the item knows the description and files.
      final book = listed == null
          ? parsed
          : listed.copyWith(
              chapters: parsed.chapters,
              description: parsed.description.isNotEmpty ? parsed.description : null,
              totalTime: listed.totalTime > Duration.zero ? null : parsed.totalTime,
            );
      if (book.chapters.isNotEmpty) {
        _bookCache[id] = book;
        while (_bookCache.length > _maxCachedBooks) {
          _bookCache.remove(_bookCache.keys.first);
        }
      }
      return book;
    } catch (e) {
      print('Book details failed for $id: $e');
      return listed;
    }
  }

  /// Genres chosen because the Archive's `subject:` index returns results for
  /// them (many LibriVox genre names return almost nothing):
  ///
  ///   Horror & Supernatural →    0      Horror     →  264  (Frankenstein)
  ///   Crime & Mystery       →    2      Mystery    →  867  (Sherlock Holmes)
  ///   Action & Adventure    →   10      Adventure  → 1139  (Sherlock Holmes)
  ///   Humorous Fiction      →    5      Fiction    → 3057  (Alice in Wonderland)
  ///
  /// Each term below returns results and leads with a recognisable book. Check
  /// both before adding more.
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
    _bookCache.clear();
  }
}

/// The catalogue could not be reached (as opposed to "no books match").
class AudiobookUnavailable implements Exception {
  const AudiobookUnavailable();
  @override
  String toString() => 'audiobook catalogue unreachable';
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

Audiobook? _parseItem((String, String) args) {
  final (id, body) = args;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final md = decoded['metadata'];
    final book = md is Map ? Audiobook.fromMetadata(id, Map<String, dynamic>.from(md)) : null;
    if (book == null) return null;
    return book.copyWith(chapters: parseChapters(Map<String, dynamic>.from(decoded)));
  } catch (_) {
    return null;
  }
}

/// The playable chapters in an item's metadata, in reading order.
@visibleForTesting
List<AudiobookChapter> parseChapters(Map<String, dynamic> decoded) {
  final files = decoded['files'];
  if (files is! List) return const [];
  // `server` + `dir` build the direct file URL. Using them rather than the
  // /download/ redirect saves a hop per chapter and gives the player a URL that
  // supports range requests, which seeking within a fifty-minute chapter needs.
  final server = (decoded['server'] ?? 'archive.org').toString();
  final dir = (decoded['dir'] ?? '').toString();

  List<(Map, String)> pick(bool Function(String format, String name) want) => [
        for (final f in files)
          if (f is Map)
            if (want((f['format'] ?? '').toString().toLowerCase(), (f['name'] ?? '').toString()))
              (f, (f['name'] ?? '').toString())
      ];
  // 64kbps MP3 is the format LibriVox always produces and the smallest that is
  // pleasant for speech. Preferring one format also stops the same chapter
  // appearing three times (the Archive keeps several encodings per item).
  var chosen = pick((format, name) =>
      format.contains('64kbps mp3') ||
      (format.contains('mp3') && name.toLowerCase().contains('_64kb')));
  // Nothing in the preferred format: any MP3 rather than an empty book.
  if (chosen.isEmpty) chosen = pick((_, name) => name.toLowerCase().endsWith('.mp3'));

  // File order in the metadata is not guaranteed to be reading order. The track
  // number is when present; otherwise the filenames carry the sequence.
  int track(Map f) => int.tryParse((f['track'] ?? '').toString().split('/').first) ?? 1 << 20;
  chosen.sort((a, b) {
    final t = track(a.$1).compareTo(track(b.$1));
    return t != 0 ? t : a.$2.compareTo(b.$2);
  });
  return [
    for (var i = 0; i < chosen.length; i++)
      AudiobookChapter(
        title: _chapterTitle(chosen[i].$1, chosen[i].$2),
        streamUrl: 'https://$server$dir/${Uri.encodeComponent(chosen[i].$2)}',
        duration: Audiobook.parseLength(chosen[i].$1['length']),
        index: i,
      )
  ];
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
