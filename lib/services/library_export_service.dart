import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A copy of your library that you own
///
/// Writes the library, taste profile and recognition history to one `.backup`
/// file in a public folder the user can reach, and reads it back — including
/// files written by an earlier build as bare `.json`, and (via
/// [ForeignBackupReader]) backups written by other music apps entirely.
///
/// WHY THIS EXISTS. Every existing safety net for this data is one the app
/// controls: the cloud backup needs an approved account and a working Worker,
/// the `_last_good` snapshot lives in the app's own prefs, and both are gone the
/// moment the install is. Those protect against Auvy's mistakes; they do not
/// protect against Auvy being unavailable. A file in a folder the user can see,
/// copy to a laptop and keep is the only backup that survives the app itself —
/// and after a session spent chasing ways a restore can silently return nothing,
/// that gap is worth closing.
///
/// Deliberately PLAIN JSON, not the encrypted cloud format. The point is that the
/// user can open it, read it and keep it somewhere else; an opaque blob they
/// cannot inspect fails the only purpose it has. Nothing here is a credential —
/// it is playlists, likes, play counts and titles, which is exactly what the
/// user already sees on screen. Cookies, tokens and encryption keys are NOT
/// exported, and there is no code path here that could reach them.
class LibraryExportService {
  LibraryExportService._();
  static final LibraryExportService instance = LibraryExportService._();

  /// PREFERRED locations, in order. Public so the file is reachable from a file
  /// manager or a USB cable without root — a backup inside app-private storage is
  /// invisible and dies with the install, which defeats most of the point.
  ///
  /// NOT `Music/Auvy`, WHICH CANNOT HOLD THIS FILE AT ALL. That was the first
  /// choice because downloads already live there, and it failed every time:
  ///
  ///   PathAccessException: '/storage/emulated/0/Music/Auvy/auvy-library-….json'
  ///   OS Error: Operation not permitted, errno = 1
  ///
  /// MediaStore's `Music/` accepts AUDIO types only, so a `.json` is rejected no
  /// matter what permission the app holds — downloads succeed there precisely
  /// because `.m4a` is audio. `Download/` and `Documents/` accept arbitrary
  /// files, which is what a backup needs, and Downloads is also where a person
  /// already looks for a file an app gave them.
  static const List<String> _publicDirs = [
    '/storage/emulated/0/Download/Auvy',
    '/storage/emulated/0/Documents/Auvy',
  ];

  /// Where the export can actually be written.
  ///
  /// AN EXPORT THAT SILENTLY FAILS IS WORSE THAN NO EXPORT BUTTON. The first
  /// version wrote only to the public folder and returned null on any error, so a
  /// missing storage permission looked identical to a bug and said nothing about
  /// which — reported simply as "Export failed". A backup feature that cannot
  /// explain itself is not a safety net.
  ///
  /// So it falls back to app-private storage, exactly as the download folder
  /// already does (see AudioCacheManager's dir setup). A private file is a
  /// weaker backup — it goes with the install, but it is a real one, and the
  /// caller is told where it landed so the difference is visible rather than
  /// hidden.
  /// The app-private fallback, used only when the public write actually fails.
  Future<Directory?> _privateDir() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/Auvy_Backups');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (e) {
      print('WARN: export: no writable location at all ($e)');
      return null;
    }
  }

  /// Write [bytes] to the public folder, falling back to private storage.
  /// Returns the path written, or null if neither worked.
  ///
  /// NO SEPARATE "CAN I WRITE HERE?" PROBE. The first version tested the
  /// folder by writing `.auvy_write_test`, which ALWAYS failed:
  ///
  ///   PathAccessException: '/storage/emulated/0/Music/Auvy/.auvy_write_test'
  ///   OS Error: Operation not permitted, errno = 1
  ///
  /// Android refuses HIDDEN files (leading dot) in MediaStore-backed media
  /// folders whatever permission the app holds — downloads land in that same
  /// folder fine because `.m4a` is a recognised media type. So the probe was
  /// testing a rule that had nothing to do with permission, and every export
  /// silently took the private fallback while the user had granted storage.
  ///
  /// Attempting the REAL write is the only test whose answer means anything.
  /// Save a diagnostic file to Download/Auvy, reusing the MediaStore path the
  /// library backup uses. Public so the activity log can share it rather than
  /// duplicating the scoped-storage handling. See _writeSomewhere for why a
  /// plain File write into /Download cannot work here.
  Future<String?> saveDiagnosticFile(String filename, List<int> bytes) =>
      _writeSomewhere(filename, bytes);

  Future<String?> _writeSomewhere(String filename, List<int> bytes) async {
    // Mediastore first, because a path cannot write here at all.
    //
    // Auvy holds no "all files access" (deliberately. See the manifest), and
    // under scoped storage that makes every File write into /Download or
    // /Documents fail with EPERM. So the loop below ALWAYS fell through to
    // app-private storage, and app-private storage is hidden from every file
    // manager on Android 11+, which is why an export the app reported as saved
    // could not be found anywhere on the phone.
    //
    // MediaStore's Downloads collection needs no permission whatsoever on API
    // 29+, and the file it produces is a real, visible one in Download/Auvy.
    try {
      final saved = await const MethodChannel('com.auvy.app/backup')
          .invokeMethod<String>('saveToDownloads', {
        'name': filename,
        'bytes': Uint8List.fromList(bytes),
      });
      if (saved != null && saved.isNotEmpty) return saved;
    } catch (e) {
      print('WARN: export: MediaStore write unavailable ($e)');
    }

    // Each candidate is TRIED, not tested: OEM skins differ about which public
    // folders exist and accept writes, and the only reliable probe is the write
    // itself. See the note on _publicDirs. Still reached on pre-API-29 devices
    // and if the channel is ever missing.
    for (final path in _publicDirs) {
      try {
        final pub = Directory(path);
        if (!await pub.exists()) await pub.create(recursive: true);
        final file = File('${pub.path}/$filename');
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      } catch (e) {
        print('WARN: export: $path not writable ($e)');
      }
    }
    print('WARN: export: no public folder accepted the file — using private storage');
    final priv = await _privateDir();
    if (priv == null) return null;
    try {
      final file = File('${priv.path}/$filename');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      print('WARN: export: private write failed too ($e)');
      return null;
    }
  }

  /// Bumped when the SHAPE changes, so a future build can refuse or migrate a
  /// file it does not understand instead of importing nonsense.
  ///
  /// 2 = the `.backup` container (a zip holding [_manifestEntry] and
  /// [_payloadEntry]). Version 1 was a bare `.json` file; [import] still reads
  /// those, because a backup format that abandons its own old files is not a
  /// backup format.
  static const int formatVersion = 2;

  /// Entry names inside a `.backup`. Stable — a future reader identifies the
  /// container by these, not by the file extension.
  static const String _manifestEntry = 'auvy_manifest.json';
  static const String _payloadEntry = 'auvy_library.json';

  /// The keys worth carrying. Deliberately a NAMED LIST rather than "every pref":
  ///
  ///  • A blanket dump would sweep up device settings, session flags and the
  ///    access-approval markers — importing those onto another install would
  ///    hand it another account's state, which is the cross-account leak this
  ///    codebase already had once.
  ///  • It would also grow silently. A named list means adding something to the
  ///    export is a decision someone makes on purpose.
  static const List<String> _exportKeys = [
    'auvy_library_data',
    'auvy_history_v2',
    'auvy_recognition_history',
    'recent_playlists_v1',
    'auvy_artwork_overrides_v2',
    'auvy_podcast_positions',
    'intel_play_counts',
    'intel_play_history',
    'intel_first_timestamps',
    'intel_timestamps',
    'intel_tracks',
    'intel_metadata',
    'intel_artists',
    'intel_genres',
    'intel_history',
  ];

  /// Write the export and return the file path, or null when it could not be
  /// written (no permission, no storage). Never throws at the caller.
  Future<String?> export() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, String>{};
      for (final k in _exportKeys) {
        final v = prefs.getString(k);
        if (v != null && v.isNotEmpty) data[k] = v;
      }
      // Nothing to save is not a failure, but it must not produce a file that
      // could later be imported OVER a real library. See the guard in import().
      if (data.isEmpty) return null;

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final manifest = jsonEncode({
        'app': 'Auvy',
        'format': formatVersion,
        'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
        // Counted at write time so the import can describe the file BEFORE
        // applying it — "restore 412 tracks" is a decision, "restore" is a leap.
        'summary': await _summarise(prefs),
      });
      final payload = jsonEncode({'data': data});

      // A zip, AND the contents are still plain JSON.
      //
      // `.backup` is what this class of app writes (Metrolist, and the InnerTune
      // family it comes from, all use the extension), so a file from Auvy is
      // recognisable as a music-library backup rather than an anonymous .json —
      // and Android stops trying to preview it as a text document. The container
      // also compresses: a library of a few thousand tracks is mostly repeated
      // json keys and thumbnail urls, which deflates to roughly a tenth.
      //
      // What it is NOT is an excuse to make the contents opaque. Unzip it with
      // anything and both entries are readable json — that was the whole point
      // of this feature and the container does not change it.
      final archive = Archive()
        ..addFile(ArchiveFile(
            _manifestEntry, utf8.encode(manifest).length, utf8.encode(manifest)))
        ..addFile(ArchiveFile(
            _payloadEntry, utf8.encode(payload).length, utf8.encode(payload)));
      final zipped = ZipEncoder().encode(archive);
      return await _writeSomewhere('auvy-library-$stamp.backup', zipped);
    } catch (e) {
      // Named, not swallowed: an export that fails silently is indistinguishable
      // from a bug, and this is the feature people rely on when they distrust
      // everything else.
      print('WARN: export failed: $e');
      return null;
    }
  }

  /// Human-readable counts, so an import can say what it is about to do.
  Future<Map<String, int>> _summarise(SharedPreferences prefs) async {
    int playlists = 0, likedSongs = 0, items = 0;
    try {
      final raw = prefs.getString('auvy_library_data');
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) {
          final pl = j['playlistSongs'];
          if (pl is Map) playlists = pl.length;
          final ls = j['likedSongs'];
          if (ls is List) likedSongs = ls.length;
          final ai = j['allItems'];
          if (ai is List) items = ai.length;
        }
      }
    } catch (_) {}
    return {'playlists': playlists, 'likedSongs': likedSongs, 'rows': items};
  }

  /// Every backup file this device can see, newest first — Auvy's own and any
  /// other music app's.
  ///
  /// SCANNED, NOT PICKED. A system file picker would be the obvious route and
  /// it costs a plugin, a permission dance and a UI the user has to navigate to a
  /// folder they may not remember. Every backup worth restoring is written to one
  /// of a handful of known places — Download, Documents, Music, the storage root,
  /// or a folder named after the app that wrote it, so the app can simply LOOK,
  /// and offer what it found. The scan is bounded: named roots, one level of
  /// subfolders, and `Android/` is skipped (it is other apps' private data and a
  /// deep, slow walk).
  Future<List<File>> findBackups() async {
    final roots = <String>[
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Music',
      '/storage/emulated/0',
      ..._publicDirs,
      '/storage/emulated/0/Music/Auvy',
    ];
    final found = <String, File>{};

    // Names that suggest a music export. `.backup` is unconditional (it is this
    // family's extension and nothing else uses it); a `.zip`, `.json` or `.csv`
    // has to look the part, or the list would fill with every archive and config
    // file on the device and the user would have to hunt through it.
    const hints = [
      'spotify', 'playlist', 'library', 'export', 'mydata', 'my_data',
      'tracks', 'songs', 'liked', 'backup', 'metrolist', 'innertune',
      'outertune', 'auvy', 'music'
    ];
    bool interesting(String path) {
      final lower = path.toLowerCase();
      if (lower.endsWith('.backup')) return true;
      if (!lower.endsWith('.json') &&
          !lower.endsWith('.csv') &&
          !lower.endsWith('.zip')) {
        return false;
      }
      final name = lower.split('/').last;
      return hints.any(name.contains);
    }

    Future<void> scan(Directory dir, {required bool recurse}) async {
      try {
        if (!await dir.exists()) return;
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is File) {
            if (interesting(entity.path)) found[entity.path] = entity;
          } else if (entity is Directory && recurse) {
            final name = entity.path.split('/').last;
            // Android/ is other apps' sandboxes: not ours to read, and slow.
            if (name == 'Android' || name.startsWith('.')) continue;
            await scan(entity, recurse: false);
          }
        }
      } catch (_) {
        // An unreadable folder is normal on scoped storage — skip it quietly.
      }
    }

    for (final r in roots) {
      await scan(Directory(r), recurse: true);
    }
    try {
      final appDir = await getApplicationDocumentsDirectory();
      await scan(Directory('${appDir.path}/Auvy_Backups'), recurse: false);
    } catch (_) {}

    final files = found.values.toList();
    files.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return b.path.compareTo(a.path);
      }
    });
    return files;
  }

  /// The most recent export on disk, or null. Lets the UI offer "restore" without
  /// making the user hunt for a filename.
  Future<File?> latestExport() async {
    // BOTH locations, because an export may have landed in either — see
    // _resolveDir. Searching only the public folder would hide a private backup
    // and tell the user there is nothing to restore when there is.
    final dirs = <Directory>[];
    for (final p in _publicDirs) {
      try {
        dirs.add(Directory(p));
      } catch (_) {}
    }
    // The old Music/Auvy location is searched too, so a backup written by an
    // earlier build is still offered rather than reported as missing.
    try {
      dirs.add(Directory('/storage/emulated/0/Music/Auvy'));
    } catch (_) {}
    try {
      final appDir = await getApplicationDocumentsDirectory();
      dirs.add(Directory('${appDir.path}/Auvy_Backups'));
    } catch (_) {}

    final files = <File>[];
    for (final dir in dirs) {
      try {
        if (!await dir.exists()) continue;
        files.addAll(dir.listSync().whereType<File>().where((f) =>
            f.path.contains('auvy-library-') &&
            (f.path.endsWith('.backup') || f.path.endsWith('.json'))));
      } catch (_) {}
    }
    if (files.isEmpty) return null;
    // The filename carries an ISO stamp, so a name sort IS a time sort, and it
    // works across the two folders without stat-ing every file.
    files.sort((a, b) =>
        b.path.split('/').last.compareTo(a.path.split('/').last));
    return files.first;
  }

  /// Let the user pick any backup file on the device, through the system picker.
  ///
  /// THIS IS THE ONLY WAY TO READ ANOTHER APP'S BACKUP. [findBackups] can
  /// only ever see files Auvy itself wrote: without "all files access" a scan of
  /// /Download returns nothing, so a Metrolist or Spotify export sitting right
  /// there was invisible and the restore list looked broken. Choosing the file
  /// IS the permission grant, and it also reaches Drive, OneDrive and an SD card,
  /// none of which a path-based scan could ever touch.
  ///
  /// Returns the copy in the cache and the file's real display name, or null when
  /// the user cancelled.
  Future<({File file, String name})?> pickBackupFile() async {
    try {
      final res = await const MethodChannel('com.auvy.app/backup')
          .invokeMapMethod<String, String>('pickFile');
      final path = res?['path'];
      if (path == null || path.isEmpty) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      return (file: file, name: res?['name'] ?? path.split('/').last);
    } catch (e) {
      print('WARN: restore: file picker unavailable ($e)');
      return null;
    }
  }

  /// Read the manifest + payload out of a file, whichever Auvy format it is.
  ///
  /// Returns null when the file is not an Auvy backup at all — including when it
  /// is a foreign one, which [ForeignBackupReader] handles instead.
  /// SIZE CEILINGS — THE SAME POLICY AS ForeignBackupReader
  ///
  /// This reads a file the user PICKED, which means any file at all. Reading it
  /// materialises it twice before anything is parsed — the compressed bytes and
  /// the decoded archive, and a third time when an entry's `content` is
  /// touched, because that is when it decompresses.
  ///
  /// So a merely large file can exhaust a mid-range device, and one crafted to
  /// decompress enormously (a few KB expanding to gigabytes) kills the app from
  /// the import picker. ForeignBackupReader had exactly this hole and carries the
  /// same two ceilings now; **change both together** — they are one policy about
  /// how much an untrusted backup may weigh, and this file is the other half.
  ///
  /// An Auvy export of a large library is a few hundred KB, since it is JSON that
  /// deflates to roughly a tenth. These sit far above any real file.
  static const int _maxArchiveBytes = 256 * 1024 * 1024;
  static const int _maxEntryBytes = 512 * 1024 * 1024;

  Future<_AuvyBackup?> _open(File file) async {
    try {
      final onDisk = await file.length();
      if (onDisk > _maxArchiveBytes) {
        print('WARN: import: refusing a ${onDisk ~/ (1024 * 1024)}MB file '
            '(ceiling ${_maxArchiveBytes ~/ (1024 * 1024)}MB) — an Auvy export of '
            'a large library is a few hundred KB');
        return null;
      }
      final bytes = await file.readAsBytes();
      // A zip starts "PK". Sniffing the CONTENT rather than the
      // extension means a renamed file still restores, and a `.backup` that is
      // actually someone else's format is rejected here rather than half-read.
      final isZip = bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04;
      if (isZip) {
        final archive = ZipDecoder().decodeBytes(bytes);
        Map<String, dynamic>? manifest;
        Map<String, dynamic>? payload;
        for (final f in archive.files) {
          // THE HEADER'S CLAIM, BEFORE `content` DECOMPRESSES ANYTHING.
          // Checking the size after access would be checking after the damage.
          if (f.size > _maxEntryBytes) {
            print('WARN: import: "${f.name}" claims '
                '${f.size ~/ (1024 * 1024)}MB uncompressed — refusing rather '
                'than decompressing it');
            return null;
          }
          if (f.name == _manifestEntry) {
            final j = jsonDecode(utf8.decode(f.content as List<int>));
            if (j is Map) manifest = j.cast<String, dynamic>();
          } else if (f.name == _payloadEntry) {
            final j = jsonDecode(utf8.decode(f.content as List<int>));
            if (j is Map) payload = j.cast<String, dynamic>();
          }
        }
        if (manifest == null || payload == null) return null;
        final data = payload['data'];
        if (data is! Map) return null;
        return _AuvyBackup(manifest, data.cast<String, dynamic>());
      }

      // Format 1: the whole thing in one json object, data nested inside.
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map) return null;
      final data = j['data'];
      if (data is! Map) return null;
      return _AuvyBackup(j.cast<String, dynamic>(), data.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Describe a file without applying it, so the caller can confirm first.
  ///
  /// Accepts both Auvy formats and refuses anything newer than this build
  /// understands — a file from a future version is not something to guess at.
  Future<Map<String, int>?> peek(File file) async {
    final backup = await _open(file);
    if (backup == null) return null;
    final format = backup.manifest['format'];
    if (format is! int || format > formatVersion) return null;
    final s = backup.manifest['summary'];
    if (s is Map) {
      return s.map((k, v) => MapEntry(k.toString(), (v is int) ? v : 0));
    }
    return const {};
  }

  /// Apply an export. Returns the number of keys restored, or -1 on refusal.
  ///
  /// REFUSES TO REPLACE CONTENT WITH EMPTINESS. Same rule the cloud restore
  /// learned the hard way: a newer file is not automatically a better one, and
  /// the local copy is gone the moment it is overwritten. A key whose incoming
  /// value holds nothing is SKIPPED when the local one holds something, so a
  /// stale or truncated file cannot quietly erase a real library.
  ///
  /// Does not touch device settings, session state or approval markers — see
  /// [_exportKeys] for why the list is named rather than inferred.
  Future<int> import(File file) async {
    try {
      final backup = await _open(file);
      if (backup == null) return -1;
      final format = backup.manifest['format'];
      if (format is! int || format > formatVersion) return -1;
      final data = backup.data;

      final prefs = await SharedPreferences.getInstance();
      var restored = 0;
      for (final entry in data.entries) {
        final key = entry.key.toString();
        // Only keys this version knows about. An unexpected key in a
        // hand-edited file must not become a pref write.
        if (!_exportKeys.contains(key)) continue;
        final incoming = entry.value;
        if (incoming is! String || incoming.isEmpty) continue;
        if (_isEmptyPayload(incoming) &&
            !_isEmptyPayload(prefs.getString(key) ?? '')) {
          continue; // would trade content for nothing
        }
        await prefs.setString(key, incoming);
        restored++;
      }
      return restored;
    } catch (_) {
      return -1;
    }
  }

  /// Does this JSON payload carry no user content? Counts list entries at the top
  /// level and one level down, so it works for the library map and for a bare
  /// history array without knowing either schema. Unparseable → NOT empty, so
  /// something unreadable is never used as grounds to overwrite.
  static bool _isEmptyPayload(String blob) {
    if (blob.isEmpty) return true;
    try {
      final decoded = jsonDecode(blob);
      if (decoded is List) return decoded.isEmpty;
      if (decoded is! Map) return false;
      for (final v in decoded.values) {
        if (v is List && v.isNotEmpty) return false;
        if (v is Map) {
          for (final inner in v.values) {
            if (inner is List && inner.isNotEmpty) return false;
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A parsed Auvy backup: its manifest, and the pref payload it carries.
///
/// Both Auvy formats reduce to this pair, so [import] and [peek] never need to
/// know whether they were handed a zip or the old bare json.
class _AuvyBackup {
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> data;
  const _AuvyBackup(this.manifest, this.data);
}
