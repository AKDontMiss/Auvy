import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/services/page_cache_service.dart';

/// The OFFICIAL artist picture for an artist NAME, resolved lazily.
///
/// WHY: `libraryProvider.subscribedArtists` stores whatever image was on screen
/// at the moment the artist was liked — often a track thumbnail or an album
/// cover, because that is what the row the user tapped was carrying. So "Your
/// Artists" showed a grid of pictures that don't match the artists' own pages,
/// and the same artist could appear with two different faces in two places.
///
/// `getArtistData` with a name resolves the YouTube channel and reads YouTube
/// Music's artist-channel header — the picture on the official page. Same call
/// the artist page and onboarding now use, so all three agree.
///
/// Cost discipline
/// Deliberately NOT `autoDispose`. A family provider that disposes would re-fetch
/// every time a row scrolled out and back, turning one lookup into dozens on a
/// long list. Held for the session instead: bounded by how many artists the user
/// follows, and each name costs exactly one lookup ever.
///
/// And persisted across restarts
/// Holding it for the session fixed the scroll-thrash but not the restart: every
/// launch re-looked-up every followed artist, so "Your Artists" and artist pages
/// filled in over the network while the album and track data beside them came
/// straight off disk. That mismatch is what made a page look half cached. One
/// small string per artist, on the same TTL as the rest of a page.
///
/// Returns '' rather than throwing when resolution fails, so the caller simply
/// keeps the stored image — a wrong-but-present picture beats an empty circle.
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
