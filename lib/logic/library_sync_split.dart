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
    final value = section == 'allItems'
        ? withoutDevicePaths(withoutDeviceCounts(data[section]))
        : data[section];
    parts['$kLibraryPartPrefix$section'] = jsonEncode(value);
  }

  final playlists = data[kPlaylistSongsField];
  if (playlists is Map) {
    // The playlist name is stored inside the part (the key is a hash), so each
    // part can restore its playlist on its own.
    for (final e in playlists.entries) {
      final name = e.key.toString();
      final id = playlistPartId(name);
      // A device-owned list goes up empty (see kDeviceOwnedPlaylists); the
      // part stays, so the playlist itself is still there after a restore.
      final songs = kDeviceOwnedPlaylists.contains(name) ? const [] : e.value;
      parts['${kLibraryPartPrefix}pl.$id'] =
          jsonEncode({'name': name, 'songs': songs});
    }
  }
  return parts;
}

/// Playlists whose tracks belong to the device, not the account.
///
/// Downloads lists the files on THIS phone, in the order its owner arranged
/// them; My Top 50 is worked out on each phone from the synced play counts, and
/// rebuilt after every restore. Synced, each phone's list replaced the other's
/// on every restore (taking Downloads' custom order with it) and went back up
/// changed: seen 2026-10-17, both went up with nearly every push from both
/// phones. They go up empty, and a restore keeps this phone's own (see
/// [keepDeviceOwned]).
const Set<String> kDeviceOwnedPlaylists = {'Downloads', 'My Top 50'};

/// The folder custom covers are kept in, on both platforms
/// (ArtworkOverrideNotifier's `_dirName`).
const String kCoverOverrideDir = '/artwork_overrides/';

/// [allItems] with custom-cover paths blanked.
///
/// A playlist with a custom cover stores the path of that cover's file on this
/// phone. The cover itself syncs as bytes (`auvy_artwork_overrides_v2`), and
/// each phone points the row back at its own copy after every load
/// (`_reconcileCustomCovers`), so the path is noise in the backup, and a
/// different noise on each phone: seen 2026-10-17, 15 such rows made the row
/// list go up from both phones on nearly every push. Only paths into the
/// cover folder are blanked; any other value is left as it was.
Object? withoutDevicePaths(Object? allItems) {
  if (allItems is! List) return allItems;
  return [
    for (final item in allItems)
      if (item is Map &&
          item['image'] is String &&
          !(item['image'] as String).startsWith('http') &&
          (item['image'] as String).contains(kCoverOverrideDir))
        {...item, 'image': ''}
      else
        item,
  ];
}

/// [restored] with this phone's own device-owned playlists put back.
///
/// The backup carries them empty (see [kDeviceOwnedPlaylists]); a restore that
/// took that would empty Downloads until the next scan, and lose its order for
/// good. [local] is the library as it stands before the restore. Anything
/// unreadable leaves [restored] as it was.
String keepDeviceOwned(String restored, String? local) {
  if (local == null || local.isEmpty) return restored;
  try {
    final r = jsonDecode(restored);
    final l = jsonDecode(local);
    if (r is! Map<String, dynamic> || l is! Map) return restored;
    final localLists = l[kPlaylistSongsField];
    if (localLists is! Map) return restored;
    final lists = r[kPlaylistSongsField] is Map
        ? Map<String, dynamic>.from(r[kPlaylistSongsField] as Map)
        : <String, dynamic>{};
    var kept = false;
    for (final name in kDeviceOwnedPlaylists) {
      if (localLists.containsKey(name)) {
        lists[name] = localLists[name];
        kept = true;
      }
    }
    if (!kept) return restored;
    r[kPlaylistSongsField] = lists;
    return jsonEncode(r);
  } catch (_) {
    return restored;
  }
}

/// The library rows whose counts belong to THIS device: what it has cached and
/// downloaded. Synced as "0 songs" and recounted by each device after a restore,
/// so one phone's cache growing doesn't upload the row list and make the other
/// phone take a count that isn't its own (and upload its own back): seen
/// 2026-10-16, `auvy_lib::allItems` went up with most pushes from both phones.
const Set<String> kDeviceCountFolders = {'Cached', 'Downloads'};

/// [allItems] with the per-device folders' counts neutralised (see
/// [kDeviceCountFolders]). Anything unexpected is returned as it was.
Object? withoutDeviceCounts(Object? allItems) {
  if (allItems is! List) return allItems;
  return [
    for (final item in allItems)
      if (item is Map && item['isSystemFolder'] == true && kDeviceCountFolders.contains(item['title']))
        {
          ...item,
          if (item.containsKey('subtitle')) 'subtitle': 'Playlist • 0 songs',
          if (item.containsKey('songCount')) 'songCount': 0,
        }
      else
        item,
  ];
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
