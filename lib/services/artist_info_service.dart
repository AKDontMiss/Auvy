import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/artist_metadata_service.dart';
import 'package:auvy/services/http_pool.dart';

/// An externally-sourced artist bio, used when YouTube Music's "About" blurb
/// is missing or thin. Last.fm is the primary source (music-specific, already
/// keyed); Wikipedia's lead summary is the fallback.
class WikiBio {
  final String extract;
  final String pageUrl;
  final String source; // 'Last.fm' | 'Wikipedia'

  /// Wikipedia's page thumbnail — a PORTRAIT of the person, when the page has
  /// one. Carried so the artist page has something real to show other than the
  /// track's album art. Empty for Last.fm bios.
  final String imageUrl;

  const WikiBio(
      {required this.extract,
      required this.pageUrl,
      this.source = 'Wikipedia',
      this.imageUrl = ''});

  Map<String, dynamic> toMap() => {
        'extract': extract,
        'pageUrl': pageUrl,
        'source': source,
        'imageUrl': imageUrl,
      };
  factory WikiBio.fromMap(Map<String, dynamic> m) => WikiBio(
        extract: (m['extract'] ?? '').toString(),
        pageUrl: (m['pageUrl'] ?? '').toString(),
        source: (m['source'] ?? 'Wikipedia').toString(),
        imageUrl: (m['imageUrl'] ?? '').toString(),
      );
}

class ArtistInfoService {
  ArtistInfoService._();
  static final instance = ArtistInfoService._();

  static const _cacheTtl = Duration(days: 30);

  /// How many artists the prefs cache may hold. Each artist adds two
  /// SharedPreferences keys (payload and timestamp), and prefs are loaded into
  /// memory at every launch, so without a ceiling and pruning the file grew with
  /// every artist ever opened. A bio is a KB or two, so 200 is generous.
  static const int _maxCachedArtists = 200;

  /// Prefixes this service owns, each paired with a `<key>_ts` sibling.
  static const List<String> _cachePrefixes = [
    'artist_bio_v2_',
    'artist_portrait_',
  ];

  /// Drop the OLDEST cached artists once [_maxCachedArtists] is exceeded.
  ///
  /// Oldest by the entry's own `_ts`, so what survives is what the user keeps
  /// coming back to. Only walks the keys when the ceiling is actually crossed, so
  /// the ordinary write path pays nothing. Deliberately best-effort: failing to
  /// prune must never fail the write that triggered it.
  static Future<void> _pruneCache(SharedPreferences prefs) async {
    try {
      for (final prefix in _cachePrefixes) {
        // The payload keys only — the `_ts` siblings are removed alongside their
        // own payload, never counted as entries of their own.
        final keys = prefs
            .getKeys()
            .where((k) => k.startsWith(prefix) && !k.endsWith('_ts'))
            .toList();
        if (keys.length <= _maxCachedArtists) continue;
        keys.sort((a, b) {
          final ta = prefs.getInt('${a}_ts') ?? 0;
          final tb = prefs.getInt('${b}_ts') ?? 0;
          return ta.compareTo(tb); // oldest first
        });
        final doomed = keys.take(keys.length - _maxCachedArtists);
        for (final k in doomed) {
          await prefs.remove(k);
          await prefs.remove('${k}_ts');
        }
      }
    } catch (_) {}
  }

  // Judge the page's type, not its vocabulary: a film synopsis ("…starring
  // singer Jennifer Lopez…") mentions music words too. Wikipedia's `description`
  // field describes the subject ("American singer and actress" vs "2025 American
  // film"), so reject descriptions naming a work and require one that describes
  // a musician.
  static const _musicMarkers = [
    'singer', 'musician', 'band', 'rapper', 'songwriter', 'composer',
    'vocalist', 'duo', 'dj ', 'record producer', 'girl group', 'boy band',
  ];

  /// If the page describes a WORK rather than a person, it is the wrong page —
  /// however many times it says "music".
  static const _notAnArtist = [
    'film', 'movie', 'album', 'song', 'single by', 'soundtrack', 'tv series',
    'television series', 'video game', 'novel', 'book', 'documentary',
    'episode', 'season', 'tour', 'musical', 'play by', 'company',
  ];

  static bool _describesAWork(String description) =>
      _notAnArtist.any(description.contains);

  static bool _describesAnArtist(String description) =>
      _musicMarkers.any(description.contains);

  /// Artist bio for [artistName] — Last.fm first, Wikipedia fallback — or
  /// null when nothing relevant is found. Cached for 30 days ('' cached too,
  /// so misses aren't re-queried).
  Future<WikiBio?> getWikiBio(String artistName) async {
    final name = artistName.trim();
    if (name.isEmpty || name == 'Artist' || name == 'Unknown') return null;

    final prefs = await SharedPreferences.getInstance();
    // 'artist_bio_' (not 'wiki_bio_') so Wikipedia-era entries don't block the
    // Last.fm upgrade. v2 retires entries that could hold film bios or Wikipedia
    // fallbacks from before the Last.fm key was configured.
    final cacheKey = 'artist_bio_v2_${name.toLowerCase()}';
    final ts = prefs.getInt('${cacheKey}_ts');
    if (ts != null &&
        DateTime.now().millisecondsSinceEpoch - ts < _cacheTtl.inMilliseconds) {
      final raw = prefs.getString(cacheKey);
      if (raw == null || raw.isEmpty) return null; // cached miss
      try {
        return WikiBio.fromMap(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }

    WikiBio? bio;
    try {
      // Primary: Last.fm — music-specific, no disambiguation problem.
      final lfmBio = await ArtistMetadataService().getArtistBio(name);
      if (lfmBio != null) {
        bio = WikiBio(
          extract: lfmBio,
          pageUrl: 'https://www.last.fm/music/${Uri.encodeComponent(name)}',
          source: 'Last.fm',
        );
      } else {
        bio = await _fetch(name);
      }
    } catch (_) {
      // Network failure: don't cache, retry next visit.
      return null;
    }
    await prefs.setString(cacheKey, bio == null ? '' : jsonEncode(bio.toMap()));
    await prefs.setInt('${cacheKey}_ts', DateTime.now().millisecondsSinceEpoch);
    await _pruneCache(prefs);
    return bio;
  }

  /// An artist portrait from Deezer. Deezer's catalogue contains only music, so
  /// /search/artist can't return a film, book or town (Wikipedia, a general
  /// encyclopedia, can). It needs no key, and AuvyImage already handles Deezer
  /// image URLs. The name is still checked against the result, since a wrong
  /// portrait is worse than none.
  Future<String> getPortrait(String artistName) async {
    final name = artistName.trim();
    if (name.isEmpty || name == 'Artist' || name == 'Unknown') return '';

    final prefs = await SharedPreferences.getInstance();
    final key = 'artist_portrait_${name.toLowerCase()}';
    final ts = prefs.getInt('${key}_ts');
    if (ts != null &&
        DateTime.now().millisecondsSinceEpoch - ts < _cacheTtl.inMilliseconds) {
      return prefs.getString(key) ?? '';
    }

    String found = '';
    try {
      // One line per real request: this is the fallback portrait, only needed for
      // artists without a YouTube channel picture, so it should be rare.
      print('artist portrait: asking Deezer for "$name" '
          '(no YouTube channel picture)');
      final uri = Uri.https('api.deezer.com', '/search/artist',
          {'q': name, 'limit': '5'});
      final res = await HttpPool().getClient().get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = (jsonDecode(res.body)['data'] as List?) ?? const [];
        final want = _normalise(name);
        for (final a in data) {
          if (_normalise((a['name'] ?? '').toString()) != want) continue;
          // picture_xl is 1000x1000; the smaller keys are thumbnails.
          final pic = (a['picture_xl'] ?? a['picture_big'] ?? '').toString();
          // d41d8cd98f00b204e9800998ecf8427e is the MD5 of an empty string: Deezer's
          // placeholder for an artist without a photo. It looks like a valid URL but
          // renders a grey silhouette, so an exact name match isn't enough; keep looking.
          if (pic.isNotEmpty &&
              !pic.contains('d41d8cd98f00b204e9800998ecf8427e')) {
            found = pic;
            break;
          }
        }
      }
    } catch (_) {
      // Network failure: do not cache, try again next visit.
      return '';
    }

    await prefs.setString(key, found);
    await prefs.setInt('${key}_ts', DateTime.now().millisecondsSinceEpoch);
    await _pruneCache(prefs);
    return found;
  }

  /// Case, accents and punctuation removed, so "Beyonce" matches "Beyoncé" and
  /// "P!nk" matches "Pink" without matching a different artist entirely.
  static String _normalise(String s) {
    const from = 'àáâãäåèéêëìíîïòóôõöùúûüçñ';
    const to = 'aaaaaaeeeeiiiiooooouuuucn';
    var out = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      out = out.replaceAll(from[i], to[i]);
    }
    return out.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<WikiBio?> _fetch(String name) async {
    // 1. Title search (biased toward music) → best-matching page key.
    final searchUri = Uri.https('en.wikipedia.org', '/w/rest.php/v1/search/page',
        {'q': name, 'limit': '3'});
    final searchRes =
        await HttpPool().getClient().get(searchUri).timeout(const Duration(seconds: 8));
    if (searchRes.statusCode != 200) return null;
    final pages = (jsonDecode(searchRes.body)['pages'] as List?) ?? const [];
    if (pages.isEmpty) return null;

    // Exact title first: a page titled exactly with the artist's name is the
    // strongest signal, and must beat a page that merely mentions a singer.
    String? key;
    for (final p in pages) {
      final title = (p['title'] ?? '').toString().toLowerCase();
      final desc = (p['description'] ?? '').toString().toLowerCase();
      if (title == name.toLowerCase() && !_describesAWork(desc)) {
        key = (p['key'] ?? '').toString();
        break;
      }
    }
    // Otherwise the best page whose DESCRIPTION says "musician" and does not say
    // "film" — covers disambiguated titles like "Sting (musician)".
    key ??= () {
      for (final p in pages) {
        final desc = (p['description'] ?? '').toString().toLowerCase();
        if (_describesAnArtist(desc) && !_describesAWork(desc)) {
          return (p['key'] ?? '').toString();
        }
      }
      return null;
    }();
    if (key == null || key.isEmpty) return null;

    // 2. Lead summary of that page.
    final sumUri =
        Uri.https('en.wikipedia.org', '/api/rest_v1/page/summary/$key');
    final sumRes = await HttpPool().getClient().get(sumUri).timeout(const Duration(seconds: 8));
    if (sumRes.statusCode != 200) return null;
    final data = jsonDecode(sumRes.body) as Map<String, dynamic>;
    final extract = (data['extract'] ?? '').toString().trim();
    if (extract.length < 60) return null;

    // Judge the DESCRIPTION, not the prose. A film summary mentioning a singer
    // is still a film; "2025 American film" is disqualifying on its own.
    final desc = (data['description'] ?? '').toString().toLowerCase();
    if (_describesAWork(desc)) return null;
    // The description is usually present and decisive. When it is missing, fall
    // back to the lead sentence, which for a person reads "… is an American
    // singer …", but only the FIRST sentence, so a later mention of a film
    // cannot rescue the wrong page.
    if (!_describesAnArtist(desc)) {
      final firstSentence =
          extract.split(RegExp(r'(?<=\.)\s')).first.toLowerCase();
      if (!_describesAnArtist(firstSentence)) return null;
    }

    final pageUrl =
        (data['content_urls']?['desktop']?['page'] ?? '').toString();
    // Portrait, if the page has one. See WikiBio.imageUrl.
    final thumb = (data['thumbnail']?['source'] ?? '').toString();
    return WikiBio(extract: extract, pageUrl: pageUrl, imageUrl: thumb);
  }
}

/// Portrait for an artist, from a MUSIC-ONLY catalogue. See getPortrait.
final artistPortraitProvider =
    FutureProvider.family<String, String>((ref, artistName) {
  return ArtistInfoService.instance.getPortrait(artistName);
});

/// Family keyed on the artist NAME. keepAlive is fine — results are tiny and
/// prefs-cached anyway.
final artistWikiBioProvider =
    FutureProvider.family<WikiBio?, String>((ref, artistName) {
  return ArtistInfoService.instance.getWikiBio(artistName);
});
