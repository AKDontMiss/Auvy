import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/radio_station_model.dart';
import '../data/dummy_data.dart' show Song;
import '../services/radio_service.dart';

final radioServiceProvider = Provider((ref) => RadioService());

final radioSearchQueryProvider = StateProvider<String>((ref) => '');

/// The country directory: every country radio-browser knows, with its real
/// station count, from the country index (a few KB). Each country's stations are
/// fetched when its section opens.
final radioCountriesProvider = FutureProvider<List<RadioCountry>>((ref) async {
  return ref.read(radioServiceProvider).getCountries();
});

/// Stations for ONE country, fetched on demand and cached for the session.
///
/// `keepAlive` deliberately: collapsing a section and reopening it should not
/// re-hit the network, and the payload is small.
final radioByCountryProvider =
    FutureProvider.family<List<RadioStation>, String>((ref, country) async {
  return ref.read(radioServiceProvider).getByCountry(country, limit: 150);
});

/// The global chart for the hub: the stations most listened in the last 24
/// hours, worldwide. Once per session.
final radioTrendingProvider = FutureProvider<List<RadioStation>>((ref) async {
  return ref.read(radioServiceProvider).getTrendingStations(limit: 40);
});

/// What is popular now in a country, by ISO code (the listener's, on the hub).
final radioHotInCountryProvider =
    FutureProvider.family<List<RadioStation>, String>((ref, code) async {
  return ref.read(radioServiceProvider).getHotInCountryCode(code);
});

/// What is popular now in one genre, kept while its page is open.
final radioByTagProvider =
    FutureProvider.autoDispose.family<List<RadioStation>, String>((ref, tag) async {
  return ref.read(radioServiceProvider).getHotByTag(tag);
});

/// Server-side search, only when there is a query (an empty one would pull the
/// whole database). The page debounces typing, so a word is one search, not one
/// per letter (each is two requests of up to 300 stations).
final radioSearchResultsProvider =
    FutureProvider<List<RadioStation>>((ref) async {
  final q = ref.watch(radioSearchQueryProvider).trim();
  if (q.length < 2) return const [];
  return ref.read(radioServiceProvider).searchStations(query: q, limit: 150);
});

/// Manages persistently pinned radio stations for instant access at the top of the radio hub.
class PinnedRadioStationsNotifier extends StateNotifier<List<RadioStation>> {
  static const String _prefKey = 'auvy_pinned_radio_stations_v1';

  PinnedRadioStationsNotifier() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(raw);
        // Started unawaited by the constructor, so the notifier may be disposed by now
        // (a rebuild on sign-in or restore); writing state would throw.
        if (!mounted) return;
        state = decoded
            .map((e) => RadioStation.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      // Ignored if corrupt, starts empty
    }
  }

  Future<void> togglePin(RadioStation station) async {
    final exists = state.any((s) =>
        s.id == station.id ||
        (s.urlResolved.isNotEmpty && s.urlResolved == station.urlResolved));
    if (exists) {
      state = state
          .where((s) =>
              s.id != station.id &&
              (s.urlResolved.isEmpty || s.urlResolved != station.urlResolved))
          .toList();
    } else {
      state = [station, ...state];
    }
    _persist();
  }

  bool isPinned(RadioStation station) {
    return state.any((s) =>
        s.id == station.id ||
        (s.urlResolved.isNotEmpty && s.urlResolved == station.urlResolved));
  }

  Future<void> togglePinFromSong(Song song) async {
    final station = RadioStation(
      id: song.id,
      name: song.title,
      urlResolved: song.id,
      favicon: song.image,
      country: song.artist.replaceFirst('Live Radio • ', '').trim(),
      tags: song.albumTitle,
      votes: 0,
    );
    await togglePin(station);
  }

  bool isSongPinned(Song song) {
    return state.any((s) =>
        s.id == song.id ||
        (s.urlResolved.isNotEmpty && s.urlResolved == song.id));
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(state.map((s) => s.toJson()).toList());
      await prefs.setString(_prefKey, encoded);
    } catch (_) {}
  }

  /// Reset all pinned radio stations in memory and remove persistent storage.
  Future<void> clear() async {
    state = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
      print('PinnedRadioStationsNotifier: all pinned radio stations cleared');
    } catch (_) {}
  }
}

final pinnedRadioStationsProvider =
    StateNotifierProvider<PinnedRadioStationsNotifier, List<RadioStation>>(
        (ref) => PinnedRadioStationsNotifier());
