import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/search_service.dart';

// State provider for tracking the ID of a song with an active UI overlay.
final activeOverlayIdProvider = StateProvider<String?>((ref) => null);

// State provider for tracking the ID of an item currently being swiped.
final activeSwipeIdProvider = StateProvider<String?>((ref) => null);

// Categories available for filtering search results.
enum SearchFilter { all, songs, artists, albums, playlists }

// State providers for current search input and filter.
final searchQueryProvider = StateProvider<String>((ref) => '');
final searchFilterProvider = StateProvider<SearchFilter>((ref) => SearchFilter.all);

// Provider that performs the search operation and combines results across categories.
final searchResultsProvider = FutureProvider<List<Song>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final filter = ref.watch(searchFilterProvider);
  final service = SearchService();

  if (query.isEmpty) return [];

  // Aggregates top results from multiple categories when 'All' is selected.
  if (filter == SearchFilter.all) {
    final results = await Future.wait([
      service.search(query, 'track'),
      service.search(query, 'artist'),
      service.search(query, 'album'),
      service.search(query, 'playlist'),
    ]);

    return [
      ...results[1].take(3), 
      ...results[0].take(10), 
      ...results[2].take(5), 
      ...results[3].take(5), 
    ];
  }

  String type = 'track';
  if (filter == SearchFilter.artists) type = 'artist';
  else if (filter == SearchFilter.albums) type = 'album';
  else if (filter == SearchFilter.playlists) type = 'playlist';

  return await service.search(query, type);
});

// Provider for managing the list of recent search terms.
final recentSearchesProvider = StateNotifierProvider<RecentSearchesNotifier, List<String>>((ref) {
  return RecentSearchesNotifier();
});

// Notifier for adding and removing terms from search history.
class RecentSearchesNotifier extends StateNotifier<List<String>> {
  RecentSearchesNotifier() : super([]);
  void add(String query) {
    if (query.isEmpty) return;
    state = [query, ...state.where((q) => q != query)].take(10).toList();
  }
  void remove(String query) => state = state.where((q) => q != query).toList();
}