/// Reading a music library out of a database nobody documented
///
/// Every offline music player stores the same handful of facts — a track has a
/// title, an artist, a cover, a duration; some tracks are liked; playlists hold
/// tracks in an order; plays happened at times, and every one of them picks
/// different names for the tables and columns that hold them.
///
/// SO NOTHING HERE IS KEYED TO A PARTICULAR APP. An earlier version hardcoded
/// one player's schema (`song`, `thumbnailUrl`, `playlist_song_map`, …), which
/// meant it could read exactly that player and nothing else — every fork, every
/// rename, every other player would have come back "no song table" even with a
/// perfectly readable library inside. This resolves the shape by INSPECTING it:
/// find the table that looks like tracks, then find the column in it that looks
/// like a title, and so on.
///
/// The result is that a backup from an unknown app either maps cleanly or is
/// honestly reported as unreadable, and adding support for one more player is
/// usually adding one more alias to a list below, not a new code path.
library;

/// Candidate names, most specific first. Matching is case-insensitive and
/// EXACT-then-contains, so `trackName` beats `track_uri` and a column called
/// `id` never wins a title slot.
class ColumnAliases {
  static const List<String> trackTable = [
    'song', 'songs', 'track', 'tracks', 'media', 'audio', 'library'
  ];
  static const List<String> playlistTable = ['playlist', 'playlists'];
  static const List<String> playlistTrackTable = [
    'playlist_song_map', 'playlist_track', 'playlist_songs',
    'playlist_song_cross_ref', 'playlistsongmap', 'playlist_entry'
  ];
  static const List<String> artistTable = ['artist', 'artists', 'channel'];
  static const List<String> albumTable = ['album', 'albums'];
  static const List<String> trackArtistTable = [
    'song_artist_map', 'track_artist', 'song_artists', 'artist_song_map'
  ];
  static const List<String> eventTable = [
    'event', 'events', 'play_event', 'history', 'listening_history', 'scrobble'
  ];
  static const List<String> searchTable = [
    'search_history', 'searches', 'search', 'recent_search'
  ];
  static const List<String> playCountTable = [
    'playcount', 'play_count', 'play_counts', 'stats'
  ];

  static const List<String> id = ['id', 'songid', 'song_id', 'videoid',
    'video_id', 'trackid', 'track_id', 'mediaid', '_id', 'uri', 'key'];
  static const List<String> title = ['title', 'name', 'trackname',
    'track_name', 'song', 'songname', 'song_title'];
  static const List<String> artist = ['artist', 'artistname', 'artist_name',
    'albumartist', 'album_artist', 'author', 'creator', 'channelname'];
  static const List<String> image = ['thumbnailurl', 'thumbnail', 'artworkurl',
    'artwork', 'coverurl', 'cover', 'image', 'imageurl', 'picture'];
  static const List<String> duration = ['duration', 'durationms',
    'duration_ms', 'length', 'lengthms', 'totalduration'];
  static const List<String> albumId = ['albumid', 'album_id'];
  static const List<String> albumName = ['albumname', 'album_name', 'album',
    'albumtitle'];
  static const List<String> liked = ['liked', 'isliked', 'is_liked',
    'favorite', 'favourite', 'isfavorite', 'is_favorite', 'bookmarked',
    'inlibrary'];
  static const List<String> likedDate = ['likeddate', 'liked_date',
    'likedat', 'favoritedat', 'bookmarkedat', 'dateadded', 'date_added'];
  static const List<String> inLibrary = ['inlibrary', 'in_library',
    'librarydate', 'dateadded'];
  static const List<String> explicit = ['explicit', 'isexplicit',
    'is_explicit'];
  static const List<String> year = ['year', 'releaseyear', 'release_year'];
  static const List<String> totalPlayTime = ['totalplaytime',
    'total_play_time', 'playtime', 'play_time', 'mslistened', 'timelistened'];
  static const List<String> position = ['position', 'idx', 'index',
    'sortorder', 'sort_order', 'ordinal', 'trackindex'];
  static const List<String> playlistId = ['playlistid', 'playlist_id'];
  static const List<String> timestamp = ['timestamp', 'playedat', 'played_at',
    'time', 'date', 'ts', 'createdat'];
  static const List<String> query = ['query', 'text', 'term', 'q', 'keyword'];
  static const List<String> count = ['count', 'plays', 'playcount', 'n'];
  static const List<String> followedAt = ['bookmarkedat', 'subscribedat',
    'followedat', 'inlibrary', 'liked', 'isfollowed'];
}

/// A resolved table: its real name plus the columns we could identify in it.
class MappedTable {
  final String name;
  final Map<String, String> columns; // logical name → real column name
  const MappedTable(this.name, this.columns);

  String? operator [](String logical) => columns[logical];
  bool has(String logical) => columns.containsKey(logical);
}

/// Only these characters can reach a query. Table and column names come from
/// `sqlite_master`, which is trustworthy, but a backup is a FILE THE USER WAS
/// GIVEN — a crafted one could name a column `x"; DROP TABLE …`, and identifiers
/// cannot be passed as bind parameters. Anything that is not a plain identifier
/// is treated as absent rather than escaped.
final RegExp _safeIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

bool isSafeIdentifier(String s) => _safeIdentifier.hasMatch(s);

/// Pick the best table for [candidates] out of the names that exist.
String? resolveTable(Iterable<String> existing, List<String> candidates) {
  final byLower = <String, String>{};
  for (final t in existing) {
    if (isSafeIdentifier(t)) byLower[t.toLowerCase()] = t;
  }
  for (final c in candidates) {
    final hit = byLower[c];
    if (hit != null) return hit;
  }
  // A fork may prefix or suffix the name ("music_songs", "songs_v2").
  for (final c in candidates) {
    for (final entry in byLower.entries) {
      if (entry.key.contains(c)) return entry.value;
    }
  }
  return null;
}

/// Pick the best column for [candidates] out of the columns a table actually
/// has. Exact matches win over partial ones, and earlier candidates win over
/// later, so 'title' is preferred to 'name' when both exist.
String? resolveColumn(Iterable<String> columns, List<String> candidates) {
  final byLower = <String, String>{};
  for (final c in columns) {
    if (isSafeIdentifier(c)) byLower[c.toLowerCase()] = c;
  }
  for (final c in candidates) {
    final hit = byLower[c];
    if (hit != null) return hit;
  }
  for (final c in candidates) {
    for (final entry in byLower.entries) {
      if (entry.key.contains(c)) return entry.value;
    }
  }
  return null;
}

/// Resolve a whole set of logical fields at once; absent ones are simply left
/// out, and every caller must cope with a missing field rather than assume it.
Map<String, String> resolveColumns(
    Iterable<String> columns, Map<String, List<String>> wanted) {
  final out = <String, String>{};
  wanted.forEach((logical, candidates) {
    final hit = resolveColumn(columns, candidates);
    if (hit != null) out[logical] = hit;
  });
  return out;
}

/// The whole shape of one music database, resolved once.
///
/// [discover] is the only thing that knows how a library is stored, and it knows
/// it by LOOKING. Everything downstream asks this map for a table and column
/// name; nothing downstream contains a schema.
class MusicDbMap {
  final MappedTable tracks;
  final MappedTable? playlists;
  final MappedTable? playlistTracks;
  final MappedTable? artists;
  final MappedTable? albums;
  final MappedTable? trackArtists;
  final MappedTable? events;
  final MappedTable? searches;
  final MappedTable? playCounts;

  const MusicDbMap({
    required this.tracks,
    this.playlists,
    this.playlistTracks,
    this.artists,
    this.albums,
    this.trackArtists,
    this.events,
    this.searches,
    this.playCounts,
  });

  /// Reads `PRAGMA table_info` for each candidate table and resolves the columns
  /// this app cares about. Returns null when nothing in the database looks like a
  /// list of tracks — the one condition under which an import genuinely cannot
  /// proceed.
  ///
  /// [columnsOf] is injected so the resolution can be exercised without a live
  /// database (see the tests).
  static Future<MusicDbMap?> discoverWith(
    Iterable<String> tables,
    Future<List<String>> Function(String table) columnsOf,
  ) async {
    Future<MappedTable?> map(
        List<String> candidates, Map<String, List<String>> wanted) async {
      final name = resolveTable(tables, candidates);
      if (name == null) return null;
      final cols = await columnsOf(name);
      if (cols.isEmpty) return null;
      return MappedTable(name, resolveColumns(cols, wanted));
    }

    final tracks = await map(ColumnAliases.trackTable, {
      'id': ColumnAliases.id,
      'title': ColumnAliases.title,
      'artist': ColumnAliases.artist,
      'image': ColumnAliases.image,
      'duration': ColumnAliases.duration,
      'albumId': ColumnAliases.albumId,
      'albumName': ColumnAliases.albumName,
      'liked': ColumnAliases.liked,
      'likedDate': ColumnAliases.likedDate,
      'inLibrary': ColumnAliases.inLibrary,
      'explicit': ColumnAliases.explicit,
      'year': ColumnAliases.year,
      'totalPlayTime': ColumnAliases.totalPlayTime,
    });
    // A track table without an id AND a title is not one we can use: the id is
    // what playlists reference and the title is the only thing a user would
    // recognise.
    if (tracks == null || !tracks.has('id') || !tracks.has('title')) return null;

    return MusicDbMap(
      tracks: tracks,
      playlists: await map(ColumnAliases.playlistTable, {
        'id': ColumnAliases.id,
        'title': ColumnAliases.title,
        'image': ColumnAliases.image,
      }),
      playlistTracks: await map(ColumnAliases.playlistTrackTable, {
        'playlist': ColumnAliases.playlistId,
        'song': ['songid', 'song_id', 'trackid', 'track_id', 'videoid', 'mediaid'],
        'position': ColumnAliases.position,
      }),
      artists: await map(ColumnAliases.artistTable, {
        'id': ColumnAliases.id,
        'title': ColumnAliases.title,
        'image': ColumnAliases.image,
        'followedAt': ColumnAliases.followedAt,
      }),
      albums: await map(ColumnAliases.albumTable, {
        'id': ColumnAliases.id,
        'title': ColumnAliases.title,
        'image': ColumnAliases.image,
        'year': ColumnAliases.year,
        'followedAt': ColumnAliases.followedAt,
      }),
      trackArtists: await map(ColumnAliases.trackArtistTable, {
        'song': ['songid', 'song_id', 'trackid', 'track_id'],
        'artist': ['artistid', 'artist_id'],
        'position': ColumnAliases.position,
      }),
      events: await map(ColumnAliases.eventTable, {
        'song': ['songid', 'song_id', 'trackid', 'track_id', 'videoid'],
        'timestamp': ColumnAliases.timestamp,
      }),
      searches: await map(ColumnAliases.searchTable, {
        'query': ColumnAliases.query,
      }),
      playCounts: await map(ColumnAliases.playCountTable, {
        'id': ['song', 'songid', 'song_id', 'trackid', 'track_id', 'id'],
        'count': ColumnAliases.count,
      }),
    );
  }

  /// One line for the log, so a mapping that went wrong is visible rather than
  /// showing up later as an import that quietly found nothing.
  String describe() {
    final parts = <String>[
      'tracks="${tracks.name}"(${tracks.columns.length} cols)',
      if (playlists != null && playlistTracks != null)
        'playlists="${playlists!.name}"+"${playlistTracks!.name}"',
      if (artists != null) 'artists="${artists!.name}"',
      if (albums != null) 'albums="${albums!.name}"',
      if (events != null) 'events="${events!.name}"',
      if (searches != null) 'searches="${searches!.name}"',
      if (playCounts != null) 'counts="${playCounts!.name}"',
    ];
    return parts.join(', ');
  }
}
