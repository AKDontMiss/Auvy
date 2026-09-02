import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:auvy/data/dummy_data.dart';

/// Save a track's cover art to the phone's Pictures folder.
///
/// The app already has the artwork on screen at full resolution, and the only
/// way to keep a copy was a screenshot of the player, which captures the
/// controls, the gradient and the status bar along with it. This writes the
/// original image file instead.
///
/// Lands in `/Pictures/Auvy` rather than the app's private directory so it is a
/// real picture the gallery, a wallpaper picker or a chat app can reach. The same
/// public-storage permission the download folder uses covers it.
class ArtworkExportService {
  static const MethodChannel _folder = MethodChannel('com.auvy.app/folder');

  static const String _dir = '/storage/emulated/0/Pictures/Auvy';

  /// Strip characters Android's filesystem rejects, and cap the length — some
  /// track titles are a sentence long and ext4 stops at 255 bytes.
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
  /// Asks for the artwork at its LARGEST size, not the size on screen. The
  /// URL the app displays usually carries a CDN size parameter (`=w544-h544`),
  /// and saving that would write a thumbnail — the one thing someone exporting a
  /// cover does not want.
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
      var res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      // A rejected size parameter is common on non-Google hosts (podcast and
      // radio artwork), so fall back to exactly what the app displays rather
      // than failing on a URL that was working a moment ago.
      if (res.statusCode != 200 && url != raw) {
        res = await http.get(Uri.parse(raw)).timeout(const Duration(seconds: 20));
      }
      if (res.statusCode != 200) {
        return (path: null, error: "Couldn't download the cover");
      }

      final dir = Directory(_dir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Extension from the bytes, not the URL: these CDNs serve WebP from paths
      // that end in .jpg, and a mislabelled file will not open in some galleries.
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
      var file = File('$_dir/$base$ext');
      // Never overwrite: saving the same cover twice should give you two files,
      // not silently replace the first.
      var n = 2;
      while (file.existsSync()) {
        file = File('$_dir/$base ($n)$ext');
        n++;
      }
      await file.writeAsBytes(b);

      // Without this the gallery does not know the file exists. See the
      // scanMedia handler in MainActivity.
      try {
        await _folder.invokeMethod('scanMedia', {'path': file.path});
      } catch (_) {
        // Saved either way; it just may take longer to appear.
      }

      return (path: file.path, error: null);
    } catch (_) {
      return (path: null, error: "Couldn't save the cover");
    }
  }
}
