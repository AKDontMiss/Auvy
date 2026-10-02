import 'package:auvy/services/audio_service.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/data/dummy_data.dart'; // Song model

/// Outcome of a download batch, so the UI can report what actually happened
/// instead of assuming success.
class DownloadResult {
  final int requested;
  final int downloaded;
  final int skipped; // already downloaded
  final List<String> failures; // "Title — reason"

  const DownloadResult({
    required this.requested,
    required this.downloaded,
    required this.skipped,
    required this.failures,
  });

  bool get allFailed => downloaded == 0 && failures.isNotEmpty;
  bool get anyFailed => failures.isNotEmpty;

  /// One line fit for a toast, describing what actually happened.
  String get summary {
    if (requested == 0) return 'Nothing to download';
    if (failures.isEmpty) {
      if (downloaded == 0 && skipped > 0) return 'Already downloaded';
      return downloaded == 1 ? 'Downloaded' : 'Downloaded $downloaded tracks';
    }
    if (allFailed) {
      // Name the reason when a single track fails.
      return requested == 1
          ? "Couldn't download: ${failures.first}"
          : "Couldn't download ${failures.length} tracks";
    }
    return 'Downloaded $downloaded · ${failures.length} failed';
  }
}

/// Downloads a whole album or playlist and reports the result.
///
/// Every "download this" action shares this: tracks are fetched one at a time,
/// one failure does not stop the rest, and the result counts successes and
/// failures. Messages are built here so the wording is consistent.
class DownloadHelper {
  /// Caches a set of tracks to disk.
  ///
  /// [isExplicit] marks a user download (true: Downloads folder, never evicted)
  /// versus a background auto-cache (false: Cached folder, evicted when space is
  /// needed). Background caching must pass false, or cached tracks would be
  /// listed as downloads.
  ///
  /// [downloadType] / [collectionName] place files under `Albums/<name>` or
  /// `Playlists/<name>` with numbered filenames; the defaults put tracks in
  /// `Singles/` unnumbered.
  static Future<DownloadResult> downloadCollection(
    List<Song> songs, {
    bool isExplicit = true,
    String downloadType = 'Single',
    String? collectionName,
    /// Called after each track with how many of [songs] are finished, so a long
    /// download shows progress.
    void Function(int done, int total)? onProgress,
  }) async {
    final cache = AudioCacheManager();
    final audio = AudioService();
    int downloaded = 0, skipped = 0;
    final failures = <String>[];

    // Position in the batch, prefixed to filenames so a file manager sorts them in
    // playing order. Only for albums and playlists.
    final bool numbered =
        collectionName != null && songs.length > 1 && downloadType != 'Single';

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      // Check the file, not just the index: an index entry whose file is gone must
      // be downloaded again.
      if (cache.isExplicitlyDownloaded(song.id) &&
          cache.downloadedFileExists(song.id)) {
        skipped++;
        onProgress?.call(i + 1, songs.length);
        continue;
      }
      // Auto-cache: skip anything already cached.
      if (!isExplicit && cache.isCached(song.id)) {
        skipped++;
        onProgress?.call(i + 1, songs.length);
        continue;
      }
      try {
        // Resolve a playable URL plus the user agent the download must send.
        //
        // User downloads request AAC-in-MP4, which can carry title, artist and cover
        // tags and plays in other apps. Auto-cache keeps YouTube's Opus/WebM, which is
        // only played inside the app.
        final stream = await audio.getStreamWithFallback(
            song.id, song.title, song.artist,
            preferMp4: isExplicit);
        final url = stream?['url'];
        if (url == null || url.isEmpty) {
          failures.add('${song.title} — no playable stream');
          continue;
        }
        final ok = await cache.cacheTrack(
          song,
          url,
          isExplicitDownload: isExplicit,
          userAgent: stream?['user_agent'],
          downloadType: downloadType,
          collectionName: collectionName,
          trackNumber: numbered ? i + 1 : null,
        );
        if (ok) {
          downloaded++;
        } else {
          failures.add('${song.title} — could not be saved');
        }
      } catch (e) {
        // Keep the exception type, not its message: messages can contain file paths,
        // and these strings may be shown on screen.
        failures.add('${song.title} — ${e.runtimeType}');
      } finally {
        // In a finally so progress is reported on every exit path, including skips and
        // errors.
        onProgress?.call(i + 1, songs.length);
      }
    }

    return DownloadResult(
      requested: songs.length,
      downloaded: downloaded,
      skipped: skipped,
      failures: failures,
    );
  }
}
