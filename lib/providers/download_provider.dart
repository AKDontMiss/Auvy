import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What stage a bulk download is at. Before any bytes are written, each track's
/// stream has to be resolved (a network round trip each, up to 15 s), which can
/// take longer than the download itself; the banner shows this stage separately
/// so it doesn't look stuck at "0 of 20".
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

  /// Hides the banner. Called by the owner of the work from a `finally`, so every
  /// way out of a download (including early failures) clears the indicator.
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
