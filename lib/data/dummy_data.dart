import 'package:flutter/foundation.dart';

// Categories for items stored in the library.
enum LibraryCategory { all, playlist, artist, album, folder }

// Model representing a single song and its metadata.
class Song {
  final String id;
  final String title;
  final String artist;
  final String image;
  final String audioUrl;
  final String albumId;
  final String albumTitle;
  final String duration; // Added to resolve metadata discrepancy

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.image,
    this.audioUrl = '',
    this.albumId = '',
    this.albumTitle = '',
    this.duration = '0:00', // Default duration
  });

  // Converts a song object into a map for storage.
  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'artist': artist,
    'image': image,
    'audioUrl': audioUrl,
    'albumId': albumId,
    'albumTitle': albumTitle,
    'duration': duration,
  };

  // Creates a song object from a map.
  factory Song.fromMap(Map<String, dynamic> map) => Song(
    id: map['id'] ?? '',
    title: map['title'] ?? '',
    artist: map['artist'] ?? '',
    image: map['image'] ?? '',
    audioUrl: map['audioUrl'] ?? '',
    albumId: map['albumId'] ?? '',
    albumTitle: map['albumTitle'] ?? '',
    duration: map['duration'] ?? '0:00',
  );
}

// Model representing a collection or folder in the user's library.
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
    required this.title,
    required this.subtitle,
    required this.image,
    this.isPinned = false,
    this.isCircle = false,
    this.category = LibraryCategory.playlist,
    required this.dateAdded,
    this.songCount = 0,
    this.isSystemFolder = false,
  });

  // Serializes the library item for local persistence.
  Map<String, dynamic> toMap() => {
    'title': title,
    'subtitle': subtitle,
    'image': image,
    'isPinned': isPinned,
    'isCircle': isCircle,
    'category': category.index,
    'dateAdded': dateAdded.toIso8601String(),
    'songCount': songCount,
    'isSystemFolder': isSystemFolder,
  };

  // Deserializes a library item from a map.
  factory LibraryItem.fromMap(Map<String, dynamic> map) => LibraryItem(
    title: map['title'] ?? '',
    subtitle: map['subtitle'] ?? '',
    image: map['image'] ?? '',
    isPinned: map['isPinned'] ?? false,
    isCircle: map['isCircle'] ?? false,
    category: LibraryCategory.values[map['category'] ?? 1],
    dateAdded: DateTime.parse(map['dateAdded'] ?? DateTime.now().toIso8601String()),
    songCount: map['songCount'] ?? 0,
    isSystemFolder: map['isSystemFolder'] ?? false,
  );
}

// Model for grouping songs into a visual section on the home page.
class HomeSection {
  final String title;
  final List<Song> songs;
  HomeSection({required this.title, required this.songs});
}

// Default set of folders and playlists for the library view.
final List<LibraryItem> libraryItems = [
  LibraryItem(title: "Liked Songs", subtitle: "Playlist • 0 songs", image: "assets/images/liked_icon.png", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "My Top 50", subtitle: "Dynamic Playlist", image: "assets/images/top_50_icon.png", isPinned: true, category: LibraryCategory.folder, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "Your Artists", subtitle: "Folder • 0 Artists", image: "assets/images/your_artists_icon.png", isPinned: true, isCircle: true, category: LibraryCategory.artist, dateAdded: DateTime.now(), isSystemFolder: true),
  LibraryItem(title: "Liked Albums", subtitle: "Folder • 0 Albums", image: "assets/images/liked_albums_icon.png", isPinned: true, category: LibraryCategory.album, dateAdded: DateTime.now(), isSystemFolder: true),
];