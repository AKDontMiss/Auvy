import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';

// Defines sorting options for library items.
enum SortOption { dateAdded, name, songCount }

// State container for all library-related data and UI preferences.
class LibraryState {
  final LibraryCategory selectedCategory;
  final SortOption sortOption;
  final bool isGrid;
  final String searchQuery;
  final List<LibraryItem> filteredItems;
  final List<LibraryItem> allItems;
  final Set<String> likedSongIds; 
  final List<Song> likedSongs; 
  final List<Album> likedAlbums;
  final List<Song> subscribedArtists;
  final Map<String, List<Song>> playlistSongs; 

  LibraryState({
    this.selectedCategory = LibraryCategory.all,
    this.sortOption = SortOption.dateAdded,
    this.isGrid = false,
    this.searchQuery = '',
    this.filteredItems = const [],
    this.allItems = const [],
    this.likedSongIds = const {},
    this.likedSongs = const [],
    this.likedAlbums = const [],
    this.subscribedArtists = const [],
    this.playlistSongs = const {},
  });

  // Returns a new state instance with updated fields.
  LibraryState copyWith({
    LibraryCategory? selectedCategory,
    SortOption? sortOption,
    bool? isGrid,
    String? searchQuery,
    List<LibraryItem>? filteredItems,
    List<LibraryItem>? allItems,
    Set<String>? likedSongIds,
    List<Song>? likedSongs,
    List<Album>? likedAlbums,
    List<Song>? subscribedArtists,
    Map<String, List<Song>>? playlistSongs,
  }) {
    return LibraryState(
      selectedCategory: selectedCategory ?? this.selectedCategory,
      sortOption: sortOption ?? this.sortOption,
      isGrid: isGrid ?? this.isGrid,
      searchQuery: searchQuery ?? this.searchQuery,
      filteredItems: filteredItems ?? this.filteredItems,
      allItems: allItems ?? this.allItems,
      likedSongIds: likedSongIds ?? this.likedSongIds,
      likedSongs: likedSongs ?? this.likedSongs,
      likedAlbums: likedAlbums ?? this.likedAlbums,
      subscribedArtists: subscribedArtists ?? this.subscribedArtists,
      playlistSongs: playlistSongs ?? this.playlistSongs,
    );
  }
}

// Notifier that handles library persistence, playlist management, and user favorites.
class LibraryNotifier extends StateNotifier<LibraryState> {
  LibraryNotifier() : super(LibraryState(filteredItems: libraryItems, allItems: libraryItems)) {
    _init(); 
  }

  // Loads saved library data from local storage on startup.
  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString('auvy_library_data');
    if (savedData != null) {
      try {
        final Map<String, dynamic> json = jsonDecode(savedData);
        final allItems = (json['allItems'] as List).map((i) => LibraryItem.fromMap(i)).toList();
        final likedSongs = (json['likedSongs'] as List? ?? []).map((s) => Song.fromMap(s)).toList();
        final likedSongIds = Set<String>.from(likedSongs.map((s) => s.id));
        final likedAlbums = (json['likedAlbums'] as List? ?? []).map((i) => Album.fromMap(i)).toList();
        final subscribedArtists = (json['subscribedArtists'] as List? ?? []).map((i) => Song.fromMap(i)).toList();
        final Map<String, List<Song>> playlistSongs = {};
        final playlistJson = json['playlistSongs'] as Map<String, dynamic>? ?? {};
        playlistJson.forEach((key, value) {
          playlistSongs[key] = (value as List).map((s) => Song.fromMap(s)).toList();
        });
        state = state.copyWith(allItems: allItems, likedSongs: likedSongs, likedSongIds: likedSongIds, likedAlbums: likedAlbums, subscribedArtists: subscribedArtists, playlistSongs: playlistSongs);
        _applyFilterAndSort();
      } catch (e) { print("❌ Error loading library: $e"); }
    }
  }

  // Saves the current library state to local storage.
  Future<void> _saveToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'allItems': state.allItems.map((i) => i.toMap()).toList(),
      'likedSongs': state.likedSongs.map((s) => s.toMap()).toList(),
      'likedAlbums': state.likedAlbums.map((a) => a.toMap()).toList(),
      'subscribedArtists': state.subscribedArtists.map((s) => s.toMap()).toList(),
      'playlistSongs': state.playlistSongs.map((key, value) => MapEntry(key, value.map((s) => s.toMap()).toList())),
    };
    await prefs.setString('auvy_library_data', jsonEncode(data));
  }

  // Adds or removes a song from the "Liked Songs" collection.
  void toggleSongLike(Song song) {
    final newSongs = List<Song>.from(state.likedSongs);
    final newIds = Set<String>.from(state.likedSongIds);
    if (newIds.contains(song.id)) {
      newIds.remove(song.id);
      newSongs.removeWhere((s) => s.id == song.id);
    } else {
      newIds.add(song.id);
      newSongs.insert(0, song);
    }
    _updateSystemFolder("Liked Songs", "${newSongs.length} songs", null);
    state = state.copyWith(likedSongs: newSongs, likedSongIds: newIds);
    _saveToDisk();
  }

  // Changes the order of songs within the "Liked Songs" playlist.
  void reorderLikedSongs(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final current = List<Song>.from(state.likedSongs);
    final moved = current.removeAt(oldIndex);
    current.insert(newIndex, moved);
    state = state.copyWith(likedSongs: current);
    _saveToDisk();
  }

  // Removes a specific track from a user-created playlist.
  void removeSongFromPlaylist(String playlistTitle, String songId) {
    final currentSongs = state.playlistSongs[playlistTitle] ?? [];
    final newSongs = currentSongs.where((s) => s.id != songId).toList();
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = newSongs;
    final newAllItems = state.allItems.map((item) {
      if (item.title == playlistTitle) return LibraryItem(title: item.title, subtitle: "Playlist • ${newSongs.length} songs", image: item.image, isPinned: item.isPinned, category: item.category, dateAdded: item.dateAdded, songCount: newSongs.length, isSystemFolder: false);
      return item;
    }).toList();
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort(); _saveToDisk();
  }

  // Adds a song to an existing user-created playlist.
  void addSongToPlaylist(String playlistTitle, Song song) {
    final currentSongs = state.playlistSongs[playlistTitle] ?? [];
    if (currentSongs.any((s) => s.id == song.id)) return;
    final newSongs = [...currentSongs, song];
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = newSongs;
    final newAllItems = state.allItems.map((item) {
      if (item.title == playlistTitle) return LibraryItem(title: item.title, subtitle: "Playlist • ${newSongs.length} songs", image: item.image, isPinned: item.isPinned, category: item.category, dateAdded: item.dateAdded, songCount: newSongs.length, isSystemFolder: false);
      return item;
    }).toList();
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort(); _saveToDisk();
  }

  // Reorders tracks within a specific user playlist.
  void reorderPlaylistTracks(String playlistTitle, int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final currentSongs = List<Song>.from(state.playlistSongs[playlistTitle] ?? []);
    if (oldIndex >= currentSongs.length || newIndex >= currentSongs.length) return;
    final movedSong = currentSongs.removeAt(oldIndex);
    currentSongs.insert(newIndex, movedSong);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = currentSongs;
    state = state.copyWith(playlistSongs: newMap);
    _saveToDisk();
  }

  // Creates a new empty playlist with the specified name.
  void addPlaylist(String name) {
    if (state.allItems.any((i) => i.title == name)) return;
    final newItem = LibraryItem(title: name, subtitle: "Playlist • 0 songs", image: "assets/images/playlist_icon.png", category: LibraryCategory.playlist, dateAdded: DateTime.now());
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[name] = [];
    state = state.copyWith(allItems: [newItem, ...state.allItems], playlistSongs: newMap);
    _applyFilterAndSort(); _saveToDisk();
  }

  // Saves a playlist found via search into the user's local library.
  bool savePlaylistFromSearch(Song playlistItem, List<Song> initialTracks) {
    if (state.allItems.any((i) => i.title == playlistItem.title && i.category == LibraryCategory.playlist)) return false; 
    final newItem = LibraryItem(title: playlistItem.title, subtitle: "Playlist • ${initialTracks.length} songs", image: playlistItem.image, category: LibraryCategory.playlist, dateAdded: DateTime.now(), songCount: initialTracks.length);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistItem.title] = initialTracks;
    state = state.copyWith(allItems: [newItem, ...state.allItems], playlistSongs: newMap);
    _applyFilterAndSort(); _saveToDisk();
    return true;
  }

  // Toggles an album's presence in the user's liked collection.
  bool toggleAlbumLike(Album album, String artistName) {
    final exists = state.likedAlbums.any((a) => a.title == album.title);
    List<Album> newList;
    if (exists) newList = state.likedAlbums.where((a) => a.title != album.title).toList();
    else newList = [...state.likedAlbums, album];
    _updateSystemFolder("Liked Albums", "${newList.length} Albums", null);
    state = state.copyWith(likedAlbums: newList); _saveToDisk();
    return !exists;
  }

  // Toggles the subscription status for a specific artist.
  bool toggleArtistSubscription(String artistName, String imageUrl, String artistId) {
    final exists = state.subscribedArtists.any((a) => a.title == artistName);
    List<Song> newList;
    if (exists) newList = state.subscribedArtists.where((a) => a.title != artistName).toList();
    else newList = [...state.subscribedArtists, Song(title: artistName, artist: "Artist", image: imageUrl, id: artistId)];
    _updateSystemFolder("Your Artists", "${newList.length} Artists", null);
    state = state.copyWith(subscribedArtists: newList); _saveToDisk();
    return !exists;
  }

  // Permanently deletes a playlist from the library.
  void deleteItem(LibraryItem item) { if (item.isSystemFolder) return; state = state.copyWith(allItems: state.allItems.where((i) => i != item).toList()); _applyFilterAndSort(); _saveToDisk(); }
  
  // Toggles the pinned status of a library item for priority listing.
  void togglePin(LibraryItem item) { final updated = LibraryItem(title: item.title, subtitle: item.subtitle, image: item.image, isPinned: !item.isPinned, isCircle: item.isCircle, category: item.category, dateAdded: item.dateAdded, songCount: item.songCount, isSystemFolder: item.isSystemFolder); state = state.copyWith(allItems: state.allItems.map((i) => i == item ? updated : i).toList()); _applyFilterAndSort(); _saveToDisk(); }
  
  // Changes the active category filter for the library view.
  void setCategory(LibraryCategory category) { state = state.copyWith(selectedCategory: category); _applyFilterAndSort(); }
  
  // Switches the library display between list and grid views.
  void toggleView() { state = state.copyWith(isGrid: !state.isGrid); _saveToDisk(); }
  
  // Updates the active search query for filtering library items.
  void setSearchQuery(String query) { state = state.copyWith(searchQuery: query); _applyFilterAndSort(); }

  // Check functions for UI state (likes and subscriptions).
  bool isSongLiked(String id) => state.likedSongIds.contains(id);
  bool isSubscribed(String artistName) => state.subscribedArtists.any((a) => a.title == artistName);
  bool isAlbumLiked(String albumTitle) => state.likedAlbums.any((a) => a.title == albumTitle);

  // Internal helper to update metadata for automatic system folders like "Liked Songs".
  void _updateSystemFolder(String title, String newSubtitle, String? newImage) {
    final newAllItems = state.allItems.map((item) {
      if (item.title == title) return LibraryItem(title: item.title, subtitle: "Folder • $newSubtitle", image: newImage ?? item.image, isPinned: item.isPinned, category: item.category, dateAdded: item.dateAdded, isSystemFolder: true, isCircle: item.isCircle);
      return item;
    }).toList();
    state = state.copyWith(allItems: newAllItems); _applyFilterAndSort(); 
  }

  // Filters and sorts the library items based on the active search query and category.
  void _applyFilterAndSort() {
    List<LibraryItem> items;
    if (state.selectedCategory == LibraryCategory.all) items = state.allItems.where((i) => i.category == LibraryCategory.folder || i.category == LibraryCategory.playlist || (i.title == "Your Artists") || (i.title == "Liked Albums")).toList();
    else items = state.allItems.where((i) => i.category == state.selectedCategory).toList();
    if (state.searchQuery.isNotEmpty) items = items.where((i) => i.title.toLowerCase().contains(state.searchQuery.toLowerCase()) || i.subtitle.toLowerCase().contains(state.searchQuery.toLowerCase())).toList();
    items.sort((a, b) { if (a.isPinned && !b.isPinned) return -1; if (!a.isPinned && b.isPinned) return 1; return b.dateAdded.compareTo(a.dateAdded); });
    state = state.copyWith(filteredItems: items);
  }
}

// Provider for accessing the library state and logic.
final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>((ref) => LibraryNotifier());