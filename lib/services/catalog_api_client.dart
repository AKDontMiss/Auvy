import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/services/catalog_api_clients.dart';
import 'package:auvy/services/catalog_api_parser.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/core/cache/lru_cache.dart';
import 'package:auvy/core/net/rate_limiter.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/logic/adaptive_bitrate.dart';

/// Transport layer for YouTube's private InnerTube API.
///
///   * Posts to the right endpoint with the right client context and headers
///     (WEB_REMIX at music.youtube.com for the catalogue; ANDROID/IOS-family
///     clients for the player).
///   * Adds the signed-in user's cookies and SAPISIDHASH where useful, so
///     personal and age-gated content is reachable. Guest requests send no auth.
///   * Paces requests through a shared [RateLimiter] and caches metadata in a
///     shared [LruCache].
///   * Decodes large catalogue responses on a background isolate (`compute`) so
///     big JSON never blocks the UI thread.
///
/// Heavy state is `static`, so the many `CatalogApiClient()` call sites share one
/// client, cache and limiter.
class CatalogApiClient {
  static final RateLimiter _limiter =
      RateLimiter(minInterval: const Duration(milliseconds: 220), burst: 5);
  static final LruCache<String, Map<String, dynamic>> _metaCache =
      LruCache<String, Map<String, dynamic>>(maxEntries: 120, defaultTtl: const Duration(minutes: 30));
  // Don't add in-flight de-duplication (sharing one Future between identical
  // requests) without a re-entrancy guard and a timeout. It was tried and froze
  // the app: if anything inside a deduped fetch asks for the same key again (a
  // retry, a fallback), it waits on its own future forever, with no error.

  /// The shared pooled client, so catalogue traffic (search, browse, home, player)
  /// is counted in Settings → data usage.
  ///
  /// A getter, not `static final`: HttpPool replaces its client with a
  /// data-tracking wrapper when `attachDataTracker` runs (see main_layout), and a
  /// captured reference would keep the unwrapped client forever. Every call site
  /// passes its own headers, so the client is pure transport.
  static http.Client get _http => HttpPool().getClient();
  static String? _visitorData;

  /// Set when every client just refused, so the next response may replace the
  /// visitor id instead of being ignored.
  ///
  /// Login-free player clients need a usable visitor id (see [_captureVisitor]),
  /// and a stale id gets the same refusals as none. The harvest skips responses
  /// while an id is held, and the id is persisted, so without this a stale id would
  /// survive forever. The id isn't dropped (a bare request is worse); the next
  /// response carrying a responseContext replaces it.
  static bool _visitorStale = false;

  // Tunable network budgets
  // These were hardcoded literals scattered across the methods below. An
  // interactive audio app must fail over FAST rather than hang, so they're
  // deliberately tight and now live in one place.
  static const Duration _catalogTimeout = Duration(seconds: 10); // search/browse/home/next
  static const Duration _playerTimeout  = Duration(seconds: 8);  // per player POST attempt
  static const Duration _probeTimeout   = Duration(seconds: 4);  // stream-URL validation probe
  static const int      _playerRetries  = 2;                     // attempts per stream client
  // Overall wall-clock budget to resolve ONE videoId across ALL stream clients.
  // Past this we stop trying further clients instead of hanging the UI. (Worst
  // case before: 5 clients x 3 retries x 12s ≈ 3 minutes on a flaky network.)
  static const Duration _resolveDeadline = Duration(seconds: 18);

  final SessionCookieManager _cookies = SessionCookieManager();

  /// No API key: the catalogue is reached with a visitor id and the session cookie.
  CatalogApiClient();

  /// Drop cached catalog responses + visitor id. Call on login/logout so
  /// personalized (or de-personalized) results are re-fetched immediately.
  static void clearCaches() {
    _metaCache.clear();
    _visitorData = null;
    // Clear the persisted copy too, or _ensureVisitor reads it back on the next
    // request and signing in or out can't get a fresh anonymous session.
    _visitorRestoreTried = false;
    SharedPreferences.getInstance().then((p) {
      p.remove(_kVisitorPref);
      p.remove(_kVisitorAtPref);
      return true;
    }).catchError((_) => false);
  }

  // Catalog: search / browse / next (WEB_REMIX @ music.youtube.com)

  Future<Map<String, dynamic>> search(String query, {String params = ''}) async {
    final key = 'search:$params:${query.toLowerCase().trim()}';
    final cached = _metaCache.get(key);
    if (cached != null) return cached;

    final body = await _postRaw(CatalogApiClients.webRemix, 'search', {
      'query': query,
      if (params.isNotEmpty) 'params': params,
    });
    final parsed = await compute(CatalogApiParser.decodeAndCollect, body);
    _captureVisitor(parsed);
    if ((parsed['items'] as List).isNotEmpty) _metaCache.put(key, parsed);
    return parsed;
  }

  /// [authenticated] sends the user's cookies + SAPISIDHASH — required for the
  /// PRIVATE library surfaces (FEmusic_liked_playlists, private playlists).
  /// Authed responses are user-specific and must be fresh, so they bypass the
  /// shared cache entirely.
  Future<Map<String, dynamic>> getBrowse(String browseId,
      {String params = '', int maxPages = 1, bool authenticated = false}) async {
    final key = 'browse:$browseId:$params:$maxPages';
    if (!authenticated) {
      final cached = _metaCache.get(key);
      if (cached != null) return cached;
    }

    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {
      'browseId': browseId,
      if (params.isNotEmpty) 'params': params,
    }, authenticated: authenticated);
    final parsed = await compute(CatalogApiParser.decodeAndCollect, body);
    _captureVisitor(parsed);

    // Long playlists arrive one ~100-row page at a time; a single browse call
    // silently truncates them. When the caller asks for more pages, follow the
    // continuation chain (bounded) and merge the rows, deduped by id.
    if (maxPages > 1) {
      final items = (parsed['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final seen = items.map((m) => '${m['id']}').toSet();
      var token = parsed['continuation'] as String?;
      var pages = 1;
      while (token != null && token.isNotEmpty && pages < maxPages) {
        Map<String, dynamic> more;
        try {
          more = await getBrowseContinuation(token, authenticated: authenticated);
        } catch (_) {
          break; // network hiccup — keep what we already have
        }
        var progressed = false;
        for (final raw in (more['items'] as List? ?? const [])) {
          final m = Map<String, dynamic>.from(raw as Map);
          if (seen.add('${m['id']}')) {
            items.add(m);
            progressed = true;
          }
        }
        final next = more['continuation'] as String?;
        if (!progressed || next == token) break; // no forward progress — stop
        token = next;
        pages++;
      }
      parsed['items'] = items;
      parsed['continuation'] = token;
    }

    if (!authenticated && (parsed['items'] as List).isNotEmpty) _metaCache.put(key, parsed);
    return parsed;
  }

  Future<Map<String, dynamic>> getBrowseContinuation(String continuationToken,
      {bool authenticated = false}) async {
    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {
      'continuation': continuationToken,
    }, authenticated: authenticated);
    final parsed = await compute(CatalogApiParser.decodeAndCollect, body);
    _captureVisitor(parsed);
    return parsed;
  }

  /// Search pagination — must be posted back to the `search` endpoint.
  Future<Map<String, dynamic>> searchContinuation(String continuationToken) async {
    final body = await _postRaw(CatalogApiClients.webRemix, 'search', {
      'continuation': continuationToken,
    });
    final parsed = await compute(CatalogApiParser.decodeAndCollect, body);
    _captureVisitor(parsed);
    return parsed;
  }

  Future<Map<String, dynamic>> getNext(String videoId, {String? playlistId, String? params}) async {
    final body = await _postRaw(CatalogApiClients.webRemix, 'next', {
      if (videoId.isNotEmpty) 'videoId': videoId,
      if (playlistId != null) 'playlistId': playlistId,
      if (params != null) 'params': params,
      'isAudioOnly': true,
    });
    final parsed = await compute(CatalogApiParser.decodeAndCollect, body);
    _captureVisitor(parsed);
    return parsed;
  }

  /// Real YouTube Music home feed (FEmusic_home) as titled carousels:
  /// `[{ title, items: [...] }]`. Guests get curated playlist carousels;
  /// logged-in users get personalized track shelves.
  Future<List<Map<String, dynamic>>> getHomeSections() async {
    const key = 'homesections';
    // _metaCache stores Map<String,dynamic>; the home feed is a List, so wrap it
    // under a 'sections' key on store and unwrap it on read (mirrors getBrowse /
    // getArtistPage caching but adapted to this method's List return type).
    final cached = _metaCache.get(key);
    if (cached != null) {
      return (cached['sections'] as List).cast<Map<String, dynamic>>();
    }

    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {'browseId': 'FEmusic_home'});
    final parsed = await compute(CatalogApiParser.decodeAndHome, body);
    _captureVisitor(parsed);
    final sections = (parsed['sections'] as List).cast<Map<String, dynamic>>();
    if (sections.isNotEmpty) _metaCache.put(key, {'sections': sections});
    return sections;
  }

  /// YouTube Music's own query completions for a partial search
  /// (`music/get_search_suggestions`, what the web client uses), including
  /// spelling recovery ("the week" → "the weeknd" and "the weekend").
  ///
  /// Cached, because it runs on every keystroke and prefixes repeat as the user
  /// edits. Callers must also debounce: the cache stops repeat requests, not first
  /// ones. Returns [] on any failure so typing is never interrupted.
  Future<List<String>> getSearchSuggestions(String input) async {
    final q = input.trim();
    if (q.isEmpty) return const [];
    final key = 'suggest:${q.toLowerCase()}';
    final cached = _metaCache.get(key);
    if (cached != null) {
      return (cached['suggestions'] as List).cast<String>();
    }
    try {
      final body = await _postRaw(
          CatalogApiClients.webRemix, 'music/get_search_suggestions', {
        'input': q,
      });
      final suggestions =
          await compute(CatalogApiParser.decodeAndSuggestions, body);
      if (suggestions.isNotEmpty) {
        _metaCache.put(key, {'suggestions': suggestions});
      }
      return suggestions;
    } catch (_) {
      return const [];
    }
  }

  /// Any YouTube Music browse feed, parsed with the same shelf reader as the home
  /// feed. Charts, New Releases and Moods & Genres share the `sectionListRenderer`
  /// → `musicCarouselShelfRenderer` shape, so they only differ by browseId.
  Future<List<Map<String, dynamic>>> getFeedSections(String browseId) async {
    final key = 'feed:$browseId';
    final cached = _metaCache.get(key);
    if (cached != null) {
      return (cached['sections'] as List).cast<Map<String, dynamic>>();
    }
    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {'browseId': browseId});
    final parsed = await compute(CatalogApiParser.decodeAndHome, body);
    _captureVisitor(parsed);
    final sections = (parsed['sections'] as List).cast<Map<String, dynamic>>();
    if (sections.isNotEmpty) _metaCache.put(key, {'sections': sections});
    return sections;
  }

  /// YouTube Music's real charts — Top Songs / Top Videos / Trending / Top
  /// Artists, localized to the account's region.
  Future<List<Map<String, dynamic>>> getCharts() => getFeedSections('FEmusic_charts');

  /// This week's new album + single releases.
  Future<List<Map<String, dynamic>>> getNewReleases() =>
      getFeedSections('FEmusic_new_releases_albums');

  /// The mood/genre grid ("Chill", "Commute", "Workout", "Focus", …).
  ///
  /// This feed can't use [getFeedSections]: `FEmusic_moods_and_genres` contains
  /// only `musicNavigationButtonRenderer` chips, which the shelf parser ignores.
  ///
  /// Each entry is `{title, browseId, params, color}`; `color` is an ARGB int from
  /// YouTube's `leftStripeColor`. Follow one with [getCategorySections] to list its
  /// playlists.
  Future<List<Map<String, dynamic>>> getMoodCategories() async {
    const key = 'moodcats';
    final cached = _metaCache.get(key);
    if (cached != null) {
      return (cached['items'] as List).cast<Map<String, dynamic>>();
    }
    final body =
        await _postRaw(CatalogApiClients.webRemix, 'browse', {'browseId': 'FEmusic_moods_and_genres'});
    final json = jsonDecode(body) as Map<String, dynamic>;
    _captureVisitor(json);

    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    // The buttons are nested a few levels deep and the exact path shifts between
    // API revisions, so walk the tree for the renderer instead of hardcoding it.
    // Each grid has a heading ("Moods & moments", "Genres"), carried down to its
    // buttons as their section.
    void walk(dynamic node, String section) {
      if (node is Map) {
        final grid = node['gridRenderer'];
        if (grid is Map) {
          final runs = ((((grid['header'] as Map?)?['gridHeaderRenderer'] as Map?)?['title']
              as Map?)?['runs']);
          final heading = (runs is List && runs.isNotEmpty)
              ? (runs.first as Map)['text']?.toString() ?? ''
              : '';
          if (heading.isNotEmpty) section = heading;
        }
        final btn = node['musicNavigationButtonRenderer'];
        if (btn is Map) {
          final runs = (btn['buttonText'] as Map?)?['runs'];
          final title = (runs is List && runs.isNotEmpty)
              ? (runs.first as Map)['text']?.toString() ?? ''
              : '';
          final endpoint =
              ((btn['clickCommand'] as Map?)?['browseEndpoint']) as Map?;
          final browseId = endpoint?['browseId']?.toString() ?? '';
          final params = endpoint?['params']?.toString() ?? '';
          final color = (btn['solid'] as Map?)?['leftStripeColor'];
          // Deduplicated on browseId + params: the same browseId serves several
          // categories and params choose between them. The tree walk (needed because the
          // button path shifts between API revisions) can reach one node twice.
          if (title.isNotEmpty && browseId.isNotEmpty && seen.add('$browseId|$params')) {
            out.add({
              'title': title,
              'browseId': browseId,
              'params': params,
              if (color is num) 'color': color.toInt(),
              if (section.isNotEmpty) 'section': section,
            });
          }
        }
        for (final v in node.values) {
          walk(v, section);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v, section);
        }
      }
    }

    walk(json, '');
    if (out.isNotEmpty) _metaCache.put(key, {'items': out});
    return out;
  }

  /// Playlist shelves inside one mood/genre category. Unlike the category GRID,
  /// these pages DO use the standard shelf renderers, so the shared home parser
  /// handles them — they just need the `params` alongside the browseId.
  Future<List<Map<String, dynamic>>> getCategorySections(
      String browseId, String params) async {
    final key = 'cat:$browseId:$params';
    final cached = _metaCache.get(key);
    if (cached != null) {
      return (cached['sections'] as List).cast<Map<String, dynamic>>();
    }
    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {
      'browseId': browseId,
      if (params.isNotEmpty) 'params': params,
    });
    final parsed = await compute(CatalogApiParser.decodeAndHome, body);
    _captureVisitor(parsed);
    final sections = (parsed['sections'] as List).cast<Map<String, dynamic>>();
    if (sections.isNotEmpty) _metaCache.put(key, {'sections': sections});
    return sections;
  }

  Future<Map<String, dynamic>> getArtistPage(String browseId) async {
    final key = 'artistpage:$browseId';
    final cached = _metaCache.get(key);
    if (cached != null) return cached;

    final body = await _postRaw(CatalogApiClients.webRemix, 'browse', {'browseId': browseId});
    final parsed = await compute(CatalogApiParser.decodeAndArtist, body);
    _captureVisitor(parsed);
    if ((parsed['sections'] as List?)?.isNotEmpty == true) _metaCache.put(key, parsed);
    return parsed;
  }

  /// The signed-in user's account profile from the authenticated
  /// `account/account_menu` endpoint. Returns `{name, email, handle, avatarUrl}`
  /// or null when the user isn't signed in / on failure. Used to register the
  /// cookie-based YouTube session in the app's account provider so the UI shows
  /// the logged-in user without a second (OAuth) prompt. Uses the
  /// `accountMenu` call.
  Future<Map<String, String>?> getAccountInfo() async {
    try {
      if (!await _cookies.hasAuthCookies()) return null;
      final body = await _postRaw(CatalogApiClients.webRemix, 'account/account_menu', const {},
          authenticated: true);
      final json = jsonDecode(body) as Map<String, dynamic>;
      return CatalogApiParser.parseAccountMenu(json);
    } catch (e) {
      print('WARN: account_menu failed: $e');
      return null;
    }
  }

  // Player / streaming (ANDROID primary, IOS fallback)

  /// Full resolve: a directly playable audio URL plus the matching user agent (the
  /// native player must send this UA or the CDN returns 403). Null if no client
  /// yields a playable stream.
  ///
  /// [maxBitrate] is the adaptive ceiling in bps (0 = uncapped), from measured
  /// throughput; it normally decides the format. [lowQuality] is the data saver's
  /// hard preference. [preferMp4] asks for AAC-in-MP4 so the file can carry tags
  /// and cover art; for downloads only (see [_bestAudioFormat]).
  ///
  /// [isStillWanted] is checked before each client; once the user has moved to
  /// another track the resolve stops and returns null without marking the visitor
  /// id stale, since a skip says nothing about the id.
  Future<Map<String, String>?> getStreamUrl(String videoId, {bool lowQuality = false, int clientStartIndex = 0, int maxBitrate = 0, bool preferMp4 = false, bool Function()? isStillWanted}) async {
    if (videoId.isEmpty || videoId.length != 11) return null;
    bool abandoned() => isStillWanted != null && !isStillWanted();

    // Stop trying further clients once the overall budget is spent, so a flaky
    // network can't stall a single play for minutes.
    final deadline = DateTime.now().add(_resolveDeadline);
    // clientStartIndex rotates which client is tried FIRST. On a persistent 403
    // (a format/PO-token-gated stream that re-fetching the SAME format can't
    // cure — e.g. a chunk mid-track keeps 403ing), the caller bumps this so we
    // resolve a DIFFERENT client/format instead of hammering the gated one.
    final order = CatalogApiClients.streamOrder;
    // Two passes at most. The first is GUEST and is the only one that normally
    // runs. The second attaches the user's session and only happens when the
    // whole guest chain came back with nothing. See the note below.
    for (int pass = 0; pass < 2; pass++) {
      final authed = pass == 1;
      if (authed) {
        // Last resort: some clients (ANDROID_VR, ANDROID_MUSIC, IOS_MUSIC) refuse guest
        // player requests, and signing the request is the only thing that could change
        // that. Only tried after the guest chain failed, because the player endpoint has
        // answered 400 to signed requests (see [_postPlayer]) and a signed request ties
        // the play to the account.
        if (!await _cookies.hasAuthCookies()) break;
        if (DateTime.now().isAfter(deadline)) break;
        print('guest chain exhausted — retrying once with the signed-in session');
      }
    for (int ci = 0; ci < order.length; ci++) {
      final client = order[(clientStartIndex + ci) % order.length];
      if (DateTime.now().isAfter(deadline)) {
        print('stream resolve deadline (${_resolveDeadline.inSeconds}s) hit — giving up on remaining clients');
        break;
      }
      // The user moved on. Every remaining request is spent on a track nobody
      // is waiting for, and its eventual failure must not be read as evidence
      // about the visitor id — so leave before the tail below runs.
      if (abandoned()) {
        print('stream resolve for $videoId abandoned — the track changed');
        return null;
      }
      try {
        final raw = await _postPlayer(client, videoId, authenticated: authed);
        final status = CatalogApiParser.playabilityStatus(raw);
        if (status != 'OK') {
          print('${client.clientName}: playability=$status');
          continue;
        }

        final fmt = _bestAudioFormat(raw,
            lowQuality: lowQuality, maxBitrate: maxBitrate, preferMp4: preferMp4);
        final url = (fmt?['url'] ?? '').toString();
        if (url.isEmpty) {
          print('${client.clientName}: OK but no direct audio URL');
          continue;
        }

        // Probe the URL with the same Range request ExoPlayer will send, so we
        // never hand the player a URL that 403s (e.g. an IP/age-gated client).
        // Falls through to the next client on failure.
        if (!await _validateStreamUrl(url, client.userAgent,
            contentLength: _audioContentLength(fmt!, url))) {
          print('${client.clientName}: URL failed playback probe (403/expired)');
          continue;
        }

        print('${client.clientName}: stream OK (${fmt['bitrate']} bps)');
        // Opportunistic: if a stream client ever returns the publish date, keep it.
        // None do today, so [getPublishDate] does its own WEB_REMIX lookup.
        final resolvedDate = _publishDateOf(raw);
        if (resolvedDate != null) cachePublishDate(videoId, resolvedDate);
        // Free: this response was fetched to play the track, and it carries the
        // play count that album and playlist rows have no other source for.
        final views = _viewCountOf(raw);
        if (views != null && views > 0) _viewCountCache.put(videoId, views);
        return {
          'url': url,
          'userAgent': client.userAgent,
          'clientName': client.clientName,
          'mimeType': (fmt['mimeType'] ?? 'audio/mp4').toString(),
          'bitrate': (fmt['bitrate'] ?? 0).toString(),
          // Reported per format; surfaced so the details sheet can state the
          // stream's real properties rather than describe a setting.
          if (fmt['audioSampleRate'] != null)
            'sampleRate': fmt['audioSampleRate'].toString(),
          if (fmt['audioChannels'] != null)
            'channels': fmt['audioChannels'].toString(),
          'contentLength': _audioContentLength(fmt, url).toString(),
          'videoId': videoId,
          'source': 'youtube',
          // YouTube publishes each track's measured loudness. Without it the
          // "Normalize volume" setting had nothing to work from (Song.loudness
          // was only ever set for podcasts/radio), so it silently did nothing.
          if (_loudnessDb(raw) != null) 'loudnessDb': _loudnessDb(raw).toString(),
          // The exact release date (YYYY-MM-DD). Catalogue endpoints only return a year,
          // so cache it when a player response has it (see [getPublishDate]).
          if (_publishDateOf(raw) != null) 'publishDate': _publishDateOf(raw)!,
        };
      } catch (e) {
        print('${client.clientName}${authed ? " (signed in)" : ""}: player error $e');
        // One HTTP 400 on the signed-in pass ends it: a 400 means the endpoint rejects
        // the shape of signed player requests, so every remaining client would get it
        // too. A 403, timeout or playability answer is per-client, so those continue.
        if (authed && e is CatalogApiException && e.statusCode == 400) {
          print('signed-in pass abandoned: the player endpoint rejects '
              'authenticated requests (400) — the rest would too');
          break;
        }
        // A DNS failure ("Failed host lookup") means the device has no working network,
        // which applies to every remaining client, so stop instead of trying each one.
        final msg = e.toString().toLowerCase();
        if (msg.contains('failed host lookup') ||
            msg.contains('no address associated') ||
            msg.contains('network is unreachable')) {
          print('resolve abandoned: no network (DNS failed) — the remaining '
              'clients would fail the same way');
          return null;
        }
      }
    }
    }
    // Every client refused. That is the documented signature of an unusable
    // visitor id (see [_visitorStale]), so let the next response replace it
    // rather than carrying the same one into the same refusal again.
    if (!_visitorStale) {
      _visitorStale = true;
      print('every client refused — treating the visitor id as stale so the '
          'next response can replace it');
    }
    print('ERROR: No playable stream resolved for $videoId '
        '(visitor id ${_visitorData == null || _visitorData!.isEmpty ? "ABSENT" : "present"})');
    return null;
  }

  /// Probes the URL the way the player will use it: the first bytes and a chunk
  /// well inside the track. True only if both are served.
  ///
  /// Some clients return URLs that serve roughly the first half-megabyte and then
  /// refuse later chunks (a token check that engages after the start). A
  /// first-bytes probe would accept those and the track would stall a minute in;
  /// rejecting here costs one probe and moves to the next client.
  ///
  /// [contentLength] places the deep probe about 60% in (a fixed offset could land
  /// past the end of a short track). The deep probe is skipped when the length is
  /// unknown or the track is too small for the gate to engage.
  Future<bool> _validateStreamUrl(String url, String userAgent,
      {int contentLength = 0}) async {
    Future<int?> probe(String range) async {
      try {
        final resp = await _http.get(
          Uri.parse(url),
          headers: {'User-Agent': userAgent, 'Range': range},
        ).timeout(_probeTimeout);
        return resp.statusCode;
      } catch (_) {
        return null;
      }
    }

    final head = await probe('bytes=0-1');
    if (head != 200 && head != 206) return false;

    // 1 MiB: below that a whole track fits inside the ungated opening window, so
    // there is nothing a deep probe could discover.
    if (contentLength < 1024 * 1024) return true;

    final deep = (contentLength * 0.6).round();
    final code = await probe('bytes=$deep-${deep + 1}');
    // A null (network hiccup) is NOT treated as a gate: the url has already
    // proven it serves bytes, and rejecting on a timeout would throw away a good
    // client over a dropped packet.
    if (code == null) return true;
    if (code == 200 || code == 206) return true;
    print('url serves the start but 403s at ${(deep / 1024 / 1024).toStringAsFixed(1)} MB '
        '(code $code) — gated, skipping this client');
    return false;
  }

  /// The track's measured loudness in dB, from the player response's
  /// `playerConfig.audioConfig`. YouTube reports how far the master sits from
  /// its reference, which is exactly what volume normalization needs.
  /// `loudnessDb` is the standard field; `perceptualLoudnessDb` appears on some
  /// clients and is preferred when present. Null when neither is provided.
  static double? _loudnessDb(Map<String, dynamic> raw) {
    final cfg = raw['playerConfig'];
    if (cfg is! Map) return null;
    final audio = cfg['audioConfig'];
    if (audio is! Map) return null;
    final perceptual = audio['perceptualLoudnessDb'];
    if (perceptual is num) return perceptual.toDouble();
    final loudness = audio['loudnessDb'];
    if (loudness is num) return loudness.toDouble();
    return null;
  }

  // Exact release dates
  // YouTube Music's catalog endpoints (search / browse) put only a YEAR in the
  // subtitle runs — that's why "released" only ever showed "2019" app-wide. The
  // PLAYER response carries the real calendar date in its microformat, so that's
  // the source used here.
  static final LruCache<String, String> _publishDateCache =
      LruCache<String, String>(maxEntries: 400, defaultTtl: const Duration(days: 7));

  /// Play counts taken from player responses the app already made. Album and
  /// playlist rows carry no count, but every player response has
  /// `videoDetails.viewCount`, so resolving a stream fills those rows for free.
  /// A day's TTL: counts move, and a stale one is only cosmetic.
  static final LruCache<String, int> _viewCountCache =
      LruCache<String, int>(maxEntries: 600, defaultTtl: const Duration(days: 1));

  /// The harvested play count for [videoId], or null if none has been seen.
  /// Synchronous and allocation-free so a row builder can call it.
  static int? cachedViewCount(String videoId) =>
      videoId.isEmpty ? null : _viewCountCache.get(videoId);

  /// `videoDetails.viewCount` → an int, or null when absent/unparseable.
  static int? _viewCountOf(Map<String, dynamic> raw) {
    final details = raw['videoDetails'];
    if (details is! Map) return null;
    final v = details['viewCount'];
    if (v == null) return null;
    return int.tryParse(v.toString());
  }

  /// Video ids whose count is being fetched right now, so a rebuilding row
  /// cannot start a second request for the same track.
  static final Map<String, Future<int?>> _viewCountInFlight = {};

  /// Ids already looked up and found to have no count — remembered so a row that
  /// rebuilds does not retry a track YouTube has no number for.
  static final Set<String> _viewCountMisses = <String>{};

  /// At most this many count lookups at once.
  ///
  /// Scrolling a long playlist builds rows faster than requests complete, and
  /// without a cap that is fifty parallel requests for a subtitle. Three keeps
  /// the visible rows filling quickly while leaving the connection free for the
  /// thing that matters, which is audio.
  static int _viewCountActive = 0;
  static const int _viewCountMaxParallel = 3;

  /// The play count for one track, fetched on demand and cached (memory and disk).
  /// Album and playlist rows don't include counts, so they're fetched per track;
  /// tracks resolved for playback fill the same cache for free, and a track with no
  /// count is remembered as a miss. Returns null when the parallel cap is reached;
  /// the row picks the value up next time.
  Future<int?> fetchViewCount(String videoId) async {
    if (videoId.isEmpty || videoId.length != 11) return null;
    final cached = _viewCountCache.get(videoId);
    if (cached != null) return cached;
    if (_viewCountMisses.contains(videoId)) return null;

    final inFlight = _viewCountInFlight[videoId];
    if (inFlight != null) return inFlight;
    if (_viewCountActive >= _viewCountMaxParallel) return null;

    final future = _fetchViewCountInner(videoId);
    _viewCountInFlight[videoId] = future;
    _viewCountActive++;
    try {
      return await future;
    } finally {
      _viewCountActive--;
      _viewCountInFlight.remove(videoId);
    }
  }

  Future<int?> _fetchViewCountInner(String videoId) async {
    // The first client in the chain, guest, exactly as a playback resolve would
    // ask — no separate identity to keep in step.
    final client = CatalogApiClients.streamOrder.first;
    try {
      // The response mask keeps this cheap: the full player response is ~51 KB,
      // while asking only for the view count returns a few dozen bytes.
      final raw = await _postPlayer(client, videoId,
          fields: 'videoDetails.viewCount');
      final views = _viewCountOf(raw);
      if (views != null && views > 0) {
        _viewCountCache.put(videoId, views);
        _persistViewCount(videoId, views);
        return views;
      }
      // Bounded like every other cache here: clearing costs at most one repeat
      // lookup per track, and an unbounded Set of ids grows for the whole session.
      if (_viewCountMisses.length > 800) _viewCountMisses.clear();
      _viewCountMisses.add(videoId);
      return null;
    } catch (_) {
      // A failure is NOT recorded as a miss: the track may well have a count and
      // the network merely failed, so the next build may try again.
      return null;
    }
  }

  static const String _viewCountPrefsKey = 'auvy_view_counts_v1';

  /// Disk-backed so a playlist costs its lookups once, not once per launch.
  /// Written debounced and capped, because this is a cosmetic cache and must not
  /// grow without bound or thrash storage.
  static Timer? _viewCountSaveTimer;
  static final Map<String, int> _viewCountPending = {};

  static void _persistViewCount(String videoId, int views) {
    _viewCountPending[videoId] = views;
    _viewCountSaveTimer?.cancel();
    _viewCountSaveTimer = Timer(const Duration(seconds: 5), _flushViewCounts);
  }

  static Future<void> _flushViewCounts() async {
    if (_viewCountPending.isEmpty) return;
    final batch = Map<String, int>.from(_viewCountPending);
    _viewCountPending.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = <String, int>{};
      final raw = prefs.getString(_viewCountPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final n = v is int ? v : int.tryParse(v.toString());
            if (n != null) stored[k.toString()] = n;
          });
        }
      }
      stored.addAll(batch);
      // Newest-last insertion order, so trimming from the front drops the oldest.
      if (stored.length > 1500) {
        final keep = stored.entries.toList().sublist(stored.length - 1500);
        stored
          ..clear()
          ..addEntries(keep);
      }
      await prefs.setString(_viewCountPrefsKey, jsonEncode(stored));
    } catch (_) {
      // Cosmetic cache; a failed write costs a re-fetch, nothing more.
    }
  }

  /// Loads the disk cache into memory. Called once at startup.
  static Future<void> primeViewCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_viewCountPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      var n = 0;
      decoded.forEach((k, v) {
        final count = v is int ? v : int.tryParse(v.toString());
        if (count != null && count > 0) {
          _viewCountCache.put(k.toString(), count);
          n++;
        }
      });
      if (n > 0) print('Primed $n cached play counts');
    } catch (_) {}
  }

  /// `microformat.playerMicroformatRenderer.publishDate` → "2019-05-17", falling
  /// back to `uploadDate`, then `videoDetails.publishDate`. A timezone suffix
  /// ("2019-05-17T00:00:00-07:00") is cut to the calendar day. Null when absent or
  /// unparseable.
  static String? _publishDateOf(Map<String, dynamic> raw) {
    String? pick(dynamic v) {
      if (v is! String) return null;
      final s = v.trim();
      if (s.length < 10) return null;
      final day = s.substring(0, 10);
      // Must be a real YYYY-MM-DD, not a duration or a stray id.
      return DateTime.tryParse(day) == null ? null : day;
    }

    final mf = raw['microformat'];
    if (mf is Map) {
      final r = mf['playerMicroformatRenderer'];
      if (r is Map) {
        final d = pick(r['publishDate']) ?? pick(r['uploadDate']);
        if (d != null) return d;
      }
      // Music/web responses sometimes use microformatDataRenderer instead.
      final md = mf['microformatDataRenderer'];
      if (md is Map) {
        final d = pick(md['publishDate']) ?? pick(md['uploadDate']);
        if (d != null) return d;
      }
    }
    final vd = raw['videoDetails'];
    if (vd is Map) {
      final d = pick(vd['publishDate']) ?? pick(vd['uploadDate']);
      if (d != null) return d;
    }
    return null;
  }

  /// The exact release date of [videoId] as "YYYY-MM-DD", or null. One guest
  /// `player` request, cached for a week; playing a track fills the cache for free.
  Future<String?> getPublishDate(String videoId) async {
    if (videoId.isEmpty || videoId.length != 11) return null;
    final hit = _publishDateCache.get(videoId);
    if (hit != null) return hit;
    // Must be WEB_REMIX: the stream clients (VISIONOS / ANDROID_VR / IOS) return no
    // publish date. WEB_REMIX has it at `microformat.microformatDataRenderer`, WEB at
    // `microformat.playerMicroformatRenderer`.
    for (final client in [CatalogApiClients.webRemix]) {
      try {
        final raw = await _postPlayer(client, videoId);
        final date = _publishDateOf(raw);
        if (date != null) {
          _publishDateCache.put(videoId, date);
          return date;
        }
      } catch (_) {
        // Fall through to the next client; a missing date is not an error.
      }
    }
    return null;
  }

  /// Seed the publish-date cache from a resolve that already happened.
  static void cachePublishDate(String videoId, String date) {
    if (videoId.isEmpty || date.isEmpty) return;
    _publishDateCache.put(videoId, date);
  }

  /// [preferMp4] limits the choice to AAC-in-MP4 formats when any exist.
  ///
  /// For files the user keeps, not playback. YouTube's best audio is usually Opus
  /// in WebM, which sounds better when streaming, but a WebM file can't carry
  /// MP4/ID3 tags (no title, artist or cover) and Android's media scanner won't
  /// index it. MP4 is the right trade for a file copied to a car stereo or PC.
  /// Falls back to the full list when a track has no MP4 audio.
  Map<String, dynamic>? _bestAudioFormat(Map<String, dynamic> raw,
      {bool lowQuality = false, int maxBitrate = 0, bool preferMp4 = false}) {
    final sd = raw['streamingData'];
    if (sd is! Map) return null;
    final all = <dynamic>[
      ...((sd['adaptiveFormats'] as List?) ?? const []),
      ...((sd['formats'] as List?) ?? const []),
    ];
    var audio = all
        .whereType<Map>()
        .where((f) => (f['mimeType'] ?? '').toString().startsWith('audio/'))
        .map((f) => Map<String, dynamic>.from(f))
        .toList();
    if (audio.isEmpty) return null;
    // Apple platforms can't decode Opus/WebM (AVPlayer fails the item), so on iOS
    // AAC-in-MP4 is required, not preferred. Other platforms are unaffected.
    if (preferMp4 || defaultTargetPlatform == TargetPlatform.iOS) {
      final mp4 = audio
          .where((f) => (f['mimeType'] ?? '').toString().startsWith('audio/mp4'))
          .toList();
      if (mp4.isNotEmpty) audio = mp4;
    }


    // Adaptive ceiling first. [maxBitrate] comes from measured throughput and
    // mid-track stalls (see adaptive_bitrate.dart), not from the connection type.
    if (maxBitrate > 0) {
      return pickFormatForCeiling(audio, ceilingBps: maxBitrate);
    }

    // Sorted highest-bitrate first.
    audio.sort((a, b) {
      final ab = int.tryParse('${b['bitrate'] ?? 0}') ?? 0;
      final aa = int.tryParse('${a['bitrate'] ?? 0}') ?? 0;
      return ab.compareTo(aa);
    });
    if (!lowQuality) return audio.first; // default: highest quality (unchanged)

    // Data-saver with no adaptive ceiling to apply: prefer the lowest-bitrate
    // format that's still >= ~96kbps so audio stays acceptable; if none clear
    // that bar, fall back to the very lowest available.
    const minAcceptable = kDataSaverCeiling;
    Map<String, dynamic>? pick;
    for (final f in audio) {
      final br = int.tryParse('${f['bitrate'] ?? 0}') ?? 0;
      if (br >= minAcceptable) pick = f; // keep walking down; ends on the lowest >= bar
    }
    return pick ?? audio.last;
  }

  /// The audio byte length. ANDROID-client audio formats frequently OMIT the
  /// `contentLength` JSON field — without it the native player can't bound its
  /// Range request and googlevideo 403s the open-ended `bytes=0-` it then sends.
  /// googlevideo embeds the true length in the URL as `&clen=`, so fall back to
  /// that. Returns 0 only if neither source has it.
  int _audioContentLength(Map<String, dynamic> fmt, String url) {
    final field = int.tryParse('${fmt['contentLength'] ?? ''}') ?? 0;
    if (field > 0) return field;
    final m = RegExp(r'[?&]clen=(\d+)').firstMatch(url);
    return m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
  }

  // Transport internals

  /// POSTs and returns the raw response body (the caller decodes, possibly on an
  /// isolate). Catalogue calls (search/browse/home/next) go out as guest by
  /// default: signed WEB_REMIX responses are much larger (~1.8 MB vs a few hundred
  /// KB) and slowed everything down. Only calls that need the user (e.g.
  /// account_menu) pass [authenticated] = true. Streaming has its own guest path
  /// in _postPlayer.
  Future<String> _postRaw(CatalogApiClientInfo client, String endpoint, Map<String, dynamic> body,
      {bool authenticated = false}) async {
    final uri = Uri.parse('${client.apiUrl}$endpoint?prettyPrint=false');
    final headers = {
      ...client.headers(visitorData: _visitorData),
      if (authenticated) ...await _authHeaders(client.origin),
    };
    final payload = jsonEncode({
      'context': client.context(visitorData: _visitorData),
      ...body,
    });
    var resp = await _limiter.run(() =>
        _http.post(uri, headers: headers, body: payload).timeout(_catalogTimeout));

    // Tell the rate limiter about throttling (429/503) and retry once after backing
    // off, honouring Retry-After when sent. Otherwise the app kept hitting the
    // limit and throttling looked like "nothing matched".
    if (resp.statusCode == 429 || resp.statusCode == 503) {
      final retryAfter =
          int.tryParse(resp.headers['retry-after'] ?? '') ?? 0;
      final cooldown = Duration(
          seconds: retryAfter > 0 ? retryAfter.clamp(1, 30) : 2);
      _limiter.penalise(cooldown: cooldown);
      await Future<void>.delayed(cooldown);
      resp = await _limiter.run(() =>
          _http.post(uri, headers: headers, body: payload).timeout(_catalogTimeout));
    }

    if (resp.statusCode != 200) {
      throw CatalogApiException(
          statusCode: resp.statusCode,
          // Named so callers (and logs) can tell a throttle apart from a
          // genuine failure instead of both reading as "Request failed".
          message: resp.statusCode == 429 || resp.statusCode == 503
              ? 'Throttled by YouTube'
              : 'Request failed',
          body: resp.body);
    }
    return resp.body;
  }

  /// [authenticated] attaches the user's cookies and SAPISIDHASH. Only used as a
  /// last resort after the guest chain failed: login-free clients return their
  /// unthrottled URLs only to unauthenticated requests, and signed requests have
  /// been rejected with 400 (see [getStreamUrl]).
  ///
  /// [fields] is Google's response mask, e.g. `videoDetails.viewCount`; for a
  /// single value it shrinks a ~51 KB response to a few dozen bytes. Omit it to get
  /// the whole response, which stream resolution needs.
  Future<Map<String, dynamic>> _postPlayer(CatalogApiClientInfo client, String videoId,
      {bool authenticated = false, String fields = ''}) async {
    // The login-free clients want a visitor id; without one they answer
    // UNPLAYABLE / LOGIN_REQUIRED and resolution falls through to a client whose
    // URLs googlevideo gates. See _ensureVisitor.
    await _ensureVisitor();
    // playerApiUrl, NOT apiUrl — a client may send its player request to a
    // different host than its catalog traffic. See CatalogApiClientInfo.
    final uri = Uri.parse('${client.playerApiUrl}player?prettyPrint=false'
        '${fields.isEmpty ? "" : "&fields=$fields"}');
    // Stream resolution is normally guest: the login-free clients (VISIONOS /
    // ANDROID_VR / IOS) return unthrottled URLs only to unauthenticated requests,
    // and attaching cookies can get a 400. Auth still applies to catalogue requests
    // in _postRaw, where it personalises results.
    final headers = {
      // forPlayer: Origin/Referer must match the host this request actually goes
      // to. A music-host request stamped with a www Origin is a mismatched pair,
      // and a mismatched pair is exactly what InnerTube rejects.
      ...client.headers(visitorData: _visitorData, forPlayer: true),
      if (authenticated) ...await _authHeaders(client.playerOrigin),
    };
    final payload = jsonEncode({
      'context': client.context(visitorData: _visitorData),
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    });
    // Retry transient network failures (DNS miss / "write failed" / timeout),
    // which happen on cold start and would otherwise skip a good stream client
    // (e.g. VISIONOS) and fall through to a throttled one. Only TRANSPORT
    // errors are retried; a non-200 from YouTube is NOT (it's a real rejection).
    http.Response? resp;
    for (var attempt = 0; attempt < _playerRetries; attempt++) {
      try {
        resp = await _limiter.run(() =>
            _http.post(uri, headers: headers, body: payload).timeout(_playerTimeout));
        break;
      } catch (e) {
        if (attempt == _playerRetries - 1) rethrow;
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    if (resp!.statusCode != 200) {
      throw CatalogApiException(statusCode: resp.statusCode, message: 'player failed', body: resp.body);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Cookie + SAPISIDHASH headers when signed in; empty (guest) otherwise.
  Future<Map<String, String>> _authHeaders(String origin) async {
    try {
      if (!await _cookies.hasAuthCookies()) return const {};
      final headers = <String, String>{};
      final cookie = await _cookies.getCookieHeader();
      if (cookie != null && cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
        headers['X-Goog-AuthUser'] = '0';
      }
      final authz = await _cookies.getAuthorizationHeader(origin);
      if (authz != null && authz.isNotEmpty) {
        headers['Authorization'] = authz;
        headers['X-Origin'] = origin;
      }
      return headers;
    } catch (_) {
      return const {};
    }
  }

  /// Takes the visitor id from a response's `responseContext`.
  ///
  /// Catalogue responses have it lifted to a top-level `visitorData` by
  /// CatalogApiParser, but player responses don't, so reading only the top-level
  /// key never harvested it from `_postPlayer`. With cached home data (no catalogue
  /// request at all) the id then stayed empty, the login-free clients refused, and
  /// resolution fell through to a client whose URLs stop after about a minute.
  /// Reading `responseContext` directly lets the first player response seed the id.
  void _captureVisitor(Map<String, dynamic> parsed) {
    if (!_visitorStale && _visitorData != null && _visitorData!.isNotEmpty) {
      return;
    }
    // Top-level first: that is what the parser hands back, already lifted.
    final lifted = parsed['visitorData'];
    if (lifted is String && lifted.isNotEmpty) {
      _rememberVisitor(lifted);
      return;
    }
    // Otherwise dig where InnerTube actually puts it. This is the branch that
    // player responses need.
    final ctx = parsed['responseContext'];
    if (ctx is Map) {
      final vd = ctx['visitorData'];
      if (vd is String && vd.isNotEmpty) _rememberVisitor(vd);
    }
  }

  /// Pref holding the harvested visitor id.
  static const String _kVisitorPref = 'auvy_visitor_data';
  static const String _kVisitorAtPref = 'auvy_visitor_data_at';

  /// How long a harvested visitor id is trusted across launches.
  ///
  /// It identifies an anonymous session, and YouTube stops honouring one
  /// eventually. Twelve hours keeps the cold-start benefit the persistence
  /// exists for — the first resolve of the day is as good as the hundredth —
  /// while guaranteeing an id cannot outlive its usefulness by days.
  static const Duration _visitorMaxAge = Duration(hours: 12);
  static bool _visitorRestoreTried = false;

  void _rememberVisitor(String vd) {
    final replacing = _visitorStale && _visitorData != null && _visitorData != vd;
    _visitorData = vd;
    _visitorStale = false;
    if (replacing) {
      print('visitor id replaced after a whole-chain refusal — the old one '
          'had gone stale');
    }
    // Fire-and-forget: a failed write costs one cold start, and blocking a
    // response parse on disk I/O would be worse.
    SharedPreferences.getInstance().then((p) {
      p.setString(_kVisitorPref, vd);
      // Timestamped, so the restore can tell a fresh id from an old, likely stale one.
      p.setInt(_kVisitorAtPref, DateTime.now().millisecondsSinceEpoch);
      return true;
    }).catchError((_) => false);
  }

  /// Restores the persisted visitor id once per process, so the first resolve of a
  /// cold start (when cached data means no catalogue request has run yet) isn't
  /// sent without one. The id identifies an anonymous session, not the user, so
  /// persisting it is safe.
  Future<void> _ensureVisitor() async {
    if (_visitorData != null && _visitorData!.isNotEmpty) return;
    if (_visitorRestoreTried) return;
    _visitorRestoreTried = true;
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_kVisitorPref);
      if (v == null || v.isEmpty) return;
      final at = p.getInt(_kVisitorAtPref) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      _visitorData = v;
      // An old or undated id is kept and marked stale, never deleted. Ids saved before
      // the timestamp existed are undated, and deleting them sent requests out bare,
      // which is worse. A still-good id keeps working, and a dead one is replaced by
      // the next response carrying a responseContext.
      if (at == 0 || age > _visitorMaxAge.inMilliseconds) {
        _visitorStale = true;
        print('visitor id is '
            '${at == 0 ? "undated" : "${(age / 3600000).round()}h old"} — '
            'using it but letting the next response replace it');
        return;
      }
      print('visitor id restored (${(age / 60000).round()}m old)');
    } catch (_) {
      // No visitor id: behaves exactly as before this fix.
    }
  }

  // The HTTP client is shared + app-lifetime; nothing to dispose per instance.
  void dispose() {}
}

class CatalogApiException implements Exception {
  final int statusCode;
  final String message;
  final String body;
  CatalogApiException({required this.statusCode, required this.message, required this.body});
  @override
  String toString() => 'CatalogApiException(statusCode: $statusCode, message: $message)';
}
