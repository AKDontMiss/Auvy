import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/music_link.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/search_service.dart';

/// Why a link couldn't be opened, in words for the listener.
class MusicLinkException implements Exception {
  final String message;
  const MusicLinkException(this.message);
  @override
  String toString() => message;
}

/// What a link points at, ready to play.
class ResolvedMusicLink {
  final MusicLink link;

  /// The song, album, playlist or artist name, and a line under it.
  final String title;
  final String subtitle;
  final String image;

  /// Songs already playable: YouTube links, and a matched single track.
  final List<Song> songs;

  /// "Title Artist" for each song still to be found on YouTube Music, in the
  /// list's order (Spotify and Apple Music albums and playlists).
  final List<String> queries;

  const ResolvedMusicLink({
    required this.link,
    required this.title,
    required this.subtitle,
    required this.image,
    this.songs = const [],
    this.queries = const [],
  });

  bool get isCollection =>
      link.kind == MusicLinkKind.album ||
      link.kind == MusicLinkKind.playlist ||
      link.kind == MusicLinkKind.artist;

  int get trackCount => queries.isNotEmpty ? queries.length : songs.length;
}

/// Turns a [MusicLink] into something Auvy can play, using only keyless public
/// endpoints: Spotify's web-player and embed pages (as the playlist import
/// already does), Apple's iTunes lookup and Apple Music's public pages, and
/// YouTube Music's own catalogue.
class MusicLinkResolver {
  MusicLinkResolver(this._library, {SearchService? search}) : _search = search ?? SearchService();

  final LibraryNotifier _library;
  final SearchService _search;

  static const _browserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _timeout = Duration(seconds: 12);

  Future<ResolvedMusicLink> resolve(MusicLink input) async {
    final link = input.kind == MusicLinkKind.short ? await _expand(input) : input;
    print('open link: ${link.source.name} ${link.kind.name}');
    switch (link.source) {
      case MusicLinkSource.youtube:
        return _youtube(link);
      case MusicLinkSource.spotify:
        return _spotify(link);
      case MusicLinkSource.appleMusic:
        return _apple(link);
    }
  }

  /// The best YouTube Music match for "Title Artist", or null.
  Future<Song?> match(String query) async {
    try {
      final results = await _search.search(query, 'track').timeout(const Duration(seconds: 10));
      if (results.isEmpty) return null;
      final best = pickBestOverlap(query, results);
      return best.copyWith(
          image: best.image.replaceAll('small', 'large').replaceAll('50x50', '500x500'));
    } catch (_) {
      return null;
    }
  }

  // ── Short links ──

  /// Where a short link may lead while it is followed: Spotify's and Apple's
  /// own addresses. A redirect anywhere else stops the expansion, so a pasted
  /// link can't make Auvy fetch an arbitrary site.
  static const _shortLinkHosts = ['spotify.link', 'spoti.fi', 'spotify.app.link', 'spotify.com', 'apple.co', 'apple.com'];

  static bool isShortLinkHop(Uri url) =>
      url.scheme == 'https' &&
      _shortLinkHosts.any((h) => url.host == h || url.host.endsWith('.$h'));

  /// Follows spotify.link and apple.co to the link they stand for. Redirects are
  /// followed by hand so the final address can be read; Spotify's short links
  /// answer with a page that names the target instead of redirecting.
  Future<MusicLink> _expand(MusicLink short) async {
    // Both hosts answer on https; a link pasted as http goes there too.
    var url = short.uri.scheme == 'http' ? short.uri.replace(scheme: 'https') : short.uri;
    final client = HttpPool().getClient();
    for (var hop = 0; hop < 6; hop++) {
      if (!isShortLinkHop(url)) break;
      final req = http.Request('GET', url)
        ..followRedirects = false
        ..headers['User-Agent'] = _browserAgent;
      final resp = await http.Response.fromStream(await client.send(req).timeout(_timeout));
      final location = resp.headers['location'];
      if (resp.statusCode >= 300 && resp.statusCode < 400 && location != null) {
        url = url.resolve(location);
        final parsed = MusicLink.fromUri(url);
        if (parsed != null && parsed.kind != MusicLinkKind.short) return parsed;
        continue;
      }
      final inBody = RegExp(r'https://open\.spotify\.com/(?:intl-[a-z]+/)?(track|album|playlist|artist)/[A-Za-z0-9]+')
          .firstMatch(resp.body);
      if (inBody != null) {
        final parsed = MusicLink.fromUri(Uri.parse(inBody.group(0)!));
        if (parsed != null) return parsed;
      }
      break;
    }
    throw const MusicLinkException("That short link didn't lead to a song, album or playlist.");
  }

  // ── YouTube and YouTube Music ──

  Future<ResolvedMusicLink> _youtube(MusicLink link) async {
    switch (link.kind) {
      case MusicLinkKind.track:
        final song = await _search.getSongById(link.id);
        if (song == null) {
          throw const MusicLinkException("YouTube didn't return that video. It may be private or removed.");
        }
        return ResolvedMusicLink(
            link: link, title: song.title, subtitle: song.artist, image: song.image, songs: [song]);
      case MusicLinkKind.album:
        final tracks = link.id.startsWith('MPREb_')
            ? await _search.getAlbumTracks(link.id)
            : await _search.getPlaylistTracks(link.id);
        if (tracks.isEmpty) throw const MusicLinkException('That album came back empty.');
        final first = tracks.first;
        return ResolvedMusicLink(
          link: link,
          title: first.albumTitle.isNotEmpty ? first.albumTitle : 'Album',
          subtitle: 'Album · ${first.artist}',
          image: first.image,
          songs: tracks,
        );
      case MusicLinkKind.playlist:
        final tracks = await _search.getPlaylistTracks(link.id);
        if (tracks.isEmpty) {
          throw const MusicLinkException('That playlist came back empty. Is it private?');
        }
        return ResolvedMusicLink(
          link: link,
          title: '${link.sourceName} playlist',
          subtitle: 'Playlist · ${tracks.length} songs',
          image: tracks.first.image,
          songs: tracks,
        );
      case MusicLinkKind.artist:
        final top = await _search.getArtistTopTracks(link.id);
        if (top.isEmpty) throw const MusicLinkException("Couldn't find songs for that artist.");
        final name = top.first.artists.isNotEmpty ? top.first.artists.first.name : top.first.artist;
        return ResolvedMusicLink(
            link: link, title: name, subtitle: 'Artist · top songs', image: top.first.image, songs: top);
      case MusicLinkKind.short:
        throw const MusicLinkException("That link isn't one Auvy can open.");
    }
  }

  // ── Spotify ──

  Future<ResolvedMusicLink> _spotify(MusicLink link) async {
    if (link.kind == MusicLinkKind.artist) {
      final info = await _oembed('https://open.spotify.com/artist/${link.id}');
      return _artistByName(link, info.title, fallbackImage: info.image);
    }
    final read = await _library.spotifyTrackQueries(link.kind.name, link.id);
    if (read.queries.isEmpty) {
      throw MusicLinkException(link.kind == MusicLinkKind.playlist
          ? "Spotify didn't share that playlist. Only public playlists can be opened."
          : "Spotify didn't answer for that link. Try again in a moment.");
    }
    if (link.kind == MusicLinkKind.track) {
      return _matchedTrack(link, read.queries.first, image: read.cover);
    }
    return ResolvedMusicLink(
      link: link,
      title: read.name.isNotEmpty ? read.name : 'Spotify ${link.kind.name}',
      subtitle: '${link.kind == MusicLinkKind.album ? 'Album' : 'Playlist'} · ${read.queries.length} songs',
      image: read.cover,
      queries: read.queries,
    );
  }

  Future<({String title, String image})> _oembed(String url) async {
    try {
      final resp = await HttpPool()
          .getClient()
          .get(Uri.parse('https://open.spotify.com/oembed?url=${Uri.encodeComponent(url)}'))
          .timeout(_timeout);
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        return (title: (j['title'] ?? '').toString(), image: (j['thumbnail_url'] ?? '').toString());
      }
    } catch (_) {}
    return (title: '', image: '');
  }

  // ── Apple Music ──

  Future<ResolvedMusicLink> _apple(MusicLink link) async {
    switch (link.kind) {
      case MusicLinkKind.track:
        final rows = await _itunesLookup(link.songId ?? link.id, link.country);
        final song = rows.where((r) => r['wrapperType'] == 'track').firstOrNull;
        if (song == null) throw const MusicLinkException("Apple Music didn't recognise that song.");
        return _matchedTrack(link, '${song['trackName']} ${song['artistName']}',
            image: _appleArt(song['artworkUrl100']));
      case MusicLinkKind.album:
        final rows = await _itunesLookup(link.id, link.country, entity: 'song');
        final album = rows.where((r) => r['wrapperType'] == 'collection').firstOrNull;
        final tracks = rows.where((r) => r['wrapperType'] == 'track' && r['kind'] == 'song').toList()
          ..sort((a, b) {
            final d = ((a['discNumber'] ?? 1) as num).compareTo((b['discNumber'] ?? 1) as num);
            return d != 0 ? d : ((a['trackNumber'] ?? 0) as num).compareTo((b['trackNumber'] ?? 0) as num);
          });
        if (album == null || tracks.isEmpty) {
          throw const MusicLinkException("Apple Music didn't recognise that album.");
        }
        return ResolvedMusicLink(
          link: link,
          title: (album['collectionName'] ?? 'Album').toString(),
          subtitle: 'Album · ${album['artistName'] ?? ''}',
          image: _appleArt(album['artworkUrl100']),
          queries: [for (final t in tracks) '${t['trackName']} ${t['artistName']}'],
        );
      case MusicLinkKind.playlist:
        return _applePlaylist(link);
      case MusicLinkKind.artist:
        final rows = await _itunesLookup(link.id, link.country);
        final artist = rows.where((r) => r['wrapperType'] == 'artist').firstOrNull;
        return _artistByName(link, (artist?['artistName'] ?? '').toString());
      case MusicLinkKind.short:
        throw const MusicLinkException("That link isn't one Auvy can open.");
    }
  }

  /// Apple's public catalogue lookup (no key; rate-limited to about 20 calls a
  /// minute per phone, far above what opening links needs).
  Future<List<Map<String, dynamic>>> _itunesLookup(String id, String country, {String? entity}) async {
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'id': id,
      'country': country,
      if (entity != null) 'entity': entity,
      if (entity != null) 'limit': '200',
    });
    final resp = await HttpPool().getClient().get(uri).timeout(_timeout);
    if (resp.statusCode != 200) {
      throw const MusicLinkException("Apple Music didn't answer. Try again in a moment.");
    }
    final j = jsonDecode(resp.body);
    final results = j is Map ? j['results'] : null;
    if (results is! List) return const [];
    return [for (final r in results) if (r is Map) Map<String, dynamic>.from(r)];
  }

  String _appleArt(Object? url) => (url ?? '').toString().replaceFirst('100x100bb', '600x600bb');

  /// Apple Music playlists aren't in the iTunes lookup, but the public playlist
  /// page carries its track list as JSON for the web player.
  Future<ResolvedMusicLink> _applePlaylist(MusicLink link) async {
    final resp = await HttpPool().getClient().get(link.uri, headers: const {
      'User-Agent': _browserAgent,
      'Accept-Language': 'en-US,en;q=0.9',
    }).timeout(_timeout);
    if (resp.statusCode != 200) {
      throw const MusicLinkException("Apple Music didn't share that playlist. Is it public?");
    }
    final parsed = parseApplePlaylistPage(resp.body);
    if (parsed.queries.isEmpty) {
      throw const MusicLinkException("Couldn't read the songs in that playlist.");
    }
    return ResolvedMusicLink(
      link: link,
      title: parsed.name.isNotEmpty ? parsed.name : 'Apple Music playlist',
      subtitle: 'Playlist · ${parsed.queries.length} songs',
      image: parsed.image,
      queries: parsed.queries,
    );
  }

  // ── Shared ──

  Future<ResolvedMusicLink> _matchedTrack(MusicLink link, String query, {String image = ''}) async {
    final song = await match(query);
    if (song == null) {
      throw MusicLinkException("Couldn't find \"$query\" on YouTube Music.");
    }
    return ResolvedMusicLink(
        link: link, title: song.title, subtitle: song.artist, image: song.image, songs: [song]);
  }

  Future<ResolvedMusicLink> _artistByName(MusicLink link, String name, {String fallbackImage = ''}) async {
    if (name.trim().isEmpty) throw const MusicLinkException("Couldn't tell which artist that is.");
    final card = await _search.resolveArtistCard(name);
    final top = card == null ? const <Song>[] : await _search.getArtistTopTracks(card.id);
    if (top.isEmpty) throw MusicLinkException("Couldn't find $name on YouTube Music.");
    return ResolvedMusicLink(
      link: link,
      title: name,
      subtitle: 'Artist · top songs',
      image: card!.image.isNotEmpty ? card.image : fallbackImage,
      songs: top,
    );
  }
}

/// The name, cover and "Title Artist" list from an Apple Music playlist page.
///
/// The page embeds the web player's data as JSON; every song row in it has a
/// `title` and an `artistName`. Walked generically, so a reshuffle of the
/// surrounding structure doesn't break it. Public for tests.
({String name, String image, List<String> queries}) parseApplePlaylistPage(String html) {
  String meta(String property) =>
      RegExp('<meta property="$property" content="([^"]*)"').firstMatch(html)?.group(1) ?? '';
  final name = _htmlUnescape(meta('og:title')).replaceFirst(RegExp(r' on Apple Music$'), '').trim();
  final image = meta('og:image');

  final queries = <String>[];
  final seen = <String>{};
  final data = RegExp(r'<script type="application/json" id="serialized-server-data">(.*?)</script>', dotAll: true)
      .firstMatch(html)
      ?.group(1);
  if (data != null) {
    try {
      void walk(Object? o) {
        if (o is Map) {
          final title = o['title'], artist = o['artistName'];
          // A song row also carries a duration; the playlist header doesn't.
          if (title is String && artist is String && o['duration'] is num) {
            final q = '$title $artist';
            if (seen.add(q.toLowerCase())) queries.add(q);
          }
          o.values.forEach(walk);
        } else if (o is List) {
          o.forEach(walk);
        }
      }

      walk(jsonDecode(data));
    } catch (_) {}
  }
  return (name: name, image: image, queries: queries);
}

String _htmlUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

/// Plays a resolved link through the normal player: a single song at once (its
/// radio carries on after it, as for any song), a collection as soon as its
/// first songs are matched, with the rest joining the queue as they're found.
class MusicLinkPlayer {
  MusicLinkPlayer(this._resolver, this._player, this._library);

  final MusicLinkResolver _resolver;
  final PlayerNotifier _player;
  final LibraryNotifier _library;

  /// False when nothing in the link could be played.
  Future<bool> play(ResolvedMusicLink r,
      {bool shuffle = false, void Function(int done, int total)? onProgress}) async {
    final link = r.link;
    final contextType = link.kind == MusicLinkKind.track ? 'song' : link.kind.name;

    if (r.queries.isEmpty) {
      if (r.songs.isEmpty) return false;
      final queue = List<Song>.from(r.songs);
      if (shuffle) queue.shuffle();
      await _player.playSong(queue.first,
          newQueue: queue,
          index: 0,
          source: 'Shared link',
          locationName: r.title,
          contextId: link.contextId,
          contextType: contextType,
          contextTitle: r.title);
      return true;
    }

    // Spotify and Apple Music lists: start on the first songs found, rather
    // than making the listener wait for a long playlist to match.
    final order = List<String>.from(r.queries);
    if (shuffle) order.shuffle();
    final first = <Song>[];
    var next = 0;
    while (first.isEmpty && next < order.length && next < 20) {
      final batch = order.skip(next).take(5).toList();
      next += batch.length;
      final found = await Future.wait(batch.map(_resolver.match));
      first.addAll(found.whereType<Song>());
      onProgress?.call(next, order.length);
    }
    if (first.isEmpty) return false;
    await _player.playSong(first.first,
        newQueue: first,
        index: 0,
        source: 'Shared link',
        locationName: r.title,
        contextId: link.contextId,
        contextType: contextType,
        contextTitle: r.title);

    final rest = order.skip(next).toList();
    if (rest.isEmpty) return true;
    final more = await _library.resolveQueriesToSongs(rest, SearchService(),
        onProgress: (done, total) => onProgress?.call(next + done, order.length));
    // Only while the link is still what's playing: the listener may have moved on.
    if (_player.currentState.contextId == link.contextId && more.songs.isNotEmpty) {
      await _player.addAlbumToQueue([...first, ...more.songs], albumId: link.contextId);
    }
    print('open link: ${first.length + more.songs.length} of ${order.length} song(s) found for "${r.title}"');
    return true;
  }
}
