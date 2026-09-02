import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/radio_station_model.dart';
import '../services/radio_service.dart';

final radioServiceProvider = Provider((ref) => RadioService());

final radioSearchQueryProvider = StateProvider<String>((ref) => '');
final radioCountryFilterProvider = StateProvider<String>((ref) => '');
// Genre chip filter (matches the station's tag list). Empty = all genres.
final radioGenreFilterProvider = StateProvider<String>((ref) => '');

/// The directory
///
/// Every country radio-browser knows, with its true station count.
///
/// This replaces deriving the country list from the global top-clicked
/// stations. That list is the 3000 most-clicked stations ON EARTH, so large
/// markets filled it and a smaller country showed one or two entries — the ones
/// that happened to chart globally — or none at all, while the database held
/// dozens. Countries now come from the country index and their stations are
/// fetched when the section is opened.
///
/// Cheap: a few KB, versus 3000 station records the user mostly never scrolls.
final radioCountriesProvider = FutureProvider<List<RadioCountry>>((ref) async {
  return ref.read(radioServiceProvider).getCountries();
});

/// Stations for ONE country, fetched on demand and cached for the session.
///
/// `keepAlive` deliberately: collapsing a section and reopening it should not
/// re-hit the network, and the payload is small.
final radioByCountryProvider =
    FutureProvider.family<List<RadioStation>, String>((ref, country) async {
  return ref.read(radioServiceProvider).getByCountry(country);
});

/// The global chart, for the "Popular worldwide" section at the top of the hub.
/// A genuinely different question from "what is on in Sweden", so it stays.
final radioTrendingProvider = FutureProvider<List<RadioStation>>((ref) async {
  return ref.read(radioServiceProvider).getTrendingStations(limit: 300);
});

/// Server-side search. Runs only when there IS a query — an empty query would
/// otherwise pull the whole database down to filter it on the phone.
///
/// Searching now hits the API rather than filtering the local top-3000. That
/// is the difference between "find a station in the popular list" and "find a
/// station", which is what a search box implies.
final radioSearchResultsProvider =
    FutureProvider<List<RadioStation>>((ref) async {
  final q = ref.watch(radioSearchQueryProvider).trim();
  final genre = ref.watch(radioGenreFilterProvider).trim();
  if (q.isEmpty && genre.isEmpty) return const [];
  return ref
      .read(radioServiceProvider)
      .searchStations(query: q.isNotEmpty ? q : genre);
});

// Legacy, still used by the player's "related stations" lookups
final baseRadioStationsProvider = FutureProvider<List<RadioStation>>((ref) async {
  return ref.read(radioServiceProvider).getTrendingStations(limit: 300);
});

final filteredRadioStationsProvider =
    Provider<AsyncValue<List<RadioStation>>>((ref) {
  final baseStations = ref.watch(baseRadioStationsProvider);
  final query = ref.watch(radioSearchQueryProvider).toLowerCase().trim();
  final country = ref.watch(radioCountryFilterProvider).toLowerCase().trim();
  final genre = ref.watch(radioGenreFilterProvider).toLowerCase().trim();

  return baseStations.whenData((stations) {
    return stations.where((station) {
      final name = station.name.toLowerCase();
      final tags = station.tags.toLowerCase();
      final matchesQuery =
          query.isEmpty || name.contains(query) || tags.contains(query);
      final matchesCountry =
          country.isEmpty || station.country.toLowerCase().contains(country);
      final matchesGenre = genre.isEmpty || tags.contains(genre);
      return matchesQuery && matchesCountry && matchesGenre;
    }).toList();
  });
});
