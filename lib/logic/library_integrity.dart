/// Decides whether a library save is allowed to replace the existing one.
///
/// Kept pure (no provider state) so it can be tested directly
/// (test/library_integrity_verify.dart).
library;

/// Titles present in every fresh install, so they say nothing about whether a
/// library holds anything worth keeping. An emptied library still contains these
/// folders, so counting them would let an empty save overwrite a good one.
/// The built-in playlist rebuilt each week from the listener's taste (see
/// KeepFreshNotifier.refreshWeeklyDiscovery).
const String kWeeklyDiscoveryTitle = 'Weekly Discovery';

/// Where a Keep fresh playlist's resting songs are kept: a hidden list in the
/// library, next to the playlist, so every build and every backup carries them
/// (a build that doesn't know Keep fresh still saves and restores them). Never
/// shown as a playlist.
const String kFreshReservePrefix = 'auvy:reserve:';

String freshReserveKey(String playlistTitle) => '$kFreshReservePrefix$playlistTitle';

bool isFreshReserveKey(String key) => key.startsWith(kFreshReservePrefix);

const Set<String> kSystemLibraryTitles = {
  'Cached',
  'Downloads',
  'Liked Playlists',
  'Liked Songs',
  'Liked Albums',
  'My Top 50',
  kWeeklyDiscoveryTitle,
  // Both artist folder titles stay listed: 'Your Artists' is the older name and
  // still appears in libraries saved before the rename.
  'Your Artists',
  'Followed Artists',
  'Followed Podcasts',
};

/// Whether a saved library contains anything the user made: a liked song, album
/// or playlist, a followed artist, a created playlist, or any non-system entry.
/// False for a fresh install or a library reduced to its system folders.
///
/// Tolerates unexpected shapes (older builds' JSON), because a guard like this
/// must never throw.
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

  // A user-added item: not flagged as a system folder and not a known system
  // title (older saves have only the title).
  final items = data['allItems'];
  if (items is List) {
    for (final i in items) {
      if (i is! Map) continue;
      if (i['isSystemFolder'] == true) continue;
      if (kSystemLibraryTitles.contains(i['title'])) continue;
      return true;
    }
  }

  // A user playlist with tracks. System folders are skipped because Cached and
  // Downloads fill themselves from disk.
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
