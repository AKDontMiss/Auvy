import 'package:auvy/data/dummy_data.dart';

// Model representing a music album or collection.
class Album {
  final String id;
  final String title;
  final String image;
  final String releaseDate;
  final String recordType;
  /// The item's own subtitle verbatim from YouTube Music, e.g. "Album • 2021",
  /// "Single • 2020", or "Playlist • `<creator>`". Displayed as-is so albums show
  /// their year and playlists show a proper "Playlist • creator" label.
  final String subtitle;
  /// The album's artist. Persisted with liked albums so opening one from the
  /// library can resolve its tracks by "`<title>` `<artist>`" — without this the
  /// library had to pass artistName "Unknown" and liked albums opened EMPTY.
  final String artist;

  Album({
    required this.id,
    required this.title,
    required this.image,
    required this.releaseDate,
    required this.recordType,
    this.subtitle = '',
    this.artist = '',
  });

  // Converts album metadata into a map for saving.
  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'image': image,
    'releaseDate': releaseDate,
    'recordType': recordType,
    'subtitle': subtitle,
    'artist': artist,
  };

  // Creates an album instance from a stored map.
  factory Album.fromMap(Map<String, dynamic> map) => Album(
    id: map['id'] ?? '',
    title: map['title'] ?? '',
    image: map['image'] ?? '',
    releaseDate: map['release_date'] ?? map['releaseDate'] ?? '',
    recordType: map['record_type'] ?? map['recordType'] ?? 'album',
    subtitle: (map['subtitle'] ?? '').toString(),
    artist: (map['artist'] ?? '').toString(),
  );

  // Creates an album instance from JSON data received from an API.
  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'].toString(),
      title: json['title'] ?? 'Unknown',
      image: json['cover_medium'] ?? '',
      releaseDate: json['release_date'] ?? '',
      recordType: (json['record_type'] ?? 'album').toString().toLowerCase(),
      subtitle: (json['subtitle'] ?? '').toString(),
    );
  }

  /// A display subtitle that always has content: the real YouTube subtitle when
  /// present, otherwise a sensible "`<Type>` • `<year>`" fallback.
  String get displaySubtitle {
    if (subtitle.trim().isNotEmpty) return subtitle.trim();
    final label = recordType.isEmpty
        ? 'Album'
        : (recordType == 'ep' ? 'EP' : recordType[0].toUpperCase() + recordType.substring(1));
    final year = releaseDate.isNotEmpty ? releaseDate.split('-')[0] : '';
    return year.isNotEmpty ? '$label • $year' : label;
  }
}

// Model containing comprehensive details about an artist.
class ArtistData {
  final String name;
  final String image;
  final List<Song> topTracks;
  final List<Album> albums;
  final List<Album> singles; 
  final List<Song> relatedArtists;
  final List<Song> playlists;
  final List<Album> liveAlbums;
  final List<Album> featuredAlbums; // "Featured on" — albums/playlists the artist appears on
  final String description; // "About" bio from the channel header ('' if none)
  final String subscriberCount; // e.g. "12.3M subscribers" ('' if none)

  ArtistData({
    required this.name,
    required this.image,
    required this.topTracks,
    required this.albums,
    required this.singles,
    required this.relatedArtists,
    required this.playlists,
    required this.liveAlbums,
    this.featuredAlbums = const [],
    this.description = '',
    this.subscriberCount = '',
  });

  /// Converts ArtistData to a Map for JSON encoding
  Map<String, dynamic> toJson() => {
    'name': name,
    'image': image,
    'topTracks': topTracks.map((x) => x.toMap()).toList(),
    'albums': albums.map((x) => x.toMap()).toList(),
    'singles': singles.map((x) => x.toMap()).toList(),
    'relatedArtists': relatedArtists.map((x) => x.toMap()).toList(),
    'playlists': playlists.map((x) => x.toMap()).toList(),
    'liveAlbums': liveAlbums.map((x) => x.toMap()).toList(),
    'featuredAlbums': featuredAlbums.map((x) => x.toMap()).toList(),
    'description': description,
    'subscriberCount': subscriberCount,
  };

  /// Creates ArtistData from a Map decoded from JSON
  factory ArtistData.fromJson(Map<String, dynamic> json) {
    return ArtistData(
      name: json['name'] ?? '',
      image: json['image'] ?? '',
      topTracks: (json['topTracks'] as List? ?? []).map((x) => Song.fromMap(x)).toList(),
      albums: (json['albums'] as List? ?? []).map((x) => Album.fromMap(x)).toList(),
      singles: (json['singles'] as List? ?? []).map((x) => Album.fromMap(x)).toList(),
      relatedArtists: (json['relatedArtists'] as List? ?? []).map((x) => Song.fromMap(x)).toList(),
      playlists: (json['playlists'] as List? ?? []).map((x) => Song.fromMap(x)).toList(),
      liveAlbums: (json['liveAlbums'] as List? ?? []).map((x) => Album.fromMap(x)).toList(),
      featuredAlbums: (json['featuredAlbums'] as List? ?? []).map((x) => Album.fromMap(x)).toList(),
      description: (json['description'] ?? '').toString(),
      subscriberCount: (json['subscriberCount'] ?? '').toString(),
    );
  }
}