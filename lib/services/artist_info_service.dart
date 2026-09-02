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

  /// How many artists may be held in the prefs cache at once.
  ///
  /// THIS CACHE HAD A TTL BUT NO CEILING AND NO PRUNING. Every artist ever
  /// opened wrote TWO SharedPreferences keys — the payload and a `_ts` — kept for
  /// 30 days and never removed. SharedPreferences is read WHOLLY INTO MEMORY at
  /// launch, so browsing a few hundred artists grows the on-disk file AND every
  /// subsequent cold start. A slow leak rather than a visible one, which is
  /// exactly why it survived: nothing ever looked broken.
  ///
  /// A bio is a KB or two, so this ceiling is generous in practice while still
  /// being a ceiling.
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

  // This check used to pass film pages.
  //
  // Reported live: opening Jennifer Lopez showed a bio about a film she is in.
  // The old test asked "does this text MENTION music words" and ran it over the
  // page summary, so a film synopsis reading "…starring singer Jennifer
  // Lopez…" sailed through. The old list also held 'artist', 'music' and
  // 'producer', which appear in most film summaries ever written.
  //
  // The fix is to judge the page's TYPE, not its vocabulary. Wikipedia's
  // `description` field is exactly that: "American singer and actress" versus
  // "2025 American film". So: reject anything whose description names a work,
  // and require the description itself to describe a musician.
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
    // 'artist_bio_' (not the old 'wiki_bio_') so Wikipedia-era cache entries
    // don't block the Last.fm upgrade for 30 days.
    // v2. Entries written before this fix hold film bios, and before the
    // Last.fm key was actually passed at build time they hold Wikipedia
    // fallbacks that should never have been reached. Both would be served for
    // 30 more days under the old key.
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

  /// An artist PORTRAIT from Deezer.
  ///
  /// WHY NOT WIKIPEDIA. Wikipedia is a general encyclopedia, so a search for
  /// "Jennifer Lopez" can legitimately return a film she is in, which is
  /// exactly what happened on device. No amount of keyword filtering makes a
  /// general index music-only; the failure is structural.
  ///
  /// Deezer's catalogue contains nothing BUT music, so /search/artist cannot
  /// return a film, a book or a town. It needs no key, and the app already
  /// consumes Deezer images elsewhere (AuvyImage understands dzcdn URLs).
  ///
  /// The name is still verified against the result — a search engine will
  /// happily return its best guess for a misspelling, and a confident portrait
  /// of the wrong person is worse than none.
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
      // ONE LINE PER REAL REQUEST, and it earns its place: this is the fallback
      // portrait, so a healthy session should show it rarely — only for artists
      // YouTube has no channel picture for. The artist page used to fire it on
      // EVERY open (watched while the primary was still loading) and sometimes
      // twice for one artist (the family key changed when the resolved name
      // arrived). Neither was visible from the outside; a request that is thrown
      // away looks exactly like no request at all.
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
          // d41d8cd98f00b204e9800998ecf8427e is the MD5 of an EMPTY STRING —
          // Deezer's stand-in for an artist with no photo. It comes back as a
          // perfectly valid-looking URL and renders a grey silhouette. Observed
          // live as the second hit for Jennifer Lopez, Beyoncé and The Weeknd,
          // so an exact name match is NOT enough on its own. Nothing beats a
          // stock avatar, so keep looking.
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

    // EXACT TITLE FIRST. The old order ran the fuzzy music-word scan first,
    // so for "Jennifer Lopez" a film page that merely mentioned a singer beat
    // the page actually titled "Jennifer Lopez". An exact title match on a
    // person's name is the strongest signal available here.
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
