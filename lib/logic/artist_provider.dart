import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/search_service.dart';

// Provider that fetches and organizes all data related to a specific artist.
final artistProvider = FutureProvider.family<ArtistData?, Song>((ref, artistSong) async {
  final service = SearchService();
  final id = artistSong.id;

  // Fetches tracks, discography, related artists, and playlists simultaneously.
  final results = await Future.wait([
    service.getArtistTopTracks(id),      
    service.getArtistDiscography(id),    
    service.getRelatedArtists(id),       
    service.getArtistPlaylists(id),      
  ]);

  final topTracks = results[0] as List<Song>;
  final discography = results[1] as List<Album>;
  final related = results[2] as List<Song>;
  final playlists = results[3] as List<Song>;

  final albums = <Album>[];
  final singles = <Album>[];
  final live = <Album>[];

  // Categorizes discography items into albums, singles/EPs, and live recordings.
  for (var item in discography) {
    if (item.title.toLowerCase().contains('live')) {
      live.add(item);
    } 
    else if (item.recordType == 'single' || item.recordType == 'ep') {
      singles.add(item);
    } else {
      albums.add(item);
    }
  }

  // Sorts the categorized items by their release date.
  int dateSort(Album a, Album b) => b.releaseDate.compareTo(a.releaseDate);
  albums.sort(dateSort);
  singles.sort(dateSort);
  live.sort(dateSort);

  return ArtistData(
    name: artistSong.title,
    image: artistSong.image,
    topTracks: topTracks,
    albums: albums,
    singles: singles,
    relatedArtists: related,
    playlists: playlists,
    liveAlbums: live,
  );
});