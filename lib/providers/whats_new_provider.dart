/// What's New: new releases from the artists the listener follows, new episodes
/// of the podcasts they follow, Auvy updates, and what was made for them this
/// week (Weekly Discovery, Keep fresh). Behind the bell on Home, like Spotify's.
///
/// Release dates come from Apple's public iTunes catalogue, which knows the
/// exact day of each release (YouTube Music's pages show only the year) and
/// lists upcoming ones. A followed artist is matched to it once, by name.
///
/// Checked at launch, on resume and every few hours while Auvy runs. With Auvy
/// closed, a small native check does the same with the list this writes to
/// `whats_new/watch.json` (see AuvySystemChannels.swift, WhatsNewJobService.kt), and
/// leaves what it found in `whats_new/bg.json` for the next check here.
///
/// The feed is per phone and not backed up. Notifications are off until the
/// listener turns them on.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/logic/whats_new_logic.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/update_state.dart';
import 'package:auvy/services/updater_service.dart';

class WhatsNewState {
  final List<WhatsNewItem> items;
  final Set<String> seen;

  /// Null until the listener chooses; the page asks once.
  final bool? notify;

  /// The OS notification permission: granted, denied or undecided.
  final String permission;
  final bool checking;
  final int lastCheckMs;

  /// What the last check covered, for the page's "checked" line.
  final int artists;
  final int podcasts;

  const WhatsNewState({
    this.items = const [],
    this.seen = const {},
    this.notify,
    this.permission = 'undecided',
    this.checking = false,
    this.lastCheckMs = 0,
    this.artists = 0,
    this.podcasts = 0,
  });

  int get unseen => items.where((i) => !seen.contains(i.key)).length;

  WhatsNewState copyWith({
    List<WhatsNewItem>? items,
    Set<String>? seen,
    bool? notify,
    String? permission,
    bool? checking,
    int? lastCheckMs,
    int? artists,
    int? podcasts,
  }) =>
      WhatsNewState(
        items: items ?? this.items,
        seen: seen ?? this.seen,
        notify: notify ?? this.notify,
        permission: permission ?? this.permission,
        checking: checking ?? this.checking,
        lastCheckMs: lastCheckMs ?? this.lastCheckMs,
        artists: artists ?? this.artists,
        podcasts: podcasts ?? this.podcasts,
      );
}

class WhatsNewNotifier extends StateNotifier<WhatsNewState> {
  WhatsNewNotifier(this._ref) : super(const WhatsNewState()) {
    _ready = _load();
    // Follows and unfollows reach the background list at once, so a closed
    // app never keeps looking at an artist the listener let go of.
    _ref.listen<String>(
        libraryProvider.select((l) => [
              for (final a in l.subscribedArtists) a.title,
              for (final p in l.likedAlbums)
                if (p.recordType == 'podcast') p.id,
            ].join('\n')), (prev, next) {
      if (prev != next) unawaited(_ready.then((_) => _writeWatch()));
    });
  }

  final Ref _ref;
  late final Future<void> _ready;

  static const kPrefsKey = 'auvy_whats_new_v1';
  static const _channel = MethodChannel('com.auvy.app/whatsnew');

  /// How often a check may run on its own. Resumes are frequent; releases are
  /// a few a week.
  static const _minGap = Duration(hours: 3);

  /// The YouTube Music pages are looked at once a day, on Wi-Fi (or when the
  /// listener pulls to refresh, at most every 3 hours): one page per artist.
  static const _pageGap = Duration(hours: 20);
  static const _pageGapAsked = Duration(hours: 3);

  /// Suggestions come from this many artists at most, looked at twice a day.
  static const _suggestFrom = 20;
  static const _suggestGap = Duration(hours: 12);

  /// A followed name the catalogue doesn't know is asked about again after this.
  static const _retryUnmatched = Duration(days: 30);

  /// New matches looked up per check. Apple allows about 20 requests a minute.
  static const _matchesPerCheck = 12;

  Set<String> _notified = {};

  /// Followed artist (normalized name) → [catalogue id, when matched]; 0 = none.
  Map<String, List<int>> _artistIds = {};

  /// Followed podcast feed URL → [catalogue id, when matched]; 0 = none.
  Map<String, List<int>> _podcastIds = {};

  /// The Auvy version the last check ran on, to say when it changed.
  String _appVersion = '';

  /// Followed artist (channel id) → the release ids on their YouTube Music page
  /// at the last look (see pageReleaseItems).
  Map<String, List<String>> _pageSeen = {};
  int _pageCheckMs = 0;

  /// Artists that fans of a followed artist also like, from those pages:
  /// normalized name → [name, channel id, the followed artist].
  Map<String, List<String>> _related = {};
  int _suggestCheckMs = 0;

  Future<int>? _running;
  Timer? _timer;

  /// Set by MainLayout: opens the What's New page (a notification was tapped).
  static void Function()? onOpenRequested;

  static void attachChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openWhatsNew') onOpenRequested?.call();
      return null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Storage

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPrefsKey);
      if (raw == null) {
        _notified = {};
        _artistIds = {};
        _podcastIds = {};
        _appVersion = '';
        _pageSeen = {};
        _pageCheckMs = 0;
        _related = {};
        _suggestCheckMs = 0;
        if (mounted) state = WhatsNewState(permission: state.permission);
        return;
      }
      final m = jsonDecode(raw) as Map<String, dynamic>;
      Map<String, List<int>> ids(Object? v) => {
            if (v is Map)
              for (final e in v.entries)
                if (e.value is List && (e.value as List).length == 2)
                  e.key.toString(): [
                    for (final n in e.value as List) (n as num).toInt()
                  ],
          };
      _notified = {...((m['notified'] as List?) ?? const []).whereType<String>()};
      _artistIds = ids(m['artists']);
      _podcastIds = ids(m['podcasts']);
      _appVersion = (m['appVersion'] as String?) ?? '';
      Map<String, List<String>> strings(Object? v) => {
            if (v is Map)
              for (final e in v.entries)
                if (e.value is List) e.key.toString(): (e.value as List).whereType<String>().toList()
          };
      _pageSeen = strings(m['pageSeen']);
      _pageCheckMs = (m['pageCheckMs'] as num?)?.toInt() ?? 0;
      _related = strings(m['related']);
      _suggestCheckMs = (m['suggestCheckMs'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      state = state.copyWith(
        items: [
          for (final i in (m['items'] as List?) ?? const [])
            ?WhatsNewItem.fromJson(i)
        ],
        seen: {...((m['seen'] as List?) ?? const []).whereType<String>()},
        notify: m['notify'] as bool?,
        lastCheckMs: (m['lastCheckMs'] as num?)?.toInt() ?? 0,
        artists: (m['checkedArtists'] as num?)?.toInt() ?? 0,
        podcasts: (m['checkedPodcasts'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      print('WARN: whats new: stored state unreadable ($e)');
    }
  }

  Future<void> _save() async {
    final keys = {for (final i in state.items) i.key};
    // Only keys that can still matter are kept: the feed's, and the most
    // recent notified ones (an item can leave the feed and its key still stop
    // a repeat from the native check).
    final seen = state.seen.where(keys.contains).toList();
    final notified = _notified.toList();
    if (notified.length > 400) notified.removeRange(0, notified.length - 400);
    _notified = notified.toSet();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefsKey,
        jsonEncode({
          'items': [for (final i in state.items) i.toJson()],
          'seen': seen,
          'notified': notified,
          'notify': state.notify,
          'lastCheckMs': state.lastCheckMs,
          'artists': _artistIds,
          'podcasts': _podcastIds,
          'appVersion': _appVersion,
          'pageSeen': _pageSeen,
          'pageCheckMs': _pageCheckMs,
          'related': _related,
          'suggestCheckMs': _suggestCheckMs,
          'checkedArtists': state.artists,
          'checkedPodcasts': state.podcasts,
        }));
  }

  /// Re-reads everything after a restore or an account switch (which wipes the
  /// key), and rewrites the background list for the library now on the phone.
  Future<void> reload() async {
    await _load();
    await _writeWatch();
  }

  // Checks

  /// Starts the periodic check. Main engine only: a headless one (widget, tile)
  /// has no screen and must not spend the network.
  void start() {
    if (!NativeAudioEngine.platformAvailable) return;
    // Looks every hour whether a check is due; one runs every 3 hours while
    // Auvy is open or playing.
    _timer ??= Timer.periodic(const Duration(hours: 1), (_) => maybeCheck());
    unawaited(refreshPermission());
  }

  /// Runs a check if none ran in [minGap] (3 hours unless given). [force]
  /// looks even under data saver (the page is open); [manual] is the listener
  /// asking (pull to refresh, the button), which also looks at the YouTube
  /// Music pages and suggestions sooner than their own schedule. Returns how
  /// many items it added, or -1 when it didn't run (too soon, offline).
  Future<int> maybeCheck({Duration? minGap, bool force = false, bool manual = false}) {
    if (!NativeAudioEngine.platformAvailable) return Future.value(-1);
    return _running ??= _check(minGap ?? _minGap, force || manual, manual)
        .whenComplete(() => _running = null);
  }

  Future<int> _check(Duration minGap, bool force, bool manual) async {
    await _ready;
    if (!mounted) return -1;
    final now = DateTime.now();
    await _mergeBackground(now);
    if (now.millisecondsSinceEpoch - state.lastCheckMs < minGap.inMilliseconds) {
      return -1;
    }
    final conn = _ref.read(connectivityProvider);
    if (conn.isOffline) return -1;
    // Data saver set to always: only when asked (pull to refresh, opening the page).
    if (!force && !conn.shouldPreload) return -1;
    final before = {for (final i in state.items) i.key};

    state = state.copyWith(checking: true);
    try {
      final lib = _ref.read(libraryProvider);
      final artists = <FollowedArtist>[];
      final podcasts = <FollowedPodcast>[];
      var matched = 0;
      for (final a in lib.subscribedArtists) {
        final norm = normalizeArtistName(a.title);
        if (norm.isEmpty) continue;
        var known = _artistIds[norm];
        if ((known == null || (known[0] == 0 && _stale(known[1], now))) &&
            matched < _matchesPerCheck) {
          matched++;
          known = [await _matchArtist(a.title, norm), now.millisecondsSinceEpoch];
          _artistIds[norm] = known;
        }
        if (known != null && known[0] > 0) {
          artists.add(FollowedArtist(known[0], a.title, a.id));
        }
      }
      for (final p in lib.likedAlbums.where((a) => a.recordType == 'podcast')) {
        final feed = p.id;
        if (feed.isEmpty) continue;
        var known = _podcastIds[feed];
        if ((known == null || (known[0] == 0 && _stale(known[1], now))) &&
            matched < _matchesPerCheck) {
          matched++;
          known = [await _matchPodcast(p.title, feed), now.millisecondsSinceEpoch];
          _podcastIds[feed] = known;
        }
        if (known != null && known[0] > 0) {
          podcasts.add(FollowedPodcast(known[0], p.title, feed));
        }
      }

      final found = <WhatsNewItem>[];
      final byArtist = {for (final a in artists) a.catalogId: a};
      final ids = byArtist.keys.toList();
      for (var i = 0; i < ids.length; i += 15) {
        final chunk = ids.sublist(i, i + 15 > ids.length ? ids.length : i + 15);
        final json = await _get('lookup?id=${chunk.join(',')}&entity=album&sort=recent&limit=15');
        if (json != null) found.addAll(parseReleaseLookup(json, byArtist, now));
      }
      final byShow = {for (final p in podcasts) p.catalogId: p};
      final showIds = byShow.keys.toList();
      for (var i = 0; i < showIds.length; i += 10) {
        final chunk = showIds.sublist(i, i + 10 > showIds.length ? showIds.length : i + 10);
        final json = await _get('lookup?id=${chunk.join(',')}&entity=podcastEpisode&limit=2');
        if (json != null) found.addAll(parseEpisodeLookup(json, byShow, now));
      }
      found.addAll(await _appItems(now));

      // The second source, YouTube Music's own pages, once a day.
      final pageGap = manual ? _pageGapAsked : _pageGap;
      final pagesDue = now.millisecondsSinceEpoch - _pageCheckMs > pageGap.inMilliseconds &&
          (conn.isWifi || manual);
      var pageFound = 0;
      if (pagesDue) {
        final feedSoFar = mergeWhatsNew(state.items, found, now);
        pageFound = await _pagePass(lib.subscribedArtists, feedSoFar, found, now);
        _pageCheckMs = now.millisecondsSinceEpoch;
      }

      // You might like: new releases from artists the listener plays or that
      // fans of their artists like, without following them.
      final suggestDue = manual ||
          now.millisecondsSinceEpoch - _suggestCheckMs > _suggestGap.inMilliseconds;
      final suggested =
          suggestDue ? await _suggestionPass(lib, now, matched) : const <WhatsNewItem>[];
      if (suggestDue) _suggestCheckMs = now.millisecondsSinceEpoch;
      found.addAll(suggested);
      if (!mounted) return -1;

      final items = _dedupeSources(mergeWhatsNew(state.items, found, now));
      state = state.copyWith(
          items: items,
          lastCheckMs: now.millisecondsSinceEpoch,
          artists: artists.length,
          podcasts: podcasts.length);
      final posted = await _notifyDue(now);
      await _save();
      await _writeWatch();
      final added = items.where((i) => !before.contains(i.key)).length;
      final unmatched = lib.subscribedArtists.length - artists.length;
      print('whats new: ${artists.length} artist(s) and ${podcasts.length} podcast(s) '
          'checked${unmatched > 0 ? ' ($unmatched artist(s) not in the catalogue)' : ''}'
          '${pagesDue ? ', YouTube Music pages too ($pageFound new there)' : ''}; '
          '${suggested.length} suggestion(s); $added new, ${state.unseen} unseen, '
          '$posted notified');
      return added;
    } catch (e) {
      print('WARN: whats new: check failed ($e)');
      return -1;
    } finally {
      if (mounted) state = state.copyWith(checking: false);
    }
  }

  /// Looks at each followed artist's YouTube Music page (one request each, at
  /// most 25) and adds releases that appeared there since the last look. Also
  /// notes the artists their fans like, for suggestions. Returns how many it
  /// added to [found].
  Future<int> _pagePass(List<Song> followed, List<WhatsNewItem> feed,
      List<WhatsNewItem> found, DateTime now) async {
    final search = _ref.read(searchServiceProvider);
    final followedNorms = {for (final a in followed) normalizeArtistName(a.title)};
    final related = <String, List<String>>{};
    var added = 0;
    for (final a in followed.where((a) => a.id.startsWith('UC')).take(25)) {
      try {
        final page = await search.getArtistLatest(a.id);
        final result = pageReleaseItems(
          artist: FollowedArtist(0, a.title, a.id),
          releases: [for (final r in page.releases) PageRelease.fromAlbum(r)],
          seen: _pageSeen[a.id],
          feed: feed,
          now: now,
        );
        _pageSeen[a.id] = result.seen;
        found.addAll(result.items);
        added += result.items.length;
        for (final r in page.related.take(3)) {
          final norm = normalizeArtistName(r.title);
          if (norm.isEmpty || followedNorms.contains(norm)) continue;
          related.putIfAbsent(norm, () => [r.title, r.id, a.title]);
        }
      } catch (e) {
        print('WARN: whats new: page of ${a.title} unreadable ($e)');
      }
    }
    _pageSeen.removeWhere((id, _) => !followed.any((a) => a.id == id));
    if (related.isNotEmpty) _related = related;
    return added;
  }

  /// Up to [_suggestFrom] artists the listener doesn't follow: the ones they
  /// play most, then the ones fans of their followed artists like. Their own
  /// releases from the last two weeks become suggestions.
  Future<List<WhatsNewItem>> _suggestionPass(
      LibraryState lib, DateTime now, int matchedSoFar) async {
    final followed = {for (final a in lib.subscribedArtists) normalizeArtistName(a.title)};
    final intel = _ref.read(intelligenceProvider);
    // An affinity key is a whole credit ("mgk, blackbear"): the credit is tried
    // as a name first (it can be one, "Earth, Wind & Fire"), then its lead artist.
    final candidates = <String, (String name, String appId, String note, String lead)>{};
    final played = intel.artistAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in played.take(40)) {
      if (candidates.length >= _suggestFrom ~/ 2) break;
      final name = e.key.trim();
      final lead = leadArtist(name);
      final norm = normalizeArtistName(name);
      if (norm.isEmpty || e.value <= 0) continue;
      if (followed.contains(norm) || followed.contains(normalizeArtistName(lead))) continue;
      candidates.putIfAbsent(norm, () => (name, '', 'You play them a lot', lead == name ? '' : lead));
    }
    for (final e in _related.entries) {
      if (candidates.length >= _suggestFrom) break;
      if (followed.contains(e.key)) continue;
      candidates.putIfAbsent(
          e.key, () => (e.value[0], e.value[1], 'Fans of ${e.value[2]} like them', ''));
    }
    if (candidates.isEmpty) return const [];

    var matched = matchedSoFar;
    final byId = <int, FollowedArtist>{};
    Future<int> idFor(String name, String norm) async {
      var known = _artistIds[norm];
      if ((known == null || (known[0] == 0 && _stale(known[1], now))) &&
          matched < _matchesPerCheck + 6) {
        matched++;
        known = [await _matchArtist(name, norm), now.millisecondsSinceEpoch];
        _artistIds[norm] = known;
      }
      return known?[0] ?? 0;
    }

    for (final e in candidates.entries) {
      final (name, appId, note, lead) = e.value;
      var id = await idFor(name, e.key);
      var shown = name;
      if (id == 0 && lead.isNotEmpty) {
        final leadNorm = normalizeArtistName(lead);
        if (followed.contains(leadNorm)) continue;
        id = await idFor(lead, leadNorm);
        shown = lead;
      }
      if (id > 0) byId[id] = FollowedArtist(id, shown, appId, note: note);
    }
    final out = <WhatsNewItem>[];
    final ids = byId.keys.toList();
    for (var i = 0; i < ids.length; i += 15) {
      final chunk = ids.sublist(i, i + 15 > ids.length ? ids.length : i + 15);
      final json = await _get('lookup?id=${chunk.join(',')}&entity=album&sort=recent&limit=10');
      if (json != null) out.addAll(parseReleaseLookup(json, byId, now, suggested: true));
    }
    return out;
  }

  /// A release YouTube Music showed first, and the catalogue later, is one item:
  /// the catalogue's (it has the date), carrying over seen and notified.
  List<WhatsNewItem> _dedupeSources(List<WhatsNewItem> items) {
    final dated = <String, WhatsNewItem>{
      for (final i in items)
        if (i.key.startsWith('rel:')) '${i.target}|${normalizeArtistName(i.title)}': i
    };
    final out = <WhatsNewItem>[];
    var seen = state.seen;
    for (final i in items) {
      final twin = i.key.startsWith('yt:')
          ? dated['${i.target}|${normalizeArtistName(i.title)}']
          : null;
      if (twin == null) {
        out.add(i);
        continue;
      }
      if (seen.contains(i.key)) seen = {...seen, twin.key};
      if (_notified.contains(i.key)) _notified.add(twin.key);
    }
    if (!identical(seen, state.seen)) state = state.copyWith(seen: seen);
    return out;
  }

  bool _stale(int atMs, DateTime now) =>
      now.millisecondsSinceEpoch - atMs > _retryUnmatched.inMilliseconds;

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final res = await HttpPool()
          .getClient()
          .get(Uri.parse('https://itunes.apple.com/$path'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        print('WARN: whats new: catalogue answered ${res.statusCode}');
        return null;
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      print('WARN: whats new: catalogue request failed ($e)');
      return null;
    }
  }

  /// The catalogue's id for an artist whose name matches exactly (loosely
  /// compared), or 0. A near match is not taken: a wrong artist would mean
  /// notifications about someone else's music. Two artists with the same name
  /// (there are several "Aurora"s) are told apart by which one has the songs
  /// the listener knows by that name.
  Future<int> _matchArtist(String name, String norm) async {
    final json = await _get('search?term=${Uri.encodeQueryComponent(name)}'
        '&entity=musicArtist&limit=8');
    await Future.delayed(const Duration(milliseconds: 600));
    final exact = <int>[
      for (final r in (json?['results'] as List?) ?? const [])
        if (r is Map && normalizeArtistName((r['artistName'] as String?) ?? '') == norm)
          if ((r['artistId'] as num?)?.toInt() case final id?) id
    ];
    if (exact.length <= 1) return exact.firstOrNull ?? 0;
    final known = _knownTitles(norm);
    if (known.isEmpty) return exact.first;
    final songs = await _get('lookup?id=${exact.take(5).join(',')}&entity=song&limit=25');
    await Future.delayed(const Duration(milliseconds: 600));
    final score = <int, int>{};
    for (final r in (songs?['results'] as List?) ?? const []) {
      if (r is! Map || r['wrapperType'] != 'track') continue;
      final id = (r['artistId'] as num?)?.toInt();
      if (id == null || !exact.contains(id)) continue;
      if (known.contains(normalizeArtistName((r['trackName'] as String?) ?? ''))) {
        score[id] = (score[id] ?? 0) + 1;
      }
    }
    final best = exact.reduce((a, b) => (score[b] ?? 0) > (score[a] ?? 0) ? b : a);
    print('whats new: "$name" is ${exact.length} artists in the catalogue; '
        'chose the one with ${score[best] ?? 0} of the songs you know');
    return best;
  }

  /// Song titles the listener knows by an artist: liked, played, in playlists.
  Set<String> _knownTitles(String artistNorm) {
    final lib = _ref.read(libraryProvider);
    final intel = _ref.read(intelligenceProvider);
    final songs = [
      ...lib.likedSongs,
      ...intel.trackMetadata.values,
      for (final list in lib.playlistSongs.values) ...list,
    ];
    return {
      for (final s in songs)
        if (creditsArtist(s.artist, artistNorm)) normalizeArtistName(s.title)
    };
  }

  /// The catalogue's id for a podcast: the one with the same feed, else the
  /// same title.
  Future<int> _matchPodcast(String title, String feedUrl) async {
    String bare(String u) => u
        .toLowerCase()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/+$'), '');
    final json = await _get('search?term=${Uri.encodeQueryComponent(title)}'
        '&media=podcast&limit=5');
    await Future.delayed(const Duration(milliseconds: 600));
    final results = [for (final r in (json?['results'] as List?) ?? const []) if (r is Map) r];
    for (final r in results) {
      if (bare((r['feedUrl'] as String?) ?? '') == bare(feedUrl)) {
        return (r['collectionId'] as num?)?.toInt() ?? 0;
      }
    }
    final norm = normalizeArtistName(title);
    for (final r in results) {
      if (normalizeArtistName((r['collectionName'] as String?) ?? '') == norm) {
        return (r['collectionId'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }

  /// "Auvy x is available" once the update check has seen a newer release, and
  /// "Auvy x is installed" after an update.
  Future<List<WhatsNewItem>> _appItems(DateTime now) async {
    final out = <WhatsNewItem>[];
    final ms = now.millisecondsSinceEpoch;
    try {
      final info = await PackageInfo.fromPlatform();
      final installed = info.version;
      final latest = await UpdateState.lastSeenTag();
      if (latest.isNotEmpty && UpdaterService.isNewerThan(installed, latest)) {
        out.add(WhatsNewItem(
            key: 'app:$latest', kind: WhatsNewKind.app, title: 'Auvy $latest is available',
            source: 'Auvy', label: 'Update', image: '', dateMs: ms, foundMs: ms));
      }
      if (_appVersion.isNotEmpty && _appVersion != installed) {
        out.add(WhatsNewItem(
            key: 'app:installed:$installed', kind: WhatsNewKind.app,
            title: "You're on Auvy $installed. See what's new",
            source: 'Auvy', label: 'Installed', image: '', dateMs: ms, foundMs: ms));
      }
      _appVersion = installed;
    } catch (_) {}
    return out;
  }

  /// Something Auvy made for the listener (Weekly Discovery, a Keep fresh swap).
  /// In the feed with the dot, no notification.
  Future<void> addMadeForYou({
    required String key,
    required String title,
    required String target,
    String image = '',
  }) async {
    await _ready;
    if (!mounted || state.items.any((i) => i.key == key)) return;
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    state = state.copyWith(
        items: mergeWhatsNew(state.items, [
      WhatsNewItem(
          key: key, kind: WhatsNewKind.madeForYou, title: title, source: 'Made for you',
          label: '', image: image, dateMs: ms, foundMs: ms, target: target),
    ], now));
    await _save();
  }

  // Seen

  void markAllSeen() {
    if (state.unseen == 0) return;
    state = state.copyWith(seen: {for (final i in state.items) i.key});
    unawaited(_save());
    unawaited(_writeWatch());
  }

  // Notifications

  Future<int> _notifyDue(DateTime now) async {
    if (state.notify != true || state.permission != 'granted') return 0;
    final due = dueForNotification(state.items, {..._notified, ...state.seen}, now);
    if (due.isEmpty) return 0;
    final notes = notificationsFor(due);
    try {
      await _channel.invokeMethod('notify', {
        'items': [
          for (final n in notes) {'id': n.id, 'title': n.title, 'body': n.body}
        ]
      });
      _notified.addAll(due.map((i) => i.key));
      return due.length;
    } catch (e) {
      print('WARN: whats new: notification failed ($e)');
      return 0;
    }
  }

  Future<void> refreshPermission() async {
    try {
      final String p;
      if (Platform.isAndroid) {
        final s = await Permission.notification.status;
        p = s.isGranted ? 'granted' : (s.isPermanentlyDenied ? 'denied' : 'undecided');
      } else {
        p = await _channel.invokeMethod<String>('permission') ?? 'undecided';
      }
      if (mounted && p != state.permission) {
        state = state.copyWith(permission: p);
        await _writeWatch();
      }
    } catch (_) {}
  }

  /// Turns notifications on, asking the OS the first time. Returns false when
  /// the OS refuses (then the switch is in the OS settings).
  Future<bool> enableNotifications() async {
    await _ready;
    var permission = state.permission;
    try {
      if (Platform.isAndroid) {
        final s = await Permission.notification.request();
        permission = s.isGranted ? 'granted' : 'denied';
        if (s.isPermanentlyDenied) await openAppSettings();
      } else if (permission == 'denied') {
        await _channel.invokeMethod('openSettings');
      } else if (permission != 'granted') {
        final ok = await _channel.invokeMethod<bool>('requestPermission') ?? false;
        permission = ok ? 'granted' : 'denied';
      }
    } catch (e) {
      print('WARN: whats new: permission request failed ($e)');
    }
    final ok = permission == 'granted';
    // On even when refused, so allowing it in the OS settings later is enough.
    state = state.copyWith(notify: true, permission: permission);
    await _save();
    await _writeWatch();
    print('whats new: notifications on${ok ? '' : ' (waiting for the OS permission)'}');
    return ok;
  }

  Future<void> disableNotifications() async {
    await _ready;
    state = state.copyWith(notify: false);
    await _save();
    await _writeWatch();
    print('whats new: notifications off');
  }

  /// MainLayout asks at launch and on resume: was a notification tapped?
  static Future<bool> consumeOpenRequest() async {
    try {
      return await _channel.invokeMethod<bool>('consumeOpen') ?? false;
    } catch (_) {
      return false;
    }
  }

  // The background check's files

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/whats_new');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// The write in progress; the next one waits for it.
  Future<void> _watchWrite = Future.value();

  /// What the native check needs: who to look at, what is already announced,
  /// whether it may notify. Rewritten after every change that matters to it.
  ///
  /// One write at a time. Two at once (a restore fires several changes
  /// together) shared the temp file, and the second's rename found it already
  /// moved: seen on Android as "Cannot rename file … watch.json".
  Future<void> _writeWatch() =>
      _watchWrite = _watchWrite.then((_) => _writeWatchNow());

  Future<void> _writeWatchNow() async {
    try {
      final on = state.notify == true && state.permission == 'granted';
      final lib = _ref.read(libraryProvider);
      final followed = {for (final a in lib.subscribedArtists) normalizeArtistName(a.title): a};
      final feeds = {
        for (final p in lib.likedAlbums.where((a) => a.recordType == 'podcast')) p.id: p.title
      };
      final saver = !_ref.read(connectivityProvider).shouldPreload;
      final watch = {
        'v': 1,
        'enabled': on,
        'dataSaver': saver,
        'lastCheckMs': state.lastCheckMs,
        'artists': [
          for (final e in followed.entries)
            if ((_artistIds[e.key]?[0] ?? 0) > 0)
              {'id': _artistIds[e.key]![0], 'name': e.value.title, 'appId': e.value.id}
        ],
        'podcasts': [
          for (final e in feeds.entries)
            if ((_podcastIds[e.key]?[0] ?? 0) > 0)
              {'id': _podcastIds[e.key]![0], 'name': e.value, 'feed': e.key}
        ],
        'notified': {..._notified, ...state.seen}.toList(),
      };
      final dir = await _dir();
      final tmp = File('${dir.path}/watch.json.tmp');
      await tmp.writeAsString(jsonEncode(watch), flush: true);
      await tmp.rename('${dir.path}/watch.json');
      await _channel.invokeMethod('setBackground', {'enabled': on, 'dataSaver': saver});
    } catch (e) {
      print('WARN: whats new: background list not written ($e)');
    }
  }

  /// Takes in what the native check found and announced while Auvy was closed.
  Future<void> _mergeBackground(DateTime now) async {
    try {
      final f = File('${(await _dir()).path}/bg.json');
      if (!f.existsSync()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final notified = ((m['notified'] as List?) ?? const []).whereType<String>().toSet();
      final found = [
        for (final i in (m['found'] as List?) ?? const [])
          ?WhatsNewItem.fromJson(i)
      ];
      final fresh = notified.difference(_notified).length;
      _notified.addAll(notified);
      if (found.isNotEmpty) {
        state = state.copyWith(items: mergeWhatsNew(state.items, found, now));
      }
      await f.delete();
      final line = m['line'];
      if (line is String) print('whats new: background check ran while closed: $line');
      if (found.isNotEmpty || fresh > 0) {
        await _save();
        // The deleted file was the native check's own memory of what it
        // announced; the watch list carries it from now on.
        await _writeWatch();
        print('whats new: took in ${found.length} item(s) from the background check '
            '($fresh notified while closed)');
      }
    } catch (e) {
      print('WARN: whats new: background result unreadable ($e)');
    }
  }
}

final whatsNewProvider =
    StateNotifierProvider<WhatsNewNotifier, WhatsNewState>((ref) => WhatsNewNotifier(ref));
