import 'dart:io';

import 'package:flutter/services.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:path_provider/path_provider.dart';

import 'package:auvy/data/dummy_data.dart';

/// Save a track's cover art as an image file.
///
/// Writes the original image rather than making the user screenshot the
/// player. On Android it goes to `/Pictures/Auvy`, so the gallery, wallpaper
/// pickers and chat apps can use it (covered by the same storage permission as
/// the download folder).
class ArtworkExportService {
  static const MethodChannel _folder = MethodChannel('com.auvy.app/folder');

  static const String _androidDir = '/storage/emulated/0/Pictures/Auvy';

  /// Where a saved cover goes, which differs per platform.
  ///
  /// Android has a shared Pictures folder the gallery indexes. iOS has no
  /// writable folder outside the app sandbox, so covers go to the app's own
  /// Documents directory, which UIFileSharingEnabled shows in Files under
  /// "On My iPhone → Auvy".
  static Future<String> _resolveDir() async {
    if (Platform.isAndroid) return _androidDir;
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/Covers';
  }

  /// Strip characters Android's filesystem rejects, and cap the length (some
  /// titles are a sentence long, and ext4 allows 255 bytes).
  static String _safeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final short = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
    return short.isEmpty ? 'cover' : short;
  }

  /// Returns the saved path, or null with a reason the caller can show.
  ///
  /// Requests the artwork at its largest size: the displayed URL usually carries
  /// a CDN size parameter (`=w544-h544`), which would save a thumbnail.
  static Future<({String? path, String? error})> saveCover(Song song) async {
    final raw = song.image;
    if (raw.isEmpty || !raw.startsWith('http')) {
      return (path: null, error: 'No cover art for this track');
    }

    // Upgrade the CDN size parameter in place. Everything before the first `=wN`
    // / `=sN` / `=hN` is the image identity; the rest is a rendering request.
    var url = raw;
    final size = RegExp(r'=[wsh]\d+').firstMatch(url);
    if (size != null) url = '${url.substring(0, size.start)}=s1200';

    try {
      var res = await HttpPool().getClient().get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      // A rejected size parameter is common on non-Google hosts (podcast and
      // radio artwork), so fall back to exactly what the app displays rather
      // than failing on a URL that was working a moment ago.
      if (res.statusCode != 200 && url != raw) {
        res = await HttpPool().getClient().get(Uri.parse(raw)).timeout(const Duration(seconds: 20));
      }
      if (res.statusCode != 200) {
        return (path: null, error: "Couldn't download the cover");
      }

      final dirPath = await _resolveDir();
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Pick the extension from the bytes, not the URL: these CDNs serve WebP from
      // paths ending in .jpg, and some galleries won't open a mislabelled file.
      final b = res.bodyBytes;
      String ext = '.jpg';
      if (b.length > 12) {
        if (b[0] == 0x89 && b[1] == 0x50) {
          ext = '.png';
        } else if (b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
          ext = '.webp';
        }
      }

      final artist = song.artist.isNotEmpty ? song.artist : song.displayArtist;
      final base = _safeName(
          artist.isEmpty ? song.title : '${song.title} - $artist');
      var file = File('$dirPath/$base$ext');
      // Never overwrite: saving the same cover twice gives two files.
      var n = 2;
      while (file.existsSync()) {
        file = File('$dirPath/$base ($n)$ext');
        n++;
      }
      await file.writeAsBytes(b);

      // Tell the media store about the file so the gallery shows it (see the
      // scanMedia handler in MainActivity).
      try {
        await _folder.invokeMethod('scanMedia', {'path': file.path});
      } catch (_) {
        // The file is saved either way; it may just take longer to appear.
      }

      return (path: file.path, error: null);
    } catch (_) {
      return (path: null, error: "Couldn't save the cover");
    }
  }
}
