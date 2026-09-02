import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
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
///   * Posts to the right endpoint with the right client context + headers
///     (WEB_REMIX @ music.youtube.com for catalog; ANDROID/IOS for the player).
///   * Injects the signed-in user's cookies + SAPISIDHASH when available, so
///     search/browse/home become personalized and the user's library/age-gated
///     content is reachable. Guests send no auth (verified working).
///   * Paces requests through a shared [RateLimiter] and serves metadata from a
///     shared in-memory [LruCache].
///   * Decodes + parses large catalog responses on a background isolate (via
///     `compute`) so big JSON never janks the UI thread.
///
/// All heavy state is `static` so a single HTTP client / cache / limiter is
/// shared across the many `CatalogApiClient()` call sites (no per-instance leak).
class CatalogApiClient {
  static final RateLimiter _limiter =
      RateLimiter(minInterval: const Duration(milliseconds: 220), burst: 5);
  static final LruCache<String, Map<String, dynamic>> _metaCache =
      LruCache<String, Map<String, dynamic>>(maxEntries: 120, defaultTtl: const Duration(minutes: 30));
  // IN-FLIGHT DE-DUPLICATION WAS REMOVED — IT DEADLOCKED.
  //
  // Sharing one Future between callers asking the same question is a real
  // optimisation, and it worked in isolation. On device it hung the app: every
  // request returned 200 and parsed, then the awaiting Future.wait never
  // resolved and nothing threw.
  //
  // The trap is RE-ENTRANCY. If any path inside a deduped fetch asks for the
  // same key again — a retry, a fallback, two scoped searches collapsing to one
  // key — the map hands it the future that is waiting on that very call. It
  // waits on itself, silently, with no error and no timeout to break it.
  //
  // If this is ever reintroduced it needs BOTH a re-entrancy guard (a zone flag
  // or an explicit "already fetching on this stack" marker) and a timeout, so a
  // mistake degrades into a slow request rather than a frozen screen.

  /// The shared pooled client — NOT a private one.
  ///
  /// A GETTER, NOT `static final`. `HttpPool` REPLACES its client with a
  /// `DataTrackingHttpClient` wrapper when `attachDataTracker` runs from the UI
  /// (see main_layout). Anything that captures the reference in a `static final`
  /// captures the pre-attach, UNWRAPPED client and keeps it forever, so its
  /// traffic never reaches the tracker. Resolving per call always yields the
  /// current, wrapped client.
  ///
  /// This used to be a private `http.Client()`. It was correct about sharing one
  /// client (no per-instance leak), but it meant catalog traffic — search,
  /// browse, home, next, and every player POST, almost certainly the app's
  /// largest non-artwork consumer — was invisible to the "Total Data Used"
  /// figure in Settings. Same reason artwork was missing before it was routed
  /// through the tracker.
  ///
  /// Headers are unaffected: every call site passes its own (`client.headers(...)`,
  /// per-request `User-Agent`/`Range`), so the client is pure transport here.
  static http.Client get _http => HttpPool().getClient();
  static String? _visitorData;

  /// Set when the client chain has just refused everything, so the next
  /// response is allowed to REPLACE the visitor id instead of being ignored.
  ///
  /// WHY A VISITOR ID CAN BE THE WHOLE PROBLEM. The login-free player
  /// clients want a visitor id, and the comment on [_captureVisitor] already
  /// records what happens without a usable one: VISIONOS answers UNPLAYABLE and
  /// ANDROID_VR answers LOGIN_REQUIRED. A STALE id produces the same refusals as
  /// no id at all, and until now nothing could ever replace one: the harvest
  /// returns early whenever an id is already held, and the restore reads the
  /// persisted copy on every launch. So one expired id survived restarts
  /// forever, and every client refused forever.
  ///
  /// The id is NOT dropped when this is set. A bare request is what the doc
  /// above warns about; instead the refused response, which still carries a
  /// responseContext — is allowed to supply the replacement, so the recovery
  /// happens on the attempt that detected the problem.
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

  /// No API key, and no parameter pretending to take one.
  ///
  /// This accepted `{String apiKey = ''}` and did nothing with it — a leftover
  /// from when a key lived in the app. Not one of the six call sites passed it,
  /// and a parameter that silently discards a credential is worse than no
  /// parameter: it invites someone to hand it a real key and believe it is being
  /// used. The catalogue is reached with a visitor id and the session cookie
  /// above; there is nothing else to supply.
  CatalogApiClient();

  /// Drop cached catalog responses + visitor id. Call on login/logout so
  /// personalized (or de-personalized) results are re-fetched immediately.
  static void clearCaches() {
    _metaCache.clear();
    _visitorData = null;
    // AND THE PERSISTED COPY. Nulling only the field looked like a reset and
    // was not: _ensureVisitor reads the pref back on the next request, so the
    // id this was called to get rid of returned immediately, which made
    // signing in or out unable to obtain a fresh anonymous session at all.
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

  /// YouTube Music's own query completions for a partial search.
  ///
  /// `music/get_search_suggestions` is the endpoint the YouTube Music web client
  /// uses as you type, so the completions match what people actually search for
  /// there — including misspelling recovery ("the week" → "the weeknd" AND "the
  /// weekend") that no local history list can offer.
  ///
  /// CACHED, BECAUSE THIS IS CALLED FROM A KEYSTROKE PATH. Every extra
  /// character is a new query, and prefixes repeat constantly as the user edits or
  /// backspaces. The LRU turns most of that into zero requests. Callers must ALSO
  /// debounce — the cache stops repeat traffic, not first-time traffic.
  ///
  /// Returns [] on any failure: a search box that silently has no suggestions is
  /// fine, and an error there would interrupt typing.
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

  /// Full artist page (channel browseId, UC…) parsed into the header name +
  /// thumbnail and its titled shelves (Songs / Albums / Singles / Featured on /
  /// Playlists / Fans might also like). Returns `{name, thumbnail, sections}`.
  /// Any YouTube Music BROWSE feed, parsed with the same shelf reader as the
  /// home feed. Charts / New Releases / Moods & Genres all return the same
  /// `sectionListRenderer` → `musicCarouselShelfRenderer` shape, so they need no
  /// separate parser — only a different browseId.
  ///
  /// Auvy previously used just two of these endpoints (`FEmusic_home`,
  /// `FEmusic_liked_playlists`) and synthesised "charts"/genre discovery out of
  /// Last.fm searches instead. These are YouTube Music's OWN curated feeds.
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
  /// This feed CANNOT go through [getFeedSections]. Verified against the live
  /// endpoint: `FEmusic_moods_and_genres` contains **only**
  /// `musicNavigationButtonRenderer` items (36 coloured chips) and NO
  /// `musicTwoRowItemRenderer`/`musicResponsiveListItemRenderer`, so the shared
  /// shelf parser finds nothing and silently returns empty sections. Hence this
  /// dedicated parse.
  ///
  /// Each entry: `{title, browseId, params, color}` — `color` is an ARGB int from
  /// YouTube's own `leftStripeColor`, so the grid can use the real category
  /// colours. Follow one with [getCategorySections] to list its playlists.
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
    // The buttons are nested a few levels deep and the exact path shifts between
    // API revisions, so walk the tree for the renderer instead of hardcoding it.
    void walk(dynamic node) {
      if (node is Map) {
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
          if (title.isNotEmpty && browseId.isNotEmpty) {
            out.add({
              'title': title,
              'browseId': browseId,
              'params': params,
              if (color is num) 'color': color.toInt(),
            });
          }
        }
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(json);
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

  /// Full resolve: a directly-playable audio URL plus the matching user-agent
  /// (the native player MUST send this UA or googlevideo returns 403). Null if
  /// no client yields a playable stream.
  /// [maxBitrate] is the adaptive ceiling in bps (0 = uncapped). It comes from
  /// measured throughput, so it — not [lowQuality] — is what normally decides
  /// the format now. [lowQuality] remains the data-saver's own hard preference.
  /// [preferMp4] asks for AAC-in-MP4 so the bytes can carry tags and cover art —
  /// set it for downloads, never for playback. See [_bestAudioFormat].
  /// [isStillWanted] is asked before each client whether this resolve is worth
  /// continuing — it returns false once the user has moved to another track.
  ///
  /// WITHOUT IT, AN ABANDONED RESOLVE KEEPS RUNNING AND POISONS THE NEXT ONE.
  /// Caught on device 2026-09-02: the user skipped a gated track at 21:56:16.8,
  /// the next track resolved fine at :18.4, and the resolve for the ABANDONED
  /// track carried on until :19.3 — two more clients, a signed-in POST, and
  /// then it declared "every client refused" and marked the visitor id stale.
  /// That verdict was drawn from a track nobody was waiting for and it applies
  /// to the whole session, so a track the user had already left could degrade
  /// the resolve of the one they had moved to. It also logged an ERROR and
  /// would have surfaced a failure for a track already off screen.
  ///
  /// Abandoning returns null WITHOUT touching [_visitorStale]: "the user
  /// skipped" is not evidence about the visitor id.
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
        // THIS PASS EXISTS BECAUSE SOME CLIENTS NOW ANSWER LOGIN_REQUIRED.
        //
        // ANDROID_VR, ANDROID_MUSIC and IOS_MUSIC refuse guest player requests
        // outright. Signing the request is the only thing that could change that
        // answer, and the alternative here is silence — the guest chain has
        // already failed by this point.
        //
        // It is a LAST resort, not a preference, for two measured reasons: the
        // player endpoint has answered HTTP 400 to authenticated requests before
        // (see [_postPlayer]), and an authenticated response ties the play to the
        // account. Costing nothing on the normal path is what makes it safe to
        // keep.
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
        // Opportunistic only: if a stream client ever starts returning the
        // publish date, take it for free. Today none of them do (verified), so
        // [getPublishDate] does its own WEB_REMIX lookup — don't rely on this.
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
          // The EXACT release date (YYYY-MM-DD). The catalog endpoints only ever
          // hand back a YEAR, so this player response is the one place the full
          // date exists — cache it while we're here (see [getPublishDate]).
          if (_publishDateOf(raw) != null) 'publishDate': _publishDateOf(raw)!,
        };
      } catch (e) {
        print('${client.clientName}${authed ? " (signed in)" : ""}: player error $e');
        // One HTTP 400 on the signed-in pass ends the pass.
        //
        // A 400 there is the endpoint rejecting the SHAPE of an authenticated
        // player request, not a verdict on this video or this client, so once
        // one client gets it, every remaining client will too. Measured on
        // device: after the guest chain failed, all five clients were tried
        // signed-in and all five answered 400, costing five POSTs and about a
        // second of the user's time before the app admitted the track would not
        // play.
        //
        // Only 400 breaks out. A 403, a timeout or a playability answer is
        // genuinely per-client and the remaining clients are still worth trying.
        if (authed && e is CatalogApiException && e.statusCode == 400) {
          print('signed-in pass abandoned: the player endpoint rejects '
              'authenticated requests (400) — the rest would too');
          break;
        }
        // A DNS FAILURE IS ABOUT THE DEVICE, NOT THE CLIENT — STOP ASKING.
        //
        // Same reasoning as the 400 above, one layer lower. "Failed host lookup"
        // means this device currently has no working network, which is true for
        // every remaining client and every remaining video. Measured during an
        // offline test, one resolve produced TEN of these:
        //
        // IOS: player error … Failed host lookup: 'www.youtube.com'
        // IOS (signed in): player error … Failed host lookup …
        // ANDROID_VR: … ANDROID_VR (signed in): … VISIONOS: … (etc.)
        //
        // Ten DNS attempts and ten POSTs for an answer the first one settled.
        // That is wasted radio time and battery on a device that is offline —
        // exactly when both are worth conserving.
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

  /// Probes the url the way the player will USE it: the opening bytes, and then
  /// a chunk well inside the track. True only if both are served.
  ///
  /// The first bytes are NOT enough, AND believing they were cost a mid-track
  /// Stall every time a gated client answered.
  ///
  /// Several clients hand back a url that serves roughly the first half-megabyte
  /// and then refuses every later chunk — a PoToken gate that engages after the
  /// start of the stream rather than at the start. Measured 2026-08-21: iOS,
  /// iPadOS, ANDROID and the newer ANDROID_VR all return 206 for `bytes=0-1` and
  /// 403 for `bytes=1500000-…` on the same url.
  ///
  /// A first-bytes probe therefore passes them, the player accepts the url, and
  /// the failure surfaces about a minute in as five same-url retries, four fresh
  /// re-resolves, a drop to a lower tier that is gated too, and finally silence.
  /// Nine wasted requests and an audible stall, where rejecting the url here
  /// costs one probe and falls through to the next client immediately.
  ///
  /// [contentLength] is the stream's size, used to place the deep probe about
  /// 60% in — a fixed offset would land past the end of a short track and read
  /// as 416 rather than as a gate. The deep probe is skipped when the length is
  /// unknown or the track is small enough that the gate could not engage before
  /// the end anyway.
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

  /// Play counts harvested from player responses the app ALREADY made.
  ///
  /// NEVER FETCHED ON ITS OWN. YouTube puts a play count in the text of some
  /// browse shelves and not others — album and playlist rows carry none, which is
  /// why those rows were blank. The count IS in `videoDetails.viewCount` of every
  /// player response, so taking it while resolving a stream fills those rows for
  /// free. Requesting it per row would be one network call per visible track,
  /// which is not worth a subtitle.
  ///
  /// A day's TTL because a play count moves, and a stale one is only cosmetic.
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

  /// The play count for one track, fetched on demand and cached.
  ///
  /// PER TRACK, BECAUSE COLLECTIONS DO NOT CARRY IT. YouTube puts a count in
  /// the row text of search results and some browse shelves, but album and
  /// playlist rows have none, so a page built from a collection can only get the
  /// number by asking about each track. `videoDetails.viewCount` on the player
  /// response has it for every track.
  ///
  /// Costs at most one request per track EVER: the result is cached in memory and
  /// on disk, tracks resolved for playback fill the same cache for free, and a
  /// track with no count is remembered as a miss rather than retried. Returns
  /// null rather than queueing when the parallel cap is reached — the row simply
  /// shows nothing and picks the value up next time it is built.
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
      // THE MASK IS WHAT MAKES THIS AFFORDABLE. Without it every row would
      // pull a full player response — 51 KB of streaming formats fetched to read
      // one number, which on a 60-track playlist is about 3 MB for a subtitle.
      // With it a lookup is 42 bytes of response, so the whole list costs less
      // than a single cover image.
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

  /// `microformat.playerMicroformatRenderer.publishDate` → "2019-05-17".
  /// Falls back to `uploadDate`, then `videoDetails.publishDate`. Some player
  /// clients return the date with a timezone suffix ("2019-05-17T00:00:00-07:00")
  /// — normalized to the plain calendar day. Null when absent or unparseable.
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

  /// The exact release date of [videoId] as "YYYY-MM-DD", or null.
  ///
  /// Cheap: one guest `player` POST, memoized for a week (the release date of a
  /// track never changes). Playing a track fills this cache for free from the
  /// stream resolve, so the common case costs no extra request at all.
  Future<String?> getPublishDate(String videoId) async {
    if (videoId.isEmpty || videoId.length != 11) return null;
    final hit = _publishDateCache.get(videoId);
    if (hit != null) return hit;
    // MUST be WEB_REMIX. The STREAM clients (VISIONOS / ANDROID_VR / IOS)
    // return **no publish date at all** — verified against the live endpoint:
    // only WEB_REMIX and WEB include it, at
    // `microformat.microformatDataRenderer.publishDate` /
    // `microformat.playerMicroformatRenderer.publishDate` respectively. Asking a
    // stream client (the first version of this did) made the whole feature return
    // null every single time, which is why release dates never appeared.
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

  /// [preferMp4] restricts the choice to AAC-in-MP4 formats when any exist.
  ///
  /// This is for FILES THE USER KEEPS, not for playback. YouTube's best audio is
  /// normally Opus in a WebM container, which is the right choice to stream: at
  /// an equal bitrate it sounds better than AAC. But a WebM file cannot carry
  /// MP4/ID3 tags, so a downloaded track had no embedded title, artist or cover
  /// art, and Android's media scanner would not index it either, leaving the
  /// download invisible to every other app on the phone.
  ///
  /// MP4 fixes all of that at the cost of a slightly less efficient codec, which
  /// is the correct trade for a file that gets copied to a car stereo or a PC.
  /// Playback never passes this flag, so streaming quality is unchanged.
  ///
  /// Falls back to the full list when a track genuinely has no MP4 audio, rather
  /// than failing the download.
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
    if (preferMp4) {
      final mp4 = audio
          .where((f) => (f['mimeType'] ?? '').toString().startsWith('audio/mp4'))
          .toList();
      if (mp4.isNotEmpty) audio = mp4;
    }

    // Adaptive ceiling first
    // [maxBitrate] is measured, not guessed: it comes from media3's throughput
    // estimate and the mid-track stall count (see adaptive_bitrate.dart). This
    // replaces the old rule, which was "highest format unless the device says
    // mobile data" — a proxy that mislabels weak Wi-Fi as good and good 5G as
    // bad, and that never noticed a track stalling in front of it.
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

  /// POST and return the raw response body (caller decodes/parses, possibly on
  /// an isolate). Catalog calls (search/browse/home/next) are sent GUEST by
  /// default: authenticated WEB_REMIX responses are far larger (personalized
  /// shelves) — ~1.8 MB each vs a few hundred KB, which made search, page loads
  /// and audio resolution noticeably slow once a real login was captured. Only
  /// calls that genuinely need the user (e.g. account_menu) pass
  /// [authenticated] = true. Streaming has its own guest path in _postPlayer.
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

    // Throttling was invisible to the pacer.
    //
    // A 429 (or a 503) threw like any other failure, callers turned it into an
    // empty result, and the limiter carried on at full speed, so the app kept
    // sprinting into a wall it could not see, and the user could not tell
    // "nothing matched" from "we are being throttled".
    //
    // One retry, after telling the limiter to back off. Retry-After is honoured
    // when the server sends it, because guessing shorter than the server asked
    // is how a soft throttle becomes a hard block.
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

  /// [authenticated] attaches the signed-in user's cookies + SAPISIDHASH.
  ///
  /// Only as a last resort, AND only because the guest chain has already
  /// FAILED. This was tried as the default once and the player endpoint answered
  /// HTTP 400 — the login-free clients hand back their un-throttled urls for
  /// UNAUTHENTICATED requests, and auth is how you lose them. See the call site
  /// in [getStreamUrl] for why it is still worth one attempt at the very end.
  /// [fields] is Google's response mask, e.g. `videoDetails.viewCount`. InnerTube
  /// honours it, and for anything that needs ONE value that turns a 51 KB
  /// response into 42 bytes — measured. Omit it to get the whole response, which
  /// is what stream resolution needs.
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
    // IMPORTANT: stream resolution must be GUEST. The login-free clients
    // (VISIONOS / ANDROID_VR / IOS) return their un-throttled URLs only for
    // unauthenticated requests — attaching the user's Cookie/SAPISIDHASH makes
    // the player endpoint reject with HTTP 400. (Auth still flows on catalog
    // requests in _postRaw, where it personalizes results.) These stream
    // clients are used WITHOUT login by design.
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

  /// Harvest the visitor id from a response.
  ///
  /// THIS IS WHY STREAMS FALL BACK TO A GATED CLIENT. It only read
  /// `parsed['visitorData']`, a TOP-LEVEL key that exists purely because
  /// CatalogApiParser's isolate entry points lift it there
  /// (`decodeAndCollect` / `decodeAndHome` / `decodeAndArtist` all copy
  /// `responseContext.visitorData` up). So the harvest worked for CATALOG
  /// requests and never for `_postPlayer`, which decodes the player response
  /// itself.
  ///
  /// The consequence is a chain that ends in broken playback:
  ///
  ///   cached home data (no network catalog call at all)
  ///     → `_visitorData` stays null
  ///     → VISIONOS answers UNPLAYABLE and ANDROID_VR answers LOGIN_REQUIRED,
  ///       because those login-free clients want a visitor id
  ///     → resolution falls through to IOS
  ///     → that URL carries no `pot` and no `n`
  ///     → googlevideo serves ~1 MiB and 403s the rest, i.e. the track dies
  ///       around 0:52
  ///
  /// Observed exactly that way on a cold start: "Using cached home data" at
  /// +458ms, a stream resolve at +567ms, three client rejections, then IOS.
  ///
  /// Reading `responseContext` directly means the FIRST player response seeds
  /// the id for every resolve after it, regardless of what the caches served.
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
      // STAMPED, BECAUSE AN ID HAS A SHELF LIFE. Without a date the restore
      // below cannot tell a fresh id from one harvested a week ago, and the
      // stale one is exactly what makes every player client refuse.
      p.setInt(_kVisitorAtPref, DateTime.now().millisecondsSinceEpoch);
      return true;
    }).catchError((_) => false);
  }

  /// Without this, the first resolve of every cold start is still degraded.
  ///
  /// Harvesting the id from responses fixes the second resolve onward, but the
  /// first one has nothing yet, and on a cold start with warm caches ("Using
  /// cached home data") no catalog request runs at all, so the very request that
  /// matters most goes out bare and lands on the gated client.
  ///
  /// The id is stable and not a credential — it identifies a fresh anonymous
  /// session, not the user, so persisting it is safe and makes the first resolve
  /// as good as the hundredth. One pref read, once per process.
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
      // An old ID is kept AND marked, never thrown away
      //
      // THE REGRESSION THIS FIXES, caught on device within minutes of shipping
      // the age check:
      //
      // No playable stream resolved for dC9QIUKviJU (visitor id ABSENT)
      //
      // The first version deleted an undated or expired id and returned. Every
      // id stored before the stamp existed is undated, so the very first launch
      // on the new build discarded a PERFECTLY GOOD id and went out bare — and
      // bare is the degraded state this whole mechanism exists to avoid (see
      // _captureVisitor: the login-free clients answer UNPLAYABLE and
      // LOGIN_REQUIRED without a visitor id). Worse, _visitorRestoreTried was
      // already latched, so nothing would read the pref again this process.
      //
      // Keeping it and setting _visitorStale is strictly better in both
      // directions: a still-good id keeps working, and a genuinely dead one is
      // replaced by the first response that carries a responseContext, which is
      // the same self-healing path a whole-chain refusal uses. Nothing is ever
      // deleted on a guess.
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
