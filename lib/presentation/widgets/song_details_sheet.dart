import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/services/stream_resolver.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';

/// Song Details sheet, shared by the player menu and the track 3-dot menu.
///
/// Three quiet groups — the track itself, the user's own listening, and the
/// technical playback source. Rows with nothing to say are omitted entirely
/// (no "Unknown" filler), which keeps the sheet informative but light.
void showSongDetailsSheet(BuildContext context, WidgetRef ref, Song song,
    {Duration activeDuration = Duration.zero}) {
  final cache = AudioCacheManager();
  final isDownloaded = cache.isExplicitlyDownloaded(song.id);
  final isCached = cache.isCached(song.id);
  final trackInfo = cache.getTrackInfo(song.id);
  final themeColor = ref.read(themeProvider);

  // The playback facts
  //
  // Every label here is null unless the value is genuinely known, and a null
  // label renders no row. Nothing in this sheet is a placeholder or a restatement
  // of a setting: the previous version printed the user's chosen quality tier as
  // though it described the audio, so someone on Automatic read "Automatic" and
  // learned nothing about what was actually playing.
  final resolved = StreamResolver().peekResolved(song.id);

  final durationSeconds = _durationSeconds(song, ref, activeDuration);

  // Real bitrate: what the stream reports, or — for a file on disk — its size
  // over its length, which is the average bitrate by definition.
  int? bitrateBps = int.tryParse(resolved?['bitrate'] ?? '');
  if ((bitrateBps == null || bitrateBps <= 0) &&
      trackInfo != null &&
      trackInfo.fileSizeBytes > 0 &&
      durationSeconds > 0) {
    bitrateBps = (trackInfo.fileSizeBytes * 8 / durationSeconds).round();
  }
  final hasBitrate = bitrateBps != null && bitrateBps > 0;

  final String? bitrateLabel =
      hasBitrate ? '${(bitrateBps / 1000).round()} kbps' : null;

  // Named from the measured bitrate, so it says what the audio IS.
  final String? audioQuality = !hasBitrate
      ? null
      : bitrateBps >= 200000
          ? 'Very high'
          : bitrateBps >= 128000
              ? 'High'
              : bitrateBps >= 96000
                  ? 'Standard'
                  : 'Data saver';

  // Only when the stream named a codec. A container does not name one — WebM can
  // hold Opus or Vorbis, so a local-only track shows its container in Format
  // instead of an inferred codec here.
  final String? codecLabel =
      resolved?['mimeType'] == null ? null : _codecOf(resolved!['mimeType']);

  final int? sampleHz = int.tryParse(resolved?['sampleRate'] ?? '');
  final int? channels = int.tryParse(resolved?['channels'] ?? '');
  final String? sampleRateLabel = (sampleHz == null || sampleHz <= 0)
      ? null
      : '${(sampleHz / 1000).toStringAsFixed(sampleHz % 1000 == 0 ? 0 : 1)} kHz'
          '${channels == 2 ? ' · Stereo' : channels == 1 ? ' · Mono' : ''}';

  // YouTube's measured loudness for the master, the same figure volume
  // normalization works from.
  final double? loudnessDb = double.tryParse(resolved?['loudnessDb'] ?? '');
  final String? loudnessLabel =
      loudnessDb == null ? null : '${loudnessDb.toStringAsFixed(1)} dB';

  final int streamBytes = int.tryParse(resolved?['contentLength'] ?? '') ?? 0;

  // Says WHERE, specifically. "Network stream" was technically true and told the
  // user nothing they could act on.
  final String sourceLabel = isDownloaded
      ? 'Downloaded to this device'
      : isCached
          ? 'Cached for offline playback'
          : song.id.startsWith('http')
              ? 'Streaming · ${Uri.tryParse(song.id)?.host ?? 'direct link'}'
              : 'Streaming · YouTube Music';

  // The user's own relationship with this track. Play counts live in Stats, so
  // they are not repeated here.
  final intelState = ref.read(intelligenceProvider);
  // FIRST heard, not LAST played. See the row below for why.
  final firstPlayedMs = intelState.firstPlayTimestamps[song.id];

  final library = ref.read(libraryProvider);
  final isLiked = library.likedSongIds.contains(song.id);
  final playlistCount = library.allItems
      .where((i) => i.category == LibraryCategory.playlist && !i.isSystemFolder)
      .where((i) => (library.playlistSongs[i.title] ?? const []).any((s) => s.id == song.id))
      .length;

  final releaseDate = _formatReleaseDate(song.releaseDate);
  final albumName = (song.albumTitle.isEmpty || song.albumTitle == "null") ? "Single" : song.albumTitle;

  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _DragToDismiss(
      builder: (scrollCtrl) => Container(
      // 0.78, not 0.85: a cap, not a height — the sheet still sizes to its
      // content. Dropping the Close button and tightening the group gaps took
      // roughly a section's worth of height out, so on most tracks it no longer
      // reaches the cap at all, and the page stays visible above it.
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: Colors.white.withOpacity(0.05), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grabber lives OUTSIDE the scroll view so a downward drag on it drags
          // the SHEET (swipe-to-dismiss) instead of being eaten as a scroll
          // overscroll bounce — that's why the sheet couldn't be dragged down and
          // needed the back button. Clamping physics keeps the content itself from
          // bouncing over the dismiss gesture too.
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 12),
            child: Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)))),
          ),
          Flexible(
            child: SingleChildScrollView(
              controller: scrollCtrl,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).padding.bottom + 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            Row(
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(10)), child: AuvyImage(path: song.image, width: 56, height: 56, fit: BoxFit.cover)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("SONG DETAILS", style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.6, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(song.title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold, height: 1.2), maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(song.displayArtist, style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            _TrackInfoGroup(
              song: song,
              albumName: albumName,
              initialRelease: releaseDate,
            ),
            const SizedBox(height: 12),

            // "Your Plays" is deliberately absent — the play count already has a
            // home in Stats, and repeating it here spent a row on something the
            // user can already find.
            //
            // "last played" was worthless by construction
            //
            // It read "just now" almost every time it was seen, because of WHERE
            // this sheet is opened from: the track playing, or one just tapped in
            // a list. A field whose answer is determined by the act of looking at
            // it tells the reader nothing.
            //
            // FIRST heard is the same data shape and a real fact — when this
            // track entered the listener's life. It cannot be produced by opening
            // the sheet, it does not repeat Stats, and it is the one thing here
            // nothing else in the app shows.
            _detailsGroup([
              if (firstPlayedMs != null && firstPlayedMs > 0)
                _detailRow(Icons.auto_awesome_rounded, "First heard",
                    _relativeTime(firstPlayedMs)),
              // Only show "Liked" when it's actually liked — "Liked: No" is
              // noise the user already knows (they tap the heart to change it).
              if (isLiked)
                _detailRow(Icons.favorite_rounded, "Liked", "Yes", accent: themeColor),
              if (playlistCount > 0)
                _detailRow(Icons.queue_music_rounded, "In Playlists", playlistCount == 1 ? "1 playlist" : "$playlistCount playlists"),
            ]),
            const SizedBox(height: 12),

            _detailsGroup([
              if (audioQuality != null)
                _detailRow(Icons.graphic_eq_rounded, "Quality", audioQuality),
              if (codecLabel != null)
                _detailRow(Icons.memory_rounded, "Codec", codecLabel),
              if (bitrateLabel != null)
                _detailRow(Icons.speed_rounded, "Bitrate", bitrateLabel),
              if (sampleRateLabel != null)
                _detailRow(Icons.waves_rounded, "Sample rate", sampleRateLabel),
              if (loudnessLabel != null)
                _detailRow(Icons.volume_up_rounded, "Loudness", loudnessLabel),
              _detailRow(Icons.file_present_rounded, "Source", sourceLabel),
              if (trackInfo != null && trackInfo.fileSizeBytes > 0)
                _detailRow(Icons.sd_storage_rounded, "File size", _formatBytes(trackInfo.fileSizeBytes))
              else if (streamBytes > 0)
                _detailRow(Icons.sd_storage_rounded, "Stream size", _formatBytes(streamBytes)),
              // Measured from the file's own bytes, or taken from the resolved
              // stream. NOT from the filename: cache files are all named `.m4a`
              // while the audio inside is usually Opus in WebM, so the extension
              // reported the wrong format for nearly every cached track.
              _FormatRow(
                  songId: song.id,
                  streamMimeType: resolved?['mimeType'],
                  hasLocalFile: trackInfo != null),
              _CopyableDetailRow(label: "Track ID", value: song.id, themeColor: themeColor),
            ]),

            // NO Close button. It was 54px plus a 24px gap at the end of a sheet
            // that already dismisses three ways — the grabber above (see the
            // `_DragToDismiss` note), a tap outside, and the system back gesture.
            // A button that only repeats gestures the sheet already has costs
            // height and implies the others might not work.
                ],
              ),
            ),
          ),
        ],
      ),
    )),
  );
}

/// Makes a bottom sheet dismissible by dragging DOWN anywhere on it (not just
/// the grabber). Uses a passive [Listener] — it OBSERVES pointer events without
/// competing in the gesture arena, so it doesn't fight the inner scroll view:
/// while the content is scrolled to the top, a cumulative downward drag past a
/// small threshold pops the sheet. The content still scrolls normally otherwise.
class _DragToDismiss extends StatefulWidget {
  final Widget Function(ScrollController scrollController) builder;
  const _DragToDismiss({required this.builder});

  @override
  State<_DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<_DragToDismiss> {
  final ScrollController _scroll = ScrollController();
  double _accumDown = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: (e) {
        final atTop = !_scroll.hasClients || _scroll.offset <= 0;
        if (e.delta.dy > 0 && atTop) {
          _accumDown += e.delta.dy;
          if (_accumDown > 110 && Navigator.of(context).canPop()) {
            _accumDown = 0;
            Navigator.of(context).pop();
          }
        } else if (e.delta.dy < 0) {
          _accumDown = 0; // dragging back up cancels the dismiss
        }
      },
      onPointerUp: (_) => _accumDown = 0,
      onPointerCancel: (_) => _accumDown = 0,
      child: widget.builder(_scroll),
    );
  }
}

// Formatting helpers

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  if (bytes >= 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  if (bytes >= 1024) return "${(bytes / 1024).toStringAsFixed(0)} KB";
  return "$bytes B";
}

const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The track's length in seconds, for computing a file's average bitrate.
///
/// Prefers the player's live duration, but ONLY when the sheet's song is the one
/// playing — reading it unconditionally is what once printed the playing track's
/// length against a different song opened from History.
int _durationSeconds(Song song, WidgetRef ref, Duration activeDuration) {
  final isCurrent = ref.read(playerProvider).currentSong?.id == song.id;
  if (isCurrent && activeDuration.inSeconds > 0) return activeDuration.inSeconds;
  final raw = song.duration.trim();
  if (raw.contains(':')) {
    final parts = raw.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    return 0;
  }
  return int.tryParse(raw) ?? 0;
}

/// The codec name out of a stream mimeType like `audio/webm; codecs="opus"`.
/// Falls back to the container when no codec is named.
String _codecOf(String? mimeType) {
  final m = (mimeType ?? '').toLowerCase();
  if (m.contains('opus')) return 'Opus';
  if (m.contains('mp4a') || m.contains('aac')) return 'AAC';
  if (m.contains('vorbis')) return 'Vorbis';
  if (m.contains('mpeg') || m.contains('mp3')) return 'MP3';
  if (m.contains('flac')) return 'FLAC';
  if (m.startsWith('audio/webm')) return 'WebM';
  if (m.startsWith('audio/mp4')) return 'AAC';
  return 'Audio';
}

/// The Format row, resolved asynchronously because the only trustworthy answer
/// for a local file is its magic number.
///
/// Renders nothing at all when neither the file nor the stream can say — an
/// absent row beats a wrong one, and this sheet already omits fields it cannot
/// establish.
class _FormatRow extends StatefulWidget {
  final String songId;
  final String? streamMimeType;
  final bool hasLocalFile;

  const _FormatRow({
    required this.songId,
    required this.streamMimeType,
    required this.hasLocalFile,
  });

  @override
  State<_FormatRow> createState() => _FormatRowState();
}

class _FormatRowState extends State<_FormatRow> {
  String? _format;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    String? value;
    if (widget.hasLocalFile) {
      value = await AudioCacheManager().containerOf(widget.songId);
    }
    value ??= widget.streamMimeType == null
        ? null
        : _codecOf(widget.streamMimeType);
    if (!mounted || value == null) return;
    setState(() => _format = value);
  }

  @override
  Widget build(BuildContext context) {
    final f = _format;
    if (f == null) return const SizedBox.shrink();
    return _detailRow(Icons.audio_file_rounded, "Format", f);
  }
}

/// "2019-05-17" → "17 May 2019"; a bare year passes through; junk → null.
String? _formatReleaseDate(String raw) {
  final r = raw.trim();
  if (r.isEmpty || r.toLowerCase() == 'null' || r.toLowerCase() == 'unknown' ||
      r.toLowerCase() == 'unknown date') {
    return null;
  }
  final parsed = DateTime.tryParse(r);
  if (parsed != null) return "${parsed.day} ${_months[parsed.month - 1]} ${parsed.year}";
  return r;
}

/// True when [raw] carries only a YEAR ("2019") rather than a full date — i.e.
/// it can still be upgraded to the exact day.
bool _isYearOnly(String? raw) {
  final r = raw?.trim() ?? '';
  return r.length == 4 && int.tryParse(r) != null;
}

String _relativeTime(int ms) {
  final then = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(then);
  if (diff.inMinutes < 1) return "Just now";
  if (diff.inHours < 1) return "${diff.inMinutes} min ago";
  if (diff.inHours < 24) return diff.inHours == 1 ? "1 hour ago" : "${diff.inHours} hours ago";
  if (diff.inDays < 7) return diff.inDays == 1 ? "Yesterday" : "${diff.inDays} days ago";
  if (diff.inDays < 30) return "${(diff.inDays / 7).floor()} week${diff.inDays >= 14 ? 's' : ''} ago";
  return "${then.day} ${_months[then.month - 1]} ${then.year}";
}

// Row widgets

/// The "track facts" group. Self-enriches the RELEASE DATE on open:
///  1. asks YouTube for the EXACT date (`getTrackReleaseDate` — the player
///     microformat, the only place the calendar day exists; the catalog
///     endpoints hand back a bare year, which is why this row used to read
///     "2019" at best);
///  2. failing that, falls back to ONE cached track search for the year, so
///     rows that arrived with no date at all (radio / search / autoplay) still
///     show something instead of hiding the row.
///
/// Both are best-effort and free for anything you've played (stream resolution
/// seeds the same date cache). Every other fact is synchronous. Building the
/// group inside this widget (rather than appending an async row to a fixed list)
/// keeps the divider layout correct.
class _TrackInfoGroup extends ConsumerStatefulWidget {
  final Song song;
  final String albumName;
  final String? initialRelease;
  const _TrackInfoGroup({
    required this.song,
    required this.albumName,
    required this.initialRelease,
  });

  @override
  ConsumerState<_TrackInfoGroup> createState() => _TrackInfoGroupState();
}

class _TrackInfoGroupState extends ConsumerState<_TrackInfoGroup> {
  String? _release;

  @override
  void initState() {
    super.initState();
    _release = widget.initialRelease;
    // Enrich when there's nothing at all AND when all we have is a year — the
    // whole point is to show the actual day, not just "2019".
    if (_release == null || _isYearOnly(_release)) _enrichRelease();
  }

  Future<void> _enrichRelease() async {
    final s = widget.song;
    if (s.id.startsWith('http') || s.title.isEmpty) return;

    // 1) The exact calendar date, straight from YouTube's player microformat.
    //    Only real 11-char video ids have one.
    if (s.id.length == 11) {
      try {
        final exact = await ref
            .read(searchServiceProvider)
            .getTrackReleaseDate(s.id)
            .timeout(const Duration(seconds: 8));
        if (exact != null) {
          final formatted = _formatReleaseDate(exact);
          if (formatted != null) {
            if (mounted) setState(() => _release = formatted);
            return;
          }
        }
      } catch (_) {}
    }
    // Nothing exact available — keep a year we already had rather than
    // re-searching for the same thing.
    if (_release != null) return;

    // 2) Fallback: recover at least the YEAR from a catalog search.
    try {
      final q = s.artist.isNotEmpty ? '${s.title} ${s.artist}' : s.title;
      final results = await ref
          .read(searchServiceProvider)
          .search(q, 'track')
          .timeout(const Duration(seconds: 6));
      String needle(String x) => x.toLowerCase().split('(').first.trim();
      Song? best;
      for (final r in results) {
        if (r.releaseDate.trim().isEmpty) continue;
        if (needle(r.title) == needle(s.title)) {
          best = r;
          break;
        }
        best ??= r; // first with a date, as a fallback
      }
      if (best != null) {
        final formatted = _formatReleaseDate(best.releaseDate);
        if (formatted != null && mounted) setState(() => _release = formatted);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    return _detailsGroup([
      _detailRow(Icons.person_rounded, "Artist", song.displayArtist),
      _detailRow(Icons.album_rounded, "Album", widget.albumName),
      if (_release != null)
        _detailRow(Icons.event_rounded, "Released", _release!),
      // No "content" row — removed deliberately, don't re-add
      //
      // It was already suppressed for clean tracks, because "Content: Clean" is
      // something the reader already knows. The explicit half is the same
      // problem one step along: the E badge is drawn on the track's own row
      // wherever it is listed (see ExplicitArtistLine), so by the time this
      // sheet is open the reader has been told, and a whole labelled row is a
      // heavy way to repeat a badge.
      //
      // `Song.isExplicit` is untouched and still drives that badge.
      // POPULARITY IS NOT SHOWN AT ALL — removed deliberately, don't re-add.
      //
      // It was never trustworthy. YouTube (the source for almost everything here)
      // publishes no popularity figure, so `_mapJsonToSong` defaulted it to 50 —
      // the source of "always 50%". That default is now 0, but tracks SAVED before
      // the change still carry a stored 50 in their persisted maps (liked songs,
      // history, playlists, the conform cache), so old rows keep reporting a
      // fabricated number that no amount of display logic can distinguish from a
      // real one.
      //
      // Even the genuine values are incomparable: Spotify's 0–100 is computed
      // differently from Deezer's rank and from Last.fm listener counts, so the
      // same figure means different things depending on which service happened to
      // answer. A number the user cannot interpret, that is sometimes invented, is
      // worse than no number.
      //
      // `Song.popularity` still EXISTS and is still used for recommendation
      // ranking, where a rough relative signal is fine and never shown as fact.
      if (song.viewCount.isNotEmpty && song.viewCount != "0")
        _detailRow(Icons.visibility_rounded, "Views", song.viewCount),
    ]);
  }
}

/// One rounded card of detail rows with hairline dividers between them.
Widget _detailsGroup(List<Widget> rows) {
  final children = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    children.add(rows[i]);
    if (i != rows.length - 1) {
      children.add(const Divider(color: Colors.white10, height: 22));
    }
  }
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.circular(16)),
    child: Column(children: children),
  );
}

Widget _detailRow(IconData icon, String label, String value, {Color? accent}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(icon, color: accent ?? Colors.white54, size: 20),
      const SizedBox(width: 12),
      SizedBox(width: 92, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13))),
      Expanded(child: Text(value, style: TextStyle(color: accent ?? Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600), textAlign: TextAlign.right, maxLines: 2, overflow: TextOverflow.ellipsis)),
    ],
  );
}

/// Detail row whose value can be copied with a tap — used for the track ID so
/// power users can grab it without any debug tooling.
class _CopyableDetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color themeColor;
  const _CopyableDetailRow({required this.label, required this.value, required this.themeColor});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        AnimatedToast.show(context, text: "Track ID copied", icon: Icons.copy_rounded, color: themeColor);
      },
      borderRadius: BorderRadius.circular(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.tag_rounded, color: Colors.white54, size: 20),
          const SizedBox(width: 12),
          SizedBox(width: 92, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13))),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Icon(Icons.copy_rounded, color: Colors.white.withOpacity(0.35), size: 14),
        ],
      ),
    );
  }
}
