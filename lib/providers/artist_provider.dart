import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/page_cache_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';

/// Family key with VALUE equality (records compare structurally). Keying the
/// family on a raw Song broke page caching twice over: Song compares by
/// identity, so every visit to an artist page minted a fresh family entry —
/// the previous fetch was never reused (spinner on every revisit), and since
/// non-autoDispose family entries live for the app's lifetime, each visit
/// leaked its entry permanently.
typedef ArtistPageKey = ({String id, String title, String artist, String image});

extension ArtistPageKeyX on Song {
  ArtistPageKey get artistPageKey =>
      (id: id, title: title, artist: artist, image: image);
}

// Provider that fetches and organizes all data related to a specific artist.
final artistProvider = FutureProvider.family<ArtistData?, ArtistPageKey>((ref, artistSong) async {
  final service = ref.read(searchServiceProvider);
  final cacheService = PageCacheService();
  
  // Identify the best name to use for fallbacks
  final String artistName = (artistSong.artist == 'Artist' || artistSong.artist == 'Unknown') 
      ? artistSong.title 
      : artistSong.artist;

  String idToUse = artistSong.id;

  // Offline: skip straight to cache (stale allowed) — a network resolve/fetch
  // can only fail, and failing wipes the page into an error state.
  final offline = ref.read(connectivityProvider).isOffline;

  // Resolve plain-text / legacy ids to a real YouTube Music channel id (UC…).
  // A UC id is already resolvable, so skip the extra search in that case.
  if (!idToUse.startsWith('UC') && !offline) {
    print("Resolving artist name to channel id: $artistName");
    final searchResults = await service.search(artistName, 'artist');
    if (searchResults.isNotEmpty) {
      idToUse = searchResults.first.id;
      print("OK: Resolved $artistName to ID: $idToUse");
    } else {
      print("WARN: Could not resolve $artistName to a valid ID. Data may be incomplete.");
    }
  }

  //  CACHE: Try loading from cache first
  final cachedData = await cacheService.getCachedArtistData(idToUse, allowStale: offline);
  if (cachedData != null) {
    final cacheAge =
        await cacheService.getCacheAge(PageCacheService.artistCacheKey(idToUse));
    print(" Using cached artist data for $idToUse (${cacheAge?.inDays ?? 0} days old)");
    return cachedData;
  }

  print("Fetching fresh artist data for $idToUse");

  final ArtistData artistData;
  try {
    // One browse request, split into discography sections (albums, singles & EPs,
    // live, featured on, playlists, fans-might-also-like) by SearchService.
    artistData = await service.getArtistData(
      idToUse,
      fallbackName: artistName,
      // NOT artistSong.image. That is the TRACK's artwork, and handing it
      // over as an artist portrait is how a soundtrack single put a film poster
      // on the artist page (reported live for Jennifer Lopez). An empty string
      // lets the page fall through to the Wikipedia portrait, and failing that
      // to a placeholder — both of which are honest, while a film poster is
      // confidently wrong.
      fallbackImage: '',
    );
  } catch (e) {
    // Fetch failed (offline / flaky network): serve anything we have, however
    // old, before surfacing the error page.
    final stale = await cacheService.getCachedArtistData(idToUse, allowStale: true);
    if (stale != null) {
      print("Artist fetch failed, serving stale cache for $idToUse");
      return stale;
    }
    rethrow;
  }

  int dateSort(Album a, Album b) => b.releaseDate.compareTo(a.releaseDate);
  artistData.albums.sort(dateSort);
  artistData.singles.sort(dateSort);
  artistData.liveAlbums.sort(dateSort);

  //  CACHE: Save the fresh data
  await cacheService.cacheArtistData(idToUse, artistData);

  return artistData;
});