import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What stage a bulk download is at.
///
/// The two stages look nothing alike AND the banner used to conflate them.
///
/// Before a single byte is written, every track needs its stream resolved, and
/// that stage can take longer than the download itself — each resolve is a
/// network round trip with a 15s ceiling. The banner only knew how to say
/// "N of M tracks saved", which during that stage is "0 of 20" for a minute or
/// more, indistinguishable from a download that is stuck.
enum DownloadPhase { preparing, downloading }

class DownloadState {
  final bool isDownloading;
  final int downloadedTracks;
  final int totalTracks;
  final String currentItemName;

  /// What is being downloaded — "Album", "Playlist", so the banner can name it
  /// rather than saying "Downloading <title>" and leaving the kind to guess.
  final String collectionKind;
  final DownloadPhase phase;

  /// Tracks that could not be fetched at all. Shown when the run ends, because a
  /// download that silently saved 17 of 20 reads as success.
  final int failedTracks;

  const DownloadState({
    this.isDownloading = false,
    this.downloadedTracks = 0,
    this.totalTracks = 0,
    this.currentItemName = '',
    this.collectionKind = '',
    this.phase = DownloadPhase.preparing,
    this.failedTracks = 0,
  });

  DownloadState copyWith({
    bool? isDownloading,
    int? downloadedTracks,
    int? totalTracks,
    String? currentItemName,
    String? collectionKind,
    DownloadPhase? phase,
    int? failedTracks,
  }) {
    return DownloadState(
      isDownloading: isDownloading ?? this.isDownloading,
      downloadedTracks: downloadedTracks ?? this.downloadedTracks,
      totalTracks: totalTracks ?? this.totalTracks,
      currentItemName: currentItemName ?? this.currentItemName,
      collectionKind: collectionKind ?? this.collectionKind,
      phase: phase ?? this.phase,
      failedTracks: failedTracks ?? this.failedTracks,
    );
  }

  /// 0..1, or null while preparing — a determinate bar at 0% for a minute is a
  /// worse lie than an indeterminate one.
  double? get fraction {
    if (phase == DownloadPhase.preparing || totalTracks <= 0) return null;
    return (downloadedTracks / totalTracks).clamp(0.0, 1.0);
  }
}

class DownloadNotifier extends StateNotifier<DownloadState> {
  DownloadNotifier() : super(const DownloadState());

  void startDownload(int total, String name, {String kind = ''}) {
    state = DownloadState(
      isDownloading: true,
      totalTracks: total,
      downloadedTracks: 0,
      currentItemName: name,
      collectionKind: kind,
      phase: DownloadPhase.preparing,
    );
  }

  /// Stream resolution finished; [ready] tracks actually have a URL to fetch.
  void beginTransfer(int ready) {
    if (!state.isDownloading) return;
    state = state.copyWith(
      phase: DownloadPhase.downloading,
      totalTracks: ready,
      downloadedTracks: 0,
    );
  }

  void updateProgress(int completed) {
    if (!state.isDownloading) return;
    state = state.copyWith(downloadedTracks: completed);
  }

  /// NO AUTO-HIDE ON A COUNT. The old version hid itself two seconds after
  /// `completed >= totalTracks`, which meant a run that ENDED EARLY — a failed
  /// resolve, a thrown exception, nothing left to fetch — never reached that
  /// condition and the banner stayed on screen forever showing "7 of 20".
  ///
  /// The owner of the work calls this from a `finally` instead, so there is no
  /// path out of a download that leaves the indicator behind.
  void finishDownload({int failed = 0}) {
    if (!state.isDownloading) return;
    state = state.copyWith(
      isDownloading: false,
      downloadedTracks: 0,
      totalTracks: 0,
      failedTracks: failed,
    );
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((ref) {
  return DownloadNotifier();
});
