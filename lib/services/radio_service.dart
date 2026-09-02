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
  /// MIRRORS, not a primary and a spare
  ///
  /// radio-browser is a volunteer network: individual mirrors go down, rate
  /// limit, or answer slowly, and which one is healthy changes week to week.
  /// The old code tried de1 and fell back to at1 only when de1 THREW — a mirror
  /// answering 500, or hanging past a sane wait, produced an empty page with no
  /// second attempt.
  ///
  /// Now every call walks the list until one answers, with a timeout, and the
  /// first mirror that works is remembered for the rest of the session so the
  /// dead one is not retried on every request.
  static const List<String> _mirrors = [
    'https://de1.api.radio-browser.info/json',
    'https://at1.api.radio-browser.info/json',
    'https://nl1.api.radio-browser.info/json',
    'https://fi1.api.radio-browser.info/json',
  ];
  static int _preferredMirror = 0;

  static const Duration _timeout = Duration(seconds: 12);

  /// GET [path], through the Worker when it can, direct as a fallback.
  ///
  /// THE WORKER FIRST, BUT NEVER THE ONLY WAY. These directories are
  /// IDENTICAL for every user — nobody gets a personalised "stations in Germany,
  /// most-voted first", so fetching them per device is the same bytes travelling
  /// many times over, from a volunteer-run service.
  ///
  /// It also fixes a real wait. The mirror walk below tries four hosts with a
  /// 12-second timeout each, so on a bad day a phone can spend up to 48 seconds
  /// on a spinner, and every device rediscovers the same outage on its own. At
  /// the edge one Worker finds the healthy mirror and everyone gets the answer
  /// from cache.
  ///
  /// The direct path is deliberately KEPT. Routing through the Worker makes it a
  /// single point of failure for radio, and radio should not stop working because
  /// one Cloudflare route is misdeployed, which is exactly what happened to
  /// /covers today. Worker first, mirrors if it cannot answer.
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

  /// Every country radio-browser knows, with its real station count.
  ///
  /// THIS IS WHY COUNTRIES LOOKED EMPTY. The hub used to derive its country
  /// list from `/topclick?limit=3000` — the 3000 most-clicked stations ON EARTH.
  /// Large markets fill that list, so a smaller country showed one or two
  /// stations (the couple that charted globally) or vanished entirely, even
  /// though the database holds dozens. The directory is now built from the
  /// country index, and each country's stations are fetched when it is opened.
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

  /// Stations for ONE country, most-voted first.
  /// The top stations in a country, votes first.
  ///
  /// 400 is a browse depth, not the whole country: the biggest markets run into
  /// the thousands and nobody scrolls a section that far. A station past #400 is
  /// reached by SEARCHING for it, which queries the directory by name and tag
  /// rather than this list.
  Future<List<RadioStation>> getByCountry(String country, {int limit = 400}) async {
    final body = await _get(
      '/stations/bycountryexact/${Uri.encodeComponent(country)}'
      '?limit=$limit&hidebroken=true&order=votes&reverse=true',
    );
    if (body == null) return [];
    return compute(_parseAndDeduplicateStatic, body);
  }

  /// The global chart — still used for the "Popular" section at the top of the
  /// hub, which is a genuinely different question from "what is on in Sweden".
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
