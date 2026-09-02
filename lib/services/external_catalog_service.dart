import 'package:spotify/spotify.dart' as sp;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';

/// A client for Spotify's Web API.
///
/// WHAT IT IS FOR, in practice: importing a Spotify playlist into Auvy. The
/// user pastes a playlist link, and getPlaylistTracks turns its id into a list
/// of tracks that Auvy then matches against YouTube Music.
///
/// Only two places in the app construct this:
///
///   playlist_page.dart    getPlaylistTracks() for the import flow
///   library_provider.dart getTrackDetails() as a last-resort metadata lookup
///
/// The other nine public methods here have no caller. They are left in place
/// because they are a thin wrapper over the Spotify SDK and cost nothing to
/// keep, but do not assume they work or are exercised.
///
/// IT IS INERT IN A PUBLIC BUILD, AND THAT IS DELIBERATE. Spotify requires a
/// client id and secret, and Auvy ships neither: the secret was removed rather
/// than baked into the APK. Without both keys, _configured stays false and
/// every method returns an empty result instead of throwing. A fork that wants
/// Spotify import supplies its own keys through .env or --dart-define.
///
/// ARTIST METADATA IS NOT HERE ANY MORE. Similar artists, bios and top tracks
/// moved to ArtistMetadataService, which uses Last.fm through the Worker.
/// Spotify's equivalents need a user OAuth token rather than these app-level
/// credentials, so they could never work from a client like this one.
class ExternalCatalogService {
  late final sp.SpotifyApiCredentials _credentials;
  late final sp.SpotifyApi _spotify;

 ExternalCatalogService() {
    String clientId = '';
    String clientSecret = '';

    // 1. Safely pull from dotenv ONLY if it was successfully initialized
    try {
      if (dotenv.isInitialized) {
        clientId = dotenv.env['SPOTIFY_CLIENT_ID'] ?? '';
        clientSecret = dotenv.env['SPOTIFY_CLIENT_SECRET'] ?? '';
      }
    } catch (e) {
      print("WARN: Dotenv access error: $e");
    }

    // 2. Fallback to compile-time injected variables (--dart-define)
    if (clientId.isEmpty) {
      clientId = const String.fromEnvironment('SPOTIFY_CLIENT_ID', defaultValue: '');
    }
    if (clientSecret.isEmpty) {
      clientSecret = const String.fromEnvironment('SPOTIFY_CLIENT_SECRET', defaultValue: '');
    }

    // 3. Strip quotes and surrounding whitespace.
    //
    // Both sources above hand back raw text, and a key is easy to paste or
    // declare WITH its quotes still attached — SPOTIFY_CLIENT_ID="abc123" in a
    // .env file, or a --dart-define whose value the shell did not unwrap. The
    // quotes then travel into the Authorization header and Spotify rejects the
    // credentials, which looks like a wrong key rather than a quoting mistake.
    clientId = clientId.replaceAll('"', '').replaceAll("'", "").trim();
    clientSecret = clientSecret.replaceAll('"', '').replaceAll("'", "").trim();

    // Don't log anything about the credentials (not even lengths) — avoid
    // leaking secret metadata to logcat. Just note if import will be unavailable.
    _configured = clientId.isNotEmpty && clientSecret.isNotEmpty;
    if (!_configured) {
      print("Spotify keys not configured — this client is inert.");
    }

    _credentials = sp.SpotifyApiCredentials(clientId, clientSecret);
    _spotify = sp.SpotifyApi(_credentials);
  }

  /// False when no credentials were supplied, which is the NORMAL case in a
  /// release build.
  ///
  /// Keys come from `.env`, and `.env` is deliberately not bundled (see
  /// BUILD.md). Nothing supplies Spotify defines either, so in every shipped
  /// build this client has empty credentials. Every call it makes therefore
  /// fails authentication, and the failure is swallowed into an empty list.
  ///
  /// That is the same waste the Last.fm client had: spending a network round
  /// trip to learn something already known before the request was formed. The
  /// guards below return the empty answer immediately instead.
  ///
  /// The app does not need this client — Spotify links import through the
  /// keyless path (the anonymous web-player token), and this is only its
  /// fallback.
  bool _configured = false;

  String _cleanId(String input) {
    if (input.contains('spotify:')) {
      return input.split(':').last;
    }
    if (input.contains('/')) {
      final parts = input.split('/');
      final lastPart = parts.last;
      return lastPart.split('?').first.trim();
    }
    return input.trim();
  }

  // Generic search
  Future<List<Song>> search(String query, String type, {int limit = 50}) async {
    if (!_configured) return [];
    try {
      List<sp.SearchType> searchTypes = [];
      if (type == 'track') searchTypes = [sp.SearchType.track];
      else if (type == 'artist') searchTypes = [sp.SearchType.artist];
      else if (type == 'album') searchTypes = [sp.SearchType.album];
      else if (type == 'playlist') searchTypes = [sp.SearchType.playlist];
      
      final pages = await _spotify.search
          .get(query, types: searchTypes)
          .first(limit) 
          .timeout(const Duration(seconds: 4));
        
      List<Song> results = [];
      int index = 0;

      for (var page in pages) {
        if (page.items == null) continue;
        for (var item in page.items!) {
          index++;
          int syntheticPop = (100 - index).clamp(0, 100);

          if (item is sp.Track) {
            results.add(Song(
              id: 'track_${item.id}',
              title: item.name!,
              artist: item.artists?.first.name ?? 'Unknown',
              image: item.album?.images?.isNotEmpty == true 
                  ? item.album!.images!.first.url! 
                  : '',
              albumId: item.album?.id ?? '',
              albumTitle: item.album?.name ?? '',
              releaseDate: item.album?.releaseDate ?? '', //  ADDED
              popularity: item.popularity ?? syntheticPop,
              isExplicit: item.explicit,
            ));
          } else if (item is sp.TrackSimple) {
            results.add(Song(
              id: 'track_${item.id}',
              title: item.name!,
              artist: item.artists?.first.name ?? 'Unknown',
              image: '',
              albumId: '',
              albumTitle: '',
              popularity: syntheticPop,
              isExplicit: item.explicit, // <--- NEW
            ));
          } else if (item is sp.Artist) {
            results.add(Song(
              id: 'artist_${item.id}',
              title: item.name!,
              artist: 'Artist',
              image: item.images?.isNotEmpty == true 
                  ? item.images!.first.url! 
                  : '',
              popularity: item.popularity ?? syntheticPop,
            ));
          } else if (item is sp.AlbumSimple) {
            results.add(Song(
              id: 'album_${item.id}',
              title: item.name!,
              artist: item.artists?.first.name ?? 'Unknown',
              image: item.images?.isNotEmpty == true 
                  ? item.images!.first.url! 
                  : '',
              albumId: item.id!,
              albumTitle: item.name!,
              popularity: syntheticPop,
            ));
          } else if (item is sp.PlaylistSimple) {
            results.add(Song(
              id: 'playlist_${item.id}',
              title: item.name!,
              artist: item.owner?.displayName ?? 'Playlist', 
              image: item.images?.isNotEmpty == true 
                  ? item.images!.first.url! 
                  : '',
              popularity: syntheticPop,
            ));
          }
        }
      }
      return results;
    } catch (e) {
      if (e.toString().contains("googleusercontent.com")) {
        print("Spotify Proxy/DNS issue detected. Switching to fallback...");
      } else {
        print("WARN: Spotify Search Error ($type): $e");
      }
      return [];
    }
  }


  Future<Song?> getArtist(String artistId) async {
    if (!_configured) return null;
    try {
      final cleanId = _cleanId(artistId);
      final artist = await _spotify.artists.get(cleanId);
      return Song(
        id: 'artist_${artist.id}',
        title: artist.name!,
        artist: 'Artist',
        image: artist.images?.isNotEmpty == true ? artist.images!.first.url! : '',
        popularity: artist.popularity ?? 0
      );
    } catch (e) {
      return null;
    }
  }

  Future<List<Song>> getArtistTopTracks(String artistId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(artistId);
      final tracks = await _spotify.artists
          .getTopTracks(cleanId, 'US')
          .timeout(const Duration(seconds: 5));
      
      int index = 0;
      return tracks.map((t) {
        index++;
        int pop = (100 - index).clamp(0, 100);
        if (t.popularity != null) pop = t.popularity!;

        return Song(
          id: 'track_${t.id}',
          title: t.name!,
          artist: t.artists?.first.name ?? 'Unknown',
          image: t.album?.images?.isNotEmpty == true 
              ? t.album!.images!.first.url! 
              : '',
          albumId: t.album?.id ?? '',
          albumTitle: t.album?.name ?? '',
          releaseDate: t.album?.releaseDate ?? '', //  ADDED
          popularity: pop,
          isExplicit: t.explicit,
        );
      }).toList();
    } catch (e) {
      print("WARN: Spotify Top Tracks Error: $e");
      return [];
    }
  }

  // UPDATE: getAlbumTracks - add explicit field
  Future<List<Song>> getAlbumTracks(String albumId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(albumId);
      final album = await _spotify.albums.get(cleanId);
      //  FIX: Use .first(100) instead of .all() to prevent infinite pagination loops
      // .all(), not .first(100). A compilation or box set runs past 100 tracks
      // and importing 100 of 140 looks like it worked. The timeout is the real
      // guard against a runaway page walk — bounded by the clock, not by
      // silently dropping content.
      final tracks = await _spotify.albums.getTracks(cleanId).all().timeout(const Duration(seconds: 25));
      final String art = album.images?.isNotEmpty == true ? album.images!.first.url! : '';
      return tracks.map((t) => Song(
        id: 'track_${t.id}',
        title: t.name!,
        artist: t.artists?.first.name ?? 'Unknown',
        image: art,
        albumId: cleanId,
        albumTitle: album.name ?? '',
        releaseDate: album.releaseDate ?? '', 
        popularity: 0,
        isExplicit: t.explicit, // <--- NEW
      )).toList();
    } catch (e) {
      return [];
    }
  }

  Future<List<Song>> getPlaylistTracks(String playlistId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(playlistId);
      // .all(): playlists routinely run to hundreds of tracks, and this was one
      // of TWO places the same import was silently cut to 100.
      final tracks = await _spotify.playlists.getTracksByPlaylistId(cleanId).all().timeout(const Duration(seconds: 25));
      return tracks.map((t) => Song(
        id: 'track_${t.id}',
        title: t.name!,
        artist: t.artists?.first.name ?? 'Unknown',
        image: t.album?.images?.isNotEmpty == true ? t.album!.images!.first.url! : '',
        albumId: t.album?.id ?? '',
        albumTitle: t.album?.name ?? '',
        releaseDate: t.album?.releaseDate ?? '',
        popularity: t.popularity ?? 0,
        isExplicit: t.explicit, 
      )).toList();
    } catch (e) {
      // Print the actual error to the terminal
      print("ALERT: SPOTIFY API ERROR (Playlist): $e");
      return [];
    }
  }

  // Get albums/singles the artist released
  Future<List<Album>> getArtistDiscography(String artistId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(artistId);
      // OPTIMIZATION: Add timeout and limit
      final albums = await _spotify.artists
          .albums(cleanId, includeGroups: ['album', 'single'])
          .all()
          .timeout(const Duration(seconds: 6));
      
      final seen = <String>{};
      final uniqueAlbums = <Album>[];

      // OPTIMIZATION: Limit to 30 albums max
      // No take(30). .all() above has ALREADY paged through the whole
      // discography — the network cost was paid in full and then 30 were kept,
      // so the cap saved nothing and just truncated prolific artists.
      for (var a in albums) {
        if (seen.contains(a.name)) continue;
        seen.add(a.name!);
        uniqueAlbums.add(Album(
          id: a.id!,
          title: a.name!,
          image: a.images?.isNotEmpty == true 
              ? a.images!.first.url! 
              : '',
          releaseDate: a.releaseDate ?? '',
          recordType: a.albumType?.toString().split('.').last ?? 'album'
        ));
      }
      return uniqueAlbums;
    } catch (e) {
      print("WARN: Spotify Discography Error: $e");
      return [];
    }
  }

  // Get albums where the artist is featured ("appears_on")
  Future<List<Album>> getArtistAppearsOn(String artistId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(artistId);
      final albums = await _spotify.artists.albums(cleanId, includeGroups: ['appears_on']).all();
      
      final seen = <String>{};
      final uniqueAlbums = <Album>[];

      for (var a in albums) {
        if (seen.contains(a.name)) continue;
        seen.add(a.name!);
        uniqueAlbums.add(Album(
          id: a.id!,
          title: a.name!,
          image: a.images?.isNotEmpty == true ? a.images!.first.url! : '',
          releaseDate: a.releaseDate ?? '',
          recordType: 'featured'
        ));
      }
      return uniqueAlbums;
    } catch (e) {
      print("WARN: Spotify Appears On Error: $e");
      return [];
    }
  }

  Future<List<Song>> getRelatedArtists(String artistId) async {
    if (!_configured) return [];
    try {
      final cleanId = _cleanId(artistId);
      final artists = await _spotify.artists.getRelatedArtists(cleanId);
      return artists.map((a) => Song(
        id: 'artist_${a.id}',
        title: a.name!,
        artist: 'Artist',
        image: a.images?.isNotEmpty == true ? a.images!.first.url! : '',
        popularity: a.popularity ?? 0
      )).toList();
    } catch (e) {
      print("WARN: Spotify Related Artists Error: $e");
      return [];
    }
  }

  Future<Map<String, dynamic>?> getTrackDetails(String trackId) async {
    if (!_configured) return null;
    try {
      final cleanId = _cleanId(trackId);
      final t = await _spotify.tracks.get(cleanId);
      return {
        'id': t.id,
        'title': t.name,
        'release_date': t.album?.releaseDate,
        'album': {
          'id': t.album?.id,
          'title': t.album?.name,
          'cover_medium': t.album?.images?.isNotEmpty == true ? t.album!.images!.first.url : ''
        }
      };
    } catch (e) {
      return null;
    }
  }

  Future<List<Song>> fetchTopHits() async {
    if (!_configured) return [];
    return getArtistTopTracks('1Xyo4u8uXC1ZmMpatF05PJ');
  }
}