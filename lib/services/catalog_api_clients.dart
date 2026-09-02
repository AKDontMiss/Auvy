import 'dart:io' show Platform;

/// The minimal set of YouTube InnerTube client identities Auvy needs.
///
/// This replaces the old 13-client "rotation" (`youtube_client_config.dart`).
/// Each client here has a single, proven job — verified live against YouTube:
///
///  * [webRemix] — the YouTube *Music* web client. Used for search / browse /
///    next. Returns the clean music catalog (songs, albums, artists) with rich
///    metadata, unlike the plain `WEB` client which returns generic videos.
///  * [android]  — primary stream resolver. Returns pre-signed media URLs that
///    need **no cipher, no n-param transform, no PoToken and no login**, and
///    whose URLs accept standard HTTP `Range:` headers, so they play directly
///    in ExoPlayer.
///  * [ios]      — stream fallback when [android] is gated.
///
/// Client versions matter: a stale version makes the player endpoint return
/// HTTP 400 (this was the original audio bug — IOS was pinned to 19.28.1).
class CatalogApiClientInfo {
  const CatalogApiClientInfo({
    required this.clientName,
    required this.clientVersion,
    required this.clientId,
    required this.userAgent,
    required this.apiUrl,
    required this.origin,
    this.sourceKey = '',
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
    this.playerHost,
  });

  /// Host to send THIS CLIENT'S `player` request to, when it must differ from
  /// [origin].
  ///
  /// Why the player call can need a different host
  ///
  /// Everything else — search, browse, next — goes to the host in [apiUrl]. The
  /// player endpoint is the exception: Metrolist sends the player request for its
  /// VISIONOS and ANDROID_VR clients to `music.youtube.com` (with a matching
  /// Origin and Referer) via a per-client `useMusicPlayerEndpoint` flag, while
  /// Auvy sent everything to `www.youtube.com`.
  ///
  /// Those are the two clients that carry Auvy's playback, so it is the one
  /// substantive difference between the two apps' stream chains that costs
  /// nothing to try. A music-app client asking the music host is also the more
  /// coherent request of the two.
  ///
  /// Null keeps the old behaviour exactly, so a client is opted in one field at a
  /// time and the change is revertible per client.
  final String? playerHost;

  /// `<host>/youtubei/v1/` for the player call — [playerHost] if set, else the
  /// client's normal [apiUrl].
  String get playerApiUrl =>
      playerHost == null ? apiUrl : '$playerHost/youtubei/v1/';

  /// Origin/Referer to send with the player call. Must match [playerApiUrl]: a
  /// request to the music host carrying a www Origin is a mismatched pair, and
  /// mismatched pairs are exactly what InnerTube rejects.
  String get playerOrigin => playerHost ?? origin;

  /// Stable identity for the "Stream sources" setting. Deliberately COARSER than
  /// the client itself: the two ANDROID_VR builds share `android_vr`, so the user
  /// toggles "Android VR" once and both fallbacks follow. Empty for clients that
  /// aren't part of the stream chain (e.g. [CatalogApiClients.webRemix], which is
  /// the catalog client and must never be switchable).
  final String sourceKey;

  final String clientName;
  final String clientVersion;
  final String clientId; // value for the X-YouTube-Client-Name header
  final String userAgent;
  final String apiUrl; // base, ends with /youtubei/v1/
  final String origin;
  final String? osName;
  final String? osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final int? androidSdkVersion;

  /// The `context.client` block sent in every InnerTube request body.
  Map<String, dynamic> context({String? visitorData}) {
    final client = <String, dynamic>{
      'clientName': clientName,
      'clientVersion': clientVersion,
      // Region + language were HARDCODED to en/US, so every user got US charts,
      // US "new releases" and US-biased search no matter where they were. Now
      // they default to the DEVICE locale and can be overridden in Settings.
      'hl': CatalogApiClients.contentLanguage,
      'gl': CatalogApiClients.contentCountry,
      if (osName != null) 'osName': osName,
      if (osVersion != null) 'osVersion': osVersion,
      if (deviceMake != null) 'deviceMake': deviceMake,
      if (deviceModel != null) 'deviceModel': deviceModel,
      if (androidSdkVersion != null) 'androidSdkVersion': androidSdkVersion,
      if (visitorData != null && visitorData.isNotEmpty) 'visitorData': visitorData,
    };
    return {'client': client};
  }

  /// [forPlayer] switches Origin/Referer to [playerOrigin], so a client whose
  /// player call goes to a different host sends a matching pair rather than a
  /// music-host request stamped with a www Origin.
  Map<String, String> headers({String? visitorData, bool forPlayer = false}) {
    final o = forPlayer ? playerOrigin : origin;
    return {
      'Content-Type': 'application/json',
      'User-Agent': userAgent,
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name': clientId,
      'X-YouTube-Client-Version': clientVersion,
      'Origin': o,
      'Referer': '$o/',
      if (visitorData != null && visitorData.isNotEmpty) 'X-Goog-Visitor-Id': visitorData,
    };
  }
}

class CatalogApiClients {
  CatalogApiClients._();

  // Content region + language
  // Sent as `gl`/`hl` on every InnerTube request. These decide which CHARTS,
  // which "new releases" and which search ranking YouTube Music returns, so a
  // hardcoded US default meant non-US users saw a foreign catalogue.
  //
  // Plain statics (the `SearchService.processVideos` pattern) because
  // `context()` is called on every single request — it must never touch prefs.
  // Defaults come from the DEVICE locale, so this is already correct before the
  // user opens Settings.
  //
  // Changing either MUST be followed by `CatalogApiClient.clearCaches()` —
  // cached search/browse responses are region-specific and would otherwise keep
  // serving the old country's results.
  static String contentCountry = deviceCountry();
  static String contentLanguage = deviceLanguage();

  /// Country from the device locale ("en_GB" → "GB"), "US" if undeterminable.
  static String deviceCountry() {
    try {
      // e.g. "en_GB" / "sv_SE" → "GB" / "SE".
      final locale = Platform.localeName;
      final parts = locale.split(RegExp(r'[_\-.]'));
      if (parts.length >= 2 && parts[1].length == 2) return parts[1].toUpperCase();
    } catch (_) {}
    return 'US';
  }

  /// Language from the device locale ("sv_SE" → "sv"), "en" if undeterminable.
  static String deviceLanguage() {
    try {
      final code = Platform.localeName.split(RegExp(r'[_\-.]')).first;
      if (code.length == 2) return code.toLowerCase();
    } catch (_) {}
    return 'en';
  }

  /// YouTube Music web client — catalog search / browse / next.
  static const CatalogApiClientInfo webRemix = CatalogApiClientInfo(
    clientName: 'WEB_REMIX',
    clientVersion: '1.20240826.01.00',
    clientId: '67',
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
    apiUrl: 'https://music.youtube.com/youtubei/v1/',
    origin: 'https://music.youtube.com',
  );

  // Stream clients
  //
  // These identifiers are FACTS ABOUT YOUTUBE'S API, not an invention: the
  // clientName/clientVersion/deviceModel triples below are what YouTube's own
  // apps send, and they are documented across the open-source YouTube tooling
  // (yt-dlp, ytmusicapi, NewPipe and every InnerTube client). Anyone inspecting
  // YouTube Music traffic arrives at the same list.
  //
  // What makes them worth using: stream URLs from these clients carry NO `spc`
  // throttle gate, so they serve full byte ranges at full speed — unlike the
  // plain ANDROID/IOS-mobile clients, whose URLs are throttled (slow trickle +
  // 403 on large ranges, which is what the stalls were). None of them need a
  // cipher, n-param transform, PoToken or login: their formats carry a direct
  // `url`.
  //
  // The ORDER is functional, not aesthetic — it is which clients actually return
  // un-throttled URLs, established by testing them.

  // Stream clients post to www.youtube.com (the standard host for the
  // non-music ANDROID_VR / VISIONOS / IOS clients, as used by yt-dlp/NewPipe).
  // music.youtube.com works too but flaked with cold-start DNS misses on some
  // devices; www resolves reliably and returns identical un-throttled URLs for
  // these client contexts.
  static const String _ytApi = 'https://www.youtube.com/youtubei/v1/';
  static const String _ytOrigin = 'https://www.youtube.com';
  /// Host the PLAYER call goes to for the clients that carry playback — see
  /// CatalogApiClientInfo.playerHost. Catalog traffic still uses _ytApi.
  static const String _musicHost = 'https://music.youtube.com';

  /// visionOS — the most reliable client in practice: no `spc` throttle gate, and
  /// it streams whole songs with no PoToken or cipher step.
  static const CatalogApiClientInfo visionOs = CatalogApiClientInfo(
    sourceKey: 'visionos',
    clientName: 'VISIONOS',
    clientVersion: '0.1',
    clientId: '101',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    apiUrl: _ytApi,
    origin: _ytOrigin,
    osName: 'visionOS',
    osVersion: '1.3.21O771',
    deviceMake: 'Apple',
    deviceModel: 'RealityDevice14,1',
    playerHost: _musicHost,
  );

  /// Android VR 1.43.32 — this build serves NON-adaptive bitrate, which is why it
  /// does not stutter on YT Music the way the adaptive clients can, and it does
  /// not hand back AV1. Login-free, no cipher.
  static const CatalogApiClientInfo androidVr143 = CatalogApiClientInfo(
    sourceKey: 'android_vr',
    clientName: 'ANDROID_VR',
    clientVersion: '1.43.32',
    clientId: '28',
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; '
        'en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)',
    apiUrl: _ytApi,
    origin: _ytOrigin,
    osName: 'Android',
    osVersion: '12',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: 32,
    playerHost: _musicHost,
  );

  /// Android VR 1.68.34 — newest VR build, login-free, no cipher.
  ///
  /// The version lives in TWO places that must agree: clientVersion and the
  /// User-Agent string. This comment said 1.61.48 while both said 1.68.34,
  /// which cost real time during the 2026-08-30 gating incident — the chain
  /// looked older than Metrolist`s when it is in fact newer.
  static const CatalogApiClientInfo androidVr161 = CatalogApiClientInfo(
    sourceKey: 'android_vr',
    clientName: 'ANDROID_VR',
    clientVersion: '1.68.34',
    clientId: '28',
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.68.34 (Linux; U; Android 12; '
        'en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
    apiUrl: _ytApi,
    origin: _ytOrigin,
    osName: 'Android',
    osVersion: '12',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: 32,
    playerHost: _musicHost,
  );

  /// iOS YouTube client — stream fallback.
  static const CatalogApiClientInfo ios = CatalogApiClientInfo(
    sourceKey: 'ios',
    clientName: 'IOS',
    clientVersion: '21.03.1',
    clientId: '5',
    userAgent:
        'com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)',
    apiUrl: _ytApi,
    origin: _ytOrigin,
    osVersion: '18.2.22C152',
  );

  /// iPadOS — last-ditch fallback.
  static const CatalogApiClientInfo ipadOs = CatalogApiClientInfo(
    sourceKey: 'ipados',
    clientName: 'IOS',
    clientVersion: '21.03.3',
    clientId: '5',
    userAgent:
        'com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)',
    apiUrl: _ytApi,
    origin: _ytOrigin,
    osName: 'iPadOS',
    osVersion: '17.7.10.21H450',
    deviceMake: 'Apple',
    deviceModel: 'iPad7,6',
  );

  /// Player resolve order: visionOS first, then the VR builds, then iOS/iPadOS.
  ///
  /// VISIONOS IS FIRST BECAUSE ITS URLS SURVIVE THE WHOLE TRACK. THIS WAS
  /// CHANGED ONCE, ON A BAD MEASUREMENT, AND IT BROKE PLAYBACK. Do not repeat it
  /// without running the test described below.
  ///
  /// Probed 2026-08-21 with a real visitorData, requesting SEVERAL byte ranges
  /// from each url rather than just the first:
  ///
  /// | client         | 0–1 | 512 KB | 1.5 MB | 3 MB | top format |
  /// | -------------- | --- | ------ | ------ | ---- | ---------- |
  /// | VISIONOS 0.1   | 206 | 206    | 206    | 206  | Opus 155k  |
  /// | IOS 21.03.1    | 206 | 206    | 403    | —    | Opus 155k  |
  /// | IPADOS 21.03.3 | 206 | 206    | 403    | —    | Opus 155k  |
  ///
  /// Both Apple phone clients offer the same Opus format and hand back a url
  /// that serves the opening half-megabyte, then refuse every later chunk — a
  /// PoToken gate that engages after the start of the stream. On device that is
  /// not a clean failure: playback runs for about a minute, then the 403 handler
  /// burns five same-url retries and four fresh re-resolves, drops to a lower
  /// tier, and 403s again on that too. Audible as a stall a minute into a track.
  ///
  /// AND THIS IS WHY `Range: bytes=0-1` IS NOT A SUFFICIENT PROBE. That range
  /// returns 206 from every gated client, so a first-bytes check reports them all
  /// as healthy. [_validateStreamUrl] uses it to catch outright rejection, which
  /// is all it claims to do — it cannot see a gate that starts later, and no
  /// cheap probe can. The chain order has to come from a LATE-RANGE test.
  ///
  /// visionOS needs the visitorData Auvy already sends; without one it answers
  /// UNPLAYABLE, which is what made an earlier probe mistake it for broken.
  ///
  /// This is the FULL chain. What actually gets tried is [streamOrder], which
  /// drops the sources the user switched off in Settings → Sound → Stream
  /// sources.
  static const List<CatalogApiClientInfo> allStreamClients = [
    visionOs,
    androidVr143,
    androidVr161,
    ios,
    ipadOs,
  ];

  /// Human-facing rows for the Stream sources screen, in resolve order. One entry
  /// per [CatalogApiClientInfo.sourceKey] — the two ANDROID_VR builds collapse
  /// into a single "Android VR" toggle, since the split is an implementation
  /// detail the user has no reason to choose between.
  static const List<({String key, String name, String detail})> streamSourceInfo = [
    (
      key: 'visionos',
      name: 'visionOS',
      detail: 'Tried first. Opus at ~155 kbps, and it streams whole tracks.',
    ),
    (
      key: 'android_vr',
      name: 'Android VR',
      detail: 'Two builds, tried in turn. Currently wants a sign-in Auvy has not got.',
    ),
    (
      key: 'ios',
      name: 'iOS',
      detail: 'Fallback. Same formats, but often gated part-way through a track.',
    ),
    (
      key: 'ipados',
      name: 'iPadOS',
      detail: 'Last resort. Behaves like iOS; reaches a few tracks the others miss.',
    ),
  ];

  /// Source keys the user has switched OFF. Stored as the disabled set rather
  /// than the enabled one so a client added in a future version is ON by default
  /// instead of silently missing from everyone's saved list.
  static final Set<String> disabledStreamSources = <String>{};

  static List<CatalogApiClientInfo>? _orderCache;

  /// The clients actually tried, in order. Called once per stream resolve, so the
  /// filtered list is cached and rebuilt only when the setting changes.
  ///
  /// Falls back to the full chain when everything is disabled. The UI already
  /// refuses to turn off the last source; this is the second guard, because an
  /// empty chain means nothing plays at all — the worst possible outcome for a
  /// preference screen to be able to produce.
  static List<CatalogApiClientInfo> get streamOrder {
    final cached = _orderCache;
    if (cached != null) return cached;
    final filtered = allStreamClients
        .where((c) => !disabledStreamSources.contains(c.sourceKey))
        .toList(growable: false);
    return _orderCache = filtered.isEmpty ? allStreamClients : filtered;
  }

  /// Replace the disabled set. Callers persist it themselves (see
  /// [ListeningPolicy.setDisabledStreamSources]).
  static void applyDisabledStreamSources(Iterable<String> keys) {
    disabledStreamSources
      ..clear()
      ..addAll(keys);
    _orderCache = null;
  }
}
