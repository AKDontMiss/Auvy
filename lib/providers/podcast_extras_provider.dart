import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/podcast_provider.dart';
import 'package:auvy/services/podcast_extras_service.dart';

/// Resolves the RSS episode behind the currently playing podcast Song: its show
/// from the feed URL the Song carries (see showForEpisodeSong), and the episode
/// inside that feed. The feed comes from podcastEpisodesProvider, so an episode
/// started from its show page costs no request at all.
final currentPodcastEpisodeProvider =
    FutureProvider.autoDispose<PodcastEpisode?>((ref) async {
  final song = ref.watch(playerProvider.select((s) => s.currentSong));
  if (song == null || song.albumTitle != 'Podcast') return null;

  final show = await showForEpisodeSong(song);
  if (show == null) return null;
  final episodes = await ref.read(podcastEpisodesProvider(show).future);
  for (final ep in episodes) {
    if (ep.streamUrl == song.id) return ep;
  }
  // Enclosure URLs can carry per-fetch tracking prefixes — fall back to title.
  final titleLower = song.title.toLowerCase().trim();
  for (final ep in episodes) {
    if (ep.title.toLowerCase().trim() == titleLower) return ep;
  }
  return null;
});

/// Chapters for the playing episode — `[]` when the feed offers nothing to
/// mine (no chapter JSON, no timestamped show notes).
final podcastChaptersProvider =
    FutureProvider.autoDispose<List<PodcastChapter>>((ref) async {
  final ep = await ref.watch(currentPodcastEpisodeProvider.future);
  if (ep == null) return const [];
  return PodcastExtrasService().getChapters(ep);
});
