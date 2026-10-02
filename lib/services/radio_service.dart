import 'dart:convert';
import 'package:flutter/foundation.dart'; //  Needed for compute()
import '../data/radio_station_model.dart';
import 'package:auvy/services/updater_service.dart' show UpdaterService;
import 'package:auvy/services/http_pool.dart';

/// One country in the radio directory, with how many stations it actually has.
class RadioCountry {
  final String name;
  final String code;
  final int stationCount;
  const RadioCountry({
    required this.name,
    required this.code,
    required this.stationCount,
  });
}

class RadioService {
  /// Mirrors, all equal. radio-browser is a volunteer network whose individual
  /// mirrors go down, rate-limit or answer slowly. Every call walks the list until
  /// one answers (with a timeout), and the first working mirror is remembered for
  /// the session.
  static const List<String> _mirrors = [
    'https://de1.api.radio-browser.info/json',
    'https://at1.api.radio-browser.info/json',
    'https://nl1.api.radio-browser.info/json',
    'https://fi1.api.radio-browser.info/json',
  ];
  static int _preferredMirror = 0;

  static const Duration _timeout = Duration(seconds: 12);

  /// GETs [path] through the Worker when possible, directly as a fallback.
  ///
  /// The directories are the same for every user, so the Worker caches them at the
  /// edge: one Worker finds a healthy mirror and everyone gets the cached answer,
  /// instead of each phone walking the mirrors (up to 4 × 12 s on a bad day). The
  /// direct path stays so a broken route can't take radio down.
  Future<String?> _get(String path) async {
    try {
      final res = await HttpPool().getClient().get(
        Uri.parse('https://${UpdaterService.updateHost}/radio'
            '?path=${Uri.encodeQueryComponent(path)}'),
        headers: const {'User-Agent': 'Auvy/1.0'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
    } catch (_) {
      // Fall through to the mirrors below.
    }
    return _getDirect(path);
  }

  /// The original mirror walk. Reached only when the Worker cannot answer.
  Future<String?> _getDirect(String path) async {
    for (int i = 0; i < _mirrors.length; i++) {
      final idx = (_preferredMirror + i) % _mirrors.length;
      try {
        final res = await HttpPool().getClient().get(
          Uri.parse('${_mirrors[idx]}$path'),
          // radio-browser asks for an identifying UA and rate-limits requests
          // that do not send one.
          headers: const {'User-Agent': 'Auvy/1.0'},
        ).timeout(_timeout);
        if (res.statusCode == 200) {
          _preferredMirror = idx; // stick with whatever is healthy today
          return res.body;
        }
      } catch (_) {
        // try the next mirror
      }
    }
    return null;
  }

  /// Every country radio-browser knows, with its real station count, from the
  /// country index. (Deriving countries from the globally most-clicked stations
  /// left smaller countries nearly empty.) Each country's stations are fetched
  /// when it's opened.
  Future<List<RadioCountry>> getCountries() async {
    final body = await _get('/countries');
    if (body == null) return [];
    try {
      final List data = jsonDecode(body);
      final out = <RadioCountry>[];
      for (final c in data) {
        final name = (c['name'] ?? '').toString().trim();
        final count = (c['stationcount'] ?? 0) as int;
        // Junk entries: radio-browser's country field is user-submitted, so it
        // carries blanks and one-off typos with a single station behind them.
        if (name.isEmpty || name.length < 2 || count < 1) continue;
        out.add(RadioCountry(
          name: name,
          code: (c['iso_3166_1'] ?? '').toString(),
          stationCount: count,
        ));
      }
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } catch (e) {
      return [];
    }
  }

  /// The top stations in one country. Ranked by [order]: `clickcount` is the
  /// last 24 hours of listening (what is popular now), `votes` the all-time
  /// favourites. 400 is a browse depth: the biggest markets have thousands, and
  /// anything further down is reached by searching.
  Future<List<RadioStation>> getByCountry(String country,
      {int limit = 400, String order = 'clickcount'}) async {
    final body = await _get(
      '/stations/bycountryexact/${Uri.encodeComponent(country)}'
      '?limit=$limit&hidebroken=true&order=$order&reverse=true',
    );
    if (body == null) return [];
    return compute(_parseAndDeduplicateStatic, body);
  }

  /// What is popular now in the country with ISO code [code] (the listener's,
  /// for the hub). Through the search endpoint, which the Worker caches.
  Future<List<RadioStation>> getHotInCountryCode(String code, {int limit = 30}) async {
    final body = await _get('/stations/search?countrycode=${Uri.encodeComponent(code)}'
        '&limit=$limit&hidebroken=true&order=clickcount&reverse=true');
    if (body == null) return [];
    return compute(_parseAndDeduplicateStatic, body);
  }

  /// What is popular now in one genre (a tag), worldwide.
  Future<List<RadioStation>> getHotByTag(String tag, {int limit = 120}) async {
    final body = await _get('/stations/search?tag=${Uri.encodeComponent(tag)}'
        '&limit=$limit&hidebroken=true&order=clickcount&reverse=true');
    if (body == null) return [];
    return compute(_parseAndDeduplicateStatic, body);
  }

  /// The global chart (most listened in the last 24 hours).
  Future<List<RadioStation>> getTrendingStations({int limit = 300}) async {
    final body = await _get('/stations/topclick?limit=$limit&hidebroken=true');
    if (body == null) return [];
    return compute(_parseAndDeduplicateStatic, body);
  }

  /// Free-text search across the whole database, optionally within a country.
  ///
  /// `name` alone misses stations whose genre is what you typed, so a tag pass
  /// runs too and the two are merged — searching "jazz" should find jazz
  /// stations, not only stations with "jazz" in their name.
  Future<List<RadioStation>> searchStations({
    String query = '',
    String country = '',
    int limit = 300,
  }) async {
    final q = query.trim();
    String base = '?limit=$limit&hidebroken=true&order=votes&reverse=true';
    if (country.isNotEmpty) base += '&country=${Uri.encodeComponent(country)}';

    final byName = q.isEmpty ? base : '$base&name=${Uri.encodeComponent(q)}';
    final results = <RadioStation>[];
    final seen = <String>{};

    final nameBody = await _get('/stations/search$byName');
    if (nameBody != null) {
      for (final s in await compute(_parseAndDeduplicateStatic, nameBody)) {
        if (seen.add(s.urlResolved)) results.add(s);
      }
    }
    if (q.isNotEmpty) {
      final tagBody =
          await _get('/stations/search$base&tag=${Uri.encodeComponent(q)}');
      if (tagBody != null) {
        for (final s in await compute(_parseAndDeduplicateStatic, tagBody)) {
          if (seen.add(s.urlResolved)) results.add(s);
        }
      }
    }
    return results;
  }
}

//  Moved OUTSIDE the class so compute() can access it on a separate thread
List<RadioStation> _parseAndDeduplicateStatic(String jsonString) {
  final List data = jsonDecode(jsonString);
  final Set<String> uniqueStreamUrls = {};
  final List<RadioStation> finalStations = [];

  for (var item in data) {
    final station = RadioStation.fromJson(item);

    if (!uniqueStreamUrls.contains(station.urlResolved) && station.urlResolved.isNotEmpty) {
      uniqueStreamUrls.add(station.urlResolved);
      finalStations.add(station);
    }
  }
  return finalStations;
}
