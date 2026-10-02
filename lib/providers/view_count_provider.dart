import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/core/utils/track_row_meta.dart';
import 'package:auvy/services/catalog_api_client.dart';

/// The play count for one track, for the subtitle on a track row. Fetched per
/// track because album and playlist rows don't include counts. See
/// [CatalogApiClient.fetchViewCount] for the cost controls: one request per track
/// ever, cached to disk, at most three at a time, free for tracks already
/// resolved for playback. `autoDispose` + `family`, so rows that scroll away hold
/// nothing; null just means no subtitle.
final trackViewCountProvider =
    FutureProvider.family.autoDispose<int?, String>((ref, videoId) async {
  // A local file, a podcast or a radio stream has no YouTube id and no count.
  if (videoId.isEmpty ||
      videoId.length != 11 ||
      videoId.startsWith('local_') ||
      videoId.startsWith('http')) {
    return null;
  }
  final cached = CatalogApiClient.cachedViewCount(videoId);
  if (cached != null) return cached;
  return CatalogApiClient().fetchViewCount(videoId);
});

/// The formatted play count for a row, or null when nothing is known yet.
///
/// Prefers the text YouTube already put in the row, then whatever the lookup has
/// found. Watching the provider is what makes the row repaint when a fetch lands.
String? watchTrackViews(WidgetRef ref, String videoId, String rowViewCount) {
  final fromRow = rowViewCount.trim();
  if (fromRow.isNotEmpty) return fromRow;
  final async = ref.watch(trackViewCountProvider(videoId));
  final count = async.valueOrNull;
  return count == null ? null : formatPlayCount(count);
}
