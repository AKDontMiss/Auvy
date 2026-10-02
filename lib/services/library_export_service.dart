import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A copy of your library that you own.
///
/// Writes the library, taste profile and recognition history to one `.backup`
/// file in a folder the user can reach, and reads it back, including older bare
/// `.json` exports and (via [ForeignBackupReader]) backups from other music apps.
///
/// The cloud backup and the local `_last_good` snapshot both depend on the app
/// (an approved account, a working Worker, the install itself). A file the user
/// can see, copy and keep is the only backup that survives the app.
///
/// Plain JSON on purpose, not the encrypted cloud format, so the user can open
/// and read it. It holds playlists, likes, play counts and titles; cookies,
/// tokens and encryption keys are never exported, and no code path here can
/// reach them.
class LibraryExportService {
  LibraryExportService._();
  static final LibraryExportService instance = LibraryExportService._();

  /// Preferred locations, in order. Public so the file can be reached from a file
  /// manager or over USB; a backup in app-private storage is invisible and dies
  /// with the install.
  ///
  /// Not `Music/Auvy`: MediaStore's `Music/` accepts audio files only, so a
  /// `.json` is rejected there whatever permission the app holds. `Download/` and
  /// `Documents/` accept any file, and Downloads is where people look for files an
  /// app gave them.
  static const List<String> _publicDirs = [
    '/storage/emulated/0/Download/Auvy',
    '/storage/emulated/0/Documents/Auvy',
  ];

  /// The app-private fallback, used only when the public write fails. A private
  /// file is a weaker backup (it goes with the install), so the caller is told
  /// where the file landed.
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

  /// Saves a diagnostic file to Download/Auvy, reusing the path the library backup
  /// uses, so the activity log doesn't duplicate the scoped-storage handling. See
  /// _writeSomewhere.
  Future<String?> saveDiagnosticFile(String filename, List<int> bytes) =>
      _writeSomewhere(filename, bytes);

  /// Writes [bytes] to the public folder, falling back to private storage.
  /// Returns the path written, or null if neither worked.
  ///
  /// There is no separate "can I write here?" probe: Android refuses hidden
  /// (dot) files in media folders regardless of permission, so a probe file
  /// gave wrong answers. Attempting the real write is the only reliable test.
  Future<String?> _writeSomewhere(String filename, List<int> bytes) async {
    // MediaStore first, because a plain file write can't work here. Auvy
    // deliberately has no "all files access", and under scoped storage every File
    // write into /Download or /Documents fails with EPERM. MediaStore's Downloads
    // collection needs no permission on API 29+ and produces a real, visible file
    // in Download/Auvy.
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

  /// Bumped when the file's shape changes, so a future build can refuse or migrate
  /// a file it doesn't understand.
  ///
  /// 2 = the `.backup` container (a zip holding [_manifestEntry] and
  /// [_payloadEntry]). Version 1 was a bare `.json` file; [import] still reads
  /// those.
  static const int formatVersion = 2;

  /// Entry names inside a `.backup`. Stable — a future reader identifies the
  /// container by these, not by the file extension.
  static const String _manifestEntry = 'auvy_manifest.json';
  static const String _payloadEntry = 'auvy_library.json';

  /// The keys worth exporting, as a named list rather than "every pref":
  ///  • A blanket dump would include device settings, session flags and approval
  ///    markers, which would carry one account's state onto another install.
  ///  • A named list means adding something to the export is a deliberate choice.
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

      // A zip whose contents are still plain JSON. `.backup` is what this family of
      // apps writes (Metrolist and the InnerTune family), so the file is recognisable
      // as a music-library backup, and the container compresses to roughly a tenth.
      // Unzipped, both entries are readable JSON.
      final archive = Archive()
        ..addFile(ArchiveFile(
            _manifestEntry, utf8.encode(manifest).length, utf8.encode(manifest)))
        ..addFile(ArchiveFile(
            _payloadEntry, utf8.encode(payload).length, utf8.encode(payload)));
      final zipped = ZipEncoder().encode(archive);
      return await _writeSomewhere('auvy-library-$stamp.backup', zipped);
    } catch (e) {
      // Log the failure; a silent export failure looks like a bug.
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

  /// Every backup file this device can see, newest first: Auvy's own and other
  /// music apps'.
  ///
  /// Scanned rather than picked: backups are written to a few known places
  /// (Download, Documents, Music, the storage root, or a folder named after the
  /// app), so the app can look and offer what it finds. The scan is bounded:
  /// named roots, one level of subfolders, and `Android/` is skipped (other apps'
  /// private data, and a slow deep walk).
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
      // The Documents root itself, which is where files arrive on iOS:
      // `UIFileSharingEnabled` exposes it as "On My iPhone → Auvy", so a `.backup`
      // copied over from another device lands here rather than in Auvy_Backups.
      //
      // Not recursive: the other folders here can hold many files that can't be
      // backups, so the folders a backup can land in are named instead.
      await scan(appDir, recurse: false);
      await scan(Directory('${appDir.path}/Auvy_Backups'), recurse: false);
      // Where "Open in Auvy" from another app puts its file.
      await scan(Directory('${appDir.path}/Inbox'), recurse: false);
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

  /// Lets the user pick any backup file through the system picker.
  ///
  /// This is the only way to read another app's backup: without "all files access"
  /// a scan of /Download can't see files other apps wrote. Choosing the file grants
  /// access, and the picker also reaches Drive, OneDrive and SD cards.
  ///
  /// Returns the cached copy and the file's display name, or null if cancelled.
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

  /// Size limits for a file the user picked (so, any file). Reading it holds it
  /// two or three times over (compressed bytes, decoded archive, decompressed
  /// entry), and a crafted archive can decompress enormously. ForeignBackupReader
  /// uses the same limits; change both together. A real Auvy export is a few
  /// hundred KB, far below these.
  static const int _maxArchiveBytes = 256 * 1024 * 1024;
  static const int _maxEntryBytes = 512 * 1024 * 1024;
  static const int _maxJsonEntryBytes = 64 * 1024 * 1024;

  /// Reads the manifest and payload out of [file], whichever Auvy format it
  /// is. Returns null when it isn't an Auvy backup (a foreign one is handled
  /// by [ForeignBackupReader]).
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
      // A zip starts "PK\x03\x04". Sniffing the CONTENT rather than the
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
          // Check the size the header claims before `content` decompresses anything.
          if (f.size > _maxEntryBytes) {
            print('WARN: import: "${f.name}" claims '
                '${f.size ~/ (1024 * 1024)}MB uncompressed — refusing rather '
                'than decompressing it');
            return null;
          }
          // The two entries actually DECODED are JSON, held whole in memory
          // and then parsed — a real payload is a few MB. The general cap
          // above is sized for archives, not for a string on a phone's heap.
          if ((f.name == _manifestEntry || f.name == _payloadEntry) &&
              f.size > _maxJsonEntryBytes) {
            print('WARN: import: "${f.name}" is '
                '${f.size ~/ (1024 * 1024)}MB of JSON — refusing');
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

  /// Applies an export. Returns the number of keys restored, or -1 on refusal.
  ///
  /// Never replaces content with emptiness: a key whose incoming value is empty is
  /// skipped when the local one has data, so a stale or truncated file can't erase
  /// a real library.
  ///
  /// Doesn't touch device settings, session state or approval markers (see
  /// [_exportKeys]).
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

/// A parsed Auvy backup: its manifest and the pref payload it carries. Both Auvy
/// formats reduce to this pair, so [import] and [peek] don't care whether they
/// got a zip or an old bare json file.
class _AuvyBackup {
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> data;
  const _AuvyBackup(this.manifest, this.data);
}
