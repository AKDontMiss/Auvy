/// Splits the library into independently synced parts for cloud backup, and
/// joins them back on restore.
///
/// With one big blob, liking a song re-uploaded every playlist, and one damaged
/// upload could make the whole library unreadable. Split by meaning (likes,
/// followed artists, each playlist), an unchanged part is never re-sent and a
/// damaged part costs only itself.
library;

import 'dart:convert';

/// Prefix for library part keys; cannot collide with a normal preference key.
const String kLibraryPartPrefix = 'auvy_lib::';

/// The per-playlist track lists, split one part per playlist, so editing one
/// playlist uploads only that playlist.
const String kPlaylistSongsField = 'playlistSongs';

/// Top-level fields stored as their own part.
const List<String> kLibrarySections = <String>[
  'allItems',
  'likedSongs',
  'likedAlbums',
  'likedPlaylists',
  'subscribedArtists',
  'downloadProgressMap',
];

/// A short, stable id for a playlist name.
///
/// Names cannot be used directly: parts become Firestore document ids, which
/// may not contain `/`. Hashing also keeps playlist names out of document ids.
String playlistPartId(String name) {
  // 64-bit FNV-1a, computed in two 32-bit halves so it is exact on every
  // platform.
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (final c in name.codeUnits) {
    h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 ^ (c + 0x9e3779b9)) * 0x85ebca6b) & 0xFFFFFFFF;
  }
  final a = h1.toRadixString(16).padLeft(8, '0');
  final b = h2.toRadixString(16).padLeft(8, '0');
  return '$a$b';
}

/// Splits a serialized library into `{partKey: json}`. Returns an empty map when
/// the input is missing or unreadable; the caller then uploads the whole blob,
/// so nothing is dropped from the backup.
Map<String, String> splitLibrary(String? libraryJson) {
  if (libraryJson == null || libraryJson.isEmpty) return const {};
  Map<String, dynamic> data;
  try {
    data = jsonDecode(libraryJson) as Map<String, dynamic>;
  } catch (_) {
    return const {};
  }

  final parts = <String, String>{};
  for (final section in kLibrarySections) {
    if (!data.containsKey(section)) continue;
    parts['$kLibraryPartPrefix$section'] = jsonEncode(data[section]);
  }

  final playlists = data[kPlaylistSongsField];
  if (playlists is Map) {
    // The playlist name is stored inside the part (the key is a hash), so each
    // part can restore its playlist on its own.
    for (final e in playlists.entries) {
      final name = e.key.toString();
      final id = playlistPartId(name);
      parts['${kLibraryPartPrefix}pl.$id'] =
          jsonEncode({'name': name, 'songs': e.value});
    }
  }
  return parts;
}

/// Rebuilds a library from parts; the inverse of [splitLibrary].
///
/// Returns null when nothing is recognisable, so the caller can fall back to an
/// older single blob. Unreadable parts are skipped, so one corrupt playlist does
/// not lose the library.
String? joinLibrary(Map<String, String> parts) {
  if (parts.isEmpty) return null;
  final data = <String, dynamic>{};
  final playlistSongs = <String, dynamic>{};
  var recognised = 0;

  for (final entry in parts.entries) {
    if (!entry.key.startsWith(kLibraryPartPrefix)) continue;
    final field = entry.key.substring(kLibraryPartPrefix.length);
    try {
      final decoded = jsonDecode(entry.value);
      if (field.startsWith('pl.')) {
        if (decoded is Map) {
          final name = decoded['name'];
          final songs = decoded['songs'];
          if (name is String && songs is List) {
            playlistSongs[name] = songs;
            recognised++;
          }
        }
      } else if (kLibrarySections.contains(field)) {
        data[field] = decoded;
        recognised++;
      }
    } catch (_) {
      // Skip only this part.
      continue;
    }
  }

  if (recognised == 0) return null;
  if (playlistSongs.isNotEmpty) data[kPlaylistSongsField] = playlistSongs;
  return jsonEncode(data);
}
