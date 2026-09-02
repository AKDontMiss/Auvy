
// Categories for items stored in the library.
enum LibraryCategory { all, playlist, artist, album, folder }

/// One artist credited on a track, with its YouTube channel/browse id so the UI
/// can navigate to the SPECIFIC tapped artist (a track can credit several).
class SongArtist {
  final String name;
  final String id; // channel/browse id (UC…); '' if YouTube didn't link it
  const SongArtist({required this.name, this.id = ''});

  Map<String, dynamic> toMap() => {'name': name, 'id': id};
  factory SongArtist.fromMap(Map<String, dynamic> m) =>
      SongArtist(name: (m['name'] ?? '').toString(), id: (m['id'] ?? '').toString());
}

/// One playable thing. A track, a radio station, a podcast episode or an
/// imported local file all arrive as a Song.
///
/// THE `id` FIELD IS POLYMORPHIC, and roughly fifty places in the app branch on
/// its shape. Nothing enforces this; it is a convention, and reading it wrong is
/// how a radio station ends up being treated as a YouTube track:
///
///   11 characters      a YouTube videoId (the common case)
///   starts with http   a live radio stream URL, played directly
///   starts with local_ a file imported from Music/Auvy on this device
///   starts with onb_   an onboarding placeholder, never played
///   starts with dummy  sample data for an empty state
///
/// So `song.id.length == 11` reads as "is this a real YouTube track", and
/// `song.id.startsWith('http')` as "is this live radio". Both appear all over
/// the codebase and mean exactly that.
///
/// A few fields carry conventions too: `albumTitle` is the string "Podcast" for
/// podcast episodes (used to keep them out of the music auto-cache), and
/// `image` may be a network URL or an on-disk path depending on where the Song
/// came from.
class Song {
  final String id;
  final String title;
  final String artist;
  final String image;
  final String audioUrl;
  final String albumId;
  final String albumTitle;
  final String releaseDate; //  Added
  final String duration;
  final int popularity;
  final double? loudness;
  final bool? isExplicit;
  final int? songCount;
  // Per-artist credits (name + browse id). Empty when only the joined [artist]
  // string is known. Lets the player page route each tapped name to its artist.
  final List<SongArtist> artists;
  // Stream/view count label from YouTube ("1.2B plays" / "500M views"), '' when
  // not provided. Best-effort — shown where available (e.g. album track rows).
  final String viewCount;
  // YouTube's MUSIC_VIDEO_TYPE_* for this track ('' when unknown). ATV = a pure
  // audio "song"; OMV/UGC = a music VIDEO (cinematic cut with intros/dialogue,
  // often longer than the song). Audio-only mode uses [isMusicVideo] to swap
  // these for their studio-audio equivalent at play time.
  final String musicVideoType;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.image,
    this.audioUrl = '',
    this.albumId = '',
    this.albumTitle = '',
    this.releaseDate = '', //  Default to empty string
    this.duration = '0:00',
    this.popularity = 0,
    this.loudness,
    this.isExplicit,
    this.songCount,
    this.artists = const [],
    this.viewCount = '',
    this.musicVideoType = '',
  });

  /// True when this track is a music VIDEO (OMV/UGC) rather than a pure audio
  /// song — the entries audio-only mode conforms to studio audio at play time.
  bool get isMusicVideo =>
      musicVideoType.contains('OMV') || musicVideoType.contains('UGC');

  /// The one video test — there were three, AND they disagreed
  ///
  /// Auvy plays audio only; there is no toggle. So every video encountered has
  /// to be recognised as one, and it was being recognised by three separate
  /// copies of the same idea — in ConformNotifier, in playSong, and in the
  /// autoplay guard, which is how "some videos still come through" survives a
  /// fix: each copy gets corrected on its own schedule.
  ///
  /// Two signals, because either alone leaks:
  ///
  ///  • `musicVideoType` is authoritative but frequently EMPTY. Confirmed on
  ///    device: Ariana Grande's "we can't be friends" arrived as an OMV video
  ///    with mvType='', so a type-only test passed it straight through.
  ///  • the THUMBNAIL is the reliable fallback. A video carries a 16:9 still
  ///    from ytimg; audio tracks carry SQUARE googleusercontent art. The old
  ///    check looked for the exact substring `ytimg.com/vi/` and therefore
  ///    missed `ytimg.com/vi_webp/` and `img.youtube.com/vi/` — the same still,
  ///    served under a different path.
  bool get looksLikeVideo {
    if (isMusicVideo) return true;
    final img = image;
    // `/vi/` and `/vi_webp/` on either host, in one test, so a new spelling of
    // the same URL cannot quietly reopen this.
    return img.contains('ytimg.com/vi') || img.contains('youtube.com/vi');
  }

  /// Artist text safe for display in tiles/subtitles: the joined [artist] when
  /// present, otherwise the per-artist credit names, otherwise a generic
  /// placeholder. Never returns blank, so tracks with missing metadata don't
  /// render an empty line under the title.
  String get displayArtist {
    final a = artist.trim();
    if (a.isNotEmpty && a.toLowerCase() != 'unknown artist' && a.toLowerCase() != 'unknown') {
      return a;
    }
    final joined =
        artists.map((e) => e.name).where((n) => n.trim().isNotEmpty).join(', ');
    if (joined.isNotEmpty) return joined;
    return a.isNotEmpty ? a : 'Unknown Artist';
  }

  Song copyWith({
    String? id, String? title, String? artist, String? image, String? audioUrl,
    String? albumId, String? albumTitle, String? releaseDate, //  Added
    String? duration, int? popularity,
    double? loudness, bool? isExplicit, int? songCount,
    List<SongArtist>? artists, String? viewCount, String? musicVideoType,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      image: image ?? this.image,
      audioUrl: audioUrl ?? this.audioUrl,
      albumId: albumId ?? this.albumId,
      albumTitle: albumTitle ?? this.albumTitle,
      releaseDate: releaseDate ?? this.releaseDate, //  Added
      duration: duration ?? this.duration,
      popularity: popularity ?? this.popularity,
      loudness: loudness ?? this.loudness,
      isExplicit: isExplicit ?? this.isExplicit,
      songCount: songCount ?? this.songCount,
      artists: artists ?? this.artists,
      viewCount: viewCount ?? this.viewCount,
      musicVideoType: musicVideoType ?? this.musicVideoType,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id, 'title': title, 'artist': artist, 'image': image,
    'audioUrl': audioUrl, 'albumId': albumId, 'albumTitle': albumTitle,
    'releaseDate': releaseDate, //  Added
    'duration': duration, 'popularity': popularity,
    'loudness': loudness, 'isExplicit': isExplicit,
    'songCount': songCount,
    'artists': artists.map((a) => a.toMap()).toList(),
    'viewCount': viewCount,
    'musicVideoType': musicVideoType,
  };

  factory Song.fromMap(Map<String, dynamic> map) => Song(
    id: map['id'] ?? '',
    title: map['title'] ?? '',
    artist: map['artist'] ?? '',
    image: map['image'] ?? '',
    audioUrl: map['audioUrl'] ?? '',
    albumId: map['albumId'] ?? '',
    albumTitle: map['albumTitle'] ?? '',
    //  FIX: Use null-coalescing to ensure a String is always returned
    releaseDate: (map['releaseDate'] ?? map['release_date'] ?? '').toString(),
    duration: map['duration'] ?? '0:00',
    popularity: map['popularity'] ?? 0,
    loudness: map['loudness']?.toDouble(),
    isExplicit: map['isExplicit'],
    songCount: map['songCount'] ?? map['nb_tracks'] ?? map['trackCount'],
    artists: (map['artists'] as List? ?? [])
        .map((e) => SongArtist.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(),
    viewCount: (map['viewCount'] ?? '').toString(),
    musicVideoType: (map['musicVideoType'] ?? '').toString(),
  );
}

/// A row on the Library screen: a playlist, album, artist or system folder.
///
/// A shelf ENTRY, not its contents. The tracks live elsewhere (the library
/// provider keys them by playlist id); this only carries what the row needs to
/// draw itself and sort itself.
///
/// `isSystemFolder` marks the rows Auvy creates rather than the user, such as
/// Downloads and Liked Songs. Those cannot be renamed or deleted, which is why
/// the flag exists rather than being inferred from the title.
class LibraryItem {
  final String title;
  final String subtitle;
  final String image;
  final bool isPinned;
  final bool isCircle;
  final LibraryCategory category;
  final DateTime dateAdded;
  final int songCount;
  final bool isSystemFolder; 

  LibraryItem({
    required this.title, required this.subtitle, required this.image,
    this.isPinned = false, this.isCircle = false,
    this.category = LibraryCategory.playlist,
    required this.dateAdded, this.songCount = 0, this.isSystemFolder = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryItem &&
          runtimeType == other.runtimeType &&
          title == other.title;

  @override
  int get hashCode => title.hashCode;

  Map<String, dynamic> toMap() => {
    'title': title, 'subtitle': subtitle, 'image': image,
    'isPinned': isPinned, 'isCircle': isCircle, 'category': category.index,
    'dateAdded': dateAdded.toIso8601String(), 'songCount': songCount, 'isSystemFolder': isSystemFolder,
  };

  factory LibraryItem.fromMap(Map<String, dynamic> map) => LibraryItem(
    title: map['title'] ?? '', subtitle: map['subtitle'] ?? '', image: map['image'] ?? '',
    isPinned: map['isPinned'] ?? false, isCircle: map['isCircle'] ?? false,
    category: LibraryCategory.values[map['category'] ?? 1],
    dateAdded: DateTime.parse(map['dateAdded'] ?? DateTime.now().toIso8601String()),
    songCount: map['songCount'] ?? 0, isSystemFolder: map['isSystemFolder'] ?? false,
  );
}

// Updated HomeSection to support different types (for click handling and UI)
class HomeSection {
  final String title;
  final List<Song> songs;
  final String type; // 'artist', 'genre', 'mix', 'random'
  /// Browse id of the playlist/album this section PREVIEWS (curated home
  /// mixes carry one) — lets the section page fetch the FULL track list on
  /// open instead of being stuck with the rail preview. '' for sections
  /// generated locally (daily mixes, "Best of", random topics).
  final String sourceId;

  HomeSection({
    required this.title,
    required this.songs,
    this.type = 'generic',
    this.sourceId = '',
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'songs': songs.map((s) => s.toMap()).toList(), // Uses the existing Song.toMap()
    'type': type,
    'sourceId': sourceId,
  };

  /// Reconstructs a HomeSection from a JSON Map
  factory HomeSection.fromJson(Map<String, dynamic> json) => HomeSection(
    title: json['title'] as String,
    songs: (json['songs'] as List)
        .map((s) => Song.fromMap(s as Map<String, dynamic>))
        .toList(), // Uses the existing Song.fromMap()
    type: json['type'] as String,
    // Absent in pre-existing cached home payloads — default to ''.
    sourceId: (json['sourceId'] as String?) ?? '',
  );
}

final List<LibraryItem> libraryItems = [
  LibraryItem(title: "Liked Songs", subtitle: "Playlist • 0 songs", image: "assets/images/liked_songs_cyan.webp", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "My Top 50", subtitle: "Dynamic Playlist", image: "assets/images/top_50_cyan.webp", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  // The image path here is a PLACEHOLDER and always overridden: _getThemedIcon
  // replaces any path starting with `assets/` with the accent-themed variant for
  // the folder's title. It pointed at `your_artists_icon.webp`, which never
  // existed — harmless only because nothing ever loaded it. Now it names a real
  // file so the fallback is honest if that overriding ever changes.
  LibraryItem(title: "Your Artists", subtitle: "Folder • 0 Artists", image: "assets/images/playlist_cyan.webp", isPinned: true, isCircle: true, category: LibraryCategory.artist, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "Liked Albums", subtitle: "Folder • 0 Albums", image: "assets/images/liked_albums_cyan.webp", isPinned: true, category: LibraryCategory.album, dateAdded: DateTime.now(), isSystemFolder: true),
];