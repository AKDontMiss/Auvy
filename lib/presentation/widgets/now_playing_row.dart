import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/presentation/widgets/playing_equalizer.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';

/// The "this row is the one playing" treatment, in one place.
///
/// Every track list in the app marks the playing row two ways — the equalizer
/// over its artwork and the title in the accent colour, but each page grew its
/// own copy, so the album page had the equalizer and no title highlight, and the
/// artist and history pages had neither. The rule is identical everywhere, so it
/// lives here and each page asks for it.
///
/// IDENTITY IS NOT THE ID — SEE [isSameTrack].
///
/// A row can be the playing track under its raw id, under its conformed id, or
/// under no shared id at all: play a song from a playlist, open its album, and
/// the album's edition of that same recording carries a different id entirely.
/// That is why every call site passes the title and artist too, and why the
/// decision is made in one shared function instead of per page.
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
  );
}

/// What a row knows about itself, so both widgets ask the same question.
class _RowRef {
  final String rowId;
  final String? altId;
  final String title;
  final String artist;
  const _RowRef(this.rowId, this.altId, this.title, this.artist);
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
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  const NowPlayingTitle({
    super.key,
    required this.title,
    required this.rowId,
    this.altId,
    this.artist = '',
    this.style,
    this.maxLines = 1,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select() — a whole-provider watch rebuilt every visible tile on each
    // periodic PlayerState write (position ticks included).
    final bool isCurrent = ref.watch(playerProvider
        .select((ps) => _isCurrent(ps, _RowRef(rowId, altId, title, artist))));
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
  final double size;
  final double borderRadius;
  final double barSize;

  const NowPlayingArtOverlay({
    super.key,
    required this.rowId,
    this.altId,
    this.title = '',
    this.artist = '',
    this.size = 48,
    this.borderRadius = 8,
    this.barSize = 10,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isRowPlaying = ref.watch(playerProvider.select((ps) {
      if (!ps.isPlaying) return false;
      return _isCurrent(ps, _RowRef(rowId, altId, title, artist));
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
