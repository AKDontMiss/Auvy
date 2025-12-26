import 'package:auvy/data/dummy_data.dart';

// Model representing a music album or collection.
class Album {
  final String id;
  final String title;
  final String image;
  final String releaseDate;
  final String recordType; 

  Album({
    required this.id,
    required this.title,
    required this.image,
    required this.releaseDate,
    required this.recordType,
  });

  // Converts album metadata into a map for saving.
  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'image': image,
    'releaseDate': releaseDate,
    'recordType': recordType,
  };

  // Creates an album instance from a stored map.
  factory Album.fromMap(Map<String, dynamic> map) => Album(
    id: map['id'] ?? '',
    title: map['title'] ?? '',
    image: map['image'] ?? '',
    releaseDate: map['release_date'] ?? map['releaseDate'] ?? '',
    recordType: map['record_type'] ?? map['recordType'] ?? 'album',
  );

  // Creates an album instance from JSON data received from an API.
  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'].toString(),
      title: json['title'] ?? 'Unknown',
      image: json['cover_medium'] ?? '',
      releaseDate: json['release_date'] ?? '',
      recordType: (json['record_type'] ?? 'album').toString().toLowerCase(),
    );
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

  ArtistData({
    required this.name,
    required this.image,
    required this.topTracks,
    required this.albums,
    required this.singles,
    required this.relatedArtists,
    required this.playlists,
    required this.liveAlbums,
  });
}