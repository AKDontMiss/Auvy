import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/listening_policy.dart';

/// A playlist the user recently opened or played, with enough information to
/// reopen the original: an `externalId` for fetched playlists (YouTube / Spotify)
/// or a `libraryTitle` for library playlists (resolved by title). Play history
/// only keeps tracks, so this is what lets the home mosaic point back at the
/// playlist.
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
        // Started unawaited by the constructor, so the notifier may be disposed by now
        // (a rebuild on sign-in or restore); writing state would throw.
        if (!mounted) return;
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

  /// Points a recorded playlist at new artwork. Recents store their own copy of the
  /// image, so a cover changed in the library must be updated here too, or the home
  /// mosaic keeps showing the old one. Matched on `libraryTitle`, which identifies a
  /// library playlist (an external playlist can share a display name).
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

  /// Re-point recorded library playlists and origin mappings when a playlist is renamed.
  void rename(String oldTitle, String newTitle) {
    if (oldTitle.trim().isEmpty || newTitle.trim().isEmpty || oldTitle == newTitle) return;
    var changed = false;
    final next = state.map((p) {
      if (p.libraryTitle != oldTitle) return p;
      changed = true;
      return RecentPlaylist(
        externalId: p.externalId,
        libraryTitle: newTitle,
        title: p.title == oldTitle ? newTitle : p.title,
        image: p.image,
        subtitle: p.subtitle,
        playedAt: p.playedAt,
        kind: p.kind,
      );
    }).toList();

    final oldKey = 'playlist:lib:$oldTitle';
    final newKey = 'playlist:lib:$newTitle';
    var originChanged = false;
    for (final entry in _origin.entries.toList()) {
      if (entry.value == oldKey) {
        _origin[entry.key] = newKey;
        originChanged = true;
      }
    }

    if (changed || originChanged) {
      if (changed) state = next;
      _persist();
    }
  }

  /// Drops recorded library playlists that no longer exist (deleted or renamed), so
  /// their tiles leave the home mosaic. Only entries with a `libraryTitle` are
  /// considered: an `externalId` entry can still be opened whether or not it's saved
  /// locally. [existingTitles] must be the set of library playlist titles.
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
