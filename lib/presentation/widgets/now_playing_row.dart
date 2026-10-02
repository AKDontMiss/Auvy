import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/presentation/widgets/playing_equalizer.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';

/// Whether a track row is the one currently playing (shown as the equalizer
/// over its artwork and an accent-coloured title), shared by every track list.
///
/// Matching uses [isSameTrack] rather than the id alone: the same recording
/// can have a different id on an album than in the playlist it was played
/// from, so call sites pass the title and artist too.
bool _isCurrent(PlayerState ps, _RowRef row) {
  final playing = ps.currentSong;
  if (playing == null) return false;
  return isSameTrack(
    playingId: playing.id,
    playingTitle: playing.title,
    playingArtist: playing.displayArtist,
    rowId: row.rowId,
    rowAltId: row.altId,
    rowTitle: row.title,
    rowArtist: row.artist,
    // The tie-breaker for a solo track and a same-named collaboration, whose
    // titles and primary artist are identical once normalised. Both are display
    // strings and either may be absent, which the rule treats as "no evidence"
    // rather than as disagreement — see isSameTrack.
    playingDurationMs: durationMsFromDisplayString(playing.duration),
    rowDurationMs: durationMsFromDisplayString(row.duration),
  );
}

/// What a row knows about itself, so both widgets ask the same question.
class _RowRef {
  final String rowId;
  final String? altId;
  final String title;
  final String artist;
  final String duration;
  const _RowRef(this.rowId, this.altId, this.title, this.artist, this.duration);
}

/// A track title that turns the accent colour while it is the current track.
///
/// Deliberately does NOT require `isPlaying`: a paused track is still the one
/// the user is on, and dropping the highlight on pause makes the list look like
/// it lost its place. The equalizer is what conveys play/pause.
class NowPlayingTitle extends ConsumerWidget {
  final String title;
  final String rowId;
  final String? altId;
  /// The row's artist. Optional only because a few rows genuinely have none;
  /// pass it wherever it exists — without it a same-titled track by a different
  /// artist can match.
  final String artist;
  /// The row's own runtime, as the display string a Song carries.
  /// Optional: absent means 'no evidence', never 'different'.
  final String duration;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  const NowPlayingTitle({
    super.key,
    required this.title,
    required this.rowId,
    this.altId,
    this.artist = '',
    this.duration = '',
    this.style,
    this.maxLines = 1,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select() — a whole-provider watch rebuilt every visible tile on each
    // periodic PlayerState write (position ticks included).
    final bool isCurrent = ref.watch(playerProvider
        .select((ps) =>
            _isCurrent(ps, _RowRef(rowId, altId, title, artist, duration))));
    final TextStyle base = style ?? const TextStyle(color: Colors.white);
    return Text(
      title,
      style: isCurrent
          ? base.copyWith(
              color: ref.watch(themeProvider), fontWeight: FontWeight.w700)
          : base,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }
}

/// The scrim + equalizer that sits on top of a row's artwork while it plays.
///
/// Stack this over the artwork at the same size; it collapses to nothing when
/// the row is not the playing one, so it costs a `SizedBox.shrink()` per row.
class NowPlayingArtOverlay extends ConsumerWidget {
  final String rowId;
  final String? altId;
  final String title;
  final String artist;
  /// See NowPlayingTitle.duration.
  final String duration;
  final double size;
  final double borderRadius;
  final double barSize;

  const NowPlayingArtOverlay({
    super.key,
    required this.rowId,
    this.altId,
    this.title = '',
    this.artist = '',
    this.duration = '',
    this.size = 48,
    this.borderRadius = 8,
    this.barSize = 10,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isRowPlaying = ref.watch(playerProvider.select((ps) {
      if (!ps.isPlaying) return false;
      return _isCurrent(ps, _RowRef(rowId, altId, title, artist, duration));
    }));
    if (!isRowPlaying) return const SizedBox.shrink();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: PlayingEqualizer(
            size: barSize, color: ref.watch(themeProvider), playing: true),
      ),
    );
  }
}
