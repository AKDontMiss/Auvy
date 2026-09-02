import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/listening_policy.dart';

/// A playlist the user recently opened/played, stored with enough info to
/// REOPEN the exact original — an `externalId` for fetched playlists (YouTube /
/// Spotify) or a `libraryTitle` for library playlists (re-resolved by title).
///
/// This exists because play HISTORY only keeps plain tracks with no playlist
/// origin, so the Home mosaic could never point back at the real playlist a
/// track came from. Recording the playlist itself (on open) fixes that.
class RecentPlaylist {
  final String? externalId;   // real browse id for fetched playlists/albums
  final String? libraryTitle; // library playlist title (re-resolved on open)
  final String title;
  final String image;
  final String subtitle;
  final int playedAt;         // ms since epoch — for recency ordering
  /// 'playlist' (default) or 'album' — opened ALBUMS are recorded here too so
  /// the Home mosaic can list them by recency and reopen the real album page.
  final String kind;

  const RecentPlaylist({
    this.externalId,
    this.libraryTitle,
    required this.title,
    required this.image,
    required this.subtitle,
    required this.playedAt,
    this.kind = 'playlist',
  });

  bool get isAlbum => kind == 'album';

  /// Stable identity for de-duplication (same collection → same key).
  String get key => '$kind:${externalId ?? 'lib:$libraryTitle'}';

  Map<String, dynamic> toMap() => {
        'externalId': externalId,
        'libraryTitle': libraryTitle,
        'title': title,
        'image': image,
        'subtitle': subtitle,
        'playedAt': playedAt,
        'kind': kind,
      };

  factory RecentPlaylist.fromMap(Map<String, dynamic> m) => RecentPlaylist(
        externalId: m['externalId'] as String?,
        libraryTitle: m['libraryTitle'] as String?,
        title: (m['title'] ?? '').toString(),
        image: (m['image'] ?? '').toString(),
        subtitle: (m['subtitle'] ?? '').toString(),
        playedAt: (m['playedAt'] ?? 0) as int,
        kind: (m['kind'] ?? 'playlist').toString(),
      );
}

class RecentPlaylistsNotifier extends StateNotifier<List<RecentPlaylist>> {
  RecentPlaylistsNotifier() : super(const []) {
    _load();
  }

  static const _prefsKey = 'recent_playlists_v1';
  static const _originKey = 'recent_playlist_origins_v1';
  static const _cap = 15;
  static const _originCap = 400;

  /// Maps a played track's id AND its title|artist signature to the KEY of the
  /// collection it was played FROM. The Home mosaic uses this to show only the
  /// collection tile (album/playlist) and suppress the individual song, so a
  /// track played from a collection never appears twice.
  final Map<String, String> _origin = {};
  Map<String, String> get origin => _origin;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        state = (jsonDecode(raw) as List)
            .map((e) =>
                RecentPlaylist.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      final rawOrigin = prefs.getString(_originKey);
      if (rawOrigin != null) {
        _origin
          ..clear()
          ..addAll(Map<String, String>.from(jsonDecode(rawOrigin) as Map));
      }
    } catch (_) {/* corrupt cache → start empty */}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(state.map((e) => e.toMap()).toList()));
      await prefs.setString(_originKey, jsonEncode(_origin));
    } catch (_) {}
  }

  /// Record (or refresh) a recently-opened playlist: dedup by identity, move to
  /// the front, cap the list. Ignores entries without a real title.
  void record(RecentPlaylist playlist) {
    if (playlist.title.trim().isEmpty) return;
    final deduped = state.where((p) => p.key != playlist.key).toList();
    state = [playlist, ...deduped].take(_cap).toList();
    _persist();
  }

  /// Re-point a recorded playlist at new artwork.
  ///
  /// THE MOSAIC KEEPS ITS OWN COPY OF THE IMAGE. Recents are persisted as
  /// whole entries in `recent_playlists_v1`, image string included, so changing a
  /// playlist's cover in the library updated `LibraryItem.image` and left this
  /// list still pointing at the old artwork. The Home mosaic then showed the
  /// previous cover indefinitely — until the playlist happened to be opened again
  /// and `record` overwrote the entry.
  ///
  /// It only looked like an intermittent bug because it depends on which store
  /// you happen to look at: it never reproduced on IMPORTED playlists, whose art
  /// is a remote URL that is identical in both places.
  ///
  /// Matching on `libraryTitle`, not `title`: that is the field that identifies a
  /// library playlist, and an external playlist can easily share a display name.
  void updateImageFor(String libraryTitle, String image) {
    if (libraryTitle.trim().isEmpty || image.isEmpty) return;
    var changed = false;
    final next = state.map((p) {
      if (p.libraryTitle != libraryTitle || p.image == image) return p;
      changed = true;
      return RecentPlaylist(
        externalId: p.externalId,
        libraryTitle: p.libraryTitle,
        title: p.title,
        image: image,
        subtitle: p.subtitle,
        playedAt: p.playedAt,
        kind: p.kind,
      );
    }).toList();
    if (!changed) return;
    state = next;
    _persist();
  }

  /// Drop recorded LIBRARY playlists that no longer exist.
  ///
  /// A DELETED PLAYLIST KEPT ITS TILE ON THE HOME MOSAIC. Recents are keyed by
  /// `libraryTitle` and persisted as whole entries, so deleting (or renaming) a
  /// playlist left this list still pointing at it — the tile stayed on Home,
  /// showing the old cover, and opening it re-resolved by title and found nothing.
  ///
  /// Only entries with a `libraryTitle` are considered. An entry with an
  /// `externalId` is a fetched YouTube/Spotify playlist or album that exists
  /// whether or not it is saved locally, so "not in the library" says nothing about
  /// whether it can still be opened — pruning those would delete perfectly valid
  /// history. [existingTitles] must therefore be the set of library playlist
  /// titles, not everything the user has ever seen.
  void pruneMissing(Set<String> existingTitles) {
    final next = state.where((p) {
      final t = p.libraryTitle;
      if (t == null || t.trim().isEmpty) return true; // external — not ours to judge
      return existingTitles.contains(t);
    }).toList();
    if (next.length == state.length) return;

    // The origin map points tracks at collection KEYS; entries for a collection
    // that no longer exists would otherwise keep suppressing those tracks from the
    // mosaic forever, so the songs would vanish along with the tile.
    final liveKeys = next.map((p) => p.key).toSet();
    _origin.removeWhere((_, key) => !liveKeys.contains(key));

    state = next;
    _persist();
  }

  /// Wipe all recents + play-origins (Delete Account / new-user reset). prefs.clear()
  /// removes the persisted blob, but this StateNotifier holds the list AND the
  /// origin map IN MEMORY — without this the Home mosaic keeps showing the old
  /// user's recently-played collections after deletion.
  void clear() {
    state = const [];
    _origin.clear();
    _persist();
  }

  /// A track was PLAYED from [collection]: record the collection as recent AND
  /// remember (by the track's id + signature) that it belongs to that
  /// collection, so the mosaic represents it with the collection tile only.
  void recordPlayedFrom(RecentPlaylist collection,
      {required String songId, required String songSig}) {
    if (collection.title.trim().isEmpty) return;
    // "Pause listening history" also stops the Home mosaic filling up — it's
    // the most visible record of what was played.
    if (ListeningPolicy.historyPaused) return;
    // Bound the origin map so a long-lived install can't grow it forever.
    if (_origin.length > _originCap) {
      final drop = _origin.keys.take(_origin.length - _originCap ~/ 2).toList();
      for (final k in drop) {
        _origin.remove(k);
      }
    }
    if (songId.isNotEmpty) _origin[songId] = collection.key;
    if (songSig.isNotEmpty) _origin[songSig] = collection.key;
    record(collection); // record() persists both lists
  }
}

final recentPlaylistsProvider =
    StateNotifierProvider<RecentPlaylistsNotifier, List<RecentPlaylist>>(
        (ref) => RecentPlaylistsNotifier());
