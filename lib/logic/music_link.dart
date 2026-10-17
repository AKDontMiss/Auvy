import 'package:auvy/data/dummy_data.dart';

/// A link to music somewhere else: Spotify, Apple Music, YouTube or YouTube
/// Music, as it arrives from a share sheet, a paste, a Shortcut or Siri.
///
/// Parsing is pure (no network) so every shape people actually share is
/// covered by tests. Short links (spotify.link, apple.co) can't be read
/// without following them, so they parse as [MusicLinkKind.short] and the
/// resolver expands them first.
enum MusicLinkSource { spotify, appleMusic, youtube }

enum MusicLinkKind { track, album, playlist, artist, short }

class MusicLink {
  final MusicLinkSource source;
  final MusicLinkKind kind;

  /// The service's own id: a Spotify id, an Apple Music numeric or `pl.` id, a
  /// YouTube video id, playlist id, album browse id or channel id.
  final String id;

  /// Apple Music only: the song inside an album link (`?i=`), and the
  /// storefront, which the catalogue lookup needs to find regional releases.
  final String? songId;
  final String country;

  final Uri uri;

  const MusicLink({
    required this.source,
    required this.kind,
    required this.id,
    required this.uri,
    this.songId,
    this.country = 'us',
  });

  String get sourceName => switch (source) {
        MusicLinkSource.spotify => 'Spotify',
        MusicLinkSource.appleMusic => 'Apple Music',
        MusicLinkSource.youtube => uri.host.contains('music.') ? 'YouTube Music' : 'YouTube',
      };

  /// A stable id for the queue context this link plays as.
  String get contextId => 'link:${source.name}:$id';

  @override
  String toString() => 'MusicLink(${source.name} ${kind.name} $id)';

  /// The first music link in [text]: a bare URL, or one inside the sentence a
  /// share sheet wraps it in ("Listen to X by Y on Spotify: https://…").
  /// Null when there is none Auvy can open.
  static MusicLink? find(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // spotify:track:ID, which desktop apps copy.
    final spUri = RegExp(r'spotify:(track|album|playlist|artist):([A-Za-z0-9]{10,})')
        .firstMatch(trimmed);
    if (spUri != null) {
      return MusicLink(
        source: MusicLinkSource.spotify,
        kind: MusicLinkKind.values.byName(spUri.group(1)!),
        id: spUri.group(2)!,
        uri: Uri.parse('https://open.spotify.com/${spUri.group(1)}/${spUri.group(2)}'),
      );
    }

    for (final m in RegExp(r'''https?://[^\s<>"']+''').allMatches(trimmed)) {
      // Trailing punctuation from the sentence around it is not part of the URL.
      final raw = m.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      final link = fromUri(uri);
      if (link != null) return link;
    }
    // A link pasted without its scheme.
    if (!trimmed.contains(' ') && trimmed.contains('.') && !trimmed.contains('://')) {
      final uri = Uri.tryParse('https://$trimmed');
      if (uri != null) return fromUri(uri);
    }
    return null;
  }

  static MusicLink? fromUri(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // ── Spotify ──
    if (host == 'open.spotify.com' || host == 'play.spotify.com') {
      // Localised links put the language first: /intl-de/track/ID.
      final parts = segs.isNotEmpty && segs.first.startsWith('intl-') ? segs.sublist(1) : segs;
      if (parts.length >= 2) {
        final kind = switch (parts[0]) {
          'track' => MusicLinkKind.track,
          'album' => MusicLinkKind.album,
          'playlist' => MusicLinkKind.playlist,
          'artist' => MusicLinkKind.artist,
          _ => null,
        };
        final id = parts[1];
        if (kind != null && RegExp(r'^[A-Za-z0-9]{10,}$').hasMatch(id)) {
          return MusicLink(source: MusicLinkSource.spotify, kind: kind, id: id, uri: uri);
        }
      }
      return null;
    }
    if (host == 'spotify.link' || host == 'spoti.fi' || host == 'spotify.app.link') {
      return segs.isEmpty
          ? null
          : MusicLink(source: MusicLinkSource.spotify, kind: MusicLinkKind.short, id: segs.last, uri: uri);
    }

    // ── Apple Music ──
    if (host == 'music.apple.com' || host == 'geo.music.apple.com' || host == 'itunes.apple.com') {
      // /{country}/{type}/{slug}/{id}; the slug is sometimes missing.
      if (segs.length < 3) return null;
      final country = RegExp(r'^[a-z]{2}$').hasMatch(segs[0]) ? segs[0] : 'us';
      final typeIndex = segs.indexWhere(
          (s) => const {'album', 'song', 'playlist', 'artist', 'music-video'}.contains(s));
      if (typeIndex < 0) return null;
      final type = segs[typeIndex];
      final id = segs.last.replaceFirst(RegExp(r'^id'), '');
      final songId = uri.queryParameters['i'];
      switch (type) {
        case 'album':
          if (!RegExp(r'^\d+$').hasMatch(id)) return null;
          if (songId != null && RegExp(r'^\d+$').hasMatch(songId)) {
            return MusicLink(
                source: MusicLinkSource.appleMusic,
                kind: MusicLinkKind.track,
                id: id,
                songId: songId,
                country: country,
                uri: uri);
          }
          return MusicLink(
              source: MusicLinkSource.appleMusic, kind: MusicLinkKind.album, id: id, country: country, uri: uri);
        case 'song':
        case 'music-video':
          if (!RegExp(r'^\d+$').hasMatch(id)) return null;
          return MusicLink(
              source: MusicLinkSource.appleMusic,
              kind: MusicLinkKind.track,
              id: id,
              songId: id,
              country: country,
              uri: uri);
        case 'playlist':
          if (!id.startsWith('pl.')) return null;
          return MusicLink(
              source: MusicLinkSource.appleMusic, kind: MusicLinkKind.playlist, id: id, country: country, uri: uri);
        case 'artist':
          if (!RegExp(r'^\d+$').hasMatch(id)) return null;
          return MusicLink(
              source: MusicLinkSource.appleMusic, kind: MusicLinkKind.artist, id: id, country: country, uri: uri);
      }
      return null;
    }
    if (host == 'apple.co') {
      return segs.isEmpty
          ? null
          : MusicLink(source: MusicLinkSource.appleMusic, kind: MusicLinkKind.short, id: segs.last, uri: uri);
    }

    // ── YouTube and YouTube Music ──
    bool isVideoId(String s) => RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s);
    if (host == 'youtu.be') {
      if (segs.isNotEmpty && isVideoId(segs.first)) {
        return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.track, id: segs.first, uri: uri);
      }
      return null;
    }
    if (host == 'youtube.com' || host == 'm.youtube.com' || host == 'music.youtube.com') {
      final v = uri.queryParameters['v'];
      final list = uri.queryParameters['list'];
      if (segs.isNotEmpty && segs.first == 'watch' && v != null && isVideoId(v)) {
        // A song opened from a playlist is still that song.
        return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.track, id: v, uri: uri);
      }
      if (segs.length >= 2 && const {'shorts', 'live', 'embed', 'v'}.contains(segs.first) && isVideoId(segs[1])) {
        return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.track, id: segs[1], uri: uri);
      }
      if (segs.isNotEmpty && segs.first == 'playlist' && list != null && list.isNotEmpty) {
        // Album "playlists" (OLAK5uy_…) play the same way as any other list.
        return MusicLink(
            source: MusicLinkSource.youtube,
            kind: list.startsWith('OLAK5uy_') ? MusicLinkKind.album : MusicLinkKind.playlist,
            id: list,
            uri: uri);
      }
      if (segs.length >= 2 && segs.first == 'browse') {
        final id = segs[1];
        if (id.startsWith('MPREb_')) {
          return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.album, id: id, uri: uri);
        }
        if (id.startsWith('VL') && id.length > 2) {
          return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.playlist, id: id.substring(2), uri: uri);
        }
        if (id.startsWith('UC')) {
          return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.artist, id: id, uri: uri);
        }
      }
      if (segs.length >= 2 && segs.first == 'channel' && segs[1].startsWith('UC')) {
        return MusicLink(source: MusicLinkSource.youtube, kind: MusicLinkKind.artist, id: segs[1], uri: uri);
      }
      return null;
    }
    return null;
  }
}

/// The search result that best covers a "Title Artist" query.
///
/// Search order is popularity, which often puts a remix, live or karaoke version
/// first. Each result is scored by the words it shares with the query divided
/// by all the words either has (a ratio, so a result with every query word plus
/// "Live Tribute Band" loses to the plain track). Ties keep search order. Shared
/// by link imports, data-export imports and opening a link.
Song pickBestOverlap(String query, List<Song> results) {
  Set<String> words(String s) =>
      s.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1).toSet();
  final wanted = words(query);
  Song best = results.first;
  if (wanted.isEmpty) return best;
  var bestScore = -1.0;
  for (final r in results) {
    final have = words('${r.title} ${r.artist}');
    final inter = wanted.intersection(have).length;
    final union = wanted.length + have.length - inter;
    final score = union == 0 ? 0.0 : inter / union;
    if (score > bestScore) {
      bestScore = score;
      best = r;
    }
  }
  return best;
}
