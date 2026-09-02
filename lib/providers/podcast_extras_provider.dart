import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/podcast_service.dart';
import 'package:auvy/services/podcast_extras_service.dart';

/// Resolves the RSS episode behind the currently playing podcast Song. The
/// Song only carries the show's display name (artist) and the enclosure URL
/// (id), so the show is re-resolved through the same iTunes search the hub
/// uses, then the episode is matched inside its feed.
final currentPodcastEpisodeProvider =
    FutureProvider.autoDispose<PodcastEpisode?>((ref) async {
  final song = ref.watch(playerProvider.select((s) => s.currentSong));
  if (song == null || song.albumTitle != 'Podcast') return null;

  final service = PodcastService();
  final shows = await service.searchPodcasts(song.artist);
  if (shows.isEmpty) return null;
  final show = shows.firstWhere(
    (s) => s.collectionName.toLowerCase() == song.artist.toLowerCase(),
    orElse: () => shows.first,
  );

  final episodes = await service.getEpisodes(show);
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
