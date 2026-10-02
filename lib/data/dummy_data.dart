
// Categories for items stored in the library.
enum LibraryCategory { all, playlist, artist, album, folder }

/// One artist credited on a track, with its browse id so the UI can open that
/// specific artist (a track can credit several).
class SongArtist {
  final String name;
  final String id; // channel/browse id (UC…); '' if YouTube didn't link it
  const SongArtist({required this.name, this.id = ''});

  Map<String, dynamic> toMap() => {'name': name, 'id': id};
  factory SongArtist.fromMap(Map<String, dynamic> m) =>
      SongArtist(name: (m['name'] ?? '').toString(), id: (m['id'] ?? '').toString());
}

/// One playable item: a track, radio station, podcast episode, audiobook chapter
/// or imported local file.
///
/// The `id` field's shape tells them apart, and much of the app relies on it:
///
///   11 characters      a YouTube video id
///   starts with http   a direct stream URL (radio, podcast, audiobook)
///   starts with local_ a file imported from the device
///   starts with onb_   an onboarding placeholder, never played
///   starts with dummy  sample data for an empty state
///
/// Other conventions: `albumTitle` is "Podcast" for podcast episodes (keeps them
/// out of the music cache), and `image` may be a URL or a local file path.
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
  // Per-artist credits (name + browse id); empty when only the joined [artist]
  // string is known.
  final List<SongArtist> artists;
  // YouTube's play-count label ("1.2B plays"), or '' when not provided.
  final String viewCount;
  // YouTube's MUSIC_VIDEO_TYPE_* ('' when unknown). ATV is an audio track;
  // OMV/UGC is a music video, which is swapped for the studio audio at play time.
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

  /// True when this is a music video (OMV/UGC) rather than an audio track.
  bool get isMusicVideo =>
      musicVideoType.contains('OMV') || musicVideoType.contains('UGC');

  /// Whether this track is a video, which the app swaps for its audio version.
  ///
  /// Two signals, because either alone misses cases: `musicVideoType` when YouTube
  /// provides it (often empty), and the thumbnail, since videos carry a 16:9 ytimg
  /// still while audio tracks carry square artwork.
  bool get looksLikeVideo {
    if (isMusicVideo) return true;
    final img = image;
    // Matches `/vi/` and `/vi_webp/` on either thumbnail host.
    return img.contains('ytimg.com/vi') || img.contains('youtube.com/vi');
  }

  /// Artist text for display: the joined [artist], else the credit names, else a
  /// placeholder. Never blank.
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
/// Only what the row needs to draw and sort itself; the tracks are stored by the
/// library provider. `isSystemFolder` marks rows Auvy creates (Downloads, Liked
/// Songs), which cannot be renamed or deleted.
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

// A home-screen rail of songs, with a type for tap handling and layout.
class HomeSection {
  final String title;
  final List<Song> songs;
  final String type; // 'artist', 'genre', 'mix', 'random'
  /// Browse id of the playlist or album this rail previews, so its page can load
  /// the full track list. '' for rails built locally.
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

  /// Rebuilds a HomeSection from JSON.
  factory HomeSection.fromJson(Map<String, dynamic> json) => HomeSection(
    title: json['title'] as String,
    songs: (json['songs'] as List)
        .map((s) => Song.fromMap(s as Map<String, dynamic>))
        .toList(), // Uses the existing Song.fromMap()
    type: json['type'] as String,
    // Absent in older cached payloads.
    sourceId: (json['sourceId'] as String?) ?? '',
  );
}

final List<LibraryItem> libraryItems = [
  LibraryItem(title: "Liked Songs", subtitle: "Playlist • 0 songs", image: "assets/images/liked_songs_cyan.webp", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "My Top 50", subtitle: "Dynamic Playlist", image: "assets/images/top_50_cyan.webp", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  // Placeholder images: the library page swaps any `assets/` path for the
  // accent-coloured icon of that folder.
  LibraryItem(title: "Your Artists", subtitle: "Folder • 0 Artists", image: "assets/images/playlist_cyan.webp", isPinned: true, isCircle: true, category: LibraryCategory.artist, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "Liked Albums", subtitle: "Folder • 0 Albums", image: "assets/images/liked_albums_cyan.webp", isPinned: true, category: LibraryCategory.album, dateAdded: DateTime.now(), isSystemFolder: true),
];