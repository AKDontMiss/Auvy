import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/services/page_cache_service.dart';

/// The official artist picture for an artist name, resolved lazily.
///
/// Followed artists store whatever image was on screen when they were liked
/// (often a track or album cover). `getArtistData` with a name resolves the
/// YouTube channel and reads its header picture, the same call the artist page
/// and onboarding use, so all three agree.
///
/// Not `autoDispose`, so scrolling doesn't re-fetch; held for the session
/// (bounded by the number of followed artists) and also persisted, on the same
/// TTL as page data, so restarts don't re-look-up every artist.
///
/// Returns '' instead of throwing, so the caller keeps its stored image.
final artistImageProvider =
    FutureProvider.family<String, String>((ref, artistName) async {
  final name = artistName.trim();
  if (name.isEmpty) return '';

  final cacheService = PageCacheService();
  final key = 'artist_image:${name.toLowerCase()}';
  final cached = await cacheService.getCachedSection(key);
  if (cached is String && cached.isNotEmpty) return cached;

  try {
    final data = await ref
        .read(searchServiceProvider)
        .getArtistData('', fallbackName: name);
    // Only a real answer is stored. Caching '' would pin a failed lookup for
    // days, so a one-off network blip would leave an artist faceless until it
    // expired — the opposite of the point.
    if (data.image.isNotEmpty) await cacheService.cacheSection(key, data.image);
    return data.image;
  } catch (_) {
    return '';
  }
});
