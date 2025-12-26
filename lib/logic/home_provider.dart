import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/search_service.dart';
import 'package:auvy/logic/spotify_service.dart';

// State model for the home screen containing recommendations and feed sections.
class HomeState {
  final List<Song> quickPicks;
  final List<Song> keepListening;
  final List<HomeSection> feedSections;
  final bool isLoading;
  final bool isFetchingMore;
  final String currentMood; 
  final Set<String> seenIds;
  final Set<String> usedTopics; 
  final bool hasReachedEnd; 

  HomeState({
    this.quickPicks = const [],
    this.keepListening = const [],
    this.feedSections = const [],
    this.isLoading = true,
    this.isFetchingMore = false,
    this.hasReachedEnd = false, 
    this.currentMood = "All",
    Set<String>? seenIds,
    this.usedTopics = const {},
  }) : seenIds = seenIds ?? {};

  // Creates a copy of the state with updated values.
  HomeState copyWith({
    List<Song>? quickPicks,
    List<Song>? keepListening,
    List<HomeSection>? feedSections,
    bool? hasReachedEnd,
    bool? isLoading,
    bool? isFetchingMore,
    String? currentMood,
    Set<String>? seenIds,
    Set<String>? usedTopics,
  }) {
    return HomeState(
      quickPicks: quickPicks ?? this.quickPicks,
      keepListening: keepListening ?? this.keepListening,
      feedSections: feedSections ?? this.feedSections,
      isLoading: isLoading ?? this.isLoading,
      hasReachedEnd: hasReachedEnd ?? this.hasReachedEnd,
      isFetchingMore: isFetchingMore ?? this.isFetchingMore,
      currentMood: currentMood ?? this.currentMood,
      seenIds: seenIds ?? this.seenIds,      
      usedTopics: usedTopics ?? this.usedTopics,
    );
  }
}

// Notifier class that manages home screen content and infinite scrolling logic.
class HomeNotifier extends StateNotifier<HomeState> {
  final Ref ref;
  final SearchService _searchService = SearchService();
  final SpotifyService _spotifyService = SpotifyService();

  static const int _maxSeenIds = 200;

  // Limits the size of the tracked song ID set to maintain performance.
  Set<String> _pruneSeenIds(Set<String> ids) {
    if (ids.length <= _maxSeenIds) return ids;
    return ids.toList().sublist(ids.length - _maxSeenIds).toSet();
  }
  
  final List<String> _randomTopics = [
    "The Weeknd", "Drake", "Taylor Swift", "Rock Classics", 
    "Lo-Fi Beats", "Hip Hop Essentials", "Top Hits 2024", 
    "Pop Smoke", "Kanye West", "Ariana Grande", "Jazz Vibes",
    "Post Malone", "Kendrick Lamar", "SZA", "Metro Boomin",
    "Travis Scott", "Future", "Bad Bunny", "Doja Cat"
  ];

  HomeNotifier(this.ref) : super(HomeState()) {
    _initHome();
    
    // Updates the "Keep Listening" section whenever player history changes.
    ref.listen(playerProvider.select((p) => p.history), (prev, next) {
      if (next.isNotEmpty) {
        state = state.copyWith(keepListening: next.take(5).toList());
      }
    });
  }

  // Reloads the home screen from scratch.
  void refreshHome() {
    _initHome(); 
  }

  // Determines a search term based on the user's most listened-to artist.
  Future<String> _getPersonalizedQuery() async {
    final history = ref.read(playerProvider).history;
    if (history.isEmpty) {
      final fallbackGenres = ["Top Hits", "Modern Rock", "Hip Hop", "Pop", "Lo-Fi"];
      return fallbackGenres[Random().nextInt(fallbackGenres.length)];
    }
    final Map<String, int> artistFreq = {};
    for (var song in history) {
      artistFreq[song.artist] = (artistFreq[song.artist] ?? 0) + 1;
    }
    final sortedArtists = artistFreq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sortedArtists.first.key;
  }

  // Initial load of home screen content, including quick picks and the first sections.
  Future<void> _initHome() async {
    state = state.copyWith(isLoading: true, usedTopics: {}, feedSections: []);

    final seenIds = <String>{};
    final history = ref.read(playerProvider).history;
    
    final initialKeep = history.isNotEmpty ? history.take(12).toList() : <Song>[];
    for (var s in initialKeep) seenIds.add(s.id); 

    final personalizedQuery = await _getPersonalizedQuery();
    List<Song> picks = [];

    try {
      final results = await Future.wait([
        _searchService.search(personalizedQuery, 'track'),
        _spotifyService.fetchTopHits(),
      ]);

      final combined = [...results[0], ...results[1]];
      combined.shuffle(); 

      for (var song in combined) {
        if (picks.length >= 12) break;
        if (!seenIds.contains(song.id)) { 
          picks.add(song);
          seenIds.add(song.id);
        }
      }
    } catch (e) {
      print("❌ Error initializing home: $e");
    }

    state = state.copyWith(
      keepListening: initialKeep,
      quickPicks: picks,
      seenIds: _pruneSeenIds(seenIds), 
      isLoading: false,
      hasReachedEnd: false, 
      usedTopics: {personalizedQuery}, 
    );

    for (int i = 0; i < 2; i++) {
      await fetchNextSection();
    }
  }

  // Replaces current home content with sections based on random topics.
  Future<void> fetchRandom() async {
    state = state.copyWith(isLoading: true, feedSections: [], usedTopics: {});
    List<HomeSection> randomSections = [];
    final topics = List<String>.from(_randomTopics)..shuffle();
    final updatedSeenIds = Set<String>.from(state.seenIds);
    final updatedTopics = <String>{};
    
    for(var topic in topics.take(5)) {
       try {
         final results = await _searchService.search(topic, 'track');
         final List<Song> sectionSongs = [];
         
         for (var s in results) {
           if (!updatedSeenIds.contains(s.id)) {
             sectionSongs.add(s);
             updatedSeenIds.add(s.id);
           }
           if (sectionSongs.length >= 8) break;
         }

         if(sectionSongs.isNotEmpty) {
           randomSections.add(HomeSection(title: "Random: $topic", songs: sectionSongs));
           updatedTopics.add(topic);
         }
       } catch (_) {}
    }
    
    state = state.copyWith(
      isLoading: false,
      feedSections: randomSections,
      currentMood: "Random",
      hasReachedEnd: false, 
      seenIds: _pruneSeenIds(updatedSeenIds),       
      usedTopics: updatedTopics,
    );
  }

  // Filters and loads sections based on a selected mood category.
  Future<void> setMood(String mood) async {
    if (mood == "Random") {
      await fetchRandom();
      return;
    }

    state = state.copyWith(currentMood: mood, isLoading: true, feedSections: [], usedTopics: {});
    
    List<String> moodTopics = [];
    if (mood == "Energize") moodTopics = ["Rock", "Pop", "Workout", "Dance", "Drake", "Future"];
    else if (mood == "Relax") moodTopics = ["Lo-Fi", "Jazz", "Piano", "Acoustic", "Chill", "SZA"];
    else if (mood == "Focus") moodTopics = ["Classical", "Study", "Ambient", "Instrumental", "Hans Zimmer"];
    else moodTopics = _randomTopics; 

    try {
      List<HomeSection> newSections = [];
      final updatedSeenIds = Set<String>.from(state.seenIds);
      final updatedTopics = <String>{};

      moodTopics.shuffle();

      for (String query in moodTopics) {
        if (newSections.length >= 3) break;
        
        final results = await _searchService.search(query, 'track'); 
        final List<Song> sectionSongs = [];

        for (var s in results) {
          if (!updatedSeenIds.contains(s.id)) {
            sectionSongs.add(s);
            updatedSeenIds.add(s.id);
          }
          if (sectionSongs.length >= 8) break;
        }

        if (sectionSongs.isNotEmpty) {
           newSections.add(HomeSection(title: "Best of $query", songs: sectionSongs));
           updatedTopics.add(query);
        }
      }

      state = state.copyWith(
        isLoading: false, 
        feedSections: newSections,
        hasReachedEnd: false, 
        seenIds: updatedSeenIds,
        usedTopics: updatedTopics,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }

  // Appends a new recommendation section to the home feed for infinite scrolling.
  Future<void> fetchNextSection() async {
    if (state.isFetchingMore || state.hasReachedEnd) return;
    
    if (state.feedSections.length >= 50) {
      state = state.copyWith(hasReachedEnd: true);
      return;
    }

    state = state.copyWith(isFetchingMore: true);

    List<String> availableTopics = _randomTopics.where((t) => !state.usedTopics.contains(t)).toList();
    String? query;

    if (availableTopics.isNotEmpty) {
      query = availableTopics[Random().nextInt(availableTopics.length)];
    } else {
      final history = ref.read(playerProvider).history;
      if (history.isNotEmpty) {
        final seedArtist = history[Random().nextInt(history.length)];
        final related = await _searchService.search(seedArtist.artist, 'artist');
        
        for (var artist in related) {
          if (!state.usedTopics.contains(artist.title)) {
            query = artist.title;
            break;
          }
        }
      }
    }
    
    if (query == null) {
      state = state.copyWith(isFetchingMore: false, hasReachedEnd: true);
      return;
    }
    
    try {
        final results = await _searchService.search(query, 'track');
        final List<Song> uniqueTracks = [];
        final updatedSeenIds = Set<String>.from(state.seenIds);

        for (var s in results) {
          if (!updatedSeenIds.contains(s.id)) {
            uniqueTracks.add(s);
            updatedSeenIds.add(s.id);
          }
          if (uniqueTracks.length >= 8) break;
        }

        if (uniqueTracks.isNotEmpty) {
          final newSection = HomeSection(title: "More from $query", songs: uniqueTracks);
          state = state.copyWith(
            feedSections: [...state.feedSections, newSection],
            seenIds: _pruneSeenIds(updatedSeenIds), 
            usedTopics: {...state.usedTopics, query},
            isFetchingMore: false
          );
        } else {
           state = state.copyWith(isFetchingMore: false, usedTopics: {...state.usedTopics, query});
           await fetchNextSection(); 
        }
    } catch (_) {
        state = state.copyWith(isFetchingMore: false);
    }
  }
}

// Global provider for the home content notifier.
final homeProvider = StateNotifierProvider<HomeNotifier, HomeState>((ref) {
  return HomeNotifier(ref);
});