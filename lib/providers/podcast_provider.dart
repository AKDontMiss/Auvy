import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/podcast_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/services/catalog_api_clients.dart';
import '../services/podcast_service.dart';

final podcastServiceProvider = Provider((ref) => PodcastService());

/// The show a podcast episode Song belongs to: from the feed URL it carries (no
/// request), or, for a Song saved before episodes carried one, the closest name
/// match from a small search.
Future<PodcastShow?> showForEpisodeSong(Song song, {PodcastService? service}) async {
  final feed = song.albumId;
  if (feed.startsWith('http')) {
    return PodcastShow(
        collectionName: song.artist, artistName: '', artworkUrl: song.image, feedUrl: feed);
  }
  final shows = await (service ?? PodcastService()).searchPodcasts(song.artist, limit: 10);
  if (shows.isEmpty) return null;
  return shows.firstWhere(
    (s) => s.collectionName.toLowerCase() == song.artist.toLowerCase(),
    orElse: () => shows.first,
  );
}
final podcastSearchQueryProvider = StateProvider<String>((ref) => ''); // Empty means "Auto-Discover"

/// Search results for the podcast search field. Empty query, no request: the
/// hub shows the listener's own shows, charts and categories instead.
///
/// (This used to build a "For You" list from five 200-result searches on every
/// visit to the page, ~800 KB, whose results were only shown while searching.)
final podcastShowsProvider = FutureProvider.autoDispose<List<PodcastShow>>((ref) async {
  final query = ref.watch(podcastSearchQueryProvider).trim();
  if (query.isEmpty) return const [];
  return ref.read(podcastServiceProvider).searchPodcasts(query);
});

final podcastEpisodesProvider = FutureProvider.family.autoDispose<List<PodcastEpisode>, PodcastShow>((ref, show) async {

  final link = ref.keepAlive();
  final timer = Timer(const Duration(hours: 24), () {
    link.close();
  });

  ref.onDispose(() => timer.cancel());

  final episodes = await ref.read(podcastServiceProvider).getEpisodes(show);
  if (episodes.isNotEmpty) return episodes;
  // Offline, or the feed is down: a followed show still has its newest episodes
  // in the library (see LibraryNotifier.podcastSnapshot). Not kept for the day
  // like a real fetch, so the next open tries the feed again.
  final snapshot = ref.read(libraryProvider).playlistSongs[show.collectionName];
  if (snapshot == null || snapshot.isEmpty) return episodes;
  link.close();
  return [
    for (final s in snapshot)
      PodcastEpisode(
        title: s.title,
        streamUrl: s.id,
        pubDate: s.releaseDate,
        podcastName: show.collectionName,
        imageUrl: s.image,
        duration: s.duration,
        feedUrl: show.feedUrl,
      )
  ];
});

/// Manages persistently pinned podcast shows for quick access at the top of the podcasts hub.
class PinnedPodcastsNotifier extends StateNotifier<List<PodcastShow>> {
  static const String _prefKey = 'auvy_pinned_podcast_shows_v1';

  PinnedPodcastsNotifier() : super(const []) {
    _ready = _load();
  }

  late final Future<void> _ready;

  /// The pinned shows once loaded. Pins are now follows: the podcast hub turns
  /// any left from an older version into followed shows and clears them.
  Future<List<PodcastShow>> loaded() async {
    await _ready;
    return state;
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
            .map((e) => PodcastShow.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // Starts empty if missing or corrupted
    }
  }

  Future<void> togglePin(PodcastShow show) async {
    final exists = state.any((s) =>
        s.feedUrl == show.feedUrl ||
        (s.collectionName.toLowerCase().trim() ==
                show.collectionName.toLowerCase().trim() &&
            s.artistName.toLowerCase().trim() ==
                show.artistName.toLowerCase().trim()));
    if (exists) {
      state = state
          .where((s) =>
              s.feedUrl != show.feedUrl &&
              !(s.collectionName.toLowerCase().trim() ==
                      show.collectionName.toLowerCase().trim() &&
                  s.artistName.toLowerCase().trim() ==
                      show.artistName.toLowerCase().trim()))
          .toList();
    } else {
      state = [show, ...state];
    }
    _persist();
  }

  bool isPinned(PodcastShow show) {
    return state.any((s) =>
        s.feedUrl == show.feedUrl ||
        (s.collectionName.toLowerCase().trim() ==
                show.collectionName.toLowerCase().trim() &&
            s.artistName.toLowerCase().trim() ==
                show.artistName.toLowerCase().trim()));
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(state.map((s) => s.toJson()).toList());
      await prefs.setString(_prefKey, encoded);
    } catch (_) {}
  }

  /// Reset all pinned podcasts in memory and remove persistent storage.
  Future<void> clear() async {
    state = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
      print('PinnedPodcastsNotifier: all pinned podcast shows cleared');
    } catch (_) {}
  }
}

/// The Apple storefront for charts: the listener's country (resolved from the
/// SIM or network, see ListeningPolicy.resolveAutoRegion), so "top" means top
/// where they are.
String podcastChartCountry() {
  final c = CatalogApiClients.contentCountry.trim().toLowerCase();
  return c.length == 2 ? c : 'us';
}

/// Apple's top podcasts in the listener's country, once per session; the US
/// chart where a country has none.
final topPodcastsProvider = FutureProvider<List<ChartShow>>((ref) async {
  final service = ref.read(podcastServiceProvider);
  final country = podcastChartCountry();
  final local = await service.getTopChart(country: country);
  if (local.isNotEmpty || country == 'us') return local;
  return service.getTopChart();
});

/// A category's chart (60 shows, in chart order: what is popular in it now),
/// kept while its page is open.
final podcastCategoryProvider =
    FutureProvider.autoDispose.family<List<PodcastShow>, String>((ref, genre) async {
  final service = ref.read(podcastServiceProvider);
  final country = podcastChartCountry();
  final local = await service.getTopByGenre(genre, country: country);
  if (local.isNotEmpty || country == 'us') return local;
  return service.getTopByGenre(genre);
});

final pinnedPodcastsProvider =
    StateNotifierProvider<PinnedPodcastsNotifier, List<PodcastShow>>(
        (ref) => PinnedPodcastsNotifier());
