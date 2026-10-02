// Local storage for audio, cover art and lyrics: the auto-cache, user
// downloads, and the index that describes them.
import 'dart:io';
import 'package:auvy/services/event_log.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
// normalize/isWithin: string checks can't safely answer "is this path inside
// that folder?" once `..` is involved. See [_deleteIfInsideDownloads].
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/services/lyrics_service.dart';
import 'package:auvy/services/audio_service.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/core/utils/container_path_resolver.dart';

final audioCacheManagerProvider = Provider<AudioCacheManager>((ref) {
    return AudioCacheManager();
  });
/// Audio files on disk, and the index that describes them.
///
/// Two kinds of file live here, and most methods treat them differently:
///
///   auto-cached  kept automatically as you listen, evicted when space runs
///                short. `isExplicitDownload == false`.
///   downloaded   requested by the user. Never evicted, and written to a
///                folder the user can browse (Music/Auvy on Android).
///
/// The auto-cache is capped (500 MB by default) and trimmed least-recently-used
/// first, except the user's most-played tracks, which are pinned. Downloads
/// don't count against the cap.
///
/// This class also owns lyrics and cover files on disk, and the startup scan
/// that re-adopts files found in the downloads folder, which is how downloads
/// survive a reinstall.
///
/// Note: cacheTrack() with an empty url downloads nothing. It checks whether the
/// native play cache already holds the whole track and, if so, copies those
/// bytes. That is how a track you just listened to becomes cached for free.
class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal();
  void Function()? onCacheUpdated;

  // Cache configuration.
  int maxCacheSizeMB = 500; 
  static const int maxCacheAgeDays = 30;   
  static const int maxCachedTracks = 500;

  Directory? _cacheDir;
  Directory? _downloadDir;
  final Map<String, CachedTrackInfo> _cacheIndex = {};

  /// Auto-cached song ids that must not be evicted or expired: the user's "My
  /// Top 50" / most-played tracks, so they stay available offline. Explicit
  /// downloads are protected separately.
  Set<String> pinnedSongIds = {};

  /// Song ids involved in playback right now (playing, upcoming, or preloaded for
  /// gapless), protected from eviction.
  Set<String> protectedPlaybackIds = {};

  /// Tracks the "Cached" folder hides while an Undo toast is open. The folder
  /// lists disk state directly, so instead of deleting immediately the row is
  /// hidden here, and [removeFromCache] deletes the file once the undo window
  /// expires. Session-only: if the app dies meanwhile, the file survives.
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

  Future<void> initialize() {
    // Library init, main() and the lyrics preload all call this at startup; a
    // single in-flight future stops MetadataGod from being initialised twice,
    // which throws.
    if (_isInitialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      await MetadataGod.initialize();
    } catch (e) {
      // flutter_rust_bridge throws if already initialised; safe to ignore.
      print("MetadataGod init skipped: $e");
    }
    
    // Private cache directory.
    //
    // On iOS this uses Application Support, not Documents: with
    // `UIFileSharingEnabled`, Documents is visible in the Files app as "On My
    // iPhone → Auvy", which is where downloads and backup exports belong but not
    // internal cache files (id-named, untagged audio with loose cover and lyrics
    // files). Application Support is private, not shared, and not purged by the
    // system like Library/Caches. On Android Documents is already app-private.
    //
    // The downloads folder stays in Documents on iOS: those files are named
    // `Artist - Title.m4a`, carry embedded art, and are meant to be found.
    final appDir = await getApplicationDocumentsDirectory();
    final Directory cacheRoot =
        Platform.isIOS ? await getApplicationSupportDirectory() : appDir;
    _cacheDir = Directory('${cacheRoot.path}/audio_cache');
    ContainerPathResolver.setDirectories(
      documentsDir: appDir.path,
      supportDir: cacheRoot.path,
    );
    
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }

    // Move any cache files still in the old visible location. The index stores
    // auto-cached entries as bare file names relative to _cacheDir, so changing the
    // directory without moving the files would orphan them and force re-downloads.
    // Moved per file, so one failure costs one re-download.
    if (Platform.isIOS) {
      await _migrateCacheOutOfDocuments(Directory('${appDir.path}/audio_cache'));
    }

    // Ask for storage permission before using the public folder.
    bool hasPermission = true;
    if (Platform.isAndroid) {
      // Both legacy storage and Android 13+ audio permissions.
      final status = await [Permission.storage, Permission.audio].request();
      hasPermission = status[Permission.storage] == PermissionStatus.granted || 
                      status[Permission.audio] == PermissionStatus.granted;
    }

    // Use the public folder on Android when permission was granted.
    if (Platform.isAndroid && hasPermission) {
      _downloadDir = Directory('/storage/emulated/0/Music/Auvy');
    } else {
      // iOS, or permission denied: use the app's own folder.
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
    // Remove cover files orphaned by older builds (which deleted audio but not its
    // cover). Unawaited; never worth delaying startup.
    unawaited(_sweepOrphanedSidecars());

    _isInitialized = true;
    // Log where both directories are and whether the cache is visible in Files.
    final cacheVisible = Platform.isIOS &&
        _cacheDir!.path.contains('/Documents/');
    print("Audio Cache Manager initialized: ${_cacheIndex.length} cached tracks");
    print("   cache    -> ${_cacheDir?.path} "
        "(${cacheVisible ? 'VISIBLE in Files — should not be' : 'private'})");
    print("   downloads-> ${_downloadDir?.path}");
  }

  /// One-time move of the private cache out of the visible Documents folder.
  /// Safe to repeat: files move one at a time, failures stay put (and re-download
  /// later), and the old directory is removed only once empty.
  Future<void> _migrateCacheOutOfDocuments(Directory old) async {
    try {
      if (!await old.exists()) return;
      if (old.path == _cacheDir!.path) return;
      var moved = 0, failed = 0;
      for (final entity in old.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final target = '${_cacheDir!.path}/${entity.uri.pathSegments.last}';
        try {
          if (File(target).existsSync()) {
            // Already moved on an earlier launch; drop the leftover.
            await entity.delete();
            continue;
          }
          await entity.rename(target);
          moved++;
        } catch (_) {
          failed++;
        }
      }
      if (moved > 0 || failed > 0) {
        print('cache: moved $moved file(s) out of the Files-visible Documents '
            'folder into Application Support'
            '${failed > 0 ? " ($failed could not be moved and will re-download)" : ""}');
      }
      try {
        if (old.listSync().isEmpty) await old.delete();
      } catch (_) {
        // An empty folder left behind is untidy, never harmful.
      }
    } catch (e) {
      print('WARN: cache migration skipped: $e');
    }
  }

  Future<void> _loadCacheIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final indexJson = prefs.getString('audio_cache_index');
      
      if (indexJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(indexJson);
        _cacheIndex.clear();
        _invalidateUrlIndex();
        final base = _downloadDir?.path;
        var rebased = 0;
        var seeded = 0;
        decoded.forEach((key, value) {
          final info = CachedTrackInfo.fromJson(value, _cacheDir!.path, base);
          // Only entries stored with an absolute path can have been re-based; legacy
          // bare file names always resolve against the cache dir.
          final stored = (value['fileName'] ?? '').toString();
          if (info.isExplicitDownload && stored.startsWith('/')) {
            // The stored path didn't resolve and the relative one did (see
            // CachedTrackInfo.fromJson).
            if (info.filePath != stored) {
              rebased++;
            } else if ((value['relPath'] ?? '').isEmpty &&
                base != null &&
                info.filePath.startsWith('$base/')) {
              // Written by a build without relPath: add it now rather than on the next
              // save, or the entry would be lost on the next container move (on iOS, the
              // next reinstall).
              seeded++;
            }
          }
          _cacheIndex[key] = info;
          _invalidateUrlIndex();
        });
        if (rebased > 0) {
          print('cache index: re-based $rebased download path(s) onto the '
              'current app folder — the container moved, the files did not');
        }
        if (rebased > 0 || seeded > 0) await _saveCacheIndex();
        await _repairPlaceholderAlbums();
      }
    } catch (e) {
      print("WARN: Failed to load cache index: $e");
    }
  }

  /// Removes the phantom "Auvy Downloads" album from indexes that already have it.
  /// scanAndImportDownloads skips files already in the index, so tracks imported by
  /// an older build would otherwise keep the bad album name forever. Safe to run
  /// every launch: it does nothing once the index is clean, and
  /// [kDownloadsAlbumTag] is never a real album.
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

  /// [silent] writes the index without notifying the UI. The epoch bump and
  /// `onCacheUpdated` exist so a finished download shows its badge immediately;
  /// an access-time update changes nothing visible.
  Future<void> _saveCacheIndex({bool silent = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final indexJson = jsonEncode(
        _cacheIndex.map((key, value) =>
            MapEntry(key, value.toJson(downloadBase: _downloadDir?.path)))
      );
      await prefs.setString('audio_cache_index', indexJson);
      if (silent) return;
      onCacheUpdated?.call();
      cacheEpoch.value++; // wake reactive download/cached badges + buttons
    } catch (e) {
      print("WARN: Failed to save cache index: $e");
    }
  }

  /// Batches access-time writes. See [_updateAccessTime].
  Timer? _accessSaveTimer;

  void _scheduleSilentIndexSave() {
    _accessSaveTimer?.cancel();
    _accessSaveTimer = Timer(const Duration(seconds: 8), () {
      _accessSaveTimer = null;
      _saveCacheIndex(silent: true);
    });
  }

  /// Bumps whenever the cache index or pending-delete set changes (download done,
  /// track removed, undo). Badges and buttons that read
  /// isCached/isExplicitlyDownloaded rebuild on it so they update immediately.
  static final ValueNotifier<int> cacheEpoch = ValueNotifier(0);

  bool isCached(String songId) {
    if (!_cacheIndex.containsKey(songId)) return false;
    
    final info = _cacheIndex[songId]!;
    final file = File(info.filePath);
    
    try {
      if (!file.existsSync() || file.lengthSync() <= 0) {
        try { if (file.existsSync()) file.deleteSync(); } catch (_) {}
        _cacheIndex.remove(songId);
        _invalidateUrlIndex();
        _saveCacheIndex();
        return false;
      }
    } catch (_) {
      return false;
    }
    
    final age = DateTime.now().difference(info.cachedAt);
    if (age.inDays > maxCacheAgeDays && !info.isExplicitDownload && !pinnedSongIds.contains(songId)) {
      // Only auto-remove if not explicitly downloaded and not a pinned top track.
      removeFromCache(songId);
      return false;
    }
    
    return true;
  }

  /// Whether the audio for an explicit download is actually on disk. The index
  /// and filesystem can disagree (a file deleted outside the app, a failed
  /// write), so callers that skip work for "already downloaded" must check this,
  /// or a stale entry could never be retried.
  bool downloadedFileExists(String songId) {
    final info = _cacheIndex[songId];
    if (info == null) return false;
    try {
      final f = File(info.filePath);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  bool isExplicitlyDownloaded(String songId) {
    return _cacheIndex[songId]?.isExplicitDownload ?? false;
  }

  /// Read-only index entry for a track (size, path, cached-at), used by the Song
  /// Details sheet. Null when there is no local copy.
  CachedTrackInfo? getTrackInfo(String songId) => _cacheIndex[songId];

  String? getCachedPath(String songId) {
    if (!isCached(songId)) return null;
    
    // Mark as recently used whenever the file is requested for playback.
    _updateAccessTime(songId); 
    
    return _cacheIndex[songId]!.filePath;
  }


  /// Which collection a downloaded track belongs to, or null for a loose single.
  ///
  /// Derived from the file's folder (`Albums/<name>/…`, `Playlists/<name>/…`,
  /// `Podcasts/<show>/…`, or `Singles/`). The index never stored the collection,
  /// so the folder is the record, and it can't disagree with itself. Reading it
  /// back avoids an index format migration.
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
  /// Memoised for a few seconds, because one library refresh asks several times
  /// and each call checks every download on disk (synchronously, on the UI
  /// thread), on app resume and every 15 minutes. The short TTL still re-checks
  /// on the next cycle, catching files deleted outside the app, and the cache
  /// epoch invalidates it immediately for changes made in the app.
  List<Song>? _downloadedMemo;
  int _downloadedMemoEpoch = -1;
  DateTime? _downloadedMemoAt;
  static const Duration _downloadedMemoTtl = Duration(seconds: 5);

  /// Songs the user explicitly downloaded whose files are still on disk.
  List<Song> getDownloadedTracks() {
    final memo = _downloadedMemo;
    final at = _downloadedMemoAt;
    if (memo != null &&
        at != null &&
        _downloadedMemoEpoch == cacheEpoch.value &&
        DateTime.now().difference(at) < _downloadedMemoTtl) {
      return memo;
    }
    final fresh = _computeDownloadedTracks();
    _downloadedMemo = fresh;
    _downloadedMemoEpoch = cacheEpoch.value;
    _downloadedMemoAt = DateTime.now();
    return fresh;
  }

  List<Song> _computeDownloadedTracks() {
    return _cacheIndex.values
        .where((info) => info.isExplicitDownload && File(info.filePath).existsSync())
        .map((info) => Song(
              id: info.songId, title: info.title, artist: info.artist,
              // Keep the network cover URL, not the local path: these Songs go into history,
              // recents and the Home mosaic, which are backed up to the cloud, and a local
              // path doesn't survive a reinstall. AuvyImage still finds the local cover from
              // the URL (getLocalPathFromUrl). The local path is used only for imported files
              // with no network URL.
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
              albumTitle: info.albumTitle,
            )).toList();
  }

  /// Audio file extensions recognised when importing user-added files. `.webm` is
  /// included because YouTube's Opus audio comes in a WebM container, so some Auvy
  /// downloads use it and must be re-imported after a reinstall.
  static const Set<String> _audioExts = {
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.mp4', '.weba',
    '.webm'
  };

  /// Scans the public Auvy folder for audio files and registers any not yet
  /// tracked, so a file the user copies in (e.g. from another player) becomes
  /// playable like a local library. Files under `Albums/<name>` or
  /// `Playlists/<name>` are grouped under that name; loose files are singles. Also
  /// prunes index entries whose download file was deleted.
  ///
  /// Returns the number of newly imported tracks. Needs no "All files access":
  /// MediaStore lists the folder's audio with READ_MEDIA_AUDIO, which the app
  /// already holds (the broad MANAGE_EXTERNAL_STORAGE is restricted by Play and a
  /// common malware signal).
  Future<int> scanAndImportDownloads() async {
    if (!_isInitialized) await initialize();
    if (_downloadDir == null) return 0;

    int imported = 0;
    try {
      final basePath = _downloadDir!.path;

      // Migrate old-format imported ids ('local:<relpath>', whose '/' broke the
      // derived lyrics_/cover_ file names). Only the index entry is dropped (the file
      // stays) so it re-imports below with a safe 'local_' id. One-time.
      final legacy = _cacheIndex.keys.where((k) => k.startsWith('local:')).toList();
      for (final k in legacy) {
        _cacheIndex.remove(k);
        _invalidateUrlIndex();
      }
      if (legacy.isNotEmpty) await _saveCacheIndex();

      final existingPaths = _cacheIndex.values.map((i) => i.filePath).toSet();

      // Enumerate via MediaStore rather than listSync: under scoped storage an app
      // can read media it has permission for but can't reliably list a shared folder.
      // MediaStore returns the audio in Music/Auvy whichever app wrote it. Falls back
      // to listSync when the channel is unavailable (headless engine, non-Android).
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

        // On iOS, files added through Files, AirDrop or other apps land in the
        // Documents root ("On My iPhone → Auvy"), not in `Auvy_Downloads`, so scan the
        // root too (same approach as LibraryExportService.findBackups).
        //
        // Not recursive: `Auvy_Backups` and `Inbox` are siblings here, and a recursive
        // walk could import things that aren't user music.
        if (Platform.isIOS) {
          try {
            final docs = await getApplicationDocumentsDirectory();
            for (final dir in [docs, Directory('${docs.path}/Inbox')]) {
              if (!dir.existsSync()) continue;
              for (final ent in dir.listSync(followLinks: false)) {
                if (ent is File) candidatePaths.add(ent.path);
              }
            }
          } catch (_) {/* unreadable folder → nothing to import */}
        }
      }
      print('scan: ${candidatePaths.length} candidate file(s) across '
          '${Platform.isIOS ? "Auvy_Downloads + Documents + Inbox" : "Music/Auvy"}');

      // Count why files were skipped, so "no new tracks found" can say whether the
      // folder was empty, held no audio, or held music already in the library.
      var skippedExt = 0, skippedKnown = 0;
      for (final path in candidatePaths) {
        final dot = path.lastIndexOf('.');
        final ext = dot >= 0 ? path.substring(dot).toLowerCase() : '';
        if (!_audioExts.contains(ext)) {
          skippedExt++;
          continue;
        }
        if (existingPaths.contains(path)) {
          skippedKnown++;
          continue; // already tracked
        }

        // Path relative to the Auvy folder → stable synthetic id and grouping.
        String rel = path.startsWith(basePath) ? path.substring(basePath.length) : path;
        rel = rel.replaceAll('\\', '/');
        if (rel.startsWith('/')) rel = rel.substring(1);

        // A `<file>.auvyid` sidecar (written at download time) carries the real video
        // id and network cover, so a reinstalled download gets its real id back (and
        // groups with its restored album) instead of a synthetic 'local_' id without
        // art.
        String scId = '', scImageUrl = '', scAlbum = '', scTitle = '', scArtist = '';
        try {
          // Check the hidden location first, then the legacy copy beside the audio, so
          // older downloads still get their ids back.
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

        // Filesystem-safe id: it is embedded in derived file names (lyrics_<id>.json,
        // cover_<id>.jpg), so it must not contain path separators or ':'.
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

        // Fall back to the file name ("Artist - Title.ext", our own convention).
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
        if (size <= 0) continue;

        // Sidecar metadata wins (exact title/artist/album and network cover).
        if (scTitle.isNotEmpty) title = scTitle;
        if (scArtist.isNotEmpty) artist = scArtist;
        if (scAlbum.isNotEmpty) album = scAlbum;

        // Auvy's own placeholder album tag is not a collection. Downloads without an
        // album are tagged [kDownloadsAlbumTag] so other players show something
        // sensible; reading it back as an album grouped every such track into an
        // "Auvy Downloads" folder after a reinstall. Cleared after the sidecar so it
        // catches the tag from either source.
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
        // Log each import with its id, so a track that keeps being re-imported and
        // pruned between launches can be traced (a real video id from a sidecar vs a
        // synthetic local_ id from the path).
        print('＋ imported "$title" as $id ← $rel');
      }

      // Prune index entries whose downloaded file was deleted (e.g. from a file
      // manager).
      final gone = _cacheIndex.entries
          .where((e) => e.value.isExplicitDownload && !File(e.value.filePath).existsSync())
          .map((e) => e.key)
          .toList();
      for (final id in gone) {
        // Log the path that was expected, to compare with the path just imported for
        // the same track.
        print('－ pruned $id — no file at ${_cacheIndex[id]?.filePath}');
        _cacheIndex.remove(id);
        _invalidateUrlIndex();
      }

      if (imported > 0 || gone.isNotEmpty) {
        await _saveCacheIndex();
        onCacheUpdated?.call();
      }
      print("Device scan: imported $imported new file(s), pruned ${gone.length} missing "
          "(skipped $skippedKnown already in the library, $skippedExt not audio, "
          "from ${candidatePaths.length} candidate(s)).");
    } catch (e) {
      // Usually a permission problem reading another app's files on Android 11+.
      print("WARN: Device scan failed (grant 'All files access'?): $e");
    }
    return imported;
  }

  bool shouldCacheTrack(String songId) {
    // Caching never stops when full: the size cap is enforced by evicting the
    // least recently used unprotected auto-cached track.
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
              // Keep the network cover URL, not the local path (see getDownloadedTracks).
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
            albumTitle: info.albumTitle,
          ))
      .toList()
    ..sort((a, b) => _cacheIndex[b.id]!.lastAccessedAt.compareTo(_cacheIndex[a.id]!.lastAccessedAt));
  }

    
  Future<List<bool>> batchCacheTrack(
    List<({Song song, String streamUrl, String? userAgent})> batch,
    {int parallelDownloads = 3, 
     bool isExplicitDownload = false,
     String downloadType = 'Single',
     String? collectionName,
     /// Called after each chunk with the number of tracks finished so far, so a
     /// caller can show progress.
     void Function(int done, int total)? onProgress,
    }
  ) async {
    if (!_isInitialized) await initialize();
    
    final results = <bool>[];
    
    for (int i = 0; i < batch.length; i += parallelDownloads) {
      final chunk = batch.sublist(i, (i + parallelDownloads).clamp(0, batch.length));
      
      final chunkResults = await Future.wait(
        chunk.asMap().entries.map((entry) {
          final indexInChunk = entry.key;
          final item = entry.value;
          final trackNum = (downloadType == 'Album' || downloadType == 'Playlist')
              ? (i + indexInChunk + 1)
              : null;
          return cacheTrack(
            item.song,
            item.streamUrl,
            isExplicitDownload: isExplicitDownload,
            userAgent: item.userAgent,
            downloadType: downloadType,     // Pass it down
            collectionName: collectionName, // Pass it down
            trackNumber: trackNum,
          ).catchError((e) {
            print("WARN: Batch Item Failure for ${item.song.title}: $e");
            return false; 
          });
        })
      );
      results.addAll(chunkResults);
      onProgress?.call(results.length, batch.length);
    }
    final ok = results.where((r) => r).length;
    print('batch download complete: $ok/${batch.length} saved'
        "${collectionName != null ? ' for \"$collectionName\"' : ''}");
    return results;
  }

  /// Caches the user's most-played tracks ("My Top 50") ahead of time and pins
  /// them so they aren't evicted. Limited per pass, and only run when allowed (the
  /// caller checks Wi-Fi / data saver). Skips anything already cached or
  /// downloaded.
  bool _isCachingTop = false;
  /// When a Top-50 track last failed to cache, so it isn't retried every pass.
  /// In memory only; a relaunch is a fair time to retry.
  static final Map<String, int> _topCacheFailedAt = {};
  static const int _topCacheRetryMs = 6 * 60 * 60 * 1000;

  Future<void> ensureTopTracksCached(List<Song> topTracks, {int maxPerPass = 6}) async {
    if (!_isInitialized) await initialize();
    if (_isCachingTop) return;
    _isCachingTop = true;
    try {
      // Pin every top track up front, including ones already cached.
      pinnedSongIds = {...pinnedSongIds, ...topTracks.map((s) => s.id)};

      int cachedThisPass = 0;
      // Attempts are capped, not just successes, so a track that can never resolve
      // (removed, region-locked) doesn't run the whole resolve chain every 5 minutes.
      int attemptsThisPass = 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      _topCacheFailedAt.removeWhere((_, at) => now - at > _topCacheRetryMs);
      final audio = AudioService();
      for (final song in topTracks) {
        if (cachedThisPass >= maxPerPass) break;
        if (attemptsThisPass >= maxPerPass * 2) break;
        if (song.id.isEmpty || song.id.startsWith('http')) continue;
        if (isCached(song.id) || isExplicitlyDownloaded(song.id)) continue;
        if (!shouldCacheTrack(song.id)) continue;
        if (_topCacheFailedAt.containsKey(song.id)) continue;
        attemptsThisPass++;
        try {
          // A Top-50 track is played often, so its bytes may already be in the play
          // cache. Promotion is free; resolve a stream only if it finds nothing.
          if (await cacheTrack(song, '')) {
            cachedThisPass++;
            continue;
          }
          final stream = await audio.getStreamWithFallback(song.id, song.title, song.artist);
          final url = stream?['url'];
          var ok = false;
          if (url != null && url.isNotEmpty) {
            ok = await cacheTrack(song, url, userAgent: stream?['user_agent']);
          }
          if (ok) {
            cachedThisPass++;
          } else {
            _topCacheFailedAt[song.id] = now;
          }
        } catch (e) {
          _topCacheFailedAt[song.id] = now;
          print("WARN: Top-track cache failed for ${song.title}: $e");
        }
        // Space out downloads to leave bandwidth for playback.
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (cachedThisPass > 0) print("Cached $cachedThisPass top track(s)");
    } finally {
      _isCachingTop = false;
    }
  }

  /// Whether [path] is inside the public downloads folder. Checked by directory
  /// rather than by `isExplicitDownload`, because that flag is what might be
  /// wrong.
  bool _isInDownloadsDir(String path) {
    final dir = _downloadDir?.path;
    if (dir == null || dir.isEmpty) return false;
    return path.replaceAll('\\', '/').startsWith(dir.replaceAll('\\', '/'));
  }

  /// Where an explicit download belongs in the public folder (creates the
  /// subfolder). Shared by the "already cached, move it" and "fresh download"
  /// paths so both compute it the same way.
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

    // File name convention. Album and playlist downloads start with a zero-padded
    // track number, so file managers and car stereos (which sort alphabetically)
    // keep playing order; singles are "Artist - Title" so a folder of unrelated
    // tracks groups by artist.
    //
    // The `.m4a` extension is provisional: the real container is only known once
    // bytes are on disk (it may be Opus/WebM), and [_retitleToRealContainer] fixes
    // the name afterwards.
    const ext = 'm4a';
    final bool numbered = subFolder.startsWith('Albums/') ||
        subFolder.startsWith('Playlists/');
    if (numbered && trackNumber != null && trackNumber > 0) {
      final n = trackNumber.toString().padLeft(2, '0');
      // Artist included even inside an album folder, since compilations and features
      // make "02 Title" ambiguous once the file is moved.
      return '${targetDir.path}/$n $safeArtist - $safeTitle.$ext';
    }
    return '${targetDir.path}/$safeArtist - $safeTitle.$ext';
  }

  /// Recursively deletes [relative] under the downloads folder, but only if it
  /// really resolves to somewhere inside it.
  ///
  /// The last safeguard before a recursive delete. `p.normalize` collapses `..`
  /// before the check, so `Albums/../..` is judged by where it actually points.
  /// `p.isWithin` is strictly inside, so a name that collapses to the root itself
  /// can never wipe every download.
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

  /// Makes one path segment safe on Android, Windows and macOS at once: strips
  /// reserved characters, control characters, and trailing dots/spaces (which
  /// Windows rejects), collapses repeated whitespace, and never returns an empty
  /// segment.

  /// Whether a finished download contains the whole track.
  ///
  /// Compares the bytes on disk with the expected length, from the response's
  /// `content-length` or the `clen=` parameter in the stream URL. (A plain "more
  /// than 1 MB" check accepted truncated files, which then stopped early on every
  /// play from cache.) The size floor remains only as a fallback when no length is
  /// declared.
  @visibleForTesting
  static bool downloadLooksComplete(
      String title, int onDisk, int declaredLength, String? clenParam) {
    final fromUrl = int.tryParse(clenParam ?? '') ?? 0;
    final expected = declaredLength > 0 ? declaredLength : fromUrl;
    if (expected <= 0) {
      // No length to compare against: keep the old floor, and log it.
      final ok = onDisk > 1024 * 1024;
      if (!ok) {
        print('WARN: "$title": ${onDisk ~/ 1024}KB downloaded and no length was '
            'declared — too small to trust, treating as incomplete');
      }
      return ok;
    }
    if (onDisk >= expected) return true;

    // Allow a small shortfall. Some hosts declare slightly more than they send (a
    // few KB short of tens of MB), which is not a truncation. A dropped connection
    // leaves a large fraction missing, so:
    //
    //   • within 0.5% AND within 128 KB → accepted and logged
    //   • anything more                 → truncated, refused
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

  /// The size the filesystem reports, or 0 if there is no readable file. Used
  /// instead of recorded sizes (index, promotion result, progress totals), which
  /// could claim bytes that weren't there.
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
  /// The folder name [raw] becomes on disk. Exposed so library titles can be
  /// compared with download folder names after both go through the same
  /// sanitiser.
  static String folderNameFor(String raw) => _sanitizeSegment(raw);

  static String _sanitizeSegment(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Windows rejects names ending in '.' or ' '.
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    // Stay well under the 255-byte segment limit once number, separator and
    // extension are added.
    if (s.length > 80) s = s.substring(0, 80).trim();
    return s.isEmpty ? 'Unknown' : s;
  }

  /// Moves a file, falling back to copy and delete. `rename` fails across
  /// filesystems (app storage → public Music), so the fallback is the usual path
  /// here.
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
        // Delete the source only once the copy is verifiably there.
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

  /// The file extension that matches what the bytes actually are, from the
  /// container's magic number, or null if unrecognised.
  ///
  /// Not every download is `.m4a`: YouTube's best audio is Opus in WebM. With the
  /// wrong extension, MP4 tags and cover art can't be written, and Android's media
  /// scanner refuses the file, so other apps can't see it.
  /// Sniffing the bytes also works for files promoted from the native play cache,
  /// where no mime type was ever seen.
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

      // Matroska/WebM; YouTube's Opus arrives here.
      if (at(0, const [0x1A, 0x45, 0xDF, 0xA3])) return 'webm';
      // ISO-BMFF: the box length comes first, so 'ftyp' is at offset 4.
      if (at(4, const [0x66, 0x74, 0x79, 0x70])) return 'm4a';
      if (at(0, const [0x66, 0x4C, 0x61, 0x43])) return 'flac';
      if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
          at(8, const [0x57, 0x41, 0x56, 0x45])) return 'wav';
      // Ogg holds both Opus and Vorbis; the codec header says which. `.opus` is the
      // widely playable name, while `.ogg` implies Vorbis to some players.
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

  /// Renames [path] so its extension matches its real container and returns the
  /// new path (unchanged if already right or if the rename fails; a misnamed file
  /// still plays, so this must never lose a download).
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
      // A re-download of the same track replaces its own previous file.
      final existing = File(target);
      if (existing.existsSync() && target != path) await existing.delete();
      await f.rename(target);
      return target;
    } catch (_) {
      return path;
    }
  }

  /// Caches or downloads a track (audio, cover art and lyrics) and records it
  /// in the index. Returns true when a playable file ended up on disk.
  ///
  /// An empty [streamUrl] means "promote only": copy the bytes from the native
  /// play cache if it holds the whole track, and download nothing.
  /// [isExplicitDownload] puts the file in the public downloads folder and
  /// protects it from eviction.
  Future<bool> cacheTrack(Song song, String streamUrl, {
    bool isExplicitDownload = false, 
    String? userAgent,
    String downloadType = 'Single',
    String? collectionName,
    /// 1-based position within an album/playlist download, used to prefix the file
    /// name so a file manager sorts the folder in playing order. Null for a single
    /// track.
    int? trackNumber,
  }) async {
    if (!_isInitialized) await initialize();
    if (!isExplicitDownload && isExplicitlyDownloaded(song.id)) return true;
    if (!isExplicitDownload && !shouldCacheTrack(song.id)) return false;

    try {
      String filePath;
      int fileSizeBytes = 0;
      String localImagePath = '';
      bool audioDownloadSuccess = false;

      // Should an explicit download reuse the cached bytes?
      //
      // Usually yes: the track you just played is already on disk, so downloading it
      // costs nothing. The exception is a cached Opus/WebM file, which can't hold
      // tags; reusing it would give the user a file with no title, artist or cover.
      // So a user download re-fetches as MP4 in that case, costing one track of data,
      // only when the user asked for a file. Auto-cache never takes this path.
      bool redownloadForTags = false;
      // The old copy, removed only once the replacement is safely on disk, so a
      // failed re-fetch never costs the user the track they had.
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

      // 1. Prepare the file path.
      if (isCached(song.id) && !redownloadForTags) {
        final info = _cacheIndex[song.id]!;
        filePath = info.filePath;
        fileSizeBytes = info.fileSizeBytes;

        // Check the file on disk, not the size the index recorded: an entry claiming
        // zero bytes would otherwise be reported as cached and handed to the decoder as
        // an empty file.
        final onDisk = await _actualSizeOf(filePath);
        if (onDisk <= 0) {
          print('WARN: cache index claims ${song.title} is cached at $filePath '
              '(${info.fileSizeBytes} B) but the file is missing or EMPTY — '
              're-downloading and dropping the stale entry');
          _cacheIndex.remove(song.id);
          _invalidateUrlIndex();
          fileSizeBytes = 0;
          // Fall through to a fresh download with a new path rather than writing over a
          // known-bad file.
          filePath = '';
        } else {
          audioDownloadSuccess = true;
          if (onDisk != info.fileSizeBytes) {
            // Correct the index size quietly and log it once; eviction does its arithmetic
            // with it.
            print('cache index size corrected for ${song.title}: '
                '${info.fileSizeBytes} B → $onDisk B');
            fileSizeBytes = onDisk;
          }
        }

        // The track is already auto-cached in the private folder: move the file into
        // the public downloads folder. Without this, downloading a cached track only
        // flipped `isExplicitDownload` and nothing ever reached /Music/Auvy. The bytes
        // are already local, so no network is used.
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
        // Make room first, except for a tag re-fetch (it replaces bytes already
        // counted) and a promote-only call (no url), which may produce nothing and
        // shouldn't evict a track for that. Promotions are trimmed by the periodic
        // enforceCacheLimit pass.
        if (!redownloadForTags && streamUrl.isNotEmpty) {
          await _ensureCacheSpace(currentPlayingId: song.id);
        }

        if (isExplicitDownload) {
          filePath = await _publicDownloadPath(song,
              downloadType: downloadType,
              collectionName: collectionName,
              trackNumber: trackNumber);
        } else {
          // Internal background cache.
          final fileName = '${song.id}_${DateTime.now().millisecondsSinceEpoch}.m4a';
          filePath = '${_cacheDir!.path}/$fileName';
        }
      }

      // Pooled connections; audio, cover and lyrics download in parallel.
      final pool = HttpPool();
      
      final tasks = <Future<void> Function()>[
        // Task A: audio.
        () async {
          if (!isCached(song.id) || redownloadForTags) {
            // Promotion first: if the native play cache holds the whole track (streamed end
            // to end), copy those bytes instead of downloading again. No data cost; falls
            // through to HTTP only when the play cache doesn't have it all.
            //
            // Skipped for a tag re-fetch, since the play cache holds the untaggable Opus
            // this download is replacing.
            try {
              final promo = redownloadForTags
                  ? null
                  : await NativeAudioEngine.promoteFromPlayCache(song.id, filePath);
              if (promo != null && promo['promoted'] == true) {
                fileSizeBytes = (promo['bytes'] as num?)?.toInt() ?? 0;
                if (fileSizeBytes <= 0) {
                  try { fileSizeBytes = await File(filePath).length(); } catch (_) {}
                }
                // A promotion that produced no bytes failed. Registering an empty file as
                // cached would make playback prefer it and die mid-track, so delete it and fall
                // through to a real download.
                if (fileSizeBytes <= 0) {
                  try { await File(filePath).delete(); } catch (_) {}
                  print("WARN: play-cache promotion for ${song.title} produced an "
                      "EMPTY file — discarding it and downloading properly");
                } else {
                  audioDownloadSuccess = true;
                  _activeDownloads[song.id] = 1.0;
                  _downloadProgressController.add(Map.from(_activeDownloads));
                  return; // promoted from play-cache — skip the HTTP download
                }
              }
            } catch (_) {}
            // Promote-only callers (e.g. the track-end auto-cache) pass an empty url;
            // nothing to download, so stop here.
            if (streamUrl.isEmpty) return;
            int retryCount = 0;
            bool success = false;
            // User downloads retry up to 3 times. Auto-cache gets one attempt, so a flaky
            // connection never re-downloads a whole file from the start again and again.
            final int maxAttempts = isExplicitDownload ? 3 : 1;
            while (retryCount < maxAttempts && !success) {
              // Fresh retry clients must be closed or each failed attempt leaks a socket;
              // pool clients are shared and never closed.
              http.Client? freshClient;
              try {
                // Retries bypass the pool for a fresh connection.
                final client = retryCount == 0 ? pool.getClient() : (freshClient = http.Client());
                final request = http.Request('GET', Uri.parse(streamUrl));
                
                request.headers['User-Agent'] = userAgent ?? 'Mozilla/5.0';
                request.headers['Connection'] = 'keep-alive';
                // YouTube's CDN rejects open-ended ranges (bytes=0-), so bound the request to
                // the content length from the URL.
                final clen = RegExp(r'[?&]clen=(\d+)').firstMatch(streamUrl)?.group(1);
                if (clen != null) {
                  final parsedLen = int.tryParse(clen);
                  if (parsedLen != null && parsedLen > 0) {
                    request.headers['Range'] = 'bytes=0-${parsedLen - 1}';
                  }
                }

                final response = await client.send(request).timeout(const Duration(seconds: 45));

                if (response.statusCode != 200 && response.statusCode != 206) {
                  throw HttpException('Download HTTP ${response.statusCode}');
                }

                final file = File(filePath);
                final sink = file.openWrite();
                
                _activeDownloads[song.id] = 0.0;
                _downloadProgressController.add(Map.from(_activeDownloads));
                
                final contentLength = response.contentLength ?? 0;
                int downloaded = 0;
                // The last fraction broadcast, which differs from the last one computed (see
                // below).
                double lastBroadcast = -1.0;
                
                try {
                  await for (var chunk in response.stream) {
                    sink.add(chunk);
                    downloaded += chunk.length;
                    
                    if (contentLength > 0) {
                      final fraction = downloaded / contentLength;
                      // The map itself stays exact; the download sheet reads it directly.
                      _activeDownloads[song.id] = fraction;

                      // Broadcast at most once per 1% step. Each broadcast copies the downloads map
                      // and rebuilds every download bar on screen, and chunks are small, so per-chunk
                      // updates did hundreds of invisible rebuilds per track.
                      if (fraction - lastBroadcast >= 0.01 || fraction >= 1.0) {
                        lastBroadcast = fraction;
                        _downloadProgressController.add(Map.from(_activeDownloads));
                      }
                    }
                  }
                } finally {
                  _activeDownloads.remove(song.id);
                  _downloadProgressController.add(Map.from(_activeDownloads));
                  await sink.close(); // Ensure sink is closed even if pipe fails
                }

                fileSizeBytes = await file.length();
                success = downloadLooksComplete(
                    song.title, fileSizeBytes, contentLength, clen);
                if (!success) {
                  throw HttpException('Download incomplete: $fileSizeBytes bytes');
                }
                audioDownloadSuccess = true;
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
        },

        // Task B: cover art.
        () async {
          // Each track caches its own cover, keyed by song id. Sharing covers by album
          // title gave every track with the same (or empty) album name the first track's
          // art. If this track's cover is already on disk, reuse it.
          final existingCover = File('${_cacheDir!.path}/cover_${song.id}.jpg');
          if (existingCover.existsSync() && existingCover.lengthSync() > 0) {
            localImagePath = existingCover.absolute.path;
            return;
          }
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
        },

        // Task C: lyrics.
        () async {
          // Not for spoken word (podcasts and audiobook chapters), which have no lyrics.
          // Their ids are URLs, which also can't be used in a file name.
          if (song.isSpokenWord) return;
          try {
            // Called for its effect: getLyrics saves its answer to disk itself, with its
            // verification stamp. The return value is unused on purpose (see below).
            await LyricsService().getLyrics(
              song.title,
              song.artist,
              album: song.albumTitle,
              songId: song.id,
              // Sent here too: this path may be the first to fetch lyrics for a track, and
              // the first answer is the one saved. Without the duration the version check
              // can't run.
              trackDurationMs: LyricsService.durationMsFromDisplay(song.duration),
            ).timeout(const Duration(seconds: 8));
            // No second save here. getLyrics already saved the answer along with
            // `auvyVerifiedAgainstMs`, the length it was checked against; saving
            // `lyrics.toJson()` again would drop that stamp and force a full re-scan on the
            // next play. One writer keeps the record intact
            // (test/lyrics_target_duration_test.dart guards this).
          } catch (e) {
            print("WARN: Lyrics skipped: $e");
          }
        },
      ];
      // A promote-only call (no url, not a download) often ends with nothing on disk,
      // so fetch cover and lyrics only after the audio succeeds; otherwise orphaned
      // cover files pile up. Real downloads keep all three in parallel.
      if (streamUrl.isEmpty && !isExplicitDownload) {
        await tasks[0]();
        if (fileSizeBytes > 0) {
          await Future.wait([tasks[1](), tasks[2]()]);
        }
      } else {
        await Future.wait(tasks.map((t) => t()));
      }

      // Stop here if the download produced nothing, before renaming, tagging and
      // indexing an empty file. This also clears the `_activeDownloads` entry for
      // promote-only calls that found nothing, so no progress entry is left stuck.
      // Playback is unaffected: nothing is indexed, so the track keeps streaming.
      if (fileSizeBytes <= 0 || (!audioDownloadSuccess && streamUrl.isNotEmpty)) {
        try {
          final partial = File(filePath);
          if (filePath.isNotEmpty && await partial.exists()) await partial.delete();
        } catch (_) {}
        // An empty url means a promote-only call, where "nothing to promote" is a
        // normal answer (a track played from a local file or only partly streamed), so
        // it gets its own quieter message.
        if (streamUrl.isEmpty) {
          print('"${song.title}" not promoted — the play-cache does not hold '
              'it whole, and there is no url to fetch it from');
        } else {
          print('WARN: download incomplete or truncated for "${song.title}" ($fileSizeBytes B) — '
              'partial bytes discarded, nothing registered as cached');
        }
        _activeDownloads.remove(song.id);
        _downloadProgressController.add(Map.from(_activeDownloads));
        return false;
      }

      // Give the file the extension its bytes deserve before tagging, since the tag
      // writer picks its format from the name. Downloads only: the private cache is
      // addressed by the index and the player sniffs content anyway.
      if (fileSizeBytes > 0 && isExplicitDownload) {
        final retitled = await _retitleToRealContainer(filePath);
        if (retitled != filePath) {
          print("Named by container: ${retitled.split('/').last}");
          filePath = retitled;
        }
      }

      // The replacement is on disk and non-empty, so the copy it replaces can go. If
      // the re-fetch produced nothing, the original stays and the download reports
      // failure.
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
          final parsedYear = int.tryParse(RegExp(r'(19|20)\d{2}').firstMatch(song.releaseDate)?.group(0) ?? '');
          await MetadataGod.writeMetadata(
            file: filePath,
            metadata: Metadata(
              title: song.title,
              artist: song.artist,
              albumArtist: song.artist.isNotEmpty ? song.artist : null,
              album: song.albumTitle.isNotEmpty && song.albumTitle != 'null' 
                  ? song.albumTitle 
                  : (collectionName ?? kDownloadsAlbumTag),
              trackNumber: trackNumber,
              year: parsedYear,
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
          // Log the extension and the error: a `.webm` here means the MP4 format request
          // didn't take; anything else means the tagger itself failed.
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

      // iOS: fix the duration stored in the file, once. YouTube's audio is
      // fragmented MP4, and AVFoundation adds the declared duration to the fragments'
      // own, so a 3:30 track plays as 7:00 with silence at the end. Streaming repairs
      // this in the native loader; files written here never pass through it. Done
      // after tagging, where every path that produces a file converges. No-op on
      // Android and for non-fragmented files. Awaited, because the index entry below
      // is what makes the file playable.
      if (fileSizeBytes > 0) {
        await NativeAudioEngine.repairAudioFile(filePath);
      }

      // 3. Update the index.
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
      // Downloads survive an uninstall but the index doesn't, so write the real video
      // id and network cover beside the file for a reinstall to re-key it (see
      // _writeDownloadSidecar).
      if (isExplicitDownload || (existing?.isExplicitDownload ?? false)) {
        await _writeDownloadSidecar(filePath, song);
        // After the sidecar, so the scan sees the final name.
        await _notifyMediaStore(filePath);
      }
      // Final check: never register a cache entry without bytes. Several paths lead
      // here (index reuse, promotion, fresh download, move to the public folder), so
      // the file is measured once, here, before the entry is trusted by playback and
      // eviction.
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
        // Re-register with the real size; eviction budgets against it.
        _cacheIndex[song.id] = _cacheIndex[song.id]!.copyWith(
          fileSizeBytes: verifiedBytes,
        );
        await _saveCacheIndex();
      }
      print("Cached: ${song.title} "
          "(${(fileSizeBytes / 1024 / 1024).toStringAsFixed(2)}MB"
          "${isExplicitDownload ? ', download' : ''})");
      // Enforce the cap again now that the real size is known, so a cache just under
      // its limit can't step over it and stay there. The new track is the most
      // recently used, so it can't be the one evicted.
      await enforceCacheLimit(currentPlayingId: song.id);
      onCacheUpdated?.call();
      if (_activeDownloads.containsKey(song.id)) {
        _activeDownloads.remove(song.id);
        _downloadProgressController.add(Map.from(_activeDownloads));
      }
      return true;
    } catch (e) { 
      print("WARN: Cache failed for ${song.title}: $e");
      if (_activeDownloads.containsKey(song.id)) {
        _activeDownloads.remove(song.id);
        _downloadProgressController.add(Map.from(_activeDownloads));
      }
      return false; 
    }
  }

  /// Removes every downloaded file belonging to one album or playlist.
  ///
  /// The folder name comes from [_sanitizeSegment], the same function the
  /// download side uses, so the right folder is found. The deletion itself goes
  /// through a containment check, so a collection named `..` (playlist names are
  /// free text) can never delete outside the downloads folder.
  Future<void> deleteCollectionLocally(String collectionName) async {
    if (!_isInitialized) await initialize();

    final safeCollection = _sanitizeSegment(collectionName);
    final idsToRemove = <String>[];
    
    _cacheIndex.forEach((id, info) {
      if (info.isExplicitDownload) {
        // Tracks with this exact album title, or that live in the target folder.
        if (info.albumTitle == collectionName || info.filePath.contains('/$safeCollection/')) {
          idsToRemove.add(id);
        }
      }
    });

    // 1. Delete each track's audio, lyrics and cover and drop it from the index.
    // By id, so the container the download ended up in doesn't matter.
    for (var id in idsToRemove) {
      removeFromCache(id);
    }
    
    // 2. Remove the folder itself.
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

  /// Album cover art from any cached track of the album.
  String? getAlbumCoverArt(String albumTitle) {
    if (albumTitle.isEmpty || albumTitle == 'null') return null;
    
    // Any track of this album with local cover art.
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
              // Keep the network cover URL, not the local path (see getDownloadedTracks).
              image: info.imageUrl.isNotEmpty ? info.imageUrl : info.localImagePath,
      albumTitle: info.albumTitle,
    )).toList();
  }

  /// A filesystem-safe stand-in for a song id. Normal video ids pass through
  /// unchanged, so existing lyrics files keep their names; anything else (e.g. a
  /// URL id) is hashed, which also keeps long ids under the file name limit.
  static String _lyricsFileId(String songId) {
    // An ordinary video id is 11 safe characters and passes through unchanged.
    if (RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(songId)) return songId;
    // FNV-1a, 32-bit. Stable across runs, unlike Object.hash, which Dart seeds per
    // process and would rename every file on every launch.
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
      // Podcast and radio ids are URLs, which can't be file names, so the id goes
      // through `_lyricsFileId`. It is stable, so older files are still found by
      // readLyrics.
      final file = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      final encoded = jsonEncode(lyricsJson);
      // Skip the write if the file already has these exact contents. A track's
      // lyrics are often saved two or three times per play (auto-cache timer and
      // track-end promotion); reading a few KB is cheaper than rewriting them.
      try {
        if (await file.exists() && await file.readAsString() == encoded) return;
      } catch (_) {}
      await file.writeAsString(encoded);
      print("Lyrics saved to disk for $songId");
    } catch (e) {
      print("WARN: Failed to save lyrics: $e");
    }
  }

  /// The album tag written into a downloaded file that belongs to no album.
  ///
  /// A label for other players, not a collection: an empty album tag shows as
  /// "Unknown album" in most apps. Auvy's own importer must not read it back as an
  /// album (see [scanAndImportDownloads]); the constant is shared so writer and
  /// reader agree.
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

  /// Updates a track's last-used time for LRU eviction.
  ///
  /// The in-memory map is updated immediately, which is what eviction reads.
  /// Saving it is deferred, batched and silent, because encoding the whole index
  /// on every play from cache was expensive and nothing on screen changes. If the
  /// process dies in the window, the track just keeps a slightly older timestamp.
  void _updateAccessTime(String songId) {
    if (_cacheIndex.containsKey(songId)) {
      _cacheIndex[songId] = _cacheIndex[songId]!.copyWith(
        lastAccessedAt: DateTime.now()
      );
      // No _invalidateUrlIndex() here: that index maps imageUrl → localImagePath,
      // which this copyWith can't change, so dropping it would only force a pointless
      // rebuild.
      _scheduleSilentIndexSave();
    }
  }

  void removeFromCache(String songId) {
    _pendingDeleteIds.remove(songId); // committed (or moot) either way
    if (!_cacheIndex.containsKey(songId)) return;
    try {
      final info = _cacheIndex[songId]!;
      final audioFile = File(info.filePath);
      if (audioFile.existsSync()) audioFile.deleteSync();

      // Also remove the lyrics file.
      final lyricsFile = File('${_cacheDir!.path}/lyrics_${_lyricsFileId(songId)}.json');
      if (lyricsFile.existsSync()) lyricsFile.deleteSync();

      // ...and the cover thumbnail, or evictions leave orphaned cover files behind.
      // localImagePath covers both naming schemes (cover_<id>.jpg from cacheTrack,
      // cover_local_<hash>.jpg from the disk scan); the guards skip it when it holds
      // a network URL because the cover download failed.
      final coverPath = info.localImagePath;
      if (coverPath.isNotEmpty &&
          !coverPath.startsWith('http') &&
          coverPath.startsWith(_cacheDir!.path)) {
        final coverFile = File(coverPath);
        if (coverFile.existsSync()) coverFile.deleteSync();
      }

      // Delete the download's sidecar with it, or a later scan would re-import a
      // deleted track. Both locations: the hidden `.auvy/` one and the legacy copy
      // beside the audio.
      for (final sidecar in sidecarCandidates(info.filePath)) {
        try {
          if (sidecar.existsSync()) sidecar.deleteSync();
        } catch (_) {}
      }

      _cacheIndex.remove(songId);
      _invalidateUrlIndex();
      _saveCacheIndex();
      onCacheUpdated?.call();
    } on PathNotFoundException catch (e) {
      // A file that's already gone is the outcome this method wants, not an error;
      // logged quietly so real failures stand out.
      print('cache entry was already gone: $e');
    } catch (e) {
      print("WARN: Failed to remove cache: $e");
    }
  }

  /// Deletes `cover_*.jpg` / `lyrics_*.json` files in the cache directory that no
  /// index entry references (left by older builds or a crash between writing a
  /// file and saving the index). Best-effort and silent.
  Future<void> _sweepOrphanedSidecars() async {
    try {
      if (_cacheDir == null || !await _cacheDir!.exists()) return;
      // Everything the index still points at, by file name.
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

  /// Bytes and track count that the cache limit governs: auto-cached entries only.
  ///
  /// Downloads are exempt from eviction, so they must not count against the
  /// budget either. Counting them made the limit permanently exceeded once
  /// downloads grew large, so every play evicted the entire auto-cache and every
  /// track re-downloaded.
  int _autoCacheBytes() => _cacheIndex.values
      .where((i) => !i.isExplicitDownload)
      .fold(0, (sum, i) => sum + i.fileSizeBytes);

  int _autoCacheCount() =>
      _cacheIndex.values.where((i) => !i.isExplicitDownload).length;

  Future<void> _ensureCacheSpace({String? currentPlayingId, Set<String>? protectedIds}) async {
    // 1. Enforce the max track count.
    if (_autoCacheCount() >= maxCachedTracks) {
      await _evictLRU(
        targetTrackCount: maxCachedTracks - 1,
        currentPlayingId: currentPlayingId,
        protectedIds: protectedIds,
      );
    }

    // 2. Enforce the max size.
    final maxBytes = maxCacheSizeMB * 1024 * 1024;

    if (_autoCacheBytes() > maxBytes) {
      final targetBytes = (maxBytes * 0.85).toInt();
      await _evictLRU(
        targetBytes: targetBytes,
        currentPlayingId: currentPlayingId,
        protectedIds: protectedIds,
      );
    }
  }

  /// Brings the auto-cache back within both limits by evicting least recently used
  /// tracks. Returns the bytes freed.
  ///
  /// Runs after each cache write, against the real size on disk ([_ensureCacheSpace]
  /// runs before a download, when the new track's size is unknown), and from the
  /// 5-minute cleanup, so this is the single enforcement path.
  ///
  /// Evicts down to a low-water mark (95%) rather than exactly to the limit, so
  /// the next track doesn't immediately trigger another pass. 95% keeps the cache
  /// well used while leaving room for a few tracks between passes.
  static const double _evictLowWaterFraction = 0.95;

  Future<int> enforceCacheLimit({String? currentPlayingId, Set<String>? protectedIds}) async {
    if (!_isInitialized) return 0;
    final maxBytes = maxCacheSizeMB * 1024 * 1024;
    final before = _autoCacheBytes();
    if (before <= maxBytes && _autoCacheCount() <= maxCachedTracks) return 0;

    // The trigger stays the real limit; this only sets how far a pass goes.
    await _evictLRU(
      targetBytes: (maxBytes * _evictLowWaterFraction).round(),
      targetTrackCount:
          (maxCachedTracks * _evictLowWaterFraction).floor().clamp(1, maxCachedTracks),
      currentPlayingId: currentPlayingId,
      protectedIds: protectedIds,
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

  /// Re-measures every cached and downloaded file on disk and corrects the index.
  /// Returns how many entries were wrong.
  ///
  /// The index records sizes at write time and can't notice files removed outside
  /// the app, which would make "Storage used" count phantom space. Downloads are
  /// measured too, so the number on screen matches the disk.
  ///
  /// Sizes only: entries are never dropped here. A missing file becomes 0 bytes;
  /// deciding an entry is dead is left to code that can tell a transient read
  /// failure from a real deletion.
  Future<int> reconcileCacheSizes() async {
    if (!_isInitialized || _cacheDir == null) return 0;
    var corrected = 0;
    // Iterate a snapshot of the keys: the await inside the loop lets a finishing
    // download insert into the index, and inserting during iteration throws.
    for (final key in _cacheIndex.keys.toList()) {
      final info = _cacheIndex[key];
      // Evicted while an earlier entry was being measured.
      if (info == null) continue;
      try {
        final f = File(info.filePath);
        final real = f.existsSync() ? await f.length() : 0;
        // Re-read after the await: the entry may have been replaced meanwhile (e.g. a
        // promotion writing its real size), and writing the old value back would undo
        // that.
        final current = _cacheIndex[key];
        if (current == null) continue;
        if (real != current.fileSizeBytes) {
          _cacheIndex[key] = current.copyWith(fileSizeBytes: real);
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
  /// null when there is no readable file. Read from the bytes, since cache files
  /// are all named `.m4a`.
  Future<String?> containerOf(String songId) async {
    final info = _cacheIndex[songId];
    if (info == null) return null;
    final f = File(info.filePath);
    if (!f.existsSync()) return null;
    return (await _sniffAudioExtension(f))?.toUpperCase();
  }

  /// Megabytes the auto-cache uses, rounded up: the minimum for the limit slider,
  /// since a lower limit could only be met by deleting tracks. "Clear cache"
  /// frees space deliberately.
  int autoCacheFloorMB() => (_autoCacheBytes() / (1024 * 1024)).ceil();

  Future<void> _evictLRU({
    int? targetTrackCount,
    int? targetBytes,
    String? currentPlayingId,
    Set<String>? protectedIds,
  }) async {
    final allProtected = {
      if (currentPlayingId != null && currentPlayingId.isNotEmpty) currentPlayingId,
      ...?protectedIds,
      ...protectedPlaybackIds,
    };

    // Eviction candidates: not explicit downloads, not pinned top tracks, and not
    // playing, upcoming or preloaded tracks.
    final candidates = _cacheIndex.values
        .where((info) => 
            !info.isExplicitDownload && 
            !pinnedSongIds.contains(info.songId) &&
            !allProtected.contains(info.songId))
        .toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt)); // Oldest accessed first

    // Log once when the target can't be reached. Pinned top tracks count toward
    // the budget but can't be evicted, so a large Top 50 can leave almost nothing
    // reclaimable.
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
      // Measured against the same auto-cache-only totals the targets came from;
      // including downloads would make the target unreachable. See [_autoCacheBytes].
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
    cleanup();
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

  /// Storage split by kind, for Settings → Storage & data. [getCacheStats] reports
  /// only the auto-cache (what the limit governs); this returns every category
  /// plus the true total, so it matches the system's app-info screen. Downloads
  /// are listed but never limited or auto-evicted.
  Map<String, dynamic> getStorageBreakdown() {
    int autoBytes = 0, autoCount = 0;
    int downloadBytes = 0, downloadCount = 0;
    int imageBytes = 0;
    // Saved lyrics: small, but counted so the total accounts for every byte.
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
      // Cover art is counted separately because it is cheap to drop and quick to
      // re-fetch.
      if (info.localImagePath.isNotEmpty) {
        try {
          final f = File(info.localImagePath);
          if (f.existsSync()) imageBytes += f.lengthSync();
        } catch (_) {
          // A missing or unreadable thumbnail shouldn't break the breakdown.
        }
      }
    }

    // Listed from disk rather than from the index, so lyrics left behind by a
    // missed eviction are counted too.
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

  /// Full wipe used by "Delete account" and by an account change that asks for
  /// it (wipeAudio): removes the
  /// auto-cache, the downloads and their files, and the whole index. Returns true
  /// only when storage really is clean.
  ///
  /// The result matters: downloads are wiped on an account change so one person's
  /// files can't enter another's library. A wipe that failed but reported success
  /// let the startup scan re-import the old files into the new account.
  Future<bool> wipeEverything() async {
    if (!_isInitialized) await initialize();
    var clean = true;
    try {
      // Remove every indexed track (deletes each file and its lyrics).
      for (final id in _cacheIndex.keys.toList()) {
        removeFromCache(id);
      }
      _cacheIndex.clear();
      _invalidateUrlIndex();
      await _saveCacheIndex();

      // Delete the public download tree (Albums, Singles, etc.) so nothing is left
      // behind.
      if (_downloadDir != null && _downloadDir!.path != _cacheDir?.path) {
        try {
          if (_downloadDir!.existsSync()) _downloadDir!.deleteSync(recursive: true);
          await _downloadDir!.create(recursive: true);
        } on PathNotFoundException {
          // A folder that is already gone is the goal, not a failure. Treating "nothing
          // to delete" (errno 2) as failure withheld the owner stamp and made every
          // launch wipe again.
          try {
            await _downloadDir!.create(recursive: true);
          } catch (_) {}
          print('download folder was already absent — nothing to wipe');
        } catch (e) {
          clean = false;
          print("WARN: Could not wipe download folder: $e");
        }
        // Verify against the disk, not the delete result or the directory listing:
        // MediaStore can list files that no longer exist, so each entry is checked
        // with existsSync before it counts as a survivor.
        try {
          if (_downloadDir!.existsSync()) {
            final left = _downloadDir!
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.existsSync())
                .length;
            if (left > 0) {
              clean = false;
              logEvent('WARN: $left download file(s) survived the wipe at '
                  '${_downloadDir!.path} — they must NOT be imported into the '
                  'next account');
            }
          }
        } catch (e) {
          clean = false;
          print('WARN: could not verify the download folder is empty: $e');
        }
      }
      print(clean
          ? 'All audio (cache + downloads) wiped.'
          : 'WARN: audio wipe INCOMPLETE — files remain on disk');
      onCacheUpdated?.call();
      return clean;
    } catch (e) {
      print("ERROR: wipeEverything failed: $e");
      return false;
    }
  }

  /// Local cover path if cached, otherwise [fallbackUrl].
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

  /// Writes `cover.jpg` beside a download whose container can't hold a picture.
  /// Most players (desktop, Android, Plex/Jellyfin) fall back to `cover.jpg` in the
  /// same folder, so the track still shows artwork. One file per folder.
  ///
  /// Album and playlist folders only: `Singles/` holds unrelated tracks, and one
  /// folder cover would show the first single's art for all of them. Skipped when
  /// a cover already exists.
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
      // Cosmetic; a download must never fail because its artwork didn't copy.
    }
  }

  /// Tells Android a new file exists so it is added to the media store. Writing
  /// to /Music doesn't register anything by itself, so without this a download
  /// could stay invisible to other apps for hours. Fire-and-forget; Auvy plays the
  /// file from its own index either way.
  Future<void> _notifyMediaStore(String path) async {
    if (path.isEmpty || !_isInDownloadsDir(path)) return;
    try {
      await const MethodChannel('com.auvy.app/folder')
          .invokeMethod('scanMedia', {'path': path});
    } catch (_) {}
  }

  /// Writes a small `.auvyid` sidecar with a download's real video id, network
  /// cover and album/title/artist. [scanAndImportDownloads] reads it after a
  /// reinstall so the file gets its real id and cover back instead of a
  /// synthetic `local_` id. Skips synthetic and URL ids.
  Future<void> _writeDownloadSidecar(String audioPath, Song song) async {
    if (song.id.isEmpty ||
        song.id.startsWith('local_') ||
        song.id.startsWith('http')) return;
    try {
      final target = sidecarFileFor(audioPath);
      await target.parent.create(recursive: true);
      // Tells Android's media scanner to skip this directory, so sidecars never show
      // up in Gallery, music apps or recent files. (iOS has no such scanner.)
      final noMedia = File('${target.parent.path}/.nomedia');
      if (Platform.isAndroid && !noMedia.existsSync()) {
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
      // Remove the legacy copy that used to sit beside the audio.
      try {
        final legacy = File('$audioPath.auvyid');
        if (legacy.existsSync()) await legacy.delete();
      } catch (_) {}
    } catch (_) {}
  }

  /// Where a download's metadata sidecar lives: a hidden `.auvy` subfolder of the
  /// downloads folder, so the folder the user browses contains only audio. The
  /// leading dot hides it from file managers, and a `.nomedia` marker keeps the
  /// media scanner out.
  static File sidecarFileFor(String audioPath) {
    final f = File(audioPath);
    final name = f.uri.pathSegments.isEmpty ? '' : f.uri.pathSegments.last;
    return File('${f.parent.path}/.auvy/$name.auvyid');
  }

  /// Both possible sidecar locations, new first. Older installs have sidecars
  /// beside the audio, and a reinstall scan must still find them.
  static List<File> sidecarCandidates(String audioPath) => [
        sidecarFileFor(audioPath),
        File('$audioPath.auvyid'),
      ];

  /// Reverse lookup: remote image URL → local cover path.
  ///
  /// [getLocalPathFromUrl] is called from `AuvyImage.build()` for every artwork on
  /// every rebuild, and scanning the whole index per call was expensive. Built
  /// lazily after the index changes, so the cost is paid once per change.
  /// Staleness is harmless: a miss means "use the network image", and callers
  /// verify the file before trusting a hit.
  Map<String, String>? _urlToLocalPath;

  /// Drops the reverse index. Called wherever [_cacheIndex] changes, including
  /// access-time updates, so a future field can't silently fall out of sync.
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

  /// Resolves a remote URL to a previously cached local file path.
  ///
  /// [verifyExists] false skips the existence check, for callers that check
  /// themselves (AuvyImage does, through its memoised `_FileExistsCache`). The
  /// default is true, for callers that only test for null.
  String? getLocalPathFromUrl(String url, {bool verifyExists = true}) {
    if (url.isEmpty || !url.startsWith('http')) return null;
    final local = _urlIndex[url];
    if (local == null) return null; // not cached — no stat needed at all
    if (!verifyExists) return local;
    return File(local).existsSync() ? local : null;
  }

  void cleanup() {
    final now = DateTime.now();
    final expired = <String>[];
    
    _cacheIndex.forEach((id, info) {
      // Don't expire explicit downloads, pinned top tracks or tracks in playback.
      if (!info.isExplicitDownload && !pinnedSongIds.contains(id) && !protectedPlaybackIds.contains(id)) {
        final age = now.difference(info.cachedAt);
        if (age.inDays > maxCacheAgeDays) {
          expired.add(id);
        }
      }
    });
    
    for (var id in expired) {
      removeFromCache(id);
    }
    
    // Log only when something expired.
    if (expired.isNotEmpty) {
      print('AudioCacheManager cleanup: removed ${expired.length} '
          'expired track${expired.length == 1 ? '' : 's'}');
    }
  }
}

/// One row of the cache index: where a file is, how big, and when last used.
/// Old entries may lack newer fields. `fileSizeBytes` is measured from disk,
/// because eviction budgets against it.
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

  // Copy with changes; JSON (de)serialisation below.
  CachedTrackInfo copyWith({
    DateTime? lastAccessedAt,
    bool? isExplicitDownload,
    /// Corrected after re-measuring the file (see
    /// [AudioCacheManager.reconcileCacheSizes]).
    int? fileSizeBytes,
    /// Cleared by [AudioCacheManager._repairPlaceholderAlbums] when it holds the
    /// placeholder tag instead of a real album.
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

  /// [downloadBase] is the current downloads folder, used to store a relative path
  /// so the entry survives the folder moving (see [fromJson]).
  Map<String, dynamic> toJson({String? downloadBase}) => {
    'songId': songId, 
    'title': title, 
    'artist': artist, 
    'albumTitle': albumTitle,
    'imageUrl': imageUrl, 
    'imageName': localImagePath.isNotEmpty ? localImagePath.split('/').last : '', 
    'fileName': isExplicitDownload ? filePath : filePath.split('/').last,
    if (isExplicitDownload &&
        downloadBase != null &&
        downloadBase.isNotEmpty &&
        filePath.startsWith('$downloadBase/'))
      'relPath': filePath.substring(downloadBase.length + 1),
    'fileSizeBytes': fileSizeBytes, 
    'cachedAt': cachedAt.toIso8601String(),
    'lastAccessedAt': lastAccessedAt.toIso8601String(), 
    'isExplicitDownload': isExplicitDownload,
  };

  /// [basePath] is the cache folder; [downloadBase] the downloads folder.
  ///
  /// Auto-cached tracks store a bare file name and downloads a full path. On iOS
  /// downloads live inside the app container, whose path contains a UUID that can
  /// change on update or reinstall; the files survive but absolute paths stop
  /// resolving. So downloads also store `relPath`, used only when the absolute
  /// path no longer exists. Android keeps resolving by the absolute path as
  /// before.
  factory CachedTrackInfo.fromJson(Map<String, dynamic> json, String basePath,
      [String? downloadBase]) {
    final String fileName = json['fileName'] ?? '';
    final String imageName = json['imageName'] ?? '';
    final bool isExplicit = json['isExplicitDownload'] ?? false;

    String resolvedPath;
    if (isExplicit && fileName.startsWith('/')) {
      resolvedPath = fileName; 
      final String rel = json['relPath'] ?? '';
      if (rel.isNotEmpty &&
          downloadBase != null &&
          downloadBase.isNotEmpty &&
          !File(resolvedPath).existsSync()) {
        // Only when the recorded path is really gone. Always preferring the re-based
        // path could redirect an Android entry that points outside the downloads
        // folder (an imported file, a restored backup) to a different file.
        final rebased = '$downloadBase/$rel';
        if (File(rebased).existsSync()) resolvedPath = rebased;
      }
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