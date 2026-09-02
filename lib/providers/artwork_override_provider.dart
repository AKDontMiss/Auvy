import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart' show FileImage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart' show auvyImageForgetFile;
import 'package:auvy/services/cloud_sync_service.dart';

/// User-chosen cover art, per track — the manual escape hatch for wrong artwork.
///
/// WHY THIS EXISTS. Auvy resolves covers automatically (YouTube's own art, then
/// the video→audio conform), and when that picks the wrong row you get a
/// confidently wrong cover with no way to correct it. That is exactly what
/// happened with "Warrior", where a movie-soundtrack sleeve won the match. The
/// matching itself was tightened (artist + duration guards in
/// `resolveAudioEquivalent`), but no heuristic is going to be right every time on
/// a catalogue this messy, so there needs to be a way to just say "no, this one".
/// Other music apps land on the same conclusion.
///
/// The chosen image is COPIED into the app's own directory rather than referenced
/// where the picker found it. A gallery URI is not a stable handle: the user can
/// delete the photo, move it, or revoke the grant, and the cover would silently
/// break weeks later. A copy costs a few hundred KB and cannot rot.
class ArtworkOverrideNotifier extends StateNotifier<Map<String, String>> {
  ArtworkOverrideNotifier() : super(const {}) {
    _load();
  }

  /// LEGACY: id → absolute file path. Read once for migration, never written.
  static const String _prefsKey = 'auvy_artwork_overrides_v1';

  /// id → base64 PNG of the cover itself
  ///
  /// THE BYTES, NOT THE PATH. v1 stored absolute local paths, and its own
  /// loader admitted the consequence: "a restore onto a new device brings the map
  /// but not the images". Clearing app data (or reinstalling) destroyed the files,
  /// so a restored map pointed at nothing and every manual cover silently
  /// reverted — reported as "it did not save my manually put cover art".
  ///
  /// A path is meaningless off this device; the image is the actual user data. So
  /// the image travels, and the local file is treated as a CACHE rebuilt from it.
  /// This key is in CloudSyncService's backup list, and the backup is already
  /// chunked, so a cover comfortably fits.
  ///
  /// Bounded by [_maxDimension]: covers are re-encoded to at most 384px before
  /// storage, which also fixes a second problem in v1 — it copied the picked
  /// gallery image at FULL resolution, so a 12MP photo sat on disk as a 4MB
  /// "thumbnail".
  static const String _prefsKeyV2 = 'auvy_artwork_overrides_v2';

  /// Longest edge, in pixels, that a stored override is re-encoded to. Large
  /// enough for the full-screen player on a 3x display, small enough that the
  /// base64 copy is measured in hundreds of KB rather than megabytes.
  static const int _maxDimension = 384;

  /// Where the copies live. Inside the app's documents directory, so they are
  /// private, survive updates, and are removed with the app.
  static const String _dirName = 'artwork_overrides';

  /// id → base64 PNG. The durable truth; [state] is the id → path view of it.
  Map<String, String> _bytes = {};

  /// Re-read the store from prefs and rebuild any missing files.
  ///
  /// MUST be called after a cloud restore. This notifier loads once, at
  /// construction — long before the restore writes
  /// `auvy_artwork_overrides_v2` into prefs. Without a reload the in-memory
  /// map stays as it was (usually empty), the base64 is never materialised
  /// back into files, and every manually-set cover — playlist covers included
  /// — comes back missing even though the BYTES restored perfectly. That is
  /// exactly the "my playlist cover art did not sync" report.
  Future<void> reloadFromStorage() => _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = await _ensureDir();

      final rawV2 = prefs.getString(_prefsKeyV2);
      if (rawV2 != null && rawV2.isNotEmpty) {
        _bytes = (jsonDecode(rawV2) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString()));
        // Rebuild any missing file from its bytes. This is the whole point: after
        // a restore the map arrives with no files on disk, and this materialises
        // them instead of dropping the entries.
        // Reuse the file that is already there
        //
        // THE BUG THIS FIXES — "the custom cover works, then disappears".
        //
        // setOverride writes a VERSIONED name (`key_<millis>.png`, deliberately,
        // to bust Flutter's image cache on a re-pick) and the caller stores THAT
        // EXACT PATH — playlist_page hands it to updatePlaylistImage, which puts
        // it in the library item's `image` field.
        //
        // This loop then rebuilt a DETERMINISTIC `key.png` on the next launch,
        // pointed `state` at it, and _sweepOrphans, which keeps only files in
        // state.values — deleted the versioned file. The library was left holding
        // the path of a file this code had just removed, so the cover rendered as
        // nothing. Set it, restart, gone: exactly the reported shape.
        //
        // Reusing the existing file keeps that stored path valid AND keeps the
        // cache-busting, because a re-pick still writes a new version.
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
        for (final e in _bytes.entries) {
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
        state = paths;
        print('loaded ${paths.length} cover override(s) from storage '
            '(${_bytes.length} in the backed-up map)');
        // A versioned name from last session is an orphan now. See _sweepOrphans.
        await _sweepOrphans();
        return;
      }

      // One-time migration from v1
      // Reads the old path map and captures the bytes of any file still present,
      // so users who set covers before this change keep them (and gain backup).
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
      state = paths;
      await _persist();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // A corrupt map must not take the app down on launch — the feature simply
      // starts empty.
    }
  }

  Future<Directory> _ensureDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The id, sanitised: YouTube ids contain '-' and '_' (both fine) but a
  /// malformed id must not be able to escape the directory.
  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Decode, downscale to [_maxDimension] on the longest edge, re-encode as PNG.
  /// Null when the bytes are not a decodable image.
  static Future<Uint8List?> _encode(Uint8List source) async {
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

  /// And ask for a backup. this did NOT, AND that is the bug
  ///
  /// `auvy_artwork_overrides_v2` is in CloudSyncService's key list, so a cover
  /// DID reach the cloud, but only when something ELSE happened to trigger a
  /// push. Setting a cover scheduled nothing at all.
  ///
  /// So: pick a cover, close the app, and it existed in exactly one place. On a
  /// later launch a restore from a cloud copy written before the cover overwrote
  /// this key with the older value and the cover was gone, and because the same
  /// restore also carries the library, a playlist created in the same sitting
  /// went with it. That is both halves of "the playlist I just added is gone and
  /// no cover art on it", from one missing call.
  ///
  /// It also defeated the unpushed-work protections added alongside this: they
  /// key off `scheduleBackup()` marking the device dirty, and nothing marked it.
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
      // for something rendered at 384px at most. Re-encoding also normalises
      // every override to PNG, so the filename no longer depends on the source
      // extension (which is what made a re-pick reuse a stale path).
      final png = await _encode(await File(sourcePath).readAsBytes());
      if (png == null) return false;

      // A FRESH FILENAME EVERY TIME, AND THAT IS THE FIX FOR "IT TAKES A
      // WHILE TO SHOW THE NEW COVER".
      //
      // Writing the same path with new bytes and calling FileImage(target)
      // .evict() looks correct and does nothing: AuvyImage wraps every provider
      // in ResizeImage (see auvy_image.dart), so the live cache key is
      // ResizeImage(FileImage(path), decodePx) — evicting the bare FileImage
      // misses it entirely, and the OLD cover kept rendering until the cache
      // happened to evict under memory pressure.
      //
      // A new path is a new cache key at every decode size at once, so the new
      // cover appears in the same frame. The old file is deleted just below
      // (the paths now differ, which is what makes that branch fire), and
      // _sweepOrphans clears anything a crash left behind, so they cannot
      // stack up.
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
      // Re-picking writes the SAME path with different bytes, and Flutter's image
      // cache keys on the path. Evict both or the old cover keeps showing.
      auvyImageForgetFile(target.path);
      await FileImage(target).evict();
      await _sweepOrphans();
      // THIS WHOLE FILE PRINTED NOTHING, WHICH IS WHY "THE COVER DID NOT
      // SURVIVE" HAS NEVER BEEN TRACEABLE.
      //
      // Setting a cover, persisting it, sweeping, and losing it all happened in
      // silence, so a transcript could not distinguish "never saved" from
      // "saved then deleted" from "saved, then a restore replaced the map".
      // Those are three different bugs with three different fixes.
      print('cover set for "$songId" → ${png.length ~/ 1024}KB '
          '(${state.length} override(s) held, backup scheduled)');
      return true;
    } catch (e) {
      print('WARN: could not set the cover for "$songId": $e');
      return false;
    }
  }

  /// Delete override files nothing points at any more.
  ///
  /// Two things leave orphans behind: a versioned write whose predecessor could
  /// not be deleted, and the load path rebuilding a deterministic
  /// `<key>.png` from the backed-up bytes while last session ended on a
  /// versioned name. Neither is visible in the UI, so without this they would
  /// simply accumulate on disk.
  Future<void> _sweepOrphans() async {
    try {
      final dir = await _ensureDir();
      final keep = state.values.toSet();
      // Say what was deleted, AND against what.
      //
      // This keeps only files listed in `state`, so if it ever ran while the
      // map was empty or half-loaded it would delete every cover on disk. The
      // load path makes that unreachable today (it rebuilds each file from the
      // backed-up bytes BEFORE sweeping), but it is one edit away from being
      // reachable again and the deletion is permanent. Naming the count and the
      // size of `keep` in the same line makes an empty-map sweep obvious.
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
}

final artworkOverrideProvider =
    StateNotifierProvider<ArtworkOverrideNotifier, Map<String, String>>(
        (ref) => ArtworkOverrideNotifier());
