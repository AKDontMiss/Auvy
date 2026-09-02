/// The check that stands between the user AND an erased library
///
/// Pulled out of LibraryNotifier so it is pure, has no dependency on provider
/// state, and can be tested directly (see test/library_integrity_verify.dart).
/// Every branch here decides whether a write is allowed to replace someone's
/// playlists, so "it looked right" is not a good enough standard for it.
library;

/// Titles that exist in a brand-new install and therefore prove NOTHING about
/// whether a library holds anything worth keeping.
///
/// This set is the whole reason the check works. A library that has been emptied
/// by a bug still serializes Liked Songs, Cached, Downloads and the rest, so a
/// naive "is allItems non-empty?" test reports every wiped library as healthy —
/// which is exactly how an empty save gets waved through.
const Set<String> kSystemLibraryTitles = {
  'Cached',
  'Downloads',
  'Liked Playlists',
  'Liked Songs',
  'Liked Albums',
  'My Top 50',
  // Both artist titles stay listed, forever.
  //
  // This set is what tells `libraryHasUserContent` which rows are scaffolding
  // rather than something the user made. A library reduced to system folders is
  // treated as EMPTY, which is what blocks an empty save from overwriting a good
  // backup.
  //
  // 'Your Artists' is the pre-rename title and still exists in every library blob
  // written before the migration ran. Drop it and one of those blobs looks like it
  // contains a user-made folder, so a genuinely empty library would pass the
  // guard and be allowed to overwrite the last-known-good snapshot. That is the
  // exact shape of the data loss this file exists to prevent.
  'Your Artists',
  'Followed Artists',
  'Followed Podcasts',
};

/// Does this serialized library contain anything the USER made?
///
/// True for: a liked song, a liked album, a liked playlist, a followed artist,
/// a playlist they created, or any non-system entry in the library grid.
/// False for a fresh install and for a library that has been reduced to its
/// system folders.
///
/// Shape-tolerant on purpose — it is handed both freshly serialized state and
/// whatever JSON an older build left on disk, and a type it does not expect must
/// never throw its way out of a data-loss guard.
bool libraryHasUserContent(Map<String, dynamic> data) {
  int lengthOf(String key) {
    final v = data[key];
    return (v is List) ? v.length : 0;
  }

  if (lengthOf('likedSongs') > 0 ||
      lengthOf('likedAlbums') > 0 ||
      lengthOf('likedPlaylists') > 0 ||
      lengthOf('subscribedArtists') > 0) {
    return true;
  }

  // A library item the user added: anything not flagged as a system folder and
  // not one of the known system titles. Both tests, because older saves predate
  // the flag and carry only the title.
  final items = data['allItems'];
  if (items is List) {
    for (final i in items) {
      if (i is! Map) continue;
      if (i['isSystemFolder'] == true) continue;
      if (kSystemLibraryTitles.contains(i['title'])) continue;
      return true;
    }
  }

  // A user-created playlist with tracks in it. System folders are skipped: the
  // Cached and Downloads folders fill themselves from disk, so counting them
  // would let a wiped library pass the moment anything was cached.
  final playlists = data['playlistSongs'];
  if (playlists is Map) {
    for (final entry in playlists.entries) {
      if (kSystemLibraryTitles.contains(entry.key)) continue;
      final v = entry.value;
      if (v is List && v.isNotEmpty) return true;
    }
  }

  return false;
}
