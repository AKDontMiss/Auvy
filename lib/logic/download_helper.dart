import 'package:auvy/services/audio_service.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/data/dummy_data.dart'; // Song model

/// Outcome of a download batch.
///
/// This exists because downloads used to fail INVISIBLY. `downloadCollection`
/// returned `void` and swallowed every error into a `print`, which release builds
/// discard (see the logging zone in main.dart). So the UI showed "Downloading
/// tracks", nothing arrived, and there was no way — for a user OR from a logcat
/// capture — to find out why. Same class of problem as a success toast for a
/// duplicate add: the app reported an outcome it had not verified.
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
      // Name the reason for a single failure — "couldn't download" with no cause
      // is what made this undebuggable in the first place.
      return requested == 1
          ? "Couldn't download: ${failures.first}"
          : "Couldn't download ${failures.length} tracks";
    }
    return 'Downloaded $downloaded · ${failures.length} failed';
  }
}

/// Downloads a whole album or playlist, and reports what happened.
///
/// One entry point, downloadCollection(). It exists so the several places that
/// offer "download this" share one behaviour: tracks are fetched one at a time
/// rather than all at once, a failure on one track does not abandon the rest,
/// and the result says how many succeeded and how many did not.
///
/// The message strings are built here rather than at the call sites so the
/// wording cannot drift between them.
class DownloadHelper {
  /// Caches a set of tracks to disk.
  ///
  /// [isExplicit] distinguishes a user-initiated DOWNLOAD (true → lives in the
  /// Downloads folder, never auto-evicted) from a background AUTO-CACHE
  /// (false → lives in the Cached folder, LRU-evictable). This MUST be false
  /// for the background cache-on-play path, otherwise auto-cached tracks get
  /// mislabeled as downloads and never show up in the "Cached" folder (which
  /// filters to !isExplicitDownload).
  /// [downloadType] / [collectionName] place the files under
  /// `Albums/<name>` or `Playlists/<name>` and switch on the numbered filename
  /// convention. Left at the defaults, tracks land in `Singles/` unnumbered.
  static Future<DownloadResult> downloadCollection(
    List<Song> songs, {
    bool isExplicit = true,
    String downloadType = 'Single',
    String? collectionName,
    /// Called after each track with how many of [songs] are finished.
    ///
    /// This downloads SERIALLY, so a fifty-track playlist is fifty round trips
    /// end to end. Without a signal per track the only observable states were
    /// "started" and "finished several minutes later", which is what made a
    /// long download indistinguishable from a hung one.
    void Function(int done, int total)? onProgress,
  }) async {
    final cache = AudioCacheManager();
    final audio = AudioService();
    int downloaded = 0, skipped = 0;
    final failures = <String>[];

    // Position within the batch, used to prefix filenames so a file manager
    // sorts the folder in playing order. Only for real collections — numbering a
    // lone track "01" would be noise, and Song carries no track number of its
    // own, so the batch is the only place this is knowable.
    final bool numbered =
        collectionName != null && songs.length > 1 && downloadType != 'Single';

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      // Verify the FILE, not just the index. A stale index entry — one whose
      // audio was deleted outside the app, or whose write failed after the entry
      // was written — used to make this `continue` forever, so a track could get
      // permanently stuck as "downloaded" with nothing on disk and no way to
      // retry.
      if (cache.isExplicitlyDownloaded(song.id) &&
          cache.downloadedFileExists(song.id)) {
        skipped++;
        onProgress?.call(i + 1, songs.length);
        continue;
      }
      // For auto-cache, skip anything already cached (don't redo work).
      if (!isExplicit && cache.isCached(song.id)) {
        skipped++;
        onProgress?.call(i + 1, songs.length);
        continue;
      }
      try {
        // Unified resolver gives a real audio URL + the matching user-agent,
        // which the CDN download below requires.
        //
        // A USER DOWNLOAD ASKS FOR MP4, streaming does not. YouTube's best audio
        // is Opus in WebM, which is the right thing to play but cannot carry a
        // title, artist or cover picture, so a downloaded file arrived bare and
        // Android refused to index it. AAC-in-MP4 is a slightly less efficient
        // codec and the correct trade for a file the user keeps, copies to a car
        // stereo, or opens on a PC. Auto-cache keeps Opus: those files are only
        // ever played back inside the app.
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
        // Keep the TYPE, not the full message: a FileSystemException embeds the
        // path, and these strings can end up on screen.
        failures.add('${song.title} — ${e.runtimeType}');
      } finally {
        // In a finally because the block above has three ways out — a `continue`
        // on an unresolvable stream, a normal end, and a throw. Reporting from
        // only one of them would stall the indicator on exactly the tracks that
        // went wrong, which is when it matters most.
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
