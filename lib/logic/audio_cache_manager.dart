// Manages local storage for audio files and lyrics to save data and enable offline playback.
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
// For normalize/isWithin — string surgery cannot safely answer "is this path
// inside that folder?" once `..` is in play. See [_deleteIfInsideDownloads].
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/services/lyrics_service.dart';
import 'package:auvy/services/audio_service.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';

final audioCacheManagerProvider = Provider<AudioCacheManager>((ref) {
    return AudioCacheManager();
  });
/// Audio files on disk, and the index that describes them.
///
/// TWO KINDS OF FILE LIVE HERE, and almost every method distinguishes them:
///
///   auto-cached  kept automatically as you listen, evicted when space runs
///                short. `isExplicitDownload == false`.
///   downloaded   asked for by the user. Never evicted, and written to
///                Music/Auvy where a file manager can see it.
///
/// The auto-cache is capped (500 MB by default) and trimmed by least-recently
/// used, except for the user's most-played tracks, which are pinned so they
/// survive. Downloads are never counted against that cap.
///
/// It also owns lyrics on disk, cover art files, and the startup scan that
/// finds files in Music/Auvy and adopts them back into the index. That scan is
/// what makes downloads survive a reinstall: the files are in shared storage,
/// so they outlive the app, and the index is rebuilt from them.
///
/// One naming trap worth knowing: cacheTrack() with an EMPTY url does not
/// download anything. It asks whether the native play-cache already holds the
/// whole track and, if so, copies those bytes across. That is how a track you
/// just listened to becomes cached for free, and why the same method covers
/// both "fetch this" and "keep what we already have".
class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal();
  void Function()? onCacheUpdated;

  // Cache configuration
  int maxCacheSizeMB = 500; 
  static const int maxCacheAgeDays = 30;   
  static const int maxCachedTracks = 500;

  Directory? _cacheDir;
  Directory? _downloadDir;
  final Map<String, CachedTrackInfo> _cacheIndex = {};

  /// Song ids that must NOT be auto-evicted or age-expired even though they're
  /// auto-cache (not explicit downloads). Set to the user's "My Top 50" / most-
  /// played tracks so their most-listened songs stay offline-ready — this is why
  /// the number of cached tracks should meet-or-exceed My Top 50. Explicit
  /// downloads are already protected separately.
  Set<String> pinnedSongIds = {};

  /// Tracks the "Cached" folder is PRETENDING to have deleted while an Undo
  /// toast is open. The folder lists disk state directly, so a real delete
  /// can't be undone — instead the row is hidden here, and only when the undo
  /// window expires does [removeFromCache] actually wipe the file. Session-only
  /// by design: if the app dies mid-window the file simply survives.
  final Set<String> _pendingDeleteIds = {};

  void hidePendingDelete(String songId) {
    _pendingDeleteIds.add(songId);
    onCacheUpdated?.call();
    cacheEpoch.value++;
  }

  void restorePendingDelete(String songId) {
    _pendingDeleteIds.remove(songId);
    onCacheUpdated?.call();
    cacheEpoch.value++;
  }

  final StreamController<Map<String, double>> _downloadProgressController =
      StreamController<Map<String, double>>.broadcast();
  final Map<String, double> _activeDownloads = {};

  Stream<Map<String, double>> get downloadProgress => _downloadProgressController.stream;
  bool _isInitialized = false;
  Future<void>? _initFuture;
  bool _isPrefetching = false;

  Future<void> initialize() {
    // Guard against concurrent callers: library init, main(), and lyrics preload
    // all race this at startup. Without a single in-flight future, MetadataGod
    // (flutter_rust_bridge) gets initialized twice and throws.
    if (_isInitialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      await MetadataGod.initialize();
    } catch (e) {
      // flutter_rust_bridge throws if already initialized — safe to ignore.
      print("MetadataGod init skipped: $e");
    }
    
    // Internal hidden cache directory
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/audio_cache');
    
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }

    //  FIX: Request storage permissions from the user before accessing the public folder
    bool hasPermission = true;
    if (Platform.isAndroid) {
      // Request both legacy storage and Android 13+ audio permissions
      final status = await [Permission.storage, Permission.audio].request();
      hasPermission = status[Permission.storage] == PermissionStatus.granted || 
                      status[Permission.audio] == PermissionStatus.granted;
    }

    //  Route to public folder if Android and permissions granted
    if (Platform.isAndroid && hasPermission) {
      _downloadDir = Directory('/storage/emulated/0/Music/Auvy');
    } else {
      // iOS or Permission Denied fallback
      _downloadDir = Directory('${appDir.path}/Auvy_Downloads'); 
    }

    if (!await _downloadDir!.exists()) {
      try {
        await _downloadDir!.create(recursive: true);
      } catch (e) {
        print("WARN: Could not create public download folder (Storage permissions missing?): $e");
        _downloadDir = _cacheDir; // Ultimate fallback to internal cache
      }
    }
    
    await _loadCacheIndex();
    await _cleanupExpiredCache();
    // Reclaim sidecars orphaned by earlier builds (which deleted the audio but
    // not the cover). Unawaited: it's a disk sweep, never worth delaying start.
    unawaited(_sweepOrphanedSidecars());

    _isInitialized = true;
    print(" Audio Cache Manager initialized: ${_cacheIndex.length} cached tracks");
  }

  Future<void> _loadCacheIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final indexJson = prefs.getString('audio_cache_index');
      
      if (indexJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(indexJson);
        _cacheIndex.clear();
        _invalidateUrlIndex();
        decoded.forEach((key, value) {
          _cacheIndex[key] = CachedTrackInfo.fromJson(value, _cacheDir!.path);
          _invalidateUrlIndex();
        });
        await _repairPlaceholderAlbums();
      }
    } catch (e) {
      print("WARN: Failed to load cache index: $e");
    }
  }

  /// Undo the phantom "Auvy Downloads" folder on indexes that already have it.
  ///
  /// FIXING THE IMPORT IS NOT ENOUGH. scanAndImportDownloads skips any file
  /// already in the index (`if (_cacheIndex.containsKey(id)) continue;`), so a
  /// device that imported these tracks before the fix keeps the bad album name
  /// for ever — the folder would survive the update and look like the fix had
  /// simply not worked.
  ///
  /// Idempotent and unstamped, unlike the intel_artist_genres migration: that
  /// one had to distinguish "not yet asked" from "asked, genuinely nothing", so
  /// re-running it would have destroyed real answers. Here the operation is a
  /// no-op the moment the index is clean, and [kDownloadsAlbumTag] is never a
  /// legitimate album, so there is nothing a repeat run could damage.
  Future<void> _repairPlaceholderAlbums() async {
    final hits = _cacheIndex.entries
        .where((e) => e.value.albumTitle.trim() == kDownloadsAlbumTag)
        .toList();
    if (hits.isEmpty) return;
    for (final e in hits) {
      _cacheIndex[e.key] = e.value.copyWith(albumTitle: '');
    }
    _invalidateUrlIndex();
    await _saveCacheIndex();
    print('downloads: cleared the placeholder album on ${hits.length} '
        'entr${hits.length == 1 ? "y" : "ies"} — they list flat again '
        'rather than under an "$kDownloadsAlbumTag" folder');
  }

  Future<void> _saveCacheIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final indexJson = jsonEncode(
        _cacheIndex.map((key, value) => MapEntry(key, value.toJson()))
      );
      await prefs.setString('audio_cache_index', indexJson);
      onCacheUpdated?.call();
      cacheEpoch.value++; // wake reactive download/cached badges + buttons
    } catch (e) {
      print("WARN: Failed to save cache index: $e");
    }
  }

  /// Bumps whenever the cache index or pending-delete set changes (download
  /// completes, track removed, undo). UI badges/buttons that read
  /// isCached/isExplicitlyDownloaded rebuild on this so they update instantly
  /// instead of only on the next unrelated rebuild (the "badge is delayed" bug).
  static final ValueNotifier<int> cacheEpoch = ValueNotifier(0);

  bool isCached(String songId) {
    if (!_cacheIndex.containsKey(songId)) return false;
    
    final info = _cacheIndex[songId]!;
    final file = File(info.filePath);
    
    if (!file.existsSync()) {
      _cacheIndex.remove(songId);
      _invalidateUrlIndex();
      _saveCacheIndex();
      return false;
    }
    
    final age = DateTime.now().difference(info.cachedAt);
    if (age.inDays > maxCacheAgeDays && !info.isExplicitDownload && !pinnedSongIds.contains(songId)) {
      // Only auto-remove if NOT explicitly downloaded AND not a pinned top track.
      removeFromCache(songId);
      return false;
    }
    
    return true;
  }

  /// Whether the audio for an explicit download is actually PRESENT on disk.
  ///
  /// The index and the filesystem can disagree — a file deleted outside the app,
  /// or an entry written before a failed write. Callers that gate work on
  /// "already downloaded" must check this too, or a stale entry makes the track
  /// permanently unretryable.
  bool downloadedFileExists(String songId) {
    final info = _cacheIndex[songId];
    if (info == null) return false;
    try {
      return File(info.filePath).existsSync();
    } catch (_) {
      return false;
    }
  }

  bool isExplicitlyDownloaded(String songId) {
    return _cacheIndex[songId]?.isExplicitDownload ?? false;
  }

  /// Read-only index entry for a track (file size, path, cached-at) — used by
  /// the Song Details sheet. Null when the track has no local copy.
  CachedTrackInfo? getTrackInfo(String songId) => _cacheIndex[songId];

  String? getCachedPath(String songId) {
    if (!isCached(songId)) return null;
    
    // CRITICAL: Update priority whenever the file is requested for playback
    _updateAccessTime(songId); 
    
    return _cacheIndex[songId]!.filePath;
  }

  Set<String> getCachedSongIds() {
    return _cacheIndex.keys.where((id) => isCached(id)).toSet();
  }

  /// Returns a list of Songs that were explicitly downloaded by the user

  /// Which collection a downloaded track belongs to, or null for a loose single.
  ///
  /// Derived from where the file actually is
  ///
  /// `CachedTrackInfo` never stored `downloadType` / `collectionName` — they were
  /// only ever used to choose a directory. The directory is therefore the record,
  /// and it is ground truth rather than a second copy that can disagree:
  /// `Albums/<name>/…`, `Playlists/<name>/…`, `Podcasts/<show>/…`, or `Singles/`.
  ///
  /// Reading it back beats adding fields to the index, which would need a format
  /// migration and would leave every track downloaded before it unclassifiable.
  ({String kind, String name})? downloadCollectionOf(String songId) {
    final info = _cacheIndex[songId];
    if (info == null || _downloadDir == null) return null;
    final base = _downloadDir!.path;
    if (!info.filePath.startsWith(base)) return null;
    final rel = info.filePath.substring(base.length).replaceAll(r'\', '/');
    final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < 3) return null; // <kind>/<name>/<file>
    if (segs[0] != 'Albums' && segs[0] != 'Playlists' && segs[0] != 'Podcasts') {
      return null;
    }
    return (kind: segs[0], name: segs[1]);
  }
  List<Song> getDownloadedTracks() {
    return _cacheIndex.values
        .where((info) => info.isExplicitDownload && File(info.filePath).existsSync())
        .map((info) => Song(
              id: info.songId, title: info.title, artist: info.artist,
              // PERSIST the NETWORK url, not the local cover path: these Songs flow into
              // play history / recents / the Home mosaic, which are cloud-backed up.
              // A local path dies on reinstall (files are wiped, not backed up) →
              // "cover art missing after restore" (#18). AuvyImage still resolves the
              // on-disk cover from this url via getLocalPathFromUrl, so offline art is
              // unaffected. Fall back to the local path only for locally-imported files
              // that have no network url at all.
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
              albumTitle: info.albumTitle,
            )).toList();
  }

  /// Audio file extensions we recognize when importing user-added files.
  ///
  /// `.webm` belongs here even though it usually names a video: YouTube's audio
  /// streams are Opus in a WebM container, so an Auvy download of a track with no
  /// MP4 audio is named that way, and leaving it out meant such a file was NOT
  /// re-imported after a reinstall — the download survived, the library entry did
  /// not.
  static const Set<String> _audioExts = {
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.mp4', '.weba',
    '.webm'
  };

  /// Scan the public Auvy folder for audio files and register any that aren't
  /// already tracked, so a track the user MOVES/COPIES into the Auvy folder
  /// (e.g. from another music player) is recognized, tagged and playable, like a
  /// local music library. Files under `Albums/<name>` or `Playlists/<name>` are
  /// grouped under that album/collection; loose files are singles. Also prunes
  /// index entries whose backing download file has been deleted on disk.
  ///
  /// Reading files another app created requires broad storage access on
  /// Android 11+; pass [requestAccess] to prompt for "All files access" first.
  /// Returns the number of newly-imported tracks.
  Future<int> scanAndImportDownloads({bool requestAccess = false}) async {
    if (!_isInitialized) await initialize();
    if (_downloadDir == null) return 0;

    // NO "ALL FILES ACCESS" REQUEST ANY MORE — the permission is gone.
    //
    // This used to ask for MANAGE_EXTERNAL_STORAGE, because reading files another
    // app wrote needs broad access if you enumerate with `Directory.listSync`.
    // That permission was the worst thing in the manifest: Play gates it behind a
    // special declaration music players do not qualify for, and it is a strong
    // malware heuristic since it grants reach over every document and photo on the
    // device — for a feature that needed to list audio in ONE folder.
    //
    // MediaStore does exactly that with READ_MEDIA_AUDIO, which the app already
    // holds, so the request is unnecessary. [requestAccess] is kept in the
    // signature (callers still pass it) but is now a no-op, deliberately: removing
    // the parameter would be a wider change for no behavioural gain, and a comment
    // here is more useful than a churn of call sites.
    if (requestAccess && Platform.isAndroid) {
      // Intentionally empty. See above.
    }

    int imported = 0;
    try {
      final basePath = _downloadDir!.path;

      // Migrate away any OLD-format imported ids ('local:<relpath>' — the colon
      // form contained '/' which broke derived lyrics_/cover_ filenames). Drop
      // the index entry only (keep the file) so it re-imports below with a
      // filesystem-safe 'local_' id. One-time; no-ops once migrated.
      final legacy = _cacheIndex.keys.where((k) => k.startsWith('local:')).toList();
      for (final k in legacy) {
        _cacheIndex.remove(k);
        _invalidateUrlIndex();
      }
      if (legacy.isNotEmpty) await _saveCacheIndex();

      final existingPaths = _cacheIndex.values.map((i) => i.filePath).toSet();

      // ENUMERATE VIA MEDIASTORE, NOT listSync
      //
      // THIS IS WHAT LET MANAGE_EXTERNAL_STORAGE GO. Under scoped storage an
      // app cannot reliably enumerate a shared-storage directory with File APIs —
      // it CAN read media files it has permission for, but listing the folder is
      // the part that needed "All files access". MediaStore answers the same
      // question ("what audio is in Music/Auvy?") with READ_MEDIA_AUDIO, and
      // returns files whichever app wrote them, which is the entire point.
      //
      // Falls back to listSync when the channel is unavailable (a headless engine
      // with no Activity, or a platform that is not Android), so nothing regresses
      // where the old path still works — Auvy's own downloads live here too and it
      // can always read those.
      final List<String> candidatePaths = [];
      if (Platform.isAndroid) {
        try {
          final rows = await const MethodChannel('com.auvy.app/folder')
              .invokeMethod<List<dynamic>>('listAudioIn', {
            'relativePath': 'Music/Auvy/',
          });
          for (final r in rows ?? const []) {
            final p = (r is Map ? r['path'] : null)?.toString() ?? '';
            if (p.isNotEmpty) candidatePaths.add(p);
          }
        } catch (e) {
          print("WARN: MediaStore listing unavailable, falling back: $e");
        }
      }
      if (candidatePaths.isEmpty) {
        try {
          for (final ent
              in _downloadDir!.listSync(recursive: true, followLinks: false)) {
            if (ent is File) candidatePaths.add(ent.path);
          }
        } catch (_) {/* unreadable folder → nothing to import */}
      }

      for (final path in candidatePaths) {
        final dot = path.lastIndexOf('.');
        final ext = dot >= 0 ? path.substring(dot).toLowerCase() : '';
        if (!_audioExts.contains(ext)) continue;
        if (existingPaths.contains(path)) continue; // already tracked

        // Relative path under the Auvy folder → stable synthetic id + grouping.
        String rel = path.startsWith(basePath) ? path.substring(basePath.length) : path;
        rel = rel.replaceAll('\\', '/');
        if (rel.startsWith('/')) rel = rel.substring(1);

        // A `<file>.auvyid` sidecar (written at download time) carries the REAL
        // videoId + network cover, so a reinstalled download re-keys to its real
        // id (matching the restored library album → correct grouping, #21) with
        // its cover intact (#18) instead of a synthetic 'local_' id and no art.
        String scId = '', scImageUrl = '', scAlbum = '', scTitle = '', scArtist = '';
        try {
          // New hidden location first, then the legacy copy beside the audio, so
          // downloads made before the move still re-key correctly.
          final sc = sidecarCandidates(path).firstWhere(
              (f) => f.existsSync(),
              orElse: () => File('$path.auvyid'));
          if (sc.existsSync()) {
            final m = jsonDecode(sc.readAsStringSync()) as Map;
            scId = (m['id'] ?? '').toString();
            scImageUrl = (m['imageUrl'] ?? '').toString();
            scAlbum = (m['album'] ?? '').toString();
            scTitle = (m['title'] ?? '').toString();
            scArtist = (m['artist'] ?? '').toString();
          }
        } catch (_) {}

        // Filesystem-SAFE id: the id is embedded in derived filenames
        // (lyrics_<id>.json, cover_<id>.jpg), so it must not contain path
        // separators or ':' — otherwise those become nonexistent nested paths.
        final id = scId.isNotEmpty
            ? scId
            : 'local_${rel.replaceAll(RegExp(r'[\\/:]'), '_')}';
        if (_cacheIndex.containsKey(id)) continue;

        // Read embedded tags (best-effort).
        String title = '', artist = '', album = '';
        String localImagePath = '';
        try {
          final meta = await MetadataGod.readMetadata(file: path);
          title = (meta.title ?? '').trim();
          artist = (meta.artist ?? '').trim();
          album = (meta.album ?? '').trim();
          if (meta.picture != null && meta.picture!.data.isNotEmpty) {
            try {
              final cover = File('${_cacheDir!.path}/cover_local_${id.hashCode}.jpg');
              await cover.writeAsBytes(meta.picture!.data);
              localImagePath = cover.path;
            } catch (_) {}
          }
        } catch (_) {}

        // Fallbacks from the filename ("Artist - Title.ext", our own convention).
        final fileName = rel.split('/').last;
        final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
        if (title.isEmpty) {
          final parts = baseName.split(' - ');
          if (parts.length >= 2) {
            if (artist.isEmpty) artist = parts.first.trim();
            title = parts.sublist(1).join(' - ').trim();
          } else {
            title = baseName.trim();
          }
        }
        if (title.isEmpty) continue;

        // Grouping from the folder (Albums/<name> or Playlists/<name>).
        if (album.isEmpty) {
          final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
          if (segs.length >= 2 && (segs[0] == 'Albums' || segs[0] == 'Playlists')) {
            album = segs[1];
          }
        }

        int size = 0;
        try { size = File(path).lengthSync(); } catch (_) {}

        // Sidecar metadata wins (exact original title/artist/album + network
        // cover), so a reinstalled download shows correctly and re-groups.
        if (scTitle.isNotEmpty) title = scTitle;
        if (scArtist.isNotEmpty) artist = scArtist;
        if (scAlbum.isNotEmpty) album = scAlbum;

        // Auvy's own placeholder is NOT a collection.
        //
        // Downloads with no album are TAGGED [kDownloadsAlbumTag] so they read
        // sensibly in other players. Reading that tag back as an album name
        // grouped every such track into a folder called "Auvy Downloads" —
        // which is what a reinstall produced, since the index is rebuilt from
        // the files rather than from the backup. Before the reinstall those
        // same tracks had an empty album and listed flat, so the folder
        // appeared out of nowhere and looked like data corruption.
        //
        // Cleared AFTER the sidecar so it catches the tag from either source.
        if (album.trim() == kDownloadsAlbumTag) album = '';

        _cacheIndex[id] = CachedTrackInfo(
          songId: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown Artist' : artist,
          albumTitle: album,
          imageUrl: scImageUrl,
          localImagePath: localImagePath,
          filePath: path,
          fileSizeBytes: size,
          cachedAt: DateTime.now(),
          lastAccessedAt: DateTime.now(),
          isExplicitDownload: true, // treated as a download: offline + shown in Downloads
        );
        _invalidateUrlIndex();
        imported++;
        // Named, because the count alone posed a question it could NOT answer.
        //
        // Four of five launches in the 2026-08-30 transcript reported exactly
        // "imported 1 new file(s), pruned 1 missing" — a flip-flop that repeats
        // instead of settling, which means one entry is being re-keyed or
        // re-pathed between launches. Whether the imported file and the pruned
        // one are the SAME track is the whole question, and the count could not
        // say. The id says how it was keyed (a real videoId from a sidecar, or a
        // synthetic local_ one derived from the path), which is where a re-key
        // would show.
        print('＋ imported "$title" as $id ← $rel');
      }

      // Prune index entries whose explicit-download file was deleted on disk
      // (e.g. the user removed it from a file manager).
      final gone = _cacheIndex.entries
          .where((e) => e.value.isExplicitDownload && !File(e.value.filePath).existsSync())
          .map((e) => e.key)
          .toList();
      for (final id in gone) {
        // The path it expected is the other half of the flip-flop above: if it
        // differs from the path just imported for the same track, the file
        // moved; if it is identical, the file is there and the existence check
        // is what is wrong.
        print('－ pruned $id — no file at ${_cacheIndex[id]?.filePath}');
        _cacheIndex.remove(id);
        _invalidateUrlIndex();
      }

      if (imported > 0 || gone.isNotEmpty) {
        await _saveCacheIndex();
        onCacheUpdated?.call();
      }
      print("Device scan: imported $imported new file(s), pruned ${gone.length} missing.");
    } catch (e) {
      // Usually a permission issue reading another app's files on Android 11+.
      print("WARN: Device scan failed (grant 'All files access'?): $e");
    }
    return imported;
  }

  /// Mark a track as explicitly downloaded (prevents auto-deletion)
  void markAsExplicitDownload(String songId) {
    if (_cacheIndex.containsKey(songId)) {
      final info = _cacheIndex[songId]!;
      if (!info.isExplicitDownload) {
        _cacheIndex[songId] = info.copyWith(isExplicitDownload: true);
        _invalidateUrlIndex();
        _saveCacheIndex();
        print("Marked as explicit download: ${info.title}");
        onCacheUpdated?.call();
      }
    }
  }   

  bool shouldCacheTrack(String songId) {
    // Caching never stops when full. Cache size is strictly capped by LRU eviction
    // in _ensureCacheSpace() (which evicts the least-recently-accessed, non-pinned,
    // non-explicitly-downloaded track). Exactly like Spotify, the newest track
    // enters and the stalest track exits.
    return !isCached(songId);
  }
  

  List<Song> getAutoCachedTracks() {
  return _cacheIndex.values
      .where((info) => !info.isExplicitDownload &&
          !_pendingDeleteIds.contains(info.songId) &&
          File(info.filePath).existsSync())
      .map((info) => Song(
            id: info.songId,
            title: info.title,
            artist: info.artist,
            // PERSIST the NETWORK url, not the local cover path: these Songs flow into
              // play history / recents / the Home mosaic, which are cloud-backed up.
              // A local path dies on reinstall (files are wiped, not backed up) →
              // "cover art missing after restore" (#18). AuvyImage still resolves the
              // on-disk cover from this url via getLocalPathFromUrl, so offline art is
              // unaffected. Fall back to the local path only for locally-imported files
              // that have no network url at all.
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
            albumTitle: info.albumTitle,
          ))
      .toList()
    ..sort((a, b) => _cacheIndex[b.id]!.lastAccessedAt.compareTo(_cacheIndex[a.id]!.lastAccessedAt));
  }

  /// Stream-based caching: Start playing immediately while downloading in background
  Future<String?> getStreamingCachePath(Song song, String streamUrl, {String? userAgent}) async {
    if (!_isInitialized) await initialize();
    
    // If already cached, return immediately
    if (isCached(song.id)) {
      return getCachedPath(song.id);
    }
    
    try {
      final fileName = '${song.id}_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final filePath = '${_cacheDir!.path}/$fileName';

      // Start downloading in background
      _downloadInBackground(song, streamUrl, filePath, userAgent);
      
      // Return stream URL immediately for playback
      return streamUrl;
    } catch (e) {
      print("WARN: Streaming cache setup failed: $e");
      return streamUrl; // Fallback to direct stream
    }
  }

  /// Background download with progress tracking
  Future<void> _downloadInBackground(Song song, String streamUrl, String filePath, String? userAgent) async {
    // Created outside the try so the failure path can close it too — a mid-
    // stream timeout used to leak the client (and its socket) on every retry.
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(streamUrl));
      if (userAgent != null) request.headers['User-Agent'] = userAgent;
      
      final response = await client.send(request).timeout(const Duration(minutes: 5));
      
      if (response.statusCode == 200) {
        final file = File(filePath);
        final sink = file.openWrite();
        
        int downloaded = 0;
        final totalSize = response.contentLength ?? 0;
        
        await for (var chunk in response.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          
          // Log progress every 1MB
          if (downloaded % (1024 * 1024) < 8192) {
            final percent = totalSize > 0 ? (downloaded / totalSize * 100).toStringAsFixed(1) : '?';
            print("Downloading ${song.title}: $percent%");
          }
        }
        
        await sink.close();
        client.close();
        
        // Update cache index after successful download
        final fileSizeBytes = await file.length();
        _cacheIndex[song.id] = CachedTrackInfo(
          songId: song.id,
          title: song.title,
          artist: song.artist,
          albumTitle: song.albumTitle,
          imageUrl: song.image,
          localImagePath: '',
          filePath: filePath,
          fileSizeBytes: fileSizeBytes,
          cachedAt: DateTime.now(),
          lastAccessedAt: DateTime.now(),
          isExplicitDownload: false,
        );
        _invalidateUrlIndex();
        
        await _saveCacheIndex();
        print(" Background download complete: ${song.title}");
        onCacheUpdated?.call();
      }
      
    } catch (e) {
      print("ERROR: Background download failed for ${song.title}: $e");
    } finally {
      client.close();
    }
  }

  /// Prefetch upcoming queue tracks intelligently
  Future<void> prefetchQueue(List<Song> queueSongs, {
    required Map<String, double> artistAffinities,
    int maxPrefetch = 1, // Default to 1
    bool isWifi = true,  // Pass connectivity status to be smarter
  }) async {
    if (!_isInitialized) await initialize();
    if (_isPrefetching) return; // Prevent concurrent prefetch loops
    
    _isPrefetching = true;
    
    try {
      // Filter songs that need caching
      final songsToPrefetch = <({Song song, double priority})>[];

      // The CALLER decides the window (maxPrefetch) — the rolling queue-download
      // (player_playback._fillPrefetchWindow) passes the exact next-N uncached
      // tracks it wants on disk so the whole session plays locally, immune to the
      // screen-off googlevideo 403 storm. Scan the provided list up to that many.
      final scanLimit = maxPrefetch.clamp(1, 30);

      for (final song in queueSongs.take(scanLimit)) {
        if (isCached(song.id) || !shouldCacheTrack(song.id)) continue;
        
        // Calculate priority score
        double priority = 0.0;
        
        // Higher priority for songs earlier in queue
        final queuePosition = queueSongs.indexOf(song);
        priority += (10 - queuePosition) * 2.0;
        
        // Higher priority for favorite artists
        final artistAffinity = artistAffinities[song.artist] ?? 0.0;
        priority += artistAffinity;
        
        songsToPrefetch.add((song: song, priority: priority));
      }
      
      // Sort by priority
      songsToPrefetch.sort((a, b) => b.priority.compareTo(a.priority));
      
      // Prefetch top priority songs — honour the caller's window on ANY network
      // (the caller already picks a smaller window on mobile). Screen-off
      // reliability needs several tracks on disk, not just one.
      final toPrefetch = songsToPrefetch.take(maxPrefetch).toList();
      
      if (toPrefetch.isEmpty) return;
      
      print("Prefetching ${toPrefetch.length} queue tracks (Wi-Fi: $isWifi)...");
      
      // Download sequentially instead of parallel to prevent bandwidth choking
      // which causes the current playing track to stutter
      for (final item in toPrefetch) {
        try {
          final audioService = AudioService();
          final streamData = await audioService.getStreamWithFallback(
            item.song.id,
            item.song.title,
            item.song.artist,
          );
          
          if (streamData != null) {
            await cacheTrack(
              item.song,
              streamData['url']!,
              userAgent: streamData['user_agent'],
            );
          }
        } catch (e) {
          print("WARN: Prefetch failed for ${item.song.title}: $e");
        }
        // Small delay between sequential prefetches
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      print(" Prefetch complete");
    } finally {
      _isPrefetching = false;
    }
  }
    
  Future<List<bool>> batchCacheTrack(
    List<({Song song, String streamUrl, String? userAgent})> batch,
    {int parallelDownloads = 3, 
     bool isExplicitDownload = false,
     String downloadType = 'Single',
     String? collectionName,
     /// Called with the number of tracks finished so far, after each chunk.
     /// Exists so a caller can drive a progress indicator: without it the only
     /// signal was the Future completing, i.e. 0% then 100%.
     void Function(int done, int total)? onProgress,
    }
  ) async {
    if (!_isInitialized) await initialize();
    
    final results = <bool>[];
    
    for (int i = 0; i < batch.length; i += parallelDownloads) {
      final chunk = batch.sublist(i, (i + parallelDownloads).clamp(0, batch.length));
      
      final chunkResults = await Future.wait(
        chunk.map((item) => cacheTrack(
          item.song,
          item.streamUrl,
          isExplicitDownload: isExplicitDownload,
          userAgent: item.userAgent,
          downloadType: downloadType,     // Pass it down
          collectionName: collectionName, // Pass it down
        ).catchError((e) {
          print("WARN: Batch Item Failure for ${item.song.title}: $e");
          return false; 
        }))
      );
      results.addAll(chunkResults);
      onProgress?.call(results.length, batch.length);
    }
    final ok = results.where((r) => r).length;
    print('batch download complete: $ok/${batch.length} saved'
        "${collectionName != null ? ' for \"$collectionName\"' : ''}");
    return results;
  }

  /// Get total cache size in bytes
  Future<int> getCacheSize() async {
    if (!_isInitialized) await initialize();
    return _getTotalCacheSize();
  }

  /// Clear oldest cached tracks (keeps most recently accessed)
  Future<void> clearOldestCache({int keepRecent = 50}) async {
    if (!_isInitialized) await initialize();
    
    // Get all non-explicit, non-pinned downloads sorted by access time (oldest first)
    final candidates = _cacheIndex.values
        .where((info) => !info.isExplicitDownload && !pinnedSongIds.contains(info.songId))
        .toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    // Calculate how many to remove (keep only the most recent)
    final totalTracks = candidates.length;
    final toRemove = totalTracks > keepRecent ? totalTracks - keepRecent : 0;
    
    if (toRemove > 0) {
      print("Clearing $toRemove oldest cached tracks (keeping $keepRecent recent)");
      
      for (var i = 0; i < toRemove; i++) {
        removeFromCache(candidates[i].songId);
      }
      
      print(" Removed $toRemove tracks, freed ${(_getFreedSpace(candidates.take(toRemove).toList()) / 1024 / 1024).toStringAsFixed(2)}MB");
    }
  }

  /// Calculate space that would be freed by removing tracks
  int _getFreedSpace(Iterable<CachedTrackInfo> tracks) {
    return tracks.fold(0, (sum, info) => sum + info.fileSizeBytes);
  }

  /// Proactively auto-cache the user's most-played tracks (their "My Top 50")
  /// so the number of cached tracks meets-or-exceeds My Top 50 — the behaviour
  /// the user expects. Also pins them so they won't be evicted afterwards.
  /// Conservative: caps the work per pass and only runs when allowed (the caller
  /// gates on Wi-Fi / data-saver). Skips anything already cached or downloaded.
  bool _isCachingTop = false;
  Future<void> ensureTopTracksCached(List<Song> topTracks, {int maxPerPass = 6}) async {
    if (!_isInitialized) await initialize();
    if (_isCachingTop) return;
    _isCachingTop = true;
    try {
      // Pin every top track up-front so nothing evicts them (even ones already
      // cached). pinnedSongIds is also refreshed by the caller.
      pinnedSongIds = {...pinnedSongIds, ...topTracks.map((s) => s.id)};

      int cachedThisPass = 0;
      final audio = AudioService();
      for (final song in topTracks) {
        if (cachedThisPass >= maxPerPass) break;
        if (song.id.isEmpty || song.id.startsWith('http')) continue;
        if (isCached(song.id) || isExplicitlyDownloaded(song.id)) continue;
        if (!shouldCacheTrack(song.id)) continue;
        try {
          final stream = await audio.getStreamWithFallback(song.id, song.title, song.artist);
          final url = stream?['url'];
          if (url != null && url.isNotEmpty) {
            final ok = await cacheTrack(song, url, userAgent: stream?['user_agent']);
            if (ok) cachedThisPass++;
          }
        } catch (e) {
          print("WARN: Top-track cache failed for ${song.title}: $e");
        }
        // Space out to avoid choking playback bandwidth.
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (cachedThisPass > 0) print("Cached $cachedThisPass top track(s)");
    } finally {
      _isCachingTop = false;
    }
  }

  /// Get detailed cache statistics
  Map<String, dynamic> getDetailedCacheStats() {
    final autoCachedItems = _cacheIndex.values.where((info) => !info.isExplicitDownload).toList();
    final downloadedItems = _cacheIndex.values.where((info) => info.isExplicitDownload).toList();
    
    final autoCacheSize = autoCachedItems.fold(0, (sum, info) => sum + info.fileSizeBytes);
    final downloadedSize = downloadedItems.fold(0, (sum, info) => sum + info.fileSizeBytes);
    final totalSize = _getTotalCacheSize();
    
    return {
      'autoCachedTracks': autoCachedItems.length,
      'downloadedTracks': downloadedItems.length,
      'totalTracks': _cacheIndex.length,
      'autoCacheSizeMB': (autoCacheSize / 1024 / 1024).toStringAsFixed(2),
      'downloadedSizeMB': (downloadedSize / 1024 / 1024).toStringAsFixed(2),
      'totalSizeMB': (totalSize / 1024 / 1024).toStringAsFixed(2),
      'maxSizeMB': maxCacheSizeMB,
      // Share of the CACHE BUDGET, so it measures the auto-cache alone. Against
      // the total it read past 100% as soon as downloads outgrew the limit, which
      // described nothing: the limit does not govern downloads.
      'usagePercent':
          ((autoCacheSize / (maxCacheSizeMB * 1024 * 1024)) * 100).toStringAsFixed(1),
    };
  }

  /// Cache a track (Audio + Lyrics + Metadata + Cover Art)
  /// Is [path] inside the public downloads folder (`/Music/Auvy`)?
  ///
  /// Used to tell a real download from an auto-cache file that merely got flagged
  /// as one. Compared on the directory prefix rather than on `isExplicitDownload`
  /// because that flag is exactly what could be wrong.
  bool _isInDownloadsDir(String path) {
    final dir = _downloadDir?.path;
    if (dir == null || dir.isEmpty) return false;
    return path.replaceAll('\\', '/').startsWith(dir.replaceAll('\\', '/'));
  }

  /// Where an explicit download belongs in the public folder, creating the
  /// subdirectory. Extracted so the "already cached, needs promoting" path and
  /// the "fresh download" path can't compute it differently — the whole bug was
  /// one of them not computing it at all.
  Future<String> _publicDownloadPath(
    Song song, {
    String downloadType = 'Single',
    String? collectionName,
    int? trackNumber,
  }) async {
    final safeTitle = _sanitizeSegment(song.title);
    final safeArtist = _sanitizeSegment(song.artist);

    String subFolder = 'Singles';
    if (song.albumTitle == 'Podcast') {
      final safePodcastName =
          safeArtist.isNotEmpty ? safeArtist : 'Unknown Podcast';
      subFolder = 'Podcasts/$safePodcastName';
    } else if (downloadType == 'Playlist' && collectionName != null) {
      subFolder = 'Playlists/${_sanitizeSegment(collectionName)}';
    } else if (downloadType == 'Album' && collectionName != null) {
      subFolder = 'Albums/${_sanitizeSegment(collectionName)}';
    } else if (downloadType == 'Single') {
      subFolder = 'Singles';
    } else if (song.albumTitle.isNotEmpty && song.albumTitle != 'null') {
      subFolder = 'Albums/${_sanitizeSegment(song.albumTitle)}';
    }

    final targetDir = Directory('${_downloadDir!.path}/$subFolder');
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    // Filename convention
    //
    // Album/playlist downloads get a zero-padded track number first, singles
    // don't. This is the convention Spotify's offline export, Plex, Jellyfin and
    // beets all use, and it exists for one reason: file managers and car stereos
    // sort ALPHABETICALLY, so "10 Track" must not land between "1 Track" and
    // "2 Track". Two digits because a padded number only sorts correctly if every
    // name in the folder is padded to the same width.
    //
    // Singles stay "Artist - Title" so a folder of unrelated tracks groups by
    // artist, which is the only useful ordering when there is no album to follow.
    // PROVISIONAL extension. The real container is only knowable once bytes are
    // on disk — the download may fall back to Opus/WebM when a track has no MP4
    // audio, and a play-cache promotion brings whatever was streamed. So the file
    // is named `.m4a` to start with and [_retitleToRealContainer] corrects it
    // afterwards. Do not treat this as the final name.
    const ext = 'm4a';
    final bool numbered = subFolder.startsWith('Albums/') ||
        subFolder.startsWith('Playlists/');
    if (numbered && trackNumber != null && trackNumber > 0) {
      final n = trackNumber.toString().padLeft(2, '0');
      // Artist included even inside an album folder: compilations and features
      // mean "02 Title" alone can be ambiguous once the file is moved elsewhere.
      return '${targetDir.path}/$n $safeArtist - $safeTitle.$ext';
    }
    return '${targetDir.path}/$safeArtist - $safeTitle.$ext';
  }

  /// Recursively deletes [relative] under the download folder, but ONLY if it
  /// really resolves to somewhere inside it.
  ///
  /// The last line of defence before a recursive delete.
  ///
  /// Sanitising the name is the primary protection; this is what makes a hole in
  /// that sanitiser survivable. `p.normalize` collapses `..` BEFORE the check, so
  /// `Albums/../..` is compared as the resolved path rather than the literal
  /// string, which is the whole trick, since a literal `contains(root)` test
  /// passes happily for a path that walks straight back out of it.
  ///
  /// `p.isWithin` is strictly inside: it returns false for the root itself, so a
  /// name that collapses to nothing can never wipe every download.
  void _deleteIfInsideDownloads(String relative) {
    final root = p.normalize(_downloadDir!.absolute.path);
    final target = p.normalize(p.join(root, relative));
    if (!p.isWithin(root, target)) {
      print("STOP: refused to delete outside the download folder: $target");
      return;
    }
    final dir = Directory(target);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Makes one path SEGMENT safe on Android, Windows and macOS at once.
  ///
  /// The old inline `replaceAll(RegExp(r'[\\/:*?"<>|]'), '')` missed three things
  /// that produce real breakage:
  ///  • A TRAILING DOT OR SPACE — legal on Android, silently rejected on Windows,
  ///    so a track called "Yeah." became an unopenable file the moment the folder
  ///    was copied to a PC (which is the whole point of downloading to /Music).
  ///  • Control characters, which some file managers refuse to display.
  ///  • Runs of whitespace, which turn into ugly double spaces in the name.
  /// It also left the segment able to be empty, yielding names like " - .m4a".

  /// Whether a finished download actually contains the whole track.
  ///
  /// "more than a megabyte" is NOT a completeness test
  ///
  /// THE BUG THIS FIXES, and it is the sibling of the native short-promotion one
  /// found beside it. Success was `fileSizeBytes > 1024 * 1024` — a floor, not a
  /// comparison. A four-megabyte track truncated at two megabytes by a dropped
  /// connection cleared that bar comfortably and was registered as a COMPLETE
  /// cached track.
  ///
  /// Nothing downstream could catch it either: the zero-byte guards test
  /// `> 0`, and a truncated file is not zero. So every later play of that track
  /// stopped early, from local cache, with nothing anywhere to explain it — and
  /// re-downloading was never attempted, because the index said the file was
  /// already there and whole.
  ///
  /// The expected length is known twice over: the response's own
  /// `content-length`, and `clen=` in the googlevideo URL (which this method
  /// already parses to bound its Range request). Either one turns the floor into
  /// an equality. The floor survives only as the fallback for a response that
  /// declares no length at all, where there is genuinely nothing to compare to.
  @visibleForTesting
  static bool downloadLooksComplete(
      String title, int onDisk, int declaredLength, String? clenParam) {
    final fromUrl = int.tryParse(clenParam ?? '') ?? 0;
    final expected = declaredLength > 0 ? declaredLength : fromUrl;
    if (expected <= 0) {
      // No length to check against — keep the old floor rather than accepting
      // anything, and say so, because a stream with no declared length is
      // itself worth knowing about.
      final ok = onDisk > 1024 * 1024;
      if (!ok) {
        print('WARN: "$title": ${onDisk ~/ 1024}KB downloaded and no length was '
            'declared — too small to trust, treating as incomplete');
      }
      return ok;
    }
    if (onDisk >= expected) return true;

    // A tolerance, because the first version rejected real downloads
    //
    // Caught on device within minutes of shipping the strict version:
    //
    //"[Q&A+] What Percentage of The Universe's Life…" TRUNCATED:
    //      27671KB of 27678KB
    //
    // Seven kilobytes short of twenty-seven megabytes — 0.025%, about half a
    // second of audio. That is a podcast host declaring marginally more than it
    // sends, not a truncation, and refusing it meant the episode did not cache
    // at all. Strictness that discards a whole download to avoid losing half a
    // second of it is worse than the bug it was written for.
    //
    // The failure this exists to catch is nothing like that shape: a dropped
    // connection leaves a FRACTION of the file — the reported case was 2 MB of
    // 4 MB. So the test is proportional, with an absolute cap so the allowance
    // cannot grow silly on a large file:
    //
    //   • within 0.5% AND within 128 KB → a short tail, accepted and logged
    //   • anything more                 → truncated, refused
    //
    // 2 MB of 4 MB fails both. 7 KB of 27 MB passes both.
    final short = expected - onDisk;
    final tolerated = short <= (expected * 0.005) && short <= 128 * 1024;
    if (tolerated) {
      print('"$title": ${short ~/ 1024}KB short of the declared '
          '${expected ~/ 1024}KB (${(short / expected * 100).toStringAsFixed(3)}%) '
          '— accepted as a short tail, not a truncation');
      return true;
    }
    print('WARN: "$title" TRUNCATED: ${onDisk ~/ 1024}KB of '
        '${expected ~/ 1024}KB — not registering it as cached, or every play '
        'from cache would stop early');
    return false;
  }

  /// The size the FILESYSTEM reports, or 0 if there is no readable file.
  ///
  /// Exists because several paths used to trust a recorded size instead: the
  /// cache index, a native promotion result, a download progress total. Each
  /// was capable of claiming bytes that were not there, and each produced the
  /// same visible outcome — a track the index calls cached that plays silence.
  static Future<int> _actualSizeOf(String path) async {
    if (path.isEmpty) return 0;
    try {
      final f = File(path);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }
  /// The folder segment [raw] becomes on disk.
  ///
  /// Exposed because reachability is decided by comparing a DOWNLOAD's folder
  /// name against LIBRARY titles, and the folder name has been through the
  /// sanitiser while the title has not. Comparing them raw silently fails for
  /// any name containing a character this strips, which is most punctuation, and
  /// podcast titles are full of it.
  static String folderNameFor(String raw) => _sanitizeSegment(raw);

  static String _sanitizeSegment(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Windows rejects names ending in '.' or ' '.
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    // Keep well clear of the 255-byte per-segment limit once the number,
    // separator and extension are added.
    if (s.length > 80) s = s.substring(0, 80).trim();
    return s.isEmpty ? 'Unknown' : s;
  }

  /// Moves a file, falling back to copy+delete.
  ///
  /// `rename` fails with EXDEV across filesystems, and that is exactly the move
  /// being made here: app-private storage → public /Music. So the copy fallback
  /// is the path that will normally run, not an edge case.
  Future<bool> _movePreservingBytes(String from, String to) async {
    try {
      final src = File(from);
      if (!src.existsSync()) return false;
      if (from == to) return true;
      try {
        await src.rename(to);
        return true;
      } catch (_) {
        await src.copy(to);
        // Only unlink the source once the copy is verifiably there — losing the
        // user's only copy of a track to a failed move is unacceptable.
        if (File(to).existsSync() &&
            await File(to).length() == await src.length()) {
          try {
            await src.delete();
          } catch (_) {}
          return true;
        }
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// The file extension that matches what the bytes ACTUALLY are, read from the
  /// container's magic number. Null when nothing recognisable is there.
  ///
  /// This exists because the filename used to lie, AND two features broke on it.
  ///
  /// Downloads were all named `.m4a`, but YouTube's best audio is Opus in a WebM
  /// container, so a download's first sixteen bytes read `1a45dfa3`, the EBML
  /// magic, not `ftyp`. Two consequences, both silent:
  ///
  ///  • EMBEDDED TAGS AND COVER ART NEVER LANDED. MetadataGod writes MP4 atoms;
  ///    a WebM file rejects them, so every download logged "container doesn't
  ///    support them" and arrived with no title, artist or artwork.
  ///  • ANDROID NEVER INDEXED THE FILE. The media scanner trusts the container
  ///    over the name, and a WebM claiming to be MP4 is refused, so downloads
  ///    were invisible to every other music app and file manager on the phone.
  ///
  /// Sniffing the bytes rather than trusting the response's `mimeType` is
  /// deliberate: it is also correct for files promoted out of the native
  /// play-cache, where no mime string was ever seen, and it cannot disagree with
  /// what is on disk.
  static Future<String?> _sniffAudioExtension(File f) async {
    try {
      final raf = await f.open();
      List<int> head;
      try {
        head = await raf.read(64);
      } finally {
        await raf.close();
      }
      if (head.length < 12) return null;
      bool at(int off, List<int> sig) {
        if (off + sig.length > head.length) return false;
        for (var i = 0; i < sig.length; i++) {
          if (head[off + i] != sig[i]) return false;
        }
        return true;
      }

      // Matroska/WebM. YouTube's Opus arrives here.
      if (at(0, const [0x1A, 0x45, 0xDF, 0xA3])) return 'webm';
      // ISO-BMFF: the box length comes first, so 'ftyp' sits at offset 4.
      if (at(4, const [0x66, 0x74, 0x79, 0x70])) return 'm4a';
      if (at(0, const [0x66, 0x4C, 0x61, 0x43])) return 'flac';
      if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
          at(8, const [0x57, 0x41, 0x56, 0x45])) return 'wav';
      // Ogg: Opus and Vorbis share the container, and the codec's identification
      // header names which — worth distinguishing because `.opus` is the tagged,
      // playable-everywhere spelling while `.ogg` implies Vorbis to some players.
      if (at(0, const [0x4F, 0x67, 0x67, 0x53])) {
        for (var i = 0; i + 8 <= head.length; i++) {
          if (at(i, const [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64])) {
            return 'opus';
          }
        }
        return 'ogg';
      }
      // ID3v2, or a bare MPEG frame sync.
      if (at(0, const [0x49, 0x44, 0x33])) return 'mp3';
      if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return 'mp3';
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Renames [path] so its extension matches its real container, returning the
  /// path the bytes now live at (unchanged if it was already right, or if the
  /// rename fails — a wrongly-named file still plays, so this must never be able
  /// to lose a download).
  static Future<String> _retitleToRealContainer(String path) async {
    final f = File(path);
    if (!f.existsSync()) return path;
    final real = await _sniffAudioExtension(f);
    if (real == null) return path;
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    final current = dot > slash ? path.substring(dot + 1).toLowerCase() : '';
    if (current == real) return path;
    final target = '${dot > slash ? path.substring(0, dot) : path}.$real';
    try {
      // A re-download of the same track lands on its own previous file; the new
      // bytes are the ones asked for, so replacing is correct.
      final existing = File(target);
      if (existing.existsSync() && target != path) await existing.delete();
      await f.rename(target);
      return target;
    } catch (_) {
      return path;
    }
  }

  Future<bool> cacheTrack(Song song, String streamUrl, {
    bool isExplicitDownload = false, 
    String? userAgent,
    String downloadType = 'Single',
    String? collectionName,
    /// 1-based position within an album/playlist download, used to prefix the
    /// filename so a file manager sorts the folder in playing order. Null for a
    /// single track — Song carries no track number, so this comes from the batch
    /// rather than being invented here.
    int? trackNumber,
  }) async {
    if (!_isInitialized) await initialize();
    if (!isExplicitDownload && isExplicitlyDownloaded(song.id)) return true;
    if (!isExplicitDownload && !shouldCacheTrack(song.id)) return false;

    try {
      String filePath;
      int fileSizeBytes = 0;
      String localImagePath = '';

      // Should an explicit download reuse the cached bytes?
      //
      // Normally yes, and that is the point of the promotion model: the track you
      // just listened to is already on disk, so downloading it costs no network
      // at all.
      //
      // The exception is a cached file in a container that cannot hold tags —
      // Opus in WebM, which is what streaming picks because it sounds better. It
      // is the COMMON case, because auto-cache keeps what you finished listening
      // to and downloading a song you just played is the normal way to reach this
      // code. Reusing it would hand back a file with no title, artist or cover
      // art, which is precisely what the user asked to stop happening.
      //
      // So a user download re-fetches as MP4 instead. That costs one track's
      // worth of data, deliberately, and only when the user explicitly asked for
      // a file. The url is already resolved by the caller, so there is no extra
      // round trip to find it. Auto-cache never takes this path.
      bool redownloadForTags = false;
      // The old copy, to be removed once the replacement is safely on disk —
      // never before, so a failed re-fetch cannot cost the user the track they
      // already had.
      String? supersededPath;
      if (isExplicitDownload && streamUrl.isNotEmpty && isCached(song.id)) {
        final cachedPath = _cacheIndex[song.id]!.filePath;
        final f = File(cachedPath);
        if (f.existsSync()) {
          final container = await _sniffAudioExtension(f);
          redownloadForTags = container != null && container != 'm4a';
          if (redownloadForTags) supersededPath = cachedPath;
        }
      }

      // 1. Prepare file path
      if (isCached(song.id) && !redownloadForTags) {
        final info = _cacheIndex[song.id]!;
        filePath = info.filePath;
        fileSizeBytes = info.fileSizeBytes;

        // The index is a claim; the file is the fact
        //
        // This trusted `info.fileSizeBytes` and carried it all the way to the
        // success print, so an entry recording zero bytes was re-announced as a
        // perfectly good cached track. From the 2026-08-28 device transcript:
        //
        //   09:56:25.133 Cached: Save Your Tears (0.00MB)
        //   09:57:18.534 Cached: Save Your Tears (0.00MB)
        //   10:00:27.277 Cached: Save Your Tears (3.45MB)
        //
        // Five of about twelve cache completions that day were 0.00MB, across
        // three different tracks. The index then claims the track is on disk, so
        // playback prefers the local copy and hands the decoder an empty file.
        //
        // The promotion path already learned this lesson (see the note further
        // down about `promoted == true`); this path never did, which is why the
        // symptom survived that fix. Both now check the same way: ask the
        // filesystem.
        final onDisk = await _actualSizeOf(filePath);
        if (onDisk <= 0) {
          print('WARN: cache index claims ${song.title} is cached at $filePath '
              '(${info.fileSizeBytes} B) but the file is missing or EMPTY — '
              're-downloading and dropping the stale entry');
          _cacheIndex.remove(song.id);
          _invalidateUrlIndex();
          fileSizeBytes = 0;
          // Fall through to the download branch below by clearing the path, so
          // a fresh one is chosen rather than writing over a known-bad file.
          filePath = '';
        } else if (onDisk != info.fileSizeBytes) {
          // Not fatal, but the index is the thing eviction does its arithmetic
          // with, so a wrong number there means the cap is enforced against a
          // fiction. Corrected quietly and said out loud once.
          print('cache index size corrected for ${song.title}: '
              '${info.fileSizeBytes} B → $onDisk B');
          fileSizeBytes = onDisk;
        }

        // THE BUG THAT MADE DOWNLOADS NEVER APPEAR IN /Music/Auvy.
        //
        // This branch reused the EXISTING path, and for an already-auto-cached
        // track that path is the app-PRIVATE cache directory. Downloading such a
        // track therefore flipped `isExplicitDownload` to true and did nothing
        // else: the download task below is gated on `!isCached(song.id)`, so no
        // file was written, and the public downloads folder stayed empty.
        //
        // Because the auto-cache fills up as you listen, virtually every track a
        // user tries to download is already cached, so in practice downloads
        // essentially never reached /Music/Auvy, while the UI reported success
        // and the track showed a "downloaded" icon.
        //
        // The bytes are already on disk, so this is a MOVE, not a re-download:
        // no network, no data, instant.
        if (isExplicitDownload && !_isInDownloadsDir(filePath)) {
          final target = await _publicDownloadPath(song,
              downloadType: downloadType,
              collectionName: collectionName,
              trackNumber: trackNumber);
          final moved = await _movePreservingBytes(filePath, target);
          if (moved) {
            filePath = target;
            try {
              fileSizeBytes = await File(target).length();
            } catch (_) {}
          }
        }
      } else {
        // A re-fetch for tags replaces bytes that are already accounted for, so
        // it is not asking the cache for new room.
        if (!redownloadForTags) {
          await _ensureCacheSpace(currentPlayingId: song.id);
        }

        if (isExplicitDownload) {
          filePath = await _publicDownloadPath(song,
              downloadType: downloadType,
              collectionName: collectionName,
              trackNumber: trackNumber);
        } else {
          // Internal background cache
          final fileName = '${song.id}_${DateTime.now().millisecondsSinceEpoch}.m4a';
          filePath = '${_cacheDir!.path}/$fileName';
        }
      }

      // OPTIMIZATION: Use connection pool + parallel downloads
      final pool = HttpPool();
      
      await Future.wait([
        // Task A: Audio Download (using connection pool)
        (() async {
          if (!isCached(song.id) || redownloadForTags) {
            // 0-NETWORK PROMOTION FIRST (cache what you played): if
            // the WHOLE track is already in the native media3 play-cache (you
            // streamed it end-to-end), copy those exact bytes into the Cached
            // folder instead of re-downloading over HTTP. No second download, no
            // data cost, works on any network. Falls through to HTTP only when
            // the play-cache doesn't hold the full track yet.
            //
            // SKIPPED WHEN RE-FETCHING FOR TAGS. The play-cache holds the bytes
            // that were STREAMED, which is the untaggable Opus this download is
            // trying to get away from — promoting it would quietly undo the whole
            // point and hand back the same bare file.
            try {
              final promo = redownloadForTags
                  ? null
                  : await NativeAudioEngine.promoteFromPlayCache(song.id, filePath);
              if (promo != null && promo['promoted'] == true) {
                fileSizeBytes = (promo['bytes'] as num?)?.toInt() ?? 0;
                if (fileSizeBytes <= 0) {
                  try { fileSizeBytes = await File(filePath).length(); } catch (_) {}
                }
                // A promotion that produced no bytes is a failed promotion.
                //
                // `promoted == true` was taken at face value, so an EMPTY file
                // was registered as a perfectly good cached track:
                //
                // Cached: Save Your Tears (0.00MB)
                //
                // That is worse than not caching at all. The index then claims the
                // track is on disk, so playback prefers the local copy, hands the
                // decoder a zero-byte file, and the track dies mid-play, which is
                // the reported "it skipped mid-track to the next one". It also
                // burns an index slot that eviction can never usefully reclaim,
                // because it accounts for zero bytes.
                //
                // Delete it and fall through to a real download instead of
                // returning success.
                if (fileSizeBytes <= 0) {
                  try { await File(filePath).delete(); } catch (_) {}
                  print("WARN: play-cache promotion for ${song.title} produced an "
                      "EMPTY file — discarding it and downloading properly");
                } else {
                  _activeDownloads.remove(song.id);
                  _downloadProgressController.add(Map.from(_activeDownloads));
                  return; // promoted from play-cache — skip the HTTP download
                }
              }
            } catch (_) {}
            // Promotion-only callers (e.g. the track-end auto-cache) pass an
            // empty url — nothing to HTTP-download, so stop here.
            if (streamUrl.isEmpty) return;
            int retryCount = 0;
            bool success = false;
            // Explicit user downloads retry (3×) since the user asked for the
            // file. Background AUTO-CACHE gets a SINGLE attempt — a failed
            // auto-cache must never re-download the whole file from byte 0
            // repeatedly (that was a silent data drain on a flaky CDN link).
            final int maxAttempts = isExplicitDownload ? 3 : 1;
            while (retryCount < maxAttempts && !success) {
              // Fresh (non-pool) retry clients must be closed or every failed
              // attempt leaks a socket; pool clients are shared — never closed.
              http.Client? freshClient;
              try {
                // For retries, bypass the pool to ensure a fresh, non-poisoned connection
                final client = retryCount == 0 ? pool.getClient() : (freshClient = http.Client());
                final request = http.Request('GET', Uri.parse(streamUrl));
                
                request.headers['User-Agent'] = userAgent ?? 'Mozilla/5.0';
                request.headers['Connection'] = 'keep-alive';
                // googlevideo 403s open-ended ranges (bytes=0-); bound to the
                // content length parsed from the URL so the download succeeds.
                final clen = RegExp(r'[?&]clen=(\d+)').firstMatch(streamUrl)?.group(1);
                if (clen != null) {
                  request.headers['Range'] = 'bytes=0-${int.parse(clen) - 1}';
                }

                final response = await client.send(request).timeout(const Duration(seconds: 45));

              if (response.statusCode == 200 || response.statusCode == 206) {
                final file = File(filePath);
                final sink = file.openWrite();
                
                _activeDownloads[song.id] = 0.0;
                _downloadProgressController.add(Map.from(_activeDownloads));
                
                final contentLength = response.contentLength ?? 0;
                int downloaded = 0;
                
                try {
                  await for (var chunk in response.stream) {
                    sink.add(chunk);
                    downloaded += chunk.length;
                    
                    if (contentLength > 0) {
                      _activeDownloads[song.id] = downloaded / contentLength;
                      _downloadProgressController.add(Map.from(_activeDownloads));
                    }
                  }
                  
                  _activeDownloads.remove(song.id);
                  _downloadProgressController.add(Map.from(_activeDownloads));
                  
                  fileSizeBytes = await file.length();
                  success = downloadLooksComplete(
                      song.title, fileSizeBytes, contentLength, clen);
                  } finally {
                    await sink.close(); // Ensure sink is closed even if pipe fails
                  }

                  fileSizeBytes = await file.length();
                  success = downloadLooksComplete(
                      song.title, fileSizeBytes, contentLength, clen);
                }
              } catch (e) {
                retryCount++;
                print("WARN: Download Attempt $retryCount failed for ${song.title}: $e");
                if (retryCount >= maxAttempts) rethrow;
                await Future.delayed(Duration(seconds: 2 * retryCount)); // Backoff delay
              } finally {
                freshClient?.close();
              }
            }
          }
        })(),

        // Task B: Cover Art Download (using connection pool)
        (() async {
          // Cache each track's OWN cover (keyed by song.id). We deliberately do
          // NOT reuse another track's art via getAlbumCoverArt(albumTitle): tracks
          // that share an album title — or a generic/empty one — would all get the
          // FIRST cached track's cover, which is the "played tracks all show the
          // first track's artwork" and "wrong-version cover" bug. Per-track covers
          // are tiny and always match the exact song that was played.
          if (song.image.isNotEmpty && song.image.startsWith('http')) {
            try {
              final client = pool.getClient();
              final imgRes = await client.get(Uri.parse(song.image))
                  .timeout(const Duration(seconds: 8));
                  
              if (imgRes.statusCode == 200) {
                final imgFile = File('${_cacheDir!.path}/cover_${song.id}.jpg');
                await imgFile.writeAsBytes(imgRes.bodyBytes);
                localImagePath = imgFile.absolute.path;
              }
            } catch (e) {
              localImagePath = song.image;
            }
          } else {
            localImagePath = song.image;
          }
        })(),

        // Task C: Lyrics Download
        (() async {
          // Not for spoken word
          //
          // Caught on device as four of these per session:
          //
          // Failed to save lyrics: PathNotFoundException: Cannot open
          //      file, path = '…/lyrics_https://c10.patreonusercontent.com/4/
          //      patreon-media/p/post/…m4a?token-hash=…json'
          //
          // Two problems in one line. A podcast episode's id IS its enclosure
          // URL, so the filename below became a URL with slashes and query
          // parameters in it — never a valid path, so every save threw.
          //
          // The deeper waste is that it looked at all: a full multi-source
          // lyrics scan, per episode, for something that has no lyrics and never
          // will. The scan is several requests across several providers, and the
          // only reason it was invisible is that its failure was swallowed into a
          // print nobody was reading.
          //
          // Song.isSpokenWord covers podcasts AND audiobook chapters, which have
          // exactly the same non-relationship with lyrics.
          if (song.isSpokenWord) return;
          try {
            final lyrics = await LyricsService().getLyrics(
              song.title, 
              song.artist, 
              album: song.albumTitle, 
              songId: song.id
            ).timeout(const Duration(seconds: 8));
            
            if (lyrics != null) {
              await saveLyrics(song.id, lyrics.toJson());
            }
          } catch (e) {
            print("WARN: Lyrics skipped: $e");
          }
        })(),
      ]);

      // A download that produced nothing stops here
      //
      // THE ROOT CAUSE OF `Cached: <title> (0.00MB)`, caught live on device
      // by the registration guard further down:
      //
      // REFUSING to register X (feat. Future) as cached — …m4a is missing
      //   or empty after the write (index said 0 B)
      //
      // There was no failure exit at all. The retry loop above sets its local
      // `success` only when the file exceeds 1 MB, and that flag is declared
      // INSIDE the download closure, so nothing outside it ever consulted the
      // result. A download that fetched zero bytes fell straight through to the
      // retitle, the tag write, the folder cover and the index write, and was
      // only stopped at the very end.
      //
      // Stopping here instead skips all of that wasted work, and, because the
      // promotion-only path (an empty streamUrl, nothing to fetch) also arrives
      // with zero bytes — it is the one place that reliably clears
      // `_activeDownloads`. That path used to `return` from inside the closure
      // and leave a progress entry stuck at whatever fraction it reached.
      //
      // Playback is unaffected: nothing is indexed, so the track keeps streaming
      // rather than being handed an empty file.
      if (fileSizeBytes <= 0) {
        try {
          final partial = File(filePath);
          if (filePath.isNotEmpty && await partial.exists()) await partial.delete();
        } catch (_) {}
        // Two outcomes arrive here AND only one of them is a failure.
        //
        // A promotion-only caller — the track-end auto-cache — passes an empty
        // url deliberately: it is asking whether the play-cache happens to hold
        // the whole track, and "no" is an ordinary answer. A track played from a
        // local file, or only partly streamed, has nothing to promote and there
        // is nothing to download from either.
        //
        // One message covered both, so the 2026-08-30 transcript reported
        // "nothing downloaded for Baptized In Fear" twice for a track where no
        // download had ever been attempted. A warning that fires on a normal
        // outcome trains the reader to skip it, which costs the real one.
        if (streamUrl.isEmpty) {
          print('"${song.title}" not promoted — the play-cache does not hold '
              'it whole, and there is no url to fetch it from');
        } else {
          print('WARN: nothing downloaded for "${song.title}" — no bytes on disk, so '
              'nothing is being registered as cached');
        }
        _activeDownloads.remove(song.id);
        _downloadProgressController.add(Map.from(_activeDownloads));
        return false;
      }

      // Give the file the extension its bytes actually earn, BEFORE tagging: the
      // tag writer picks its format from the name, so tagging a mislabelled file
      // is guaranteed to fail. Downloads only — the private cache is addressed by
      // the index rather than by name, and the player sniffs content anyway, so
      // renaming there would be churn with nothing gained.
      if (fileSizeBytes > 0 && isExplicitDownload) {
        final retitled = await _retitleToRealContainer(filePath);
        if (retitled != filePath) {
          print("Named by container: ${retitled.split('/').last}");
          filePath = retitled;
        }
      }

      // The replacement is on disk and verified non-empty, so the copy it
      // supersedes can go. Guarded on fileSizeBytes for exactly that reason: if
      // the re-fetch produced nothing, the original stays and the download simply
      // reports failure rather than deleting the only copy the user had.
      if (supersededPath != null &&
          fileSizeBytes > 0 &&
          supersededPath != filePath) {
        try {
          final old = File(supersededPath);
          if (old.existsSync()) await old.delete();
        } catch (_) {}
      }

      if (fileSizeBytes > 0 && isExplicitDownload) {
        try {
          await MetadataGod.writeMetadata(
            file: filePath,
            metadata: Metadata(
              title: song.title,
              artist: song.artist,
              album: song.albumTitle.isNotEmpty && song.albumTitle != 'null' 
                  ? song.albumTitle 
                  : (collectionName ?? kDownloadsAlbumTag),
              picture: localImagePath.isNotEmpty && File(localImagePath).existsSync()
                  ? Picture(
                      data: File(localImagePath).readAsBytesSync(),
                      mimeType: localImagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg',
                    )
                  : null,
            ),
          );
          print("Tagged with cover art: ${song.title}");
        } catch (e) {
          // This printed a conclusion AND discarded the evidence.
          //
          // "The container genuinely cannot hold tags" is one possible cause —
          // and it is the assumption that let a REAL bug hide behind this line
          // for as long as it existed. On device, a dozen album tracks landed
          // here while a single downloaded minutes earlier tagged fine; the
          // actual cause was the bulk download path never asking for MP4, not
          // anything about the container being unable to hold tags.
          //
          // The extension and the error are what tell those apart, so both are
          // printed. A `.webm` here means the format request did not take;
          // anything else means the tagger itself failed and the assumption
          // above is wrong again.
          final ext = filePath.contains('.')
              ? filePath.substring(filePath.lastIndexOf('.'))
              : '(none)';
          final hadArt =
              localImagePath.isNotEmpty && File(localImagePath).existsSync();
          print('WARN: ${song.title}: could not write tags to a $ext file '
              '(cover available: $hadArt) — $e. Falling back to a folder cover, '
              'so other players see art but the file itself stays bare.');
          await _writeFolderCover(filePath, localImagePath);
        }
      }

      // 3. Update Index
      final existing = _cacheIndex[song.id];
      _cacheIndex[song.id] = CachedTrackInfo(
        songId: song.id,
        title: song.title,
        artist: song.artist, 
        albumTitle: song.albumTitle,
        imageUrl: song.image,
        localImagePath: localImagePath,
        filePath: filePath,
        fileSizeBytes: fileSizeBytes,
        cachedAt: existing?.cachedAt ?? DateTime.now(),
        lastAccessedAt: DateTime.now(),
        isExplicitDownload: isExplicitDownload || (existing?.isExplicitDownload ?? false),
      );
      _invalidateUrlIndex();
      
      await _saveCacheIndex();
      // Downloads live in PUBLIC /Music/Auvy and survive an uninstall, but the
      // internal cache index does NOT, so record the real videoId + network
      // cover next to the file, letting a reinstall re-key it to its real id
      // (matches the restored library album → correct grouping, #21) with its
      // cover intact (#18), instead of a synthetic 'local_' id with no art.
      if (isExplicitDownload || (existing?.isExplicitDownload ?? false)) {
        await _writeDownloadSidecar(filePath, song);
        // After the sidecar, so the scan sees the final name and the folder is
        // already complete when the system looks at it.
        await _notifyMediaStore(filePath);
      }
      // Last line of defence: never register a cache with no bytes
      //
      // Several paths reach here — index reuse, native promotion, a fresh HTTP
      // download, a move into /Music/Auvy, and each has been capable of
      // arriving with a size that the file does not have. Rather than trust the
      // fourth one to be different, the fact is checked once, here, where the
      // entry is about to become the truth for playback and eviction.
      //
      // Verified against the transcript that prompted this: five "Cached (0.00MB)"
      // lines in a day, three separate tracks.
      final verifiedBytes = await _actualSizeOf(filePath);
      if (verifiedBytes <= 0) {
        print('WARN: REFUSING to register ${song.title} as cached — $filePath is '
            'missing or empty after the write (index said $fileSizeBytes B). '
            'Nothing is indexed, so playback keeps streaming rather than being '
            'handed an empty file.');
        _cacheIndex.remove(song.id);
        _invalidateUrlIndex();
        await _saveCacheIndex();
        _activeDownloads.remove(song.id);
        _downloadProgressController.add(Map.from(_activeDownloads));
        return false;
      }
      if (verifiedBytes != fileSizeBytes) {
        print('cache size reconciled for ${song.title}: '
            '$fileSizeBytes B claimed → $verifiedBytes B on disk');
        fileSizeBytes = verifiedBytes;
        // Re-register with the real number: eviction budgets against this, so a
        // wrong value quietly breaks the cap.
        _cacheIndex[song.id] = _cacheIndex[song.id]!.copyWith(
          fileSizeBytes: verifiedBytes,
        );
        await _saveCacheIndex();
      }
      print("Cached: ${song.title} "
          "(${(fileSizeBytes / 1024 / 1024).toStringAsFixed(2)}MB"
          "${isExplicitDownload ? ', download' : ''})");
      // THE CAP IS ENFORCED HERE, not only before the download. Before the
      // write the real size is unknown, so a cache sitting just under its limit
      // would step over it and stay there. Now the newest track is in and the
      // oldest goes out, measured against the file that actually landed. The
      // track just cached cannot be the one evicted — it is the most recently
      // accessed by definition.
      await enforceCacheLimit(currentPlayingId: song.id);
      onCacheUpdated?.call();
      return true;
    } catch (e) { 
      print("WARN: Cache failed for ${song.title}: $e");
      return false; 
    }
  }

  /// Removes every downloaded file belonging to one album or playlist.
  ///
  /// Two bugs lived here, AND one of them destroyed data.
  ///
  /// The folder name was rebuilt with the old inline
  /// `replaceAll(RegExp(r'[\\/:*?"<>|]'), '')` while the DOWNLOAD side builds the
  /// very same folder with [_sanitizeSegment]. Two different functions for one
  /// name, which failed in two directions:
  ///
  ///  • ORPHANS. [_sanitizeSegment] strips trailing dots, collapses whitespace
  ///    runs and caps at 80 characters; the inline pattern did none of that. So
  ///    "Greatest Hits." was written to `Greatest Hits` and looked for in
  ///    `Greatest Hits.` — nothing matched, nothing was deleted, and the UI
  ///    reported success while the files stayed on disk forever.
  ///
  ///  • TRAVERSAL. The inline pattern leaves `..` untouched, so a collection
  ///    named `..` made `Albums/..` resolve to the download ROOT and
  ///    `deleteSync(recursive: true)` took EVERY downloaded album and playlist
  ///    with it. That is reachable, not theoretical: playlist names are free
  ///    text the user types, and album titles arrive from remote metadata.
  ///
  /// Now there is one sanitiser, plus a containment check at the point of
  /// deletion, so even a future mistake in the name cannot delete outside the
  /// download folder.
  Future<void> deleteCollectionLocally(String collectionName) async {
    if (!_isInitialized) await initialize();

    final safeCollection = _sanitizeSegment(collectionName);
    final idsToRemove = <String>[];
    
    _cacheIndex.forEach((id, info) {
      if (info.isExplicitDownload) {
        // Find tracks by exact album title OR by checking if they live in the target folder
        if (info.albumTitle == collectionName || info.filePath.contains('/$safeCollection/')) {
          idsToRemove.add(id);
        }
      }
    });

    // 1. Delete each track's audio file, lyrics and cover, and drop it from the
    // cache index. By id rather than by name or extension, so it does not matter
    // which container the download ended up in.
    for (var id in idsToRemove) {
      removeFromCache(id);
    }
    
    // 2. Wipe the physical folder to keep the user's storage perfectly clean
    try {
      if (_downloadDir != null) {
        _deleteIfInsideDownloads('Albums/$safeCollection');
        _deleteIfInsideDownloads('Playlists/$safeCollection');
      }
    } catch (e) {
      print("WARN: Failed to delete collection folder: $e");
    }

    print("Successfully wiped local files for: $collectionName");
    onCacheUpdated?.call();
  }

  /// Get album cover art from any track in the album
  String? getAlbumCoverArt(String albumTitle) {
    if (albumTitle.isEmpty || albumTitle == 'null') return null;
    
    // Find any track from this album that has local cover art
    final albumTrack = _cacheIndex.values.firstWhere(
      (info) => info.albumTitle == albumTitle && 
                info.localImagePath.isNotEmpty && 
                File(info.localImagePath).existsSync(),
      orElse: () => _cacheIndex.values.firstWhere(
        (info) => info.albumTitle == albumTitle,
        orElse: () => CachedTrackInfo(
          songId: '', title: '', artist: '', albumTitle: '', 
          imageUrl: '', localImagePath: '', filePath: '', 
          fileSizeBytes: 0, cachedAt: DateTime.now(), 
          lastAccessedAt: DateTime.now()
        ),
      ),
    );
    
    if (albumTrack.localImagePath.isNotEmpty && File(albumTrack.localImagePath).existsSync()) {
      return albumTrack.localImagePath;
    } else if (albumTrack.imageUrl.isNotEmpty) {
      return albumTrack.imageUrl;
    }
    
    return null;
  }
 
  List<Song> getCachedTracksSorted() {
    final list = _cacheIndex.values
      .where((info) =>
        File(info.filePath).existsSync() &&
        !info.isExplicitDownload && // Exclude downloads
        !_pendingDeleteIds.contains(info.songId)) // Hidden by a pending Undo
      .toList();

    list.sort((a, b) => b.cachedAt.compareTo(a.cachedAt)); 
    return list.map((info) => Song(
      id: info.songId,
      title: info.title,
      artist: info.artist,
      // PERSIST the NETWORK url, not the local cover path: these Songs flow into
              // play history / recents / the Home mosaic, which are cloud-backed up.
              // A local path dies on reinstall (files are wiped, not backed up) →
              // "cover art missing after restore" (#18). AuvyImage still resolves the
              // on-disk cover from this url via getLocalPathFromUrl, so offline art is
              // unaffected. Fall back to the local path only for locally-imported files
              // that have no network url at all.
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
      albumTitle: info.albumTitle,
    )).toList();
  }

  /// Save lyrics to disk
  /// A filesystem-safe stand-in for a song id.
  ///
  /// An ordinary videoId passes through untouched, so every lyrics file already
  /// on disk keeps its name and stays readable. Anything containing a character
  /// a path cannot hold is hashed instead — long URLs would also blow the 255
  /// byte filename limit even after stripping.
  static String _lyricsFileId(String songId) {
    // An ordinary videoId is 11 safe characters and passes through unchanged, so
    // every lyrics file already on disk keeps its name.
    if (RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(songId)) return songId;
    // FNV-1a, 32-bit. Deterministic across runs — unlike Object.hash, which Dart
    // seeds per process (this codebase has already been bitten by that once, in
    // the backup signatures) and which would rename every file on every launch.
    var h = 0x811c9dc5;
    for (final c in songId.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'u${h.toRadixString(16)}';
  }

  Future<void> saveLyrics(String songId, Map<String, dynamic> lyricsJson) async {
    if (!_isInitialized) await initialize();
    try {
      // THE ID IS NOT ALWAYS A FILENAME. A YouTube videoId is eleven safe
      // characters; a podcast or radio id is a full URL, complete with slashes
      // and a query string. Interpolating that produced a path that could not
      // exist, and the write threw every time.
      //
      // Fixed at the caller as well (spoken word does not get a lyrics lookup at
      // all), but sanitising here too means the next caller with an unusual id
      // writes a file rather than an exception. `_lyricsFileId` is stable, so an
      // entry written before this change is still found by readLyrics.
      final file = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      final encoded = jsonEncode(lyricsJson);
      // Don't rewrite what is already there.
      //
      // A track's lyrics get saved two or three times per play: the mid-track
      // auto-cache timer runs this, and so does the track-end promotion, and
      // both hand over the identical bytes the first one wrote. Counted in the
      // 2026-08-30 transcript as 159 saves across 92 tracks — two thirds of them
      // rewriting a file with its own contents.
      //
      // Reading first costs a few KB off flash instead of writing a few KB onto
      // it, and it also stops the log claiming work that did not happen.
      try {
        if (await file.exists() && await file.readAsString() == encoded) return;
      } catch (_) {}
      await file.writeAsString(encoded);
      print("Lyrics saved to disk for $songId");
    } catch (e) {
      print("WARN: Failed to save lyrics: $e");
    }
  }

  /// Get lyrics from disk
  /// The album tag written into a downloaded file that belongs to no album.
  ///
  /// IT IS A LABEL FOR OTHER PLAYERS, NOT A COLLECTION. A file with an empty
  /// album tag shows up as "Unknown album" in most music apps, so singles get
  /// this instead and look deliberate in a file browser.
  ///
  /// Auvy's own importer must therefore NOT read it back as a real collection —
  /// see the sentinel check in [scanAndImportDownloads]. Shared as a constant
  /// because the writer and the reader agreeing is the whole point: when they
  /// disagreed, a reinstall turned every single into a folder called
  /// "Auvy Downloads".
  static const String kDownloadsAlbumTag = 'Auvy Downloads';

  Future<Map<String, dynamic>?> getLyrics(String songId) async {
    if (!_isInitialized) await initialize();
    try {
      final file = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content);
      }
    } catch (e) {
      print("WARN: Failed to read lyrics from disk: $e");
    }
    return null;
  }

  Future<void> clearLyricsCache(String songId) async {
    if (!_isInitialized) await initialize();
    try {
      final file = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      if (await file.exists()) {
        await file.delete();
        print("Lyrics cache cleared for $songId");
      }
    } catch (e) {
      print("WARN: Failed to clear lyrics cache: $e");
    }
  }

  void _updateAccessTime(String songId) {
    if (_cacheIndex.containsKey(songId)) {
      _cacheIndex[songId] = _cacheIndex[songId]!.copyWith(
        lastAccessedAt: DateTime.now()
      );
      _invalidateUrlIndex();
      _saveCacheIndex();
    }
  }

  void removeFromCache(String songId) {
    _pendingDeleteIds.remove(songId); // committed (or moot) either way
    if (!_cacheIndex.containsKey(songId)) return;
    try {
      final info = _cacheIndex[songId]!;
      final audioFile = File(info.filePath);
      if (audioFile.existsSync()) audioFile.deleteSync();

      // Also remove lyrics file
      final lyricsFile = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      if (lyricsFile.existsSync()) lyricsFile.deleteSync();

      // …and the cover thumbnail. This used to be left behind on every
      // eviction, so months of LRU churn silently accumulated thousands of
      // orphaned cover_*.jpg files that no code would ever read or delete.
      // Deleting via localImagePath covers both naming schemes
      // (cover_<id>.jpg from cacheTrack, cover_local_<hash>.jpg from the disk
      // scan); the guards skip the case where it holds a network URL because
      // the cover download failed.
      final coverPath = info.localImagePath;
      if (coverPath.isNotEmpty &&
          !coverPath.startsWith('http') &&
          coverPath.startsWith(_cacheDir!.path)) {
        final coverFile = File(coverPath);
        if (coverFile.existsSync()) coverFile.deleteSync();
      }

      // The download's videoId sidecar goes with its audio file — leaving it
      // behind would let a later disk scan re-import a track that was deleted.
      // BOTH locations: the hidden `.auvy/` one and the legacy copy that older
      // downloads wrote beside the audio.
      for (final sidecar in sidecarCandidates(info.filePath)) {
        try {
          if (sidecar.existsSync()) sidecar.deleteSync();
        } catch (_) {}
      }

      _cacheIndex.remove(songId);
      _invalidateUrlIndex();
      _saveCacheIndex();
      onCacheUpdated?.call();
    } catch (e) {
      print("WARN: Failed to remove cache: $e");
    }
  }

  /// Delete `cover_*.jpg` / `lyrics_*.json` in the cache directory that no
  /// index entry references any more. Until removeFromCache learned to delete
  /// covers, every eviction leaked one — this reclaims that backlog on upgrade
  /// (and mops up anything a crash between file-write and index-save leaves).
  /// Best-effort and silent: a sweep failure must never affect playback.
  Future<void> _sweepOrphanedSidecars() async {
    try {
      if (_cacheDir == null || !await _cacheDir!.exists()) return;
      // Everything the index still points at, by file NAME.
      final live = <String>{};
      for (final info in _cacheIndex.values) {
        live.add('lyrics_${_lyricsFileId(info.songId)}.json');
        if (info.localImagePath.isNotEmpty &&
            !info.localImagePath.startsWith('http')) {
          live.add(info.localImagePath.split(Platform.pathSeparator).last);
        }
      }

      var freed = 0, count = 0;
      await for (final entity in _cacheDir!.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        final isSidecar = (name.startsWith('cover_') && name.endsWith('.jpg')) ||
            (name.startsWith('lyrics_') && name.endsWith('.json'));
        if (!isSidecar || live.contains(name)) continue;
        try {
          freed += await entity.length();
          await entity.delete();
          count++;
        } catch (_) {}
      }
      if (count > 0) {
        print('Swept $count orphaned cover/lyrics files '
            '(${(freed / 1024).toStringAsFixed(0)} KB reclaimed)');
      }
    } catch (_) {}
  }

  /// Bytes and tracks the CACHE LIMIT governs — auto-cached entries only.
  ///
  /// The budget must NOT count downloads, AND it used to.
  ///
  /// Explicit downloads live in public /Music/Auvy, were asked for by name, and
  /// are correctly exempt from eviction. But the size and count checks measured
  /// the WHOLE index, downloads included, so downloads consumed a budget they
  /// could never be evicted from.
  ///
  /// Past ~500 MB of downloads that made the limit permanently exceeded. Every
  /// track played calls [_ensureCacheSpace], which then asked [_evictLRU] for a
  /// target it could never reach, so it evicted every eligible track — the entire
  /// auto-cache, and did it again on the next track. The play-cache would sit
  /// permanently empty and every track would re-download over the network, on
  /// repeat, for as long as the downloads existed. A storage cap silently turning
  /// into unbounded data use is the worst possible failure for this code, and
  /// nothing in the UI would have shown it: the storage screen already excluded
  /// downloads from the number it displayed, so the reading looked healthy.
  int _autoCacheBytes() => _cacheIndex.values
      .where((i) => !i.isExplicitDownload)
      .fold(0, (sum, i) => sum + i.fileSizeBytes);

  int _autoCacheCount() =>
      _cacheIndex.values.where((i) => !i.isExplicitDownload).length;

  Future<void> _ensureCacheSpace({String? currentPlayingId}) async {
    // 1. Enforce max track count limit
    if (_autoCacheCount() >= maxCachedTracks) {
      await _evictLRU(targetTrackCount: maxCachedTracks - 1, currentPlayingId: currentPlayingId);
    }

    // 2. Enforce max cache size limit (evicts down to 85% capacity to create headroom)
    final maxBytes = maxCacheSizeMB * 1024 * 1024;

    if (_autoCacheBytes() > maxBytes) {
      final targetBytes = (maxBytes * 0.85).toInt();
      await _evictLRU(targetBytes: targetBytes, currentPlayingId: currentPlayingId);
    }
  }

  /// Brings the auto-cache back inside BOTH limits, evicting least-recently-used
  /// tracks until it fits. Returns the bytes freed.
  ///
  /// The limit used to be exceedable, AND the user noticed before the code did.
  ///
  /// [_ensureCacheSpace] runs BEFORE a download, so it can only act on what is
  /// already there. At 499 MB of a 500 MB limit it sees no violation, the track
  /// downloads, and the cache lands at 503 MB — over the limit, with nothing left
  /// to notice. Enforcing again AFTER the real size is known is what actually
  /// makes the limit a limit: newest in, oldest out, checked against the number
  /// on disk rather than an estimate of it.
  ///
  /// Also the single enforcement path. The 5-minute cleanup timer used to prune
  /// by a "~5 MB per track" guess — it kept `limit ÷ 5` tracks and deleted the
  /// rest, which is not a size limit at all: 100 tracks of 8 MB is 800 MB, and
  /// 100 tracks of 2 MB throws away cache that fits perfectly well. Measured
  /// bytes replace the guess.
  /// Evict to a low-water mark, NOT to the limit
  ///
  /// Trimming to exactly the limit guarantees the next track trips it again.
  /// The 2026-09-01 log shows the shape plainly: fifty trims in a day, each
  /// freeing 3-5 MB, the cache sitting at 496-499 of 500 MB the whole time.
  /// Every one of those is an eviction pass plus an index write, to buy room for
  /// a single track.
  ///
  /// A low-water mark is the standard answer: cross the limit, fall back below
  /// it, and stay quiet until the gap is used up. At 95% that is ~25 MB of
  /// headroom, or roughly six tracks between passes — about eight trims a day
  /// instead of fifty.
  ///
  /// 95 rather than the more usual 80-90 on purpose. This cache exists to avoid
  /// re-downloading audio, so utilisation is the point; the aim is to stop the
  /// thrash, not to run the cache half empty. Total bytes evicted over time is
  /// unchanged either way — a 500 MB cache can only ever keep 500 MB.
  static const double _evictLowWaterFraction = 0.95;

  Future<int> enforceCacheLimit({String? currentPlayingId}) async {
    if (!_isInitialized) return 0;
    final maxBytes = maxCacheSizeMB * 1024 * 1024;
    final before = _autoCacheBytes();
    if (before <= maxBytes && _autoCacheCount() <= maxCachedTracks) return 0;

    // The TRIGGER stays the real limit — this only changes how far the pass
    // goes once it has already decided to run.
    await _evictLRU(
      targetBytes: (maxBytes * _evictLowWaterFraction).round(),
      targetTrackCount:
          (maxCachedTracks * _evictLowWaterFraction).floor().clamp(1, maxCachedTracks),
      currentPlayingId: currentPlayingId,
    );
    final freed = before - _autoCacheBytes();
    if (freed > 0) {
      print('Cache trimmed: '
          '${(freed / 1024 / 1024).toStringAsFixed(1)} MB freed, now '
          '${(_autoCacheBytes() / 1024 / 1024).toStringAsFixed(1)}/'
          '$maxCacheSizeMB MB '
          '(evicts to ${(_evictLowWaterFraction * 100).round()}% so the next '
          'track does not trigger another pass)');
      await _saveCacheIndex();
    }
    return freed;
  }

  /// Re-measures every cached and downloaded file against DISK and corrects the
  /// index. Returns how many entries were wrong.
  ///
  /// The index records each file's length at write time, which is real, but it
  /// cannot notice a file removed behind the app's back (a manual wipe, an OS
  /// cache clear, a file manager, a failed write). Those entries kept claiming
  /// their old bytes, so "Storage Used" could report space nothing was occupying,
  /// and eviction would work toward a target derived from that phantom space.
  ///
  /// Downloads are measured too — they sit in public storage where anything can
  /// delete them — even though they are exempt from the cache budget. The number
  /// on screen should describe the disk either way.
  ///
  /// SIZES ONLY. Entries are never dropped here. A missing file becomes 0
  /// bytes, which is the honest answer for a storage total; deciding an entry is
  /// DEAD is a different question, it can cost the user a library row, and it
  /// belongs with the code that can tell a transient read failure from a real
  /// deletion.
  Future<int> reconcileCacheSizes() async {
    if (!_isInitialized || _cacheDir == null) return 0;
    var corrected = 0;
    for (final entry in _cacheIndex.entries) {
      final info = entry.value;
      try {
        final f = File(info.filePath);
        final real = f.existsSync() ? await f.length() : 0;
        if (real != info.fileSizeBytes) {
          _cacheIndex[entry.key] = info.copyWith(fileSizeBytes: real);
          corrected++;
        }
      } catch (_) {
        // Unreadable is not the same as absent; leave the entry alone.
      }
    }
    if (corrected > 0) {
      _invalidateUrlIndex();
      await _saveCacheIndex();
      print('Re-measured $corrected cache entr'
          '${corrected == 1 ? 'y' : 'ies'} against disk');
    }
    return corrected;
  }

  /// The real container of a cached track, uppercased (`WEBM`, `M4A`, `OPUS`), or
  /// null when there is no readable file.
  ///
  /// Read from the bytes, not the filename. Cache files are all written as `.m4a`
  /// while YouTube's audio is usually Opus in WebM, so the extension is not
  /// evidence of anything — a details sheet trusting it reported the wrong format
  /// for nearly every cached track.
  Future<String?> containerOf(String songId) async {
    final info = _cacheIndex[songId];
    if (info == null) return null;
    final f = File(info.filePath);
    if (!f.existsSync()) return null;
    return (await _sniffAudioExtension(f))?.toUpperCase();
  }

  /// Megabytes the auto-cache currently occupies, rounded UP — the floor for the
  /// limit slider, since a lower limit could only be honoured by deleting tracks
  /// the user never asked to lose. "Clear Cache" frees it deliberately.
  int autoCacheFloorMB() => (_autoCacheBytes() / (1024 * 1024)).ceil();

  Future<void> _evictLRU({int? targetTrackCount, int? targetBytes, String? currentPlayingId}) async {
    // Eviction Candidates:
    // MUST NOT be explicit downloads, MUST NOT be pinned top tracks, and MUST NOT be currently playing
    final candidates = _cacheIndex.values
        .where((info) => 
            !info.isExplicitDownload && 
            !pinnedSongIds.contains(info.songId) &&
            info.songId != currentPlayingId)
        .toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt)); // Oldest accessed first

    // When the target is out of reach, say so once
    //
    // PINNED tracks (the user's Top 50) are counted by [_autoCacheBytes] — they
    // are auto-cache, not downloads, but are excluded from `candidates` above.
    // So they occupy budget that eviction cannot reclaim, and as the Top 50 grows
    // (50 tracks at high quality is easily 400 MB of a 500 MB cap) the reclaimable
    // share shrinks toward nothing. The end state is a play-cache that is wiped on
    // every track and re-downloaded — quiet, and expensive in data.
    //
    // Downloads already hit this and are excluded from the budget entirely; the
    // note on [_autoCacheBytes] records what that cost. This is the same shape one
    // exemption over, so it is worth a line in the transcript rather than a
    // silent squeeze.
    if (targetBytes != null) {
      final evictable = candidates.fold<int>(0, (n, i) => n + i.fileSizeBytes);
      final excess = _autoCacheBytes() - targetBytes;
      if (excess > 0 && evictable < excess) {
        final pinnedBytes = _cacheIndex.values
            .where((i) => !i.isExplicitDownload && pinnedSongIds.contains(i.songId))
            .fold<int>(0, (n, i) => n + i.fileSizeBytes);
        final mb = (int b) => (b / 1024 / 1024).toStringAsFixed(1);
        print('WARN: cache cannot reach its target — needs ${mb(excess)} MB '
            'freed but only ${mb(evictable)} MB is evictable. '
            '${mb(pinnedBytes)} MB is pinned (Top 50, ${pinnedSongIds.length} '
            'id(s)) and exempt, so the play-cache is being squeezed.');
      }
    }

    for (final info in candidates) {
      // Measured against the same auto-cache-only totals the targets were
      // derived from. Mixing in downloads here would make the loop unable to
      // ever satisfy its target. See [_autoCacheBytes].
      final currentSize = _autoCacheBytes();
      final currentCount = _autoCacheCount();

      bool sizeOk = targetBytes == null || currentSize <= targetBytes;
      bool countOk = targetTrackCount == null || currentCount <= targetTrackCount;

      if (sizeOk && countOk) break;

      removeFromCache(info.songId);
      print("Auto-evicted LRU cached track: ${info.title}");
    }
  }

  Future<void> _cleanupExpiredCache() async {
    final expired = <String>[];
    final now = DateTime.now();
    
    _cacheIndex.forEach((id, info) {
      // Don't expire explicit downloads or pinned top tracks
      if (!info.isExplicitDownload && !pinnedSongIds.contains(id)) {
        final age = now.difference(info.cachedAt);
        if (age.inDays > maxCacheAgeDays) {
          expired.add(id);
        }
      }
    });
    
    for (var id in expired) removeFromCache(id);
  }

  int _getTotalCacheSize() {
    return _cacheIndex.values.fold(0, (sum, info) => sum + info.fileSizeBytes);
  }

  Map<String, dynamic> getCacheStats() {
    final autoCachedItems = _cacheIndex.values.where((info) => !info.isExplicitDownload).toList();
    final autoCacheSize = autoCachedItems.fold(0, (sum, info) => sum + info.fileSizeBytes);
    return {
      'cachedTracks': autoCachedItems.length, // Now shows 17 instead of 35
      'totalSizeMB': (autoCacheSize / 1024 / 1024).toStringAsFixed(2),
      'maxSizeMB': maxCacheSizeMB,
    };
  }

  /// Storage split by KIND, for Settings → Storage & data.
  ///
  /// [getCacheStats] deliberately reports only the auto-cache, because that's
  /// what the size limit governs. But that makes the number smaller than the
  /// space Auvy actually occupies, which reads as a bug when you compare it
  /// against Android's app-info screen. This returns both halves plus the true
  /// total, so the page can account for every byte.
  ///
  /// Downloads are listed but are NOT subject to the cache limit and are never
  /// auto-evicted — they were explicitly asked for.
  Map<String, dynamic> getStorageBreakdown() {
    int autoBytes = 0, autoCount = 0;
    int downloadBytes = 0, downloadCount = 0;
    int imageBytes = 0;
    // Saved lyrics. Small individually, but this claims to account for every
    // byte, and a total that quietly omits a category is the kind of number that
    // stops matching Android's app-info screen for no visible reason.
    int lyricsBytes = 0;
    DateTime? oldest;

    for (final info in _cacheIndex.values) {
      if (info.isExplicitDownload) {
        downloadBytes += info.fileSizeBytes;
        downloadCount++;
      } else {
        autoBytes += info.fileSizeBytes;
        autoCount++;
        if (oldest == null || info.lastAccessedAt.isBefore(oldest)) {
          oldest = info.lastAccessedAt;
        }
      }
      // Cover art is stored beside the audio; counted separately because it's
      // the one part that's cheap to drop and instantly re-fetchable.
      if (info.localImagePath.isNotEmpty) {
        try {
          final f = File(info.localImagePath);
          if (f.existsSync()) imageBytes += f.lengthSync();
        } catch (_) {
          // A missing/unreadable thumbnail shouldn't break the whole breakdown.
        }
      }
    }

    // Listed from disk rather than derived from the index: lyrics outlive the
    // track they belong to if an eviction ever missed one, and a directory
    // listing is the only thing that sees those.
    try {
      if (_cacheDir != null && _cacheDir!.existsSync()) {
        for (final e in _cacheDir!.listSync(followLinks: false)) {
          if (e is! File) continue;
          final name = e.path.split(Platform.pathSeparator).last;
          if (name.startsWith('lyrics_') && name.endsWith('.json')) {
            try {
              lyricsBytes += e.lengthSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // An unreadable cache directory leaves lyrics at 0 rather than failing the
      // whole breakdown.
    }

    return {
      'autoBytes': autoBytes,
      'autoCount': autoCount,
      'downloadBytes': downloadBytes,
      'downloadCount': downloadCount,
      'imageBytes': imageBytes,
      'lyricsBytes': lyricsBytes,
      'totalBytes': autoBytes + downloadBytes + imageBytes + lyricsBytes,
      'maxSizeMB': maxCacheSizeMB,
      'oldestAccess': oldest?.millisecondsSinceEpoch,
    };
  }

  Future<void> clearAllCache() async {
    try {
      final List<String> idsToRemove = [];

      _cacheIndex.forEach((id, info) {
        if (!info.isExplicitDownload) {
          idsToRemove.add(id);
        }
      });

      for (var id in idsToRemove) {
        removeFromCache(id);
      }

      print("Cache cleared. Downloads preserved.");
      await _saveCacheIndex();
    } catch (e) {
      print("ERROR: Failed to clear cache: $e");
    }
  }

  /// Nuclear wipe used by "Delete Account": removes EVERYTHING — the auto-cache,
  /// the explicit downloads AND their physical files on disk, plus the whole
  /// index. Leaves the app in a brand-new-user storage state.
  Future<void> wipeEverything() async {
    if (!_isInitialized) await initialize();
    try {
      // Remove every indexed track (deletes each backing file + lyrics).
      for (final id in _cacheIndex.keys.toList()) {
        removeFromCache(id);
      }
      _cacheIndex.clear();
      _invalidateUrlIndex();
      await _saveCacheIndex();

      // Delete the public Auvy download tree (Albums/Singles/etc.) wholesale so
      // no orphaned files remain on the phone.
      if (_downloadDir != null && _downloadDir!.path != _cacheDir?.path) {
        try {
          if (_downloadDir!.existsSync()) _downloadDir!.deleteSync(recursive: true);
          await _downloadDir!.create(recursive: true);
        } catch (e) {
          print("WARN: Could not wipe download folder: $e");
        }
      }
      print("All audio (cache + downloads) wiped.");
      onCacheUpdated?.call();
    } catch (e) {
      print("ERROR: wipeEverything failed: $e");
    }
  }

  /// Helper to get local image if available
 String getDisplayImage(String songId, String fallbackUrl) {
    final info = _cacheIndex[songId];
    if (info != null && info.localImagePath.isNotEmpty) {
      final file = File(info.localImagePath);
      if (file.existsSync()) {
        return info.localImagePath;
      }
    }
    return fallbackUrl;
  }

  /// Write a small `<file>.auvyid` sidecar recording a downloaded track's REAL
  /// videoId + network cover + album/title/artist. Read by [scanAndImportDownloads]
  /// after a reinstall so the file re-keys to its real id (not a synthetic
  /// `local_` one) with its network cover — fixing #18 (cover-after-restore) and
  /// #21 (downloaded album shown as loose tracks). Skips synthetic/http ids.
  /// Writes `cover.jpg` beside a download whose container cannot hold a picture.
  ///
  /// `cover.jpg` in the same directory is the long-standing convention desktop
  /// players, most Android players and Plex/Jellyfin fall back to, so a track
  /// that could not be tagged still shows artwork. One file per folder rather
  /// than one per track: an album folder has one cover, and a copy per track
  /// would multiply the same image across the disk for nothing.
  ///
  /// ALBUM AND PLAYLIST FOLDERS ONLY. `Singles/` is a bucket of unrelated
  /// tracks that happen to share a directory, so a folder cover there would show
  /// whichever single was downloaded first as the artwork for ALL of them — the
  /// same "everything shows the first track's cover" mistake the per-track cover
  /// cache exists to avoid. A single with an untaggable container simply gets no
  /// embedded art; inventing wrong art is worse than none.
  ///
  /// Skipped when a cover is already there, so downloading a second track from
  /// the same album is not a second write.
  Future<void> _writeFolderCover(String audioPath, String localImagePath) async {
    if (localImagePath.isEmpty || !localImagePath.startsWith('/')) return;
    try {
      final dir = File(audioPath).parent;
      final parent = dir.parent.path.split('/').last;
      if (parent != 'Albums' && parent != 'Playlists') return;
      final src = File(localImagePath);
      if (!src.existsSync()) return;
      final dest = File('${dir.path}/cover.jpg');
      if (dest.existsSync()) return;
      await src.copy(dest.path);
    } catch (_) {
      // Cosmetic; a download must never fail because its artwork did not copy.
    }
  }

  /// Tells Android a file appeared, so it is indexed into the media store.
  ///
  /// WITHOUT THIS A DOWNLOAD IS INVISIBLE TO THE REST OF THE PHONE. Writing
  /// into /Music does not register anything by itself — the scanner indexes on
  /// notification, or else whenever the system next happens to sweep, which can
  /// be hours. A downloaded track was therefore absent from every other music
  /// app and file manager, which reads as "it did not download". Verified: the
  /// media store held no row for a file that had been on disk for days.
  ///
  /// Fire-and-forget: indexing is a convenience for other apps, and Auvy plays
  /// the file from its own index either way.
  Future<void> _notifyMediaStore(String path) async {
    if (path.isEmpty || !_isInDownloadsDir(path)) return;
    try {
      await const MethodChannel('com.auvy.app/folder')
          .invokeMethod('scanMedia', {'path': path});
    } catch (_) {}
  }

  Future<void> _writeDownloadSidecar(String audioPath, Song song) async {
    if (song.id.isEmpty ||
        song.id.startsWith('local_') ||
        song.id.startsWith('http')) return;
    try {
      final target = sidecarFileFor(audioPath);
      await target.parent.create(recursive: true);
      // Tells Android's media scanner to skip the whole directory, so these
      // never surface in Gallery, music apps or "recent files".
      final noMedia = File('${target.parent.path}/.nomedia');
      if (!noMedia.existsSync()) {
        try {
          await noMedia.create();
        } catch (_) {}
      }
      await target.writeAsString(jsonEncode({
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'album': song.albumTitle,
        'imageUrl': song.image.startsWith('http') ? song.image : '',
      }));
      // Clean up the legacy copy that used to sit beside the audio.
      try {
        final legacy = File('$audioPath.auvyid');
        if (legacy.existsSync()) await legacy.delete();
      } catch (_) {}
    } catch (_) {}
  }

  /// Where a download's metadata sidecar lives: a HIDDEN `.auvy` subdirectory of
  /// the downloads folder, not beside the audio file.
  ///
  /// Downloads go to public `/Music/Auvy` so they survive an uninstall and are
  /// visible to other players, which also means the user browses that folder.
  /// Writing `<track>.m4a.auvyid` next to each song littered it with one opaque
  /// file per download ("I see auvyid"). The audio is the only thing that belongs
  /// in a folder the user opens; bookkeeping goes somewhere it can be ignored.
  ///
  /// A leading dot hides the directory from Android file managers, and the
  /// `.nomedia` marker written alongside keeps the media scanner out of it.
  static File sidecarFileFor(String audioPath) {
    final f = File(audioPath);
    final name = f.uri.pathSegments.isEmpty ? '' : f.uri.pathSegments.last;
    return File('${f.parent.path}/.auvy/$name.auvyid');
  }

  /// Both possible sidecar locations, new first. Existing installs have sidecars
  /// beside the audio, and a reinstall scan must still find them or those
  /// downloads lose their real ids and covers.
  static List<File> sidecarCandidates(String audioPath) => [
        sidecarFileFor(audioPath),
        File('$audioPath.auvyid'),
      ];

  /// Reverse lookup, remote image URL → on-disk cover path.
  ///
  /// THIS EXISTS FOR ONE REASON: [getLocalPathFromUrl] is called from
  /// `AuvyImage.build()`, which runs for EVERY artwork on screen on EVERY
  /// rebuild. It used to scan `_cacheIndex.values` comparing a URL string per
  /// entry, so a library of a few hundred downloads and a screenful of tiles cost
  /// tens of thousands of string comparisons per frame — on the UI thread, during
  /// build, and then a stat() on top.
  ///
  /// Built lazily and only after the index actually changes, so the cost is paid
  /// once per mutation instead of once per painted image.
  ///
  /// Staleness is deliberately harmless. A MISS only means "no local copy", and
  /// every caller already verifies the file before trusting a HIT, so the worst
  /// case either way is falling back to the network image — exactly what happened
  /// before the file was cached at all.
  Map<String, String>? _urlToLocalPath;

  /// Drops the reverse index. Called from every site that mutates [_cacheIndex],
  /// including the ones that only touch access time — a boolean is cheap, and a
  /// future field added there must not silently desync this.
  void _invalidateUrlIndex() => _urlToLocalPath = null;

  Map<String, String> get _urlIndex {
    final cached = _urlToLocalPath;
    if (cached != null) return cached;
    final idx = <String, String>{};
    for (final i in _cacheIndex.values) {
      if (i.imageUrl.isNotEmpty && i.localImagePath.isNotEmpty) {
        idx[i.imageUrl] = i.localImagePath;
      }
    }
    _urlToLocalPath = idx;
    return idx;
  }

  /// Resolve a raw URL to a local file path if it was previously cached.
  String? getLocalPathFromUrl(String url) {
    if (url.isEmpty || !url.startsWith('http')) return null;
    final local = _urlIndex[url];
    if (local == null) return null; // not cached — no stat needed at all
    // Kept: the contract is "a path you can actually open", and callers such as
    // preloadQueueImages test the null-ness rather than the file.
    return File(local).existsSync() ? local : null;
  }

  Future<void> preloadQueueImages(List<Song> songs) async {
    if (!_isInitialized) await initialize();
    
    final toPreload = songs.take(5).where((s) => 
      s.image.isNotEmpty && 
      s.image.startsWith('http') &&
      getLocalPathFromUrl(s.image) == null
    );
    
    for (var song in toPreload) {
      final client = http.Client();
      try {
        final response = await client.get(Uri.parse(song.image))
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final imgFile = File('${_cacheDir!.path}/cover_${song.id}.jpg');
          await imgFile.writeAsBytes(response.bodyBytes);
          print('Preloaded image: ${song.title}');
        }
      } catch (e) {
        print('WARN: Image preload failed: ${song.title}');
      } finally {
        // One client per song in a LOOP — skipping close on a failed fetch
        // leaked a socket per miss.
        client.close();
      }
    }
  }

  void cleanup() {
    final now = DateTime.now();
    final expired = <String>[];
    
    _cacheIndex.forEach((id, info) {
      if (!info.isExplicitDownload) {
        final age = now.difference(info.cachedAt);
        if (age.inDays > maxCacheAgeDays) {
          expired.add(id);
        }
      }
    });
    
    for (var id in expired) {
      removeFromCache(id);
    }
    
    print('AudioCacheManager cleanup: removed ${expired.length} expired tracks');
  }
}

/// One row of the cache index: where a file is, how big, and when last used.
///
/// Serialised to prefs as a whole map, so adding a field means old entries
/// deserialise without it. `fileSizeBytes` is measured from disk rather than
/// trusted from a header, because eviction budgets against it.
class CachedTrackInfo {
  final String songId;
  final String title;
  final String artist;
  final String imageUrl;
  final String albumTitle; 
  final String localImagePath; 
  final String filePath;
  final int fileSizeBytes;
  final DateTime cachedAt;
  final DateTime lastAccessedAt;
  final bool isExplicitDownload;

  CachedTrackInfo({
    required this.songId,
    required this.title,
    required this.albumTitle, 
    required this.artist,
    required this.imageUrl,
    required this.localImagePath, 
    required this.filePath,
    required this.fileSizeBytes,
    required this.cachedAt,
    required this.lastAccessedAt,
    this.isExplicitDownload = false,
  });

  // Update copyWith and JSON methods
  CachedTrackInfo copyWith({
    DateTime? lastAccessedAt,
    bool? isExplicitDownload,
    /// Corrected after re-measuring the file on disk — see
    /// [AudioCacheManager.reconcileCacheSizes].
    int? fileSizeBytes,
    /// Cleared by [AudioCacheManager._repairPlaceholderAlbums] when it holds
    /// the placeholder tag rather than a real album.
    String? albumTitle,
  }) {
    return CachedTrackInfo(
      songId: songId, title: title, artist: artist,
      albumTitle: albumTitle ?? this.albumTitle,
      imageUrl: imageUrl, localImagePath: localImagePath, filePath: filePath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes, cachedAt: cachedAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      isExplicitDownload: isExplicitDownload ?? this.isExplicitDownload,
    );
  }

  Map<String, dynamic> toJson() => {
    'songId': songId, 
    'title': title, 
    'artist': artist, 
    'albumTitle': albumTitle,
    'imageUrl': imageUrl, 
    'imageName': localImagePath.isNotEmpty ? localImagePath.split('/').last : '', 
    'fileName': isExplicitDownload ? filePath : filePath.split('/').last,
    'fileSizeBytes': fileSizeBytes, 
    'cachedAt': cachedAt.toIso8601String(),
    'lastAccessedAt': lastAccessedAt.toIso8601String(), 
    'isExplicitDownload': isExplicitDownload,
  };

  factory CachedTrackInfo.fromJson(Map<String, dynamic> json, String basePath) {
    final String fileName = json['fileName'] ?? '';
    final String imageName = json['imageName'] ?? '';
    final bool isExplicit = json['isExplicitDownload'] ?? false;

    String resolvedPath;
    if (isExplicit && fileName.startsWith('/')) {
      resolvedPath = fileName; 
    } else {
      resolvedPath = '$basePath/$fileName'; 
    }

    return CachedTrackInfo(
      songId: json['songId'], 
      title: json['title'], 
      artist: json['artist'],
      albumTitle: json['albumTitle'] ?? '', 
      imageUrl: json['imageUrl'] ?? '',
      localImagePath: imageName.isNotEmpty ? '$basePath/$imageName' : '', 
      filePath: resolvedPath,
      fileSizeBytes: json['fileSizeBytes'] ?? 0, 
      cachedAt: DateTime.parse(json['cachedAt']),
      lastAccessedAt: DateTime.parse(json['lastAccessedAt']),
      isExplicitDownload: isExplicit,
    );
  }
}