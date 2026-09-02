import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/providers/theme_provider.dart';

/// Live per-song download progress for track tiles.
///
/// [AudioCacheManager] already broadcasts a `songId → 0..1` map on every chunk
/// (`downloadProgress`); this hub folds that stream into one [ValueNotifier]
/// so any number of tiles can listen without each opening a subscription.
class DownloadProgressHub {
  DownloadProgressHub._();

  static final ValueNotifier<Map<String, double>> progress =
      ValueNotifier(const {});
  static StreamSubscription<Map<String, double>>? _sub;

  static void ensureWired() {
    _sub ??= AudioCacheManager()
        .downloadProgress
        .listen((m) => progress.value = m);
  }
}

/// Drop-in for a track tile's `subtitle` slot: while the song is downloading it
/// shows a slim theme-colored HORIZONTAL progress bar (with the live byte
/// percentage) to the right of the cover art, and otherwise renders [fallback]
/// (normally the artist line) unchanged. Replaces the old circular ring that
/// dimmed the artwork.
///
///   subtitle: TrackDownloadBar(
///     songId: song.id,
///     fallback: Text(song.displayArtist, ...),
///   ),
class TrackDownloadBar extends ConsumerWidget {
  final String songId;
  final Widget fallback;

  const TrackDownloadBar({
    super.key,
    required this.songId,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    DownloadProgressHub.ensureWired();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: DownloadProgressHub.progress,
      builder: (context, map, _) {
        final p = map[songId];
        // Not downloading → show the normal subtitle (artist) untouched.
        if (p == null) return fallback;

        final accent = ref.watch(themeProvider);
        final clamped = p.clamp(0.0, 1.0);
        final pct = (clamped * 100).round();

        return Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 1),
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 5,
                    child: p > 0
                        // Determinate: real byte progress.
                        ? Stack(
                            children: [
                              Container(color: Colors.white.withOpacity(0.15)),
                              FractionallySizedBox(
                                widthFactor: clamped,
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: accent,
                                    borderRadius: BorderRadius.circular(3),
                                    boxShadow: [
                                      BoxShadow(
                                        color: accent.withOpacity(0.5),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          )
                        // Indeterminate sweep until the first sized chunk lands.
                        : LinearProgressIndicator(
                            backgroundColor: Colors.white.withOpacity(0.15),
                            color: accent,
                            minHeight: 5,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 34,
                child: Text(
                  p > 0 ? '$pct%' : '···',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.78),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
