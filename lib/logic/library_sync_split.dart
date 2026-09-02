/// Incremental library sync
///
/// Splits the one big `auvy_library_data` blob into independently-syncable
/// pieces, and puts them back together on restore.
///
/// WHY THE MONOLITH HAD TO GO. The whole library was a SINGLE cloud blob, so:
///
///  • Liking one song re-uploaded every playlist you own. On mobile data, a
///    normal listening session pushed the entire library over and over.
///  • Any failure anywhere took the WHOLE library with it. One torn part meant
///    the joined blob failed to parse, and a library that fails to parse reads
///    as empty, which is how "I lost everything" happens from a dropped packet.
///
///  Split, each piece carries its own signature and generation, so an unchanged
///  piece is never re-sent and a damaged piece costs exactly that piece. Losing
///  one playlist is a bad day; losing all of them is the bug this exists to
///  make structurally impossible.
///
/// The split is by MEANING, not by size: sections the user thinks of separately
/// (likes, followed artists, each playlist) are the units that change
/// separately, so they are the units that should sync separately.
library;

import 'dart:convert';

/// Prefix marking a part of the split library. Chosen so it cannot collide with
/// a real top-level pref key.
const String kLibraryPartPrefix = 'auvy_lib::';

/// Section holding the per-playlist track lists. Split further, one part per
/// playlist, because a playlist is the thing a user actually edits — appending
/// one track should upload one playlist, not all of them.
const String kPlaylistSongsField = 'playlistSongs';

/// Top-level fields carried as their own part.
const List<String> kLibrarySections = <String>[
  'allItems',
  'likedSongs',
  'likedAlbums',
  'likedPlaylists',
  'subscribedArtists',
  'downloadProgressMap',
];

/// A stable, filesystem- and Firestore-safe id for a playlist name.
///
/// THE NAME CANNOT BE USED DIRECTLY. Parts become Firestore document ids
/// (`{key}.{i}`), and a document id may not contain `/`, which a playlist name
/// certainly can, along with anything else a keyboard produces. Hashing gives a
/// short, fixed-shape, collision-resistant id from any name.
///
/// It is also a PRIVACY improvement: playlist names are user content, and this
/// keeps them out of document ids where they would otherwise be readable in
/// every console listing and log line without decrypting anything.
String playlistPartId(String name) {
  // FNV-1a, 64-bit, in two 32-bit halves so it stays exact on the web's
  // doubles as well as native ints.
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

/// Break a serialized library into `{partKey: json}` pieces.
///
/// Returns an empty map when [libraryJson] is absent or unparseable — the caller
/// then falls back to pushing the monolith, so a library we cannot read is never
/// silently dropped from the backup.
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
    // The name travels INSIDE the part, not in its key — the key is a hash, so
    // reassembly needs the original from somewhere. Storing it here keeps each
    // part self-describing: one part is enough to restore one playlist, with no
    // separate index to fall out of step with it.
    for (final e in playlists.entries) {
      final name = e.key.toString();
      final id = playlistPartId(name);
      parts['${kLibraryPartPrefix}pl.$id'] =
          jsonEncode({'name': name, 'songs': e.value});
    }
  }
  return parts;
}

/// Rebuild a library blob from parts. Inverse of [splitLibrary].
///
/// Returns null when [parts] holds nothing recognisable, so the caller can fall
/// back to a legacy monolithic blob rather than restoring an empty library.
///
/// Unreadable parts are SKIPPED rather than fatal — that is the entire point of
/// splitting. One corrupt playlist must cost that playlist, not the library.
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
      // Skip this part only. See the note above.
      continue;
    }
  }

  if (recognised == 0) return null;
  if (playlistSongs.isNotEmpty) data[kPlaylistSongsField] = playlistSongs;
  return jsonEncode(data);
}
