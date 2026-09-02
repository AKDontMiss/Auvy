// lib/providers/search_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/data/dummy_data.dart';

final searchServiceProvider = Provider<SearchService>((ref) => SearchService());

final activeSwipeIdProvider = StateProvider<String?>((ref) => null);
final activeOverlayIdProvider = StateProvider<String?>((ref) => null);

class SearchState {
  final List<Song> tracks;
  final List<Song> albums;
  final List<Song> artists;
  final List<Song> playlists;
  final List<String> suggestions;
  final List<String> history;
  final bool isLoading;

  /// Why the last search produced nothing, or null when it simply matched
  /// nothing.
  ///
  /// WITHOUT THIS, EVERY FAILURE LOOKED LIKE "no results". Offline, a parse
  /// error and a YouTube throttle all landed in the same `catch` and cleared
  /// isLoading, so the page showed an empty state and the user concluded the
  /// song does not exist. Flagged in the audit and left unfixed since.
  final String? error;

  SearchState({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
    this.suggestions = const [],
    this.history = const [],
    this.isLoading = false,
    this.error,
  });

  List<Song> get results => tracks;
  List<Song> get songs => tracks;
  List<String> get recentQueries => history;

  SearchState copyWith({
    List<Song>? tracks,
    List<Song>? albums,
    List<Song>? artists,
    List<Song>? playlists,
    List<String>? suggestions,
    List<String>? history,
    bool? isLoading,
    String? error,
    // `error: null` cannot clear a field through `??`, so a successful search
    // needs a way to say "no error" explicitly.
    bool clearError = false,
  }) {
    return SearchState(
      tracks: tracks ?? this.tracks,
      albums: albums ?? this.albums,
      artists: artists ?? this.artists,
      playlists: playlists ?? this.playlists,
      suggestions: suggestions ?? this.suggestions,
      history: history ?? this.history,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final SearchService _searchService;

  SearchNotifier(this._searchService) : super(SearchState()) {
    loadHistory();
  }

  Future<void> loadHistory() async {
    final historyList = await _searchService.fetchSearchHistory();
    state = state.copyWith(history: historyList);
  }

  Future<void> executeGlobalSearch(String query) async {
    if (query.trim().isEmpty) return;
    // clearError: a new search must not inherit the previous one's failure.
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final results = await Future.wait([
        _searchService.executeScopedSearch(query, scope: SearchContextScope.tracks),
        _searchService.executeScopedSearch(query, scope: SearchContextScope.albums),
        _searchService.executeScopedSearch(query, scope: SearchContextScope.artists),
        _searchService.executeScopedSearch(query, scope: SearchContextScope.playlists),
      ]);

      state = state.copyWith(
        tracks: results[0].items,
        albums: results[1].items,
        artists: results[2].items,
        playlists: results[3].items,
        isLoading: false,
      );
      await loadHistory();
    } catch (e) {
      // Name the reason. A throttle is temporary and worth retrying; being
      // offline is not the same thing; and neither is "no matches".
      final msg = e.toString();
      state = state.copyWith(
        isLoading: false,
        error: msg.contains('Throttled')
            ? 'YouTube is rate-limiting right now — try again in a moment'
            : (msg.contains('SocketException') ||
                    msg.contains('Failed host lookup') ||
                    msg.contains('TimeoutException'))
                ? "Couldn't reach YouTube — check your connection"
                : "Search failed — try again",
      );
    }
  }

  Future<void> performSearch(String query, {String? type}) async {
    await executeGlobalSearch(query);
  }

  Future<void> saveSearch(String query) async {
    await addQueryToHistory(query);
  }

  Future<void> addQueryToHistory(String query) async {
    if (query.trim().isEmpty) return;
    // Privacy: "Pause search history" stops queries being persisted. Live
    // suggestions still work — they're network results, not stored history.
    if (ListeningPolicy.searchPaused) return;
    await _searchService.addQueryToHistory(query);
    await loadHistory();
  }

  // updateSuggestions() lived here and had no callers. It wrote into
  // SearchState.suggestions, which no widget read, from an endpoint that
  // completed toward YouTube VIDEOS rather than music. Live completions now come
  // from searchSuggestionsProvider at the bottom of this file, which is debounced,
  // cached and backed by YouTube Music's own get_search_suggestions.

  Future<void> clearHistory() async {
    await _searchService.clearAllSearchHistory();
    state = state.copyWith(history: []);
  }

  Future<void> removeHistoryItem(String query) async {
    await _searchService.deleteHistoryItem(query);
    await loadHistory();
  }

  Future<void> deleteHistoryEntry(String query) async {
    await removeHistoryItem(query);
  }
}

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final service = ref.watch(searchServiceProvider);
  return SearchNotifier(service);
});

/// Debounced YouTube Music query completions for the search box.
///
/// The debounce is inside the provider, NOT the widget, on purpose.
///
/// A `family` provider keyed on the query is created per keystroke, so putting a
/// Timer in the search page would mean one timer per rebuild and a race about
/// which one wins. Here, `autoDispose` cancels the pending request the moment the
/// query changes: the delay elapses only for the text the user actually stopped
/// on, so typing "the weeknd" issues one request rather than nine.
///
/// Returns [] rather than throwing — a search box with no suggestions is a normal
/// state (short query, offline, YouTube hiccup) and must never interrupt typing.
final searchSuggestionsProvider =
    FutureProvider.family.autoDispose<List<String>, String>((ref, query) async {
  final q = query.trim();
  // Below three characters the completions are mostly noise and every keystroke
  // is a fresh query, which is the worst ratio of requests to usefulness.
  if (q.length < 3) return const [];

  // Cancelled by autoDispose when the query changes.
  await Future<void>.delayed(const Duration(milliseconds: 250));

  return ref.watch(searchServiceProvider).getSearchSuggestions(q);
});


/// Recent queries for one search surface. Scope '' is music, and the podcast and
/// radio pages pass their own so the three lists stay separate.
///
/// A plain FutureProvider rather than state on a notifier: these lists are read
/// in one place each and change only when a search is submitted, so `invalidate`
/// after a write is simpler than threading another field through SearchState —
/// and it cannot drift out of sync with the database the way a cached copy can.
final scopedSearchHistoryProvider =
    FutureProvider.family<List<String>, String>((ref, scope) async {
  return ref.watch(searchServiceProvider).fetchSearchHistory(scope: scope);
});

/// Record a query for [scope] and refresh its list.
///
/// Honours "Pause search history" exactly like the music path — a privacy switch
/// that only covered one of three search boxes would be worse than none.
Future<void> recordScopedSearch(
    WidgetRef ref, String scope, String query) async {
  if (query.trim().isEmpty) return;
  if (ListeningPolicy.searchPaused) return;
  await ref.read(searchServiceProvider).addQueryToHistory(query, scope: scope);
  ref.invalidate(scopedSearchHistoryProvider(scope));
}

/// Forget one query in [scope].
Future<void> removeScopedSearch(
    WidgetRef ref, String scope, String query) async {
  await ref.read(searchServiceProvider).deleteHistoryItem(query, scope: scope);
  ref.invalidate(scopedSearchHistoryProvider(scope));
}
