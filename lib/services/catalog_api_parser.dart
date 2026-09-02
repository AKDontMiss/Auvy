import 'dart:convert';

/// Turns raw YouTube/YouTube-Music InnerTube JSON into the normalized item maps
/// the rest of Auvy consumes: `{ items: [ {...} ], continuation: <token?> }`.
///
/// This layer went MISSING during an earlier refactor: `CatalogApiClient` was
/// returning raw JSON while every caller expected the parsed shape, which is why
/// search and home showed "random/wrong" content.
///
/// Each normalized item is a `Map<String, dynamic>` with these keys:
///   id          videoId for tracks; browseId for album/artist/playlist
///   videoId     the playable video id (tracks only; '' otherwise)
///   type        'track' | 'album' | 'artist' | 'playlist'
///   title       primary title
///   artist      joined artist name(s)
///   album       album name ('' if none)
///   albumId     album browseId ('' if none)
///   thumbnail   highest-res thumbnail URL
///   durationMs  duration in milliseconds (0 if unknown)
///   isExplicit  bool
///   source      always 'youtube'
class CatalogApiParser {
  CatalogApiParser._();

  static final RegExp _timeRegex = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');
  static final RegExp _separatorRegex = RegExp(r'^[\s•·,&]+$');
  static const Set<String> _typeLabels = {
    'song', 'songs', 'video', 'videos', 'album', 'albums', 'single', 'singles',
    'ep', 'artist', 'artists', 'playlist', 'playlists', 'podcast', 'podcasts',
    'episode', 'episodes', 'audiobook',
  };

  // Public entry points

  static Map<String, dynamic> parseSearch(Map<String, dynamic> raw) => _collect(raw);
  static Map<String, dynamic> parseBrowse(Map<String, dynamic> raw) => _collect(raw);
  static Map<String, dynamic> parseContinuation(Map<String, dynamic> raw) => _collect(raw);
  static Map<String, dynamic> parseNext(Map<String, dynamic> raw) => _collect(raw);

  // Isolate-friendly entry points: decode + parse a raw response body off the
  // UI thread (used via `compute`). Static + pure so they're safe to send to an
  // isolate. Also harvest the real visitor id from responseContext.
  static Map<String, dynamic> decodeAndCollect(String body) {
    final raw = jsonDecode(body) as Map<String, dynamic>;
    final res = _collect(raw);
    final vd = _dig(raw, ['responseContext', 'visitorData']);
    if (vd is String && vd.isNotEmpty) res['visitorData'] = vd;
    return res;
  }

  /// Query completions from `music/get_search_suggestions`.
  ///
  /// The response carries two section types. This reads only the text
  /// completions (`searchSuggestionRenderer`); the second section holds real
  /// entities in `musicResponsiveListItemRenderer`, which [_collect] already
  /// understands if a richer suggestion UI ever wants them.
  ///
  /// A suggestion arrives as RUNS, split around the part matching what was typed
  /// ("the week" + "nd"), so the runs must be concatenated — taking the first run
  /// alone yields the prefix the user already typed.
  static List<String> decodeAndSuggestions(String body) {
    final raw = jsonDecode(body);
    final out = <String>[];
    final seen = <String>{};

    void walk(dynamic node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      final s = node['searchSuggestionRenderer'];
      if (s is Map) {
        final runs = _dig(s, ['suggestion', 'runs']);
        if (runs is List) {
          final text = runs
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          // Deduped: YouTube can return the same completion twice across
          // sections, and a repeated row in a suggestion list looks broken.
          if (text.isNotEmpty && seen.add(text.toLowerCase())) out.add(text);
        }
        return; // consumed
      }
      for (final v in node.values) {
        walk(v);
      }
    }

    walk(raw);
    return out;
  }

  static Map<String, dynamic> decodeAndHome(String body) {
    final raw = jsonDecode(body) as Map<String, dynamic>;
    final vd = _dig(raw, ['responseContext', 'visitorData']);
    return {
      'sections': parseHomeSections(raw),
      if (vd is String && vd.isNotEmpty) 'visitorData': vd,
    };
  }

  /// Decode + parse an ARTIST browse page (channel UC…) into titled shelves,
  /// preserving the shelf grouping that `_collect` flattens away. The artist
  /// header name + thumbnail + description + subscriber count are pulled too.
  /// Used to build the full artist discography (Songs / Albums / Singles & EPs
  /// / Featured on / Playlists / Fans might also like).
  static Map<String, dynamic> decodeAndArtist(String body) {
    final raw = jsonDecode(body) as Map<String, dynamic>;
    final vd = _dig(raw, ['responseContext', 'visitorData']);
    final header = _artistHeader(raw);
    return {
      'name': header['name'],
      'thumbnail': header['thumbnail'],
      'description': header['description'],
      'subscriberCount': header['subscriberCount'],
      'sections': parseArtistSections(raw),
      if (vd is String && vd.isNotEmpty) 'visitorData': vd,
    };
  }

  /// The signed-in account profile from an `account/account_menu` response.
  /// Deep-searches for `activeAccountHeaderRenderer` (robust to layout shifts)
  /// and pulls the display name, email/handle and largest avatar thumbnail.
  /// Returns `{name, email, handle, avatarUrl}` or null when no header is found.
  static Map<String, String>? parseAccountMenu(dynamic raw) {
    Map? header;
    void find(dynamic node) {
      if (header != null) return;
      if (node is List) {
        for (final e in node) {
          find(e);
        }
        return;
      }
      if (node is! Map) return;
      final h = node['activeAccountHeaderRenderer'];
      if (h is Map) {
        header = h;
        return;
      }
      for (final v in node.values) {
        find(v);
      }
    }

    find(raw);
    if (header == null) return null;

    final name = _firstRunText(_dig(header, ['accountName', 'runs']));
    final email = _firstRunText(_dig(header, ['email', 'runs']));
    final handle = _firstRunText(_dig(header, ['channelHandle', 'runs']));

    String avatar = '';
    int aw = 0;
    final thumbs = _dig(header, ['accountPhoto', 'thumbnails']);
    if (thumbs is List) {
      for (final t in thumbs) {
        if (t is! Map) continue;
        final w = (t['width'] as num?)?.toInt() ?? 0;
        final u = (t['url'] ?? '').toString();
        if (u.isNotEmpty && w >= aw) {
          aw = w;
          avatar = u;
        }
      }
    }

    if (name.isEmpty && email.isEmpty && handle.isEmpty) return null;
    return {'name': name, 'email': email, 'handle': handle, 'avatarUrl': avatar};
  }

  /// Artist page shelves as `[{ title, items: [...] }]`, in page order. Handles
  /// both musicCarouselShelfRenderer (Albums/Singles/Featured/related carousels)
  /// and musicShelfRenderer (the top "Songs" list).
  static List<Map<String, dynamic>> parseArtistSections(Map raw) {
    final sections = <Map<String, dynamic>>[];

    void walk(dynamic node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;

      final carousel = node['musicCarouselShelfRenderer'];
      if (carousel is Map) {
        final headerR =
            _dig(carousel, ['header', 'musicCarouselShelfBasicHeaderRenderer']);
        final title = _firstRunText(_dig(headerR, ['title', 'runs']));
        final items = _itemsFromContents(carousel['contents']);
        // The shelf's "Show all" button navigates to the FULL grid (all singles,
        // all albums) — the carousel itself only previews ~10. Capture its
        // browse endpoint so the caller can follow it for complete discography.
        final moreEp = _dig(headerR,
            ['moreContentButton', 'buttonRenderer', 'navigationEndpoint', 'browseEndpoint']);
        final moreBrowseId = (_dig(moreEp, ['browseId']) ?? '').toString();
        final moreParams = (_dig(moreEp, ['params']) ?? '').toString();
        if (title.isNotEmpty && items.isNotEmpty) {
          sections.add({
            'title': title,
            'items': items,
            if (moreBrowseId.isNotEmpty) 'moreBrowseId': moreBrowseId,
            if (moreParams.isNotEmpty) 'moreParams': moreParams,
          });
        }
        return; // consumed
      }

      final shelf = node['musicShelfRenderer'];
      if (shelf is Map) {
        final title = _firstRunText(_dig(shelf, ['title', 'runs']));
        final items = _itemsFromContents(shelf['contents']);
        if (title.isNotEmpty && items.isNotEmpty) {
          sections.add({'title': title, 'items': items});
        }
        return; // consumed
      }

      for (final v in node.values) {
        walk(v);
      }
    }

    walk(raw);
    return sections;
  }

  static List<Map<String, dynamic>> _itemsFromContents(dynamic contents) {
    final items = <Map<String, dynamic>>[];
    if (contents is! List) return items;
    for (final c in contents) {
      if (c is! Map) continue;
      if (c.containsKey('musicTwoRowItemRenderer')) {
        final m = _parseTwoRowItem(_asMap(c['musicTwoRowItemRenderer']));
        if (m != null) items.add(m);
      } else if (c.containsKey('musicResponsiveListItemRenderer')) {
        final m = _parseMusicResponsiveListItem(_asMap(c['musicResponsiveListItemRenderer']));
        if (m != null) items.add(m);
      }
    }
    return items;
  }

  /// Artist display name + header thumbnail from musicImmersiveHeaderRenderer
  /// (or the visualHeader fallback), plus the "About" bio and subscriber count
  /// when the page ships them.
  static Map<String, String> _artistHeader(Map raw) {
    String name = '';
    String thumb = '';
    String description = '';
    String subscribers = '';

    String joinRuns(dynamic runs) {
      if (runs is! List) return '';
      final sb = StringBuffer();
      for (final r in runs) {
        if (r is Map) sb.write((r['text'] ?? '').toString());
      }
      return sb.toString();
    }

    String findName(dynamic node) {
      if (node is Map) {
        final h = node['musicImmersiveHeaderRenderer'] ?? node['musicVisualHeaderRenderer'];
        if (h is Map) {
          final t = _firstRunText(_dig(h, ['title', 'runs']));
          if (t.isNotEmpty) {
            // foregroundThumbnail is the true circular profile avatar on
            // immersive headers; plain `thumbnail` can be the wide banner.
            final thumbs = _dig(h, ['foregroundThumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
                _dig(h, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']);
            if (thumbs is List && thumbs.isNotEmpty) {
              final url = _dig(thumbs.last, ['url']);
              if (url is String) thumb = url;
            }
            description = joinRuns(_dig(h, ['description', 'runs']));
            subscribers = _firstRunText(_dig(h,
                ['subscriptionButton', 'subscribeButtonRenderer', 'subscriberCountText', 'runs']));
            if (subscribers.isEmpty) {
              subscribers = _firstRunText(_dig(h,
                  ['subscriptionButton', 'subscribeButtonRenderer', 'longSubscriberCountText', 'runs']));
            }
            return t;
          }
        }
        for (final v in node.values) {
          final r = findName(v);
          if (r.isNotEmpty) return r;
        }
      } else if (node is List) {
        for (final e in node) {
          final r = findName(e);
          if (r.isNotEmpty) return r;
        }
      }
      return '';
    }

    name = findName(raw);

    // Some layouts ship the bio in a nested musicDescriptionShelfRenderer
    // (under the header or in the page sections) instead of on the header
    // renderer itself — fall back to the first one anywhere in the response.
    if (description.isEmpty) {
      String findDescriptionShelf(dynamic node) {
        if (node is Map) {
          final shelf = node['musicDescriptionShelfRenderer'];
          if (shelf is Map) {
            final d = joinRuns(_dig(shelf, ['description', 'runs']));
            if (d.isNotEmpty) return d;
          }
          for (final v in node.values) {
            final r = findDescriptionShelf(v);
            if (r.isNotEmpty) return r;
          }
        } else if (node is List) {
          for (final e in node) {
            final r = findDescriptionShelf(e);
            if (r.isNotEmpty) return r;
          }
        }
        return '';
      }

      description = findDescriptionShelf(raw);
    }

    return {
      'name': name,
      'thumbnail': thumb,
      'description': description,
      'subscriberCount': subscribers,
    };
  }

  static String playabilityStatus(Map raw) =>
      (_dig(raw, ['playabilityStatus', 'status']) ?? '').toString();

  /// Parse the home/explore feed (FEmusic_home) into titled carousels:
  /// `[{ title, items: [...] }]`. Items may be tracks, albums or playlists.
  static List<Map<String, dynamic>> parseHomeSections(Map raw) {
    final sections = <Map<String, dynamic>>[];

    void walk(dynamic node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;

      final carousel = node['musicCarouselShelfRenderer'];
      if (carousel is Map) {
        final title = _firstRunText(
            _dig(carousel, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title', 'runs']));
        final items = <Map<String, dynamic>>[];
        final contents = carousel['contents'];
        if (contents is List) {
          for (final c in contents) {
            if (c is! Map) continue;
            if (c.containsKey('musicTwoRowItemRenderer')) {
              final m = _parseTwoRowItem(_asMap(c['musicTwoRowItemRenderer']));
              if (m != null) items.add(m);
            } else if (c.containsKey('musicResponsiveListItemRenderer')) {
              final m = _parseMusicResponsiveListItem(_asMap(c['musicResponsiveListItemRenderer']));
              if (m != null) items.add(m);
            }
          }
        }
        if (title.isNotEmpty && items.isNotEmpty) {
          sections.add({'title': title, 'items': items});
        }
        return; // don't recurse into the carousel we just consumed
      }

      for (final v in node.values) {
        walk(v);
      }
    }

    walk(raw);
    return sections;
  }

  // Core: recursively collect items + continuation from any layout
  //
  // InnerTube layouts vary wildly (sectionListRenderer, musicShelfRenderer,
  // musicCarouselShelfRenderer, twoColumn/singleColumn browse, watch-next
  // panels, continuations...). Rather than hard-code every path, we walk the
  // tree and pull out the renderers we understand. This is resilient to layout
  // changes, which is exactly what broke the old hard-coded parser.
  static Map<String, dynamic> _collect(dynamic raw) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? continuation;
    // Largest thumbnail anywhere in the response — for an album/playlist browse
    // this is the header cover. Album track rows usually carry NO per-track
    // thumbnail, so callers backfill track images with this (fixes blank album
    // track artwork).
    String headerThumb = '';
    int headerThumbW = 0;
    // The album/playlist header title (the real collection name). Album track
    // rows carry only the track title, so callers stamp this onto each track's
    // albumTitle — otherwise the page shows the navigated track-name fallback.
    String headerTitle = '';
    // The album/playlist primary artist from the header. Album track rows often
    // omit the artist (it's implied by the header), so callers stamp this onto
    // tracks whose own artist came back empty.
    String headerArtist = '';
    // The album's release year, parsed from the header subtitle
    // ("Album • Artist • 2021 • N songs"). Callers stamp it onto each track so
    // the album page shows the real year instead of "Unknown" (e.g. when the
    // album is opened from the player's title tap with no year to hand).
    String headerYear = '';

    void add(Map<String, dynamic>? m) {
      if (m == null) return;
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty) return;
      if (seen.add(id)) items.add(m);
    }

    // Counts Map nodes visited. One increment on the hot path, so a 1.4 MB
    // browse pays nothing measurable, and it is the number that separates
    // "nothing matched the search" from "the response shape moved under us".
    var nodesWalked = 0;
    void walk(dynamic node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      nodesWalked++;

      // Track the largest thumbnail in the whole response — for an album/playlist
      // browse that's the header cover. Scan ANY `thumbnails` array (covers all
      // wrappers: musicThumbnailRenderer, croppedSquareThumbnailRenderer, etc.)
      // so album track rows that carry no per-row art can be backfilled with it.
      final thumbs = node['thumbnails'];
      if (thumbs is List) {
        for (final t in thumbs) {
          if (t is! Map) continue;
          final w = (t['width'] as num?)?.toInt() ?? 0;
          final u = (t['url'] ?? '').toString();
          if (u.isNotEmpty && w >= headerThumbW) {
            headerThumbW = w;
            headerThumb = u;
          }
        }
      }

      // Capture the album/playlist header title from whichever header renderer
      // this browse uses (newer responsive header, older detail header).
      if (headerTitle.isEmpty || headerArtist.isEmpty || headerYear.isEmpty) {
        final hdr = node['musicResponsiveHeaderRenderer'] ??
            node['musicDetailHeaderRenderer'];
        if (hdr is Map) {
          if (headerTitle.isEmpty) {
            final t = _firstRunText(_dig(hdr, ['title', 'runs']));
            if (t.isNotEmpty) headerTitle = t;
          }
          if (headerYear.isEmpty) {
            headerYear = _yearFromRuns(_dig(hdr, ['subtitle', 'runs']));
          }
          if (headerArtist.isEmpty) {
            // Newer responsive header puts the artist link in straplineTextOne;
            // older detail header carries it in the "Album • Artist • Year"
            // subtitle, which _artistAlbumFromRuns picks the linked artist from.
            final strap = _firstRunText(_dig(hdr, ['straplineTextOne', 'runs']));
            if (strap.isNotEmpty) {
              headerArtist = strap;
            } else {
              final sub = _artistAlbumFromRuns(_dig(hdr, ['subtitle', 'runs']));
              if (sub.artist.isNotEmpty) headerArtist = sub.artist;
            }
          }
        }
      }

      if (node.containsKey('musicResponsiveListItemRenderer')) {
        add(_parseMusicResponsiveListItem(
            _asMap(node['musicResponsiveListItemRenderer'])));
        return;
      }
      if (node.containsKey('musicTwoRowItemRenderer')) {
        add(_parseTwoRowItem(_asMap(node['musicTwoRowItemRenderer'])));
        return;
      }
      if (node.containsKey('playlistPanelVideoRenderer')) {
        add(_parsePanelVideo(_asMap(node['playlistPanelVideoRenderer'])));
        return;
      }

      // Capture the first continuation token we encounter.
      if (continuation == null && node.containsKey('continuations')) {
        continuation = _extractContinuation(node['continuations']);
      }
      if (continuation == null && node.containsKey('continuationItemRenderer')) {
        final tok = _dig(node, [
          'continuationItemRenderer',
          'continuationEndpoint',
          'continuationCommand',
          'token'
        ]);
        if (tok is String && tok.isNotEmpty) continuation = tok;
      }

      for (final v in node.values) {
        walk(v);
      }
    }

    walk(raw);

    // An empty result is two different events, AND they looked identical
    //
    // Every search, browse, continuation and "next" in the app funnels through
    // here, and until now a parse that understood NOTHING returned the same empty
    // list as a search with no matches. The screen says "nothing here" either
    // way, and 926 lines of renderer parsing had no log line in them, so the day
    // this file stops matching YouTube's response shape, the app has no way to
    // say so. That is a failure shape this codebase has already met more than
    // once: an empty collection standing in for both "no data" and "not loaded".
    //
    // A response with hundreds of nodes in it is not empty; it is unparsed. The
    // renderer names are gathered on a SECOND pass, taken only when something is
    // already known to be wrong, so the ordinary path pays one integer increment.
    if (items.isEmpty && nodesWalked > 150) {
      final renderers = <String>{};
      void sniff(dynamic n) {
        if (n is List) {
          for (final e in n) {
            sniff(e);
          }
          return;
        }
        if (n is! Map) return;
        for (final k in n.keys) {
          if (k is String && k.endsWith('Renderer') && renderers.length < 12) {
            renderers.add(k);
          }
        }
        for (final v in n.values) {
          sniff(v);
        }
      }
      sniff(raw);
      print('WARN: parsed 0 items from a $nodesWalked-node response — content came '
          'back that no renderer parser understood, which is NOT the same as an '
          'empty result. Renderers present: '
          '${renderers.isEmpty ? "none" : renderers.join(", ")}');
    }

    return {
      'items': items,
      'continuation': continuation,
      'headerThumbnail': headerThumb,
      'headerTitle': headerTitle,
      'headerArtist': headerArtist,
      'headerYear': headerYear,
    };
  }

  // Renderer parsers

  static Map<String, dynamic>? _parseMusicResponsiveListItem(Map r) {
    final title = _firstRunText(
        _dig(r, ['flexColumns', 0, 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']));
    if (title.isEmpty) return null;

    String videoId = (_dig(r, ['playlistItemData', 'videoId']) ?? '').toString();
    if (videoId.isEmpty) {
      videoId = (_dig(r, [
                'overlay',
                'musicItemThumbnailOverlayRenderer',
                'content',
                'musicPlayButtonRenderer',
                'playNavigationEndpoint',
                'watchEndpoint',
                'videoId'
              ]) ??
              '')
          .toString();
    }
    if (videoId.isEmpty) {
      videoId = (_dig(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']) ?? '').toString();
    }

    final browseId = (_dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']) ?? '').toString();
    final pageType = (_dig(r, [
              'navigationEndpoint',
              'browseEndpoint',
              'browseEndpointContextSupportedConfigs',
              'browseEndpointContextMusicConfig',
              'pageType'
            ]) ??
            '')
        .toString();

    final subRuns = _dig(r, ['flexColumns', 1, 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']);
    final meta = _artistAlbumFromRuns(subRuns);
    final durMs = _durationFromRuns(subRuns) ??
        _durationFromRuns(_dig(r, ['flexColumns', 2, 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs'])) ??
        0;

    final resolved = _resolveTypeAndId(pageType, videoId, browseId);
    if (resolved == null) return null;

    return {
      'id': resolved.id,
      'videoId': videoId,
      'type': resolved.type,
      'title': title,
      'artist': meta.artist,
      'artists': meta.artists,
      'album': meta.album,
      'albumId': meta.albumId,
      'thumbnail': _thumbnail(r),
      'durationMs': durMs,
      'isExplicit': _hasExplicitBadge(r['badges']),
      // ATV = clean audio "song"; OMV/UGC = a music VIDEO. Lets search prefer
      // the audio version (Spotify/Apple-style) over the video.
      'musicVideoType': _musicVideoType(r),
      // Stream/view count label ("1.2B plays" / "500M views"), '' when YouTube
      // doesn't expose it for this row.
      'viewCount': _viewCount(r),
      'source': 'youtube',
    };
  }

  // A play/stream/view count run, e.g. "1.2B plays", "500M views", "12,345 streams".
  static final RegExp _viewRegex =
      RegExp(r'^[\d][\d.,]*\s*[KMB]?\+?\s*(plays|views|streams)$', caseSensitive: false);

  /// First play/view-count token found in a track row's secondary flex columns
  /// (artist column or the trailing stats column). '' when absent.
  static String _viewCount(Map r) {
    for (final col in [1, 2, 3]) {
      final runs =
          _dig(r, ['flexColumns', col, 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']);
      final v = _viewCountFromRuns(runs);
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  static String _viewCountFromRuns(dynamic runs) {
    if (runs is! List) return '';
    for (final run in runs) {
      if (run is! Map) continue;
      final text = (run['text'] ?? '').toString().trim();
      if (_viewRegex.hasMatch(text)) return text;
    }
    return '';
  }

  /// The MUSIC_VIDEO_TYPE_* of a track item ('' if unknown). ATV = audio song,
  /// OMV/UGC = music video. Checked on both the play-overlay and the row's
  /// navigation watch endpoint.
  static String _musicVideoType(Map r) {
    const tail = ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType'];
    final a = _dig(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content',
      'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', ...tail]);
    if (a is String && a.isNotEmpty) return a;
    final b = _dig(r, ['navigationEndpoint', 'watchEndpoint', ...tail]);
    return (b is String) ? b : '';
  }

  static Map<String, dynamic>? _parseTwoRowItem(Map r) {
    final title = _firstRunText(_dig(r, ['title', 'runs']));
    if (title.isEmpty) return null;

    final videoId = (_dig(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']) ?? '').toString();
    final browseId = (_dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']) ?? '').toString();
    final pageType = (_dig(r, [
              'navigationEndpoint',
              'browseEndpoint',
              'browseEndpointContextSupportedConfigs',
              'browseEndpointContextMusicConfig',
              'pageType'
            ]) ??
            '')
        .toString();

    final subtitleRuns = _dig(r, ['subtitle', 'runs']);
    final meta = _artistAlbumFromRuns(subtitleRuns);
    final resolved = _resolveTypeAndId(pageType, videoId, browseId);
    if (resolved == null) return null;

    return {
      'id': resolved.id,
      'videoId': videoId,
      'type': resolved.type,
      'title': title,
      'artist': meta.artist,
      'artists': meta.artists,
      'album': meta.album,
      'albumId': meta.albumId,
      // The artist page distinguishes Albums from Singles/EPs by the leading
      // word of the subtitle ("Album • 2021", "Single • 2020", "EP • 2019").
      // pageType is MUSIC_PAGE_TYPE_ALBUM for ALL of them, so this run-text is
      // the only reliable signal.
      'recordType': _recordTypeFromRuns(subtitleRuns, resolved.type),
      // The item's own subtitle verbatim ("Album • 2021", "Single • 2020",
      // "Playlist • <creator>") + the extracted year, so the UI can show the
      // real release year on albums and a proper "Playlist • creator" label
      // instead of a hardcoded "Album •".
      'subtitle': _joinRuns(subtitleRuns),
      'releaseDate': _yearFromRuns(subtitleRuns),
      'thumbnail': _thumbnail(r),
      'durationMs': 0,
      'isExplicit': _hasExplicitBadge(r['subtitleBadges']),
      'viewCount': _viewCountFromRuns(subtitleRuns),
      // Carousel/grid track cards can be music VIDEOS too (home feed, artist
      // "Videos" shelf) — stamp the type so audio-only mode can drop them.
      'musicVideoType': _musicVideoType(r),
      'source': 'youtube',
    };
  }

  /// Leading descriptor word of a subtitle ("Album"/"Single"/"EP"/"Playlist"),
  /// lower-cased. Falls back to the resolved item type when no descriptor word
  /// is present (e.g. a bare "2021 • 1.2M views" subtitle).
  static String _recordTypeFromRuns(dynamic runs, String fallbackType) {
    if (runs is List) {
      for (final run in runs) {
        if (run is! Map) continue;
        final text = (run['text'] ?? '').toString().trim().toLowerCase();
        if (text.isEmpty || _separatorRegex.hasMatch(text)) continue;
        if (text == 'single') return 'single';
        if (text == 'ep') return 'ep';
        if (text == 'album') return 'album';
        if (text == 'playlist') return 'playlist';
        // First non-separator token wasn't a descriptor → stop guessing.
        break;
      }
    }
    return fallbackType;
  }

  /// Join a subtitle's runs into their display text, e.g. "Album • 2021" or
  /// "Playlist • Chill Vibes". Shown verbatim in the UI.
  static String _joinRuns(dynamic runs) {
    if (runs is! List) return '';
    final b = StringBuffer();
    for (final run in runs) {
      if (run is Map && run['text'] != null) b.write(run['text'].toString());
    }
    return b.toString().trim();
  }

  /// First 4-digit year (19xx/20xx) found in the subtitle runs, or '' if none.
  static String _yearFromRuns(dynamic runs) {
    final m = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(_joinRuns(runs));
    return m?.group(0) ?? '';
  }

  static Map<String, dynamic>? _parsePanelVideo(Map r) {
    final videoId = (_dig(r, ['videoId']) ??
            _dig(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']) ??
            '')
        .toString();
    if (videoId.isEmpty) return null;
    final title = _firstRunText(_dig(r, ['title', 'runs']));
    if (title.isEmpty) return null;

    final byline = _dig(r, ['longBylineText', 'runs']) ?? _dig(r, ['shortBylineText', 'runs']);
    final meta = _artistAlbumFromRuns(byline);
    final durMs = _durationFromRuns(_dig(r, ['lengthText', 'runs'])) ?? 0;

    return {
      'id': videoId,
      'videoId': videoId,
      'type': 'track',
      'title': title,
      'artist': meta.artist,
      'artists': meta.artists,
      'album': meta.album,
      'albumId': meta.albumId,
      'thumbnail': _thumbnail(r),
      'durationMs': durMs,
      'isExplicit': _hasExplicitBadge(r['badges']),
      'musicVideoType': _musicVideoType(r),
      'source': 'youtube',
    };
  }

  // Field helpers

  static _TypeId? _resolveTypeAndId(String pageType, String videoId, String browseId) {
    final pt = pageType.toUpperCase();
    if (pt.contains('ARTIST')) {
      return browseId.isEmpty ? null : _TypeId('artist', browseId);
    }
    if (pt.contains('ALBUM') || pt.contains('AUDIOBOOK')) {
      return browseId.isEmpty ? null : _TypeId('album', browseId);
    }
    if (pt.contains('PLAYLIST') || pt.contains('PODCAST')) {
      return browseId.isEmpty ? null : _TypeId('playlist', _stripVL(browseId));
    }
    if (videoId.isNotEmpty) return _TypeId('track', videoId);
    if (browseId.isNotEmpty) return _TypeId('album', browseId); // best-effort
    return null;
  }

  static _ArtistAlbum _artistAlbumFromRuns(dynamic runs) {
    if (runs is! List) return const _ArtistAlbum('', '', '');
    final artists = <String>[];
    final artistRefs = <Map<String, String>>[]; // {name, id} per artist
    String album = '';
    String albumId = '';

    for (final run in runs) {
      if (run is! Map) continue;
      final text = (run['text'] ?? '').toString();
      if (_separatorRegex.hasMatch(text)) continue;
      final pt = (_dig(run, [
                'navigationEndpoint',
                'browseEndpoint',
                'browseEndpointContextSupportedConfigs',
                'browseEndpointContextMusicConfig',
                'pageType'
              ]) ??
              '')
          .toString()
          .toUpperCase();
      final bid = (_dig(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']) ?? '').toString();
      if (pt.contains('ARTIST')) {
        artists.add(text);
        artistRefs.add({'name': text, 'id': bid});
      } else if (pt.contains('ALBUM') || pt.contains('AUDIOBOOK')) {
        album = text;
        albumId = bid;
      }
    }

    // Fallback: no linked artist run → take the first plain text token that is
    // not a separator / duration / type-label / stats line.
    if (artists.isEmpty) {
      for (final run in runs) {
        if (run is! Map) continue;
        final text = (run['text'] ?? '').toString();
        if (_separatorRegex.hasMatch(text)) continue;
        if (_timeRegex.hasMatch(text)) continue;
        if (_typeLabels.contains(text.toLowerCase())) continue;
        final lower = text.toLowerCase();
        if (lower.contains('play') || lower.contains('view') || lower.contains('subscriber')) {
          continue;
        }
        artists.add(text);
        artistRefs.add({'name': text, 'id': ''});
        break;
      }
    }

    return _ArtistAlbum(artists.join(', '), album, albumId, artistRefs);
  }

  static int? _durationFromRuns(dynamic runs) {
    if (runs is! List) return null;
    for (final run in runs.reversed) {
      if (run is! Map) continue;
      final t = (run['text'] ?? '').toString().trim();
      if (_timeRegex.hasMatch(t)) return _timeToMs(t);
    }
    return null;
  }

  static int _timeToMs(String t) {
    final parts = t.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    int seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p;
    }
    return seconds * 1000;
  }

  static String _thumbnail(Map r) {
    const paths = [
      ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'],
      ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'],
      ['thumbnail', 'thumbnails'],
    ];
    for (final p in paths) {
      final list = _dig(r, p);
      if (list is List && list.isNotEmpty) {
        final url = _dig(list.last, ['url']);
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static bool _hasExplicitBadge(dynamic badges) {
    if (badges is! List) return false;
    for (final b in badges) {
      final iconType = _dig(b, ['musicInlineBadgeRenderer', 'icon', 'iconType']);
      if (iconType == 'MUSIC_EXPLICIT_BADGE') return true;
    }
    return false;
  }

  static String? _extractContinuation(dynamic conts) {
    if (conts is! List) return null;
    for (final c in conts) {
      final next = _dig(c, ['nextContinuationData', 'continuation']) ??
          _dig(c, ['reloadContinuationData', 'continuation']);
      if (next is String && next.isNotEmpty) return next;
    }
    return null;
  }

  // Low-level utilities

  static String _firstRunText(dynamic runs) {
    if (runs is List && runs.isNotEmpty && runs[0] is Map) {
      return (runs[0]['text'] ?? '').toString();
    }
    return '';
  }

  static String _stripVL(String id) => id.startsWith('VL') ? id.substring(2) : id;

  static Map _asMap(dynamic v) => v is Map ? v : const {};

  static dynamic _dig(dynamic node, List<dynamic> path) {
    dynamic cur = node;
    for (final key in path) {
      if (cur == null) return null;
      if (key is int) {
        if (cur is List && key >= 0 && key < cur.length) {
          cur = cur[key];
        } else {
          return null;
        }
      } else {
        if (cur is Map && cur.containsKey(key)) {
          cur = cur[key];
        } else {
          return null;
        }
      }
    }
    return cur;
  }
}

class _TypeId {
  const _TypeId(this.type, this.id);
  final String type;
  final String id;
}

class _ArtistAlbum {
  const _ArtistAlbum(this.artist, this.album, this.albumId, [this.artists = const []]);
  final String artist;
  final String album;
  final String albumId;
  // Per-artist credits: [{name, id}] — id is the artist browse id ('' if the
  // run wasn't a link). Used so the player can navigate to the tapped artist.
  final List<Map<String, String>> artists;
}
