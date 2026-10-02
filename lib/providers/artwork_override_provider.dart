import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show FileImage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart' show auvyImageForgetFile;
import 'package:auvy/services/cloud_sync_service.dart';

/// User-chosen cover art per track: the manual fix for wrong artwork. Automatic
/// matching can't be right every time on this catalogue, so the user can pick an
/// image instead.
///
/// The chosen image is copied into the app's own directory rather than
/// referenced where the picker found it, since a gallery URI can be deleted,
/// moved or have its access revoked.
class ArtworkOverrideNotifier extends StateNotifier<Map<String, String>> {
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> get initialized => _initCompleter.future;

  ArtworkOverrideNotifier() : super(const {}) {
    _load();
  }

  /// LEGACY: id → absolute file path. Read once for migration, never written.
  static const String _prefsKey = 'auvy_artwork_overrides_v1';

  /// id → base64 of the cover itself (WebP; PNG from older versions until
  /// converted, see [_convertToWebp]). The image travels, not a path: a path is
  /// meaningless on another device or after a reinstall, so the local file is just
  /// a cache rebuilt from these bytes. This key is in CloudSyncService's backup
  /// list. Covers are re-encoded to at most 384 px ([_maxDimension]) before
  /// storage.
  ///
  /// The files keep a `.png` name whatever the bytes inside: images are decoded
  /// by content, and the library stores these exact paths (a playlist's cover), so
  /// renaming them would break every one.
  static const String _prefsKeyV2 = 'auvy_artwork_overrides_v2';

  /// Longest edge, in pixels, that a stored override is re-encoded to. Large
  /// enough for the full-screen player on a 3x display, small enough that the
  /// base64 copy is measured in hundreds of KB rather than megabytes.
  static const int _maxDimension = 384;

  /// Where the copies live: Application Support on iOS (Documents is visible in
  /// the Files app, and these are internal cache files), the documents directory
  /// on Android (already private). Either way they survive updates and are
  /// removed with the app.
  static const String _dirName = 'artwork_overrides';

  /// Whether this run has already moved old iOS copies out of Documents.
  bool _movedOutOfDocuments = false;

  /// id → base64 PNG. The durable truth; [state] is the id → path view of it.
  Map<String, String> _bytes = {};

  /// Re-reads the store from prefs and rebuilds missing files. Must be called
  /// after a cloud restore: this notifier loads once at construction, before the
  /// restore writes `auvy_artwork_overrides_v2`, so without a reload restored
  /// covers (playlist covers included) wouldn't appear.
  Future<void> reloadFromStorage() => _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = await _ensureDir();

      final rawV2 = prefs.getString(_prefsKeyV2);
      if (rawV2 != null && rawV2.isNotEmpty) {
        _bytes = (jsonDecode(rawV2) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString()));
        // Rebuild any missing file from its bytes (after a restore the map arrives with
        // no files on disk).
        //
        // Reuse a file that already exists. setOverride writes a versioned name
        // (`key_<millis>.png`, to bust Flutter's image cache on a re-pick), and callers
        // store that exact path (e.g. playlist_page puts it in the library item's
        // `image`). Rebuilding a fixed `key.png` here would let _sweepOrphans delete the
        // versioned file the library still points at.
        final onDisk = <String, File>{};
        try {
          for (final entity in dir.listSync()) {
            if (entity is! File || !entity.path.endsWith('.png')) continue;
            final name = entity.path.split(Platform.pathSeparator).last;
            final stem = name.substring(0, name.length - 4); // drop .png
            final us = stem.lastIndexOf('_');
            // `key.png` or `key_<millis>.png`
            final key = (us > 0 && int.tryParse(stem.substring(us + 1)) != null)
                ? stem.substring(0, us)
                : stem;
            final prev = onDisk[key];
            // Newest wins, so a re-pick's version is the one adopted.
            if (prev == null || entity.path.compareTo(prev.path) > 0) {
              onDisk[key] = entity;
            }
          }
        } catch (_) {}

        final paths = <String, String>{};
        var rebuilt = 0, reused = 0;
        // Iterate a snapshot: this loop awaits a file write per entry, and other paths
        // may change [_bytes] meanwhile.
        for (final e in _bytes.entries.toList()) {
          try {
            final existing = onDisk[_safe(e.key)];
            if (existing != null && existing.existsSync()) {
              paths[e.key] = existing.path;
              reused++;
              continue;
            }
            // Nothing on disk for this key — a restore, or a wipe. Materialise
            // it from the backed-up bytes under the deterministic name.
            final f = File('${dir.path}/${_safe(e.key)}.png');
            await f.writeAsBytes(base64Decode(e.value));
            paths[e.key] = f.path;
            rebuilt++;
          } catch (_) {
            // One unreadable entry must not cost the others.
          }
        }
        if (rebuilt > 0) {
          print('rebuilt $rebuilt cover file(s) from the backed-up bytes '
              '($reused already on disk)');
        }
        // The constructor starts this and does not await it, and the loop
        // above awaits a file write PER COVER — so disposal here is not a
        // narrow window. Writing state after it throws "Tried to use
        // ArtworkOverrideNotifier after `dispose` was called" out of an
        // async gap, where nothing catches it.
        if (!mounted) return;
        state = paths;
        print('loaded ${paths.length} cover override(s) from storage '
            '(${_bytes.length} in the backed-up map)');
        // A versioned name from last session is an orphan now. See _sweepOrphans.
        await _sweepOrphans();
        // Covers stored as PNG by an older version become WebP, in the background.
        unawaited(_convertToWebp());
        return;
      }

      // One-time migration from v1: read the old path map and keep the bytes of any
      // file still present.
      final rawV1 = prefs.getString(_prefsKey);
      if (rawV1 == null || rawV1.isEmpty) return;
      final decoded = jsonDecode(rawV1) as Map<String, dynamic>;
      final paths = <String, String>{};
      for (final e in decoded.entries) {
        final path = e.value.toString();
        if (path.isEmpty || !File(path).existsSync()) continue;
        try {
          final png = await _encode(await File(path).readAsBytes());
          if (png == null) continue;
          final f = File('${dir.path}/${_safe(e.key)}.png');
          await f.writeAsBytes(png);
          _bytes[e.key] = base64Encode(png);
          paths[e.key] = f.path;
        } catch (_) {}
      }
      // Same guard, second exit: the v1 migration awaits an encode and a
      // file write per entry before it gets here.
      if (!mounted) return;
      state = paths;
      await _persist();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // A corrupt map must not take the app down on launch — the feature simply
      // starts empty.
    } finally {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }
  }

  Future<Directory> _ensureDir() async {
    final base = Platform.isIOS
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    if (Platform.isIOS && !_movedOutOfDocuments) {
      _movedOutOfDocuments = true;
      await _moveOutOfDocuments(dir);
    }
    return dir;
  }

  /// Older iOS builds kept these files in Documents, where they showed up in the
  /// Files app. Move them (keeping their names, so stored paths still resolve via
  /// ContainerPathResolver) and remove the old folder once it is empty.
  Future<void> _moveOutOfDocuments(Directory target) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final old = Directory('${docs.path}/$_dirName');
      if (!old.existsSync()) return;
      for (final entity in old.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        final dest = File('${target.path}/$name');
        try {
          if (dest.existsSync()) {
            await entity.delete();
          } else {
            await entity.rename(dest.path);
          }
        } catch (e) {
          print('WARN: artwork override move failed for $name ($e)');
        }
      }
      if (old.listSync().isEmpty) await old.delete();
    } catch (e) {
      print('WARN: artwork override migration skipped ($e)');
    }
  }

  /// The id, sanitised: YouTube ids contain '-' and '_' (both fine) but a
  /// malformed id must not be able to escape the directory.
  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static const _imageChannel = MethodChannel('com.auvy.app/image');

  /// Decode, downscale to [_maxDimension] on the longest edge, and re-encode as
  /// WebP (natively: Flutter can only write PNG, and measured on a real set of
  /// 23 covers PNG was 4.7 MB where WebP is 0.3 MB). PNG when the native encoder
  /// is unavailable. Null when the bytes are not a decodable image.
  static Future<Uint8List?> _encode(Uint8List source) async {
    try {
      final webp = await _imageChannel.invokeMethod<Uint8List>('encodeWebp', {
        'bytes': source,
        'maxDimension': _maxDimension,
        'quality': 82,
      });
      if (webp != null && webp.isNotEmpty) return webp;
    } catch (_) {
      // No native encoder (an old build, a test): PNG below.
    }
    try {
      // targetWidth alone preserves the aspect ratio; covers are square or close,
      // and forcing both axes would distort a non-square pick.
      final codec = await ui.instantiateImageCodec(source,
          targetWidth: _maxDimension);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) return null;
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static bool _isPng(String base64) => base64.startsWith('iVBORw0KGgo');

  /// Re-encodes covers an older version stored as PNG into WebP, once: the bytes
  /// in preferences and backups shrink about sixteenfold, and the file on disk is
  /// rewritten in place (same path, so nothing pointing at it breaks).
  Future<void> _convertToWebp() async {
    final pending = [for (final e in _bytes.entries) if (_isPng(e.value)) e.key];
    if (pending.isEmpty) return;
    var before = 0, after = 0, converted = 0;
    for (final key in pending) {
      if (!mounted) return;
      final old = _bytes[key];
      if (old == null || !_isPng(old)) continue;
      final png = base64Decode(old);
      final webp = await _encode(png);
      if (webp == null ||
          webp.length < 12 ||
          _isPng(base64Encode(webp.sublist(0, 8))) ||
          webp.length >= png.length) {
        continue; // no WebP encoder here, or nothing gained
      }
      _bytes = {..._bytes, key: base64Encode(webp)};
      before += old.length;
      after += _bytes[key]!.length;
      converted++;
      final path = state[key];
      if (path != null) {
        try {
          await File(path).writeAsBytes(webp, flush: true);
          await FileImage(File(path)).evict();
        } catch (_) {}
      }
    }
    if (converted == 0 || !mounted) return;
    await _persist();
    print('covers: $converted converted from PNG to WebP, '
        '${before ~/ 1024}KB → ${after ~/ 1024}KB stored');
  }

  /// Schedules a backup too, so a new cover reaches the cloud promptly and marks
  /// the device as having unpushed work (otherwise a later restore from an older
  /// cloud copy could remove it).
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyV2, jsonEncode(_bytes));
    CloudSyncService.instance.scheduleBackup();
  }

  /// Copy [sourcePath] into app storage and pin it as [songId]'s cover.
  /// Returns false if the copy fails, so the caller can say so rather than
  /// silently appearing to succeed.
  Future<bool> setOverride(String songId, String sourcePath) async {
    if (songId.isEmpty || sourcePath.isEmpty) return false;
    try {
      final dir = await _ensureDir();

      // RE-ENCODED, not copied. v1 did `File(sourcePath).copy(...)`, which put a
      // full-resolution gallery photo on disk as a cover thumbnail — megabytes
      // for something rendered at 384px at most. Every override gets the same
      // file name pattern whatever the source format (see _prefsKeyV2), so a
      // re-pick never reuses a stale path.
      final png = await _encode(await File(sourcePath).readAsBytes());
      if (png == null) return false;

      // A fresh file name every time, so the new cover shows immediately. AuvyImage
      // wraps providers in ResizeImage, so evicting the bare FileImage wouldn't clear
      // the cached entry; a new path is a new cache key at every size. The old file is
      // deleted below, and _sweepOrphans cleans up anything a crash left behind.
      final target =
          File('${dir.path}/${_safe(songId)}_${DateTime.now().millisecondsSinceEpoch}.png');
      final previous = state[songId];
      await target.writeAsBytes(png);

      _bytes = {..._bytes, songId: base64Encode(png)};
      state = {...state, songId: target.path};
      await _persist();

      if (previous != null && previous != target.path) {
        try {
          final old = File(previous);
          if (old.existsSync()) await old.delete();
        } catch (_) {}
        // AuvyImage memoises "this file exists" to keep a blocking stat out of
        // build; drop the entry for a path we just deleted.
        auvyImageForgetFile(previous);
      }
      // Also forget the path in AuvyImage's file-existence memo.
      auvyImageForgetFile(target.path);
      await FileImage(target).evict();
      await _sweepOrphans();
      // Log cover changes so "never saved", "saved then deleted" and "replaced by a
      // restore" can be told apart.
      print('cover set for "$songId" → ${png.length ~/ 1024}KB '
          '(${state.length} override(s) held, backup scheduled)');
      return true;
    } catch (e) {
      print('WARN: could not set the cover for "$songId": $e');
      return false;
    }
  }

  /// Deletes override files nothing points at any more (left by a versioned write
  /// whose predecessor couldn't be deleted, or by a rebuild after a restore).
  Future<void> _sweepOrphans() async {
    try {
      final dir = await _ensureDir();
      final keep = state.values.toSet();
      // Log what was deleted and against how many kept entries. This keeps only
      // files listed in `state`, so running it on an empty or half-loaded map would
      // delete every cover; the load path prevents that today, and the log would make
      // it obvious.
      var swept = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.png')) continue;
        if (keep.contains(entity.path)) continue;
        try {
          await entity.delete();
          auvyImageForgetFile(entity.path);
          swept++;
        } catch (_) {}
      }
      if (swept > 0) {
        print('swept $swept override file(s) not referenced by the '
            '${keep.length} override(s) currently held');
      }
    } catch (_) {
      // Housekeeping only — never worth failing a cover change over.
    }
  }

  /// Forget the override and delete its copy, restoring the automatic cover.
  Future<void> clearOverride(String songId) async {
    final path = state[songId];
    if (path == null) return;
    final next = {...state}..remove(songId);
    state = next;
    // Drop the BYTES too, or the next load would rebuild the file from them and
    // resurrect a cover the user just removed.
    _bytes = {..._bytes}..remove(songId);
    await _persist();
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
      await FileImage(f).evict();
    } catch (_) {}
    auvyImageForgetFile(path);
  }

  bool hasOverride(String songId) => state.containsKey(songId);

  /// Reset all overrides and purge files on disk (used on logout/account reset).
  Future<void> clearAll() async {
    state = const {};
    _bytes = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
      await prefs.remove(_prefsKeyV2);
      final dir = await _ensureDir();
      if (dir.existsSync()) {
        var count = 0;
        for (final entity in dir.listSync()) {
          if (entity is File) {
            try {
              await entity.delete();
              auvyImageForgetFile(entity.path);
              count++;
            } catch (_) {}
          }
        }
        print('ArtworkOverrideNotifier: cleared all overrides ($count files deleted from disk)');
      }
    } catch (e) {
      print('ArtworkOverrideNotifier clearAll error: $e');
    }
  }
}

final artworkOverrideProvider =
    StateNotifierProvider<ArtworkOverrideNotifier, Map<String, String>>(
        (ref) => ArtworkOverrideNotifier());
