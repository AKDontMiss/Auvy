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
import 'package:auvy/core/app_colors.dart';

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

  // The playback facts. Every label is null unless the value is genuinely known,
  // and a null label renders no row: nothing here is a placeholder or a restated
  // setting (e.g. showing "Automatic" instead of the actual audio quality).
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
        color: AppColors.modalPanel,
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
                      const Text("SONG DETAILS", style: TextStyle(color: Colors.white60, fontSize: 11, letterSpacing: 1.6, fontWeight: FontWeight.w800)),
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

            // No "Your plays" row (the count lives in Stats) and no "last played" (opening
            // this sheet is itself a play or tap, so it would almost always read "just
            // now"). First heard is a real fact that nothing else in the app shows.
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
              // Measured from the file's own bytes or taken from the resolved stream, not the
              // filename (cache files are all named `.m4a` but usually hold Opus in WebM).
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

/// "2019-05-17" → "17 May 2019"; a bare year passes through; anything else → null.
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

/// The track facts group. Fills in the release date on open: first the exact date
/// from YouTube (`getTrackReleaseDate`, the only place with the calendar day), then
/// one cached track search for the year, so rows that arrived without a date still
/// show one. Both are free for anything played (stream resolution fills the same
/// cache); every other fact is synchronous. Built inside this widget so the
/// dividers stay correct.
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
      // No "content" row: the E badge on the track's own row already says it's
      // explicit. `Song.isExplicit` still drives that badge.
      //
      // No popularity row either: YouTube publishes no popularity figure, older saved
      // tracks carry a fabricated default, and values from Spotify, Deezer and Last.fm
      // aren't comparable. `Song.popularity` is still used as a rough ranking signal in
      // recommendations, never shown as fact.
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
