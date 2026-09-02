import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/podcast_model.dart';
import '../services/podcast_service.dart';
import 'dart:math';
import 'package:auvy/providers/intelligence_provider.dart';

final podcastServiceProvider = Provider((ref) => PodcastService());
final podcastSearchQueryProvider = StateProvider<String>((ref) => ''); // Empty means "Auto-Discover"

/// The user's podcast taste, derived from what they ACTUALLY play (listening
/// history episodes carry albumTitle == 'Podcast' and artist == show name).
/// [topShows] is play-count ranked; [topGenres] is learned during the last
/// For-You fetch (iTunes primaryGenreName of the seed shows, cached in prefs
/// so the topic chips can order themselves without any network).
class PodcastTaste {
  final List<String> topShows;
  final List<String> topGenres;
  final Map<String, int> playsByShow;
  const PodcastTaste({
    this.topShows = const [],
    this.topGenres = const [],
    this.playsByShow = const {},
  });

  bool knows(String showName) =>
      playsByShow.containsKey(showName.trim().toLowerCase());
}

const String _tasteGenresKey = 'auvy_podcast_taste_genres';

Map<String, int> _podcastPlayCounts(IntelligenceState intel) {
  final counts = <String, int>{};
  for (final song in intel.listeningHistory) {
    if (song.albumTitle == 'Podcast' && song.artist.trim().isNotEmpty) {
      final key = song.artist.trim().toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  return counts;
}

final podcastTasteProvider = FutureProvider.autoDispose<PodcastTaste>((ref) async {
  final intel = ref.read(intelligenceProvider);
  final counts = _podcastPlayCounts(intel);

  // Ranked favorite shows, with ORIGINAL casing for display/chips.
  final displayNames = <String, String>{};
  for (final song in intel.listeningHistory) {
    if (song.albumTitle == 'Podcast' && song.artist.trim().isNotEmpty) {
      displayNames[song.artist.trim().toLowerCase()] = song.artist.trim();
    }
  }
  final ranked = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topShows =
      ranked.take(3).map((e) => displayNames[e.key] ?? e.key).toList();

  List<String> topGenres = const [];
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tasteGenresKey);
    if (raw != null) {
      topGenres = List<String>.from(jsonDecode(raw) as List);
    }
  } catch (_) {}

  return PodcastTaste(
      topShows: topShows, topGenres: topGenres, playsByShow: counts);
});

final podcastShowsProvider = FutureProvider.autoDispose<List<PodcastShow>>((ref) async {
  final explicitQuery = ref.watch(podcastSearchQueryProvider);
  final service = ref.read(podcastServiceProvider);

  // If the user typed a specific search (or tapped a topic chip), return that.
  if (explicitQuery.isNotEmpty) {
    return await service.searchPodcasts(explicitQuery);
  }

  // FOR YOU — taste-blended discovery.
  //
  // Old behavior searched iTunes for the NAME of the single most-played show,
  // which mostly returned that show plus lookalike titles and ignored the
  // rest of the user's history. Now: the top 3 listened shows each seed a
  // "similar by name" pool, their learned genres seed two "popular in genre"
  // pools, the pools are interleaved for variety, and shows the user already
  // plays are removed — For You is other stations you'd like, not the ones
  // you already have.
  final intel = ref.read(intelligenceProvider);
  final counts = _podcastPlayCounts(intel);

  if (counts.isEmpty) {
    // New listener: randomize a popular topic so the page feels alive.
    final defaultTopics = ['Technology', 'True Crime', 'Comedy', 'History', 'Business', 'Health', 'News', 'Music'];
    return await service.searchPodcasts(
        defaultTopics[Random().nextInt(defaultTopics.length)]);
  }

  final displayNames = <String, String>{};
  for (final song in intel.listeningHistory) {
    if (song.albumTitle == 'Podcast' && song.artist.trim().isNotEmpty) {
      displayNames[song.artist.trim().toLowerCase()] = song.artist.trim();
    }
  }
  final seeds = (counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))
      .take(3)
      .map((e) => displayNames[e.key] ?? e.key)
      .toList();

  // Seed pools in parallel (name search ≈ that show + similar stations).
  final seedPools = await Future.wait(
      seeds.map((s) => service.searchPodcasts(s).catchError((_) => <PodcastShow>[])));

  // Learn each seed's genre from its own search results (exact-name match
  // preferred), then fetch "popular in genre" pools for the top 2 genres.
  final genres = <String>[];
  for (var i = 0; i < seedPools.length; i++) {
    final pool = seedPools[i];
    if (pool.isEmpty) continue;
    final seedLower = seeds[i].trim().toLowerCase();
    final exact = pool.where(
        (s) => s.collectionName.trim().toLowerCase() == seedLower);
    final genre = (exact.isNotEmpty ? exact.first : pool.first).genre.trim();
    if (genre.isNotEmpty && !genres.contains(genre)) genres.add(genre);
  }
  final topGenres = genres.take(2).toList();

  // Cache the learned genres so podcastTasteProvider can order the topic
  // chips on the next build without any network.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tasteGenresKey, jsonEncode(topGenres));
  } catch (_) {}

  final genrePools = await Future.wait(topGenres
      .map((g) => service.searchPodcasts(g).catchError((_) => <PodcastShow>[])));

  // Round-robin interleave every pool for variety, dedupe by feed, and drop
  // stations the user already listens to.
  final pools = [...seedPools, ...genrePools];
  final seen = <String>{};
  final blended = <PodcastShow>[];
  final maxLen = pools.fold<int>(0, (m, p) => max(m, p.length));
  for (var i = 0; i < maxLen; i++) {
    for (final pool in pools) {
      if (i >= pool.length) continue;
      final show = pool[i];
      if (show.feedUrl.isEmpty || !seen.add(show.feedUrl)) continue;
      if (counts.containsKey(show.collectionName.trim().toLowerCase())) continue;
      blended.add(show);
      if (blended.length >= 30) break;
    }
    if (blended.length >= 30) break;
  }

  // Safety net: if exclusion emptied everything (tiny catalogs, offline
  // blips), fall back to the raw seed pool so the page never looks broken.
  if (blended.isEmpty) {
    return seedPools.expand((p) => p).toList();
  }
  return blended;
});

final podcastEpisodesProvider = FutureProvider.family.autoDispose<List<PodcastEpisode>, PodcastShow>((ref, show) async {

  final link = ref.keepAlive();
  final timer = Timer(const Duration(hours: 24), () {
    link.close();
  });

  ref.onDispose(() => timer.cancel());

  return await ref.read(podcastServiceProvider).getEpisodes(show);
});
