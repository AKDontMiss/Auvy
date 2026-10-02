import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:auvy/core/utils/share_origin.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/lyrics_translation_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

// Share postcard: one 9:16 story card for several kinds of content. It shows what
// a share card is for: the artwork, the name, who it's by, and a quiet mark saying
// where it came from. No fake progress bar or "now playing" chip, and the
// attribution appears once. The ambience is one widget-level blur of the artwork,
// rasterised once because the card is static (no BackdropFilter).

enum PostcardKind { track, artist, album, playlist, lyrics, podcast, radio }

extension _KindLabel on PostcardKind {
  /// The single kind label, in the app's small-caps voice. `podcast` and `radio`
  /// exist because episodes and stations are Songs internally, and the card should
  /// say what the thing actually is (see [postcardKindForSong]).
  String get label => switch (this) {
        PostcardKind.track => 'SONG',
        PostcardKind.artist => 'ARTIST',
        PostcardKind.album => 'ALBUM',
        PostcardKind.playlist => 'PLAYLIST',
        PostcardKind.lyrics => 'LYRICS',
        PostcardKind.podcast => 'PODCAST',
        PostcardKind.radio => 'RADIO',
      };

  /// Artists get a circle; everything else keeps its square artwork.
  bool get isRound => this == PostcardKind.artist;
}

class SharePostcard extends StatelessWidget {
  final Song song;
  final Color themeColor;
  final GlobalKey repaintKey;
  final PostcardKind kind;

  /// Lyrics mode only: the lines the user picked, in order.
  final List<String> lyricLines;

  /// Lyrics mode only: which rendition the lines came from, `'original'` or the code
  /// of the language the user translated to. Shown on the card, because presenting a
  /// machine translation as the songwriter's words would misattribute them.
  final String lyricLanguage;

  const SharePostcard({
    super.key,
    required this.song,
    required this.themeColor,
    required this.repaintKey,
    this.kind = PostcardKind.track,
    this.lyricLines = const [],
    this.lyricLanguage = 'original',
  });

  /// Label for [lyricLanguage], or empty for the original: only translations get a
  /// tag, so it stands out when present. "Translated · Swedish" rather than just
  /// "Swedish", which could read as the song being in Swedish.
  String get _languageLabel {
    final code = lyricLanguage.trim().toLowerCase();
    if (code.isEmpty || code == 'original') return '';
    // Language names come from the translation service's own map, so every language
    // it offers has a proper name here.
    final name = LyricsTranslationService.supportedLanguages[code];
    // A code the service does not know is not worth inventing a name for; the
    // bare code is honest, and there is no longer a routine path to it.
    final label = name ?? lyricLanguage.toUpperCase();
    return 'TRANSLATED · ${label.toUpperCase()}';
  }

  static const double _w = 340;
  static const double _h = 604; // 9:16

  Widget _artwork({required double size}) {
    if (song.image.isEmpty) {
      return Container(
        width: size,
        height: size,
        color: const Color(0xFF181818),
        child: Icon(Icons.music_note_rounded,
            color: Colors.white24, size: size * 0.3),
      );
    }
    return song.image.startsWith('assets/')
        ? Image.asset(song.image, width: size, height: size, fit: BoxFit.cover)
        : AuvyImage(path: song.image, width: size, height: size, fit: BoxFit.cover);
  }

  /// The secondary line under the name. Empty for an artist, whose name IS the
  /// content — a second line there was always either blank or a repeat.
  String get _secondary => switch (kind) {
        PostcardKind.artist => '',
        _ => song.displayArtist,
      };

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: repaintKey,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(
          width: _w,
          height: _h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF0A0A0C)),

              // Ambient wash. Transform stays OUTSIDE the filter — inside,
              // Impeller mis-computes the filter bounds and paints a sharp copy
              // on top of the blur.
              if (song.image.isNotEmpty)
                ClipRect(
                  child: Transform.scale(
                    scale: 1.35,
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                          sigmaX: 60, sigmaY: 60, tileMode: ui.TileMode.clamp),
                      child: _artwork(size: _h),
                    ),
                  ),
                ),

              // Readability scrim, theme-tinted at the base so the card reads as
              // part of the artwork rather than a black box over it.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.45, 1.0],
                    colors: [
                      Colors.black.withOpacity(0.55),
                      Colors.black.withOpacity(0.30),
                      const Color(0xFF07070A).withOpacity(0.92),
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(30, 32, 30, 26),
                child: kind == PostcardKind.lyrics
                    ? _lyricsLayout()
                    : _artworkLayout(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Track / artist / album / playlist: artwork leads, name below it.
  Widget _artworkLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Center(
          child: Container(
            decoration: BoxDecoration(
              // 34, not 20. On a 284px cover a 20px radius reads as "square with
              // the corners knocked off"; 34 (~12% of the side) is enough to read
              // as a deliberately rounded card, which is what the rest of the
              // postcard already looks like — the card itself is 28 at a much
              // larger size. Artists stay fully round (`isRound`).
              borderRadius: BorderRadius.circular(kind.isRound ? 142 : 34),
              boxShadow: [
                BoxShadow(
                    color: themeColor.withOpacity(0.28),
                    blurRadius: 44,
                    spreadRadius: -6,
                    offset: const Offset(0, 10)),
                BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 30,
                    offset: const Offset(0, 20)),
              ],
            ),
            child: ClipRRect(
              // 34, not 20. On a 284px cover a 20px radius reads as "square with
              // the corners knocked off"; 34 (~12% of the side) is enough to read
              // as a deliberately rounded card, which is what the rest of the
              // postcard already looks like — the card itself is 28 at a much
              // larger size. Artists stay fully round (`isRound`).
              borderRadius: BorderRadius.circular(kind.isRound ? 142 : 34),
              child: _artwork(size: 284),
            ),
          ),
        ),
        const SizedBox(height: 30),
        Text(
          song.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            height: 1.12,
            letterSpacing: -0.7,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (_secondary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _secondary,
            style: TextStyle(
              color: Colors.white.withOpacity(0.78),
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const Spacer(),
        _footer(),
      ],
    );
  }

  /// Lyrics: the WORDS are the subject, so they get the space the artwork
  /// normally takes and the artwork shrinks to a credit line.
  Widget _lyricsLayout() {
    // Long selections need smaller type to stay on one card. Stepped rather
    // than continuous so two similar-length shares don't look inconsistent.
    final chars = lyricLines.fold<int>(0, (a, l) => a + l.length);
    final double size = chars > 220
        ? 19
        : chars > 140
            ? 22
            : chars > 70
                ? 25
                : 28;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        // A quiet accent rule instead of a quotation mark: a big glyph would be
        // one more decoration competing with the lines themselves.
        Row(
          children: [
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: themeColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Provenance, beside the rule rather than buried in the footer: when
            // it applies, the recipient should see it at the same moment they
            // read the words. Absent entirely for original lyrics — see
            // _languageLabel.
            if (_languageLabel.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                _languageLabel,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        // One Text per line rather than one joined Text, so a wrapped line can be told
        // from the next line: tight leading within a line (1.22) and a real gap between
        // lines, scaled to the type size. Full width and left-aligned, so a short quote
        // doesn't sit in a narrow centred column.
        SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lyricLines.length; i++) ...[
                if (i > 0) SizedBox(height: size * 0.46),
                Text(
                  lyricLines[i],
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size,
                    fontWeight: FontWeight.w700,
                    height: 1.22,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        const Spacer(),
        // Credit: small artwork + who it's by. The song matters here, but it is
        // the attribution, not the headline.
        Row(
          children: [
            ClipRRect(
              // Same ~12%-of-side proportion as the big cover above, so the
              // attribution thumbnail belongs to the same family instead of
              // looking squarer than the headline artwork.
              borderRadius: BorderRadius.circular(12),
              child: _artwork(size: 46),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.displayArtist,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.78),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _footer(),
      ],
    );
  }

  /// The one attribution: mark, wordmark, kind.
  Widget _footer() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/icons/app_icon.webp',
            width: 20,
            height: 20,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 20,
              height: 20,
              color: themeColor,
              child: const Icon(Icons.graphic_eq_rounded,
                  color: Colors.black, size: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text('Auvy',
            style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3)),
        const SizedBox(width: 10),
        Container(width: 1, height: 11, color: Colors.white.withOpacity(0.18)),
        const SizedBox(width: 10),
        Text(
          kind.label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.66),
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
        // The link, printed on the card. The tappable link travels as share text (see
        // _handlePostcardShare); this printed line is the backup for targets that keep
        // only the image (Instagram Stories, gallery saves). Album and playlist cards print
        // their YouTube Music source; artist cards and local-only items print nothing (see
        // _universalLink).
        if (_universalLink(song, kind).isNotEmpty) ...[
          // Expanded, not Spacer, so the URL gets exactly the remaining space (right-aligned,
          // ellipsised) and can't overlap the kind label. The card is rasterised at 3x, so an
          // overlap would be baked into the saved image.
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              // Tappable in the preview, invisible in the PNG: a GestureDetector draws nothing,
              // so the exported image is unchanged.
              behavior: HitTestBehavior.opaque,
              onTap: () => _openShareLink(_universalLink(song, kind)),
              child: Text(
                _universalLink(song, kind).replaceFirst('https://', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Open the printed share link, or put it on the clipboard if nothing can.
///
/// The fallback is not decoration: this runs from a modal sheet on a device
/// that may have no browser willing to take the intent, and a tap that appears
/// to do nothing is worse than one that quietly hands over the url. Either way
/// the user ends up able to reach it.
Future<void> _openShareLink(String url) async {
  if (url.isEmpty) return;
  HapticService.light();
  try {
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (ok) return;
  } catch (e) {
    print('could not open the share link: $e');
  }
  try {
    await Clipboard.setData(ClipboardData(text: url));
    AnimatedToast.message('Link copied');
  } catch (_) {}
}

/// A universal link for [song], or '' when an honest one can't be built. A shared
/// picture with no link forces the recipient to retype the title, so each kind gets
/// the link that works for it:
///
///  • track / lyrics → **song.link** (Odesli), which resolves the same track on
///    Spotify, Apple Music, YouTube Music and others. Needs a YouTube video id.
///  • album → `music.youtube.com/browse/<browseId>` (Odesli can't take browse ids
///    like `OLAK5uy…` or `MPREb…`).
///  • playlist → `music.youtube.com/playlist?list=<id>`.
///  • artist and everything else → nothing.
String _universalLink(Song song, PostcardKind kind) {
  final id = song.id;

  switch (kind) {
    case PostcardKind.track:
    case PostcardKind.lyrics:
      // Video ids are exactly 11 chars of [A-Za-z0-9_-]. Radio streams (http…)
      // and browse ids all fail this, which is the intent.
      if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return '';
      // …but the length test ALONE is not enough. This app mints its own ids
      // in the same character class, and `local_12345` is exactly 11 legal
      // characters, so an imported file could slip through and produce a
      // song.link that resolves to nothing. Reject our own namespaces
      // explicitly.
      if (_isAppLocalId(id)) return '';
      return 'https://song.link/y/$id';

    case PostcardKind.album:
      // Callers pass the catalog id, which carries an `album_` prefix in this
      // app's own namespace — strip it before it reaches a real URL.
      final browseId = id.replaceFirst('album_', '');
      if (!_isCatalogBrowseId(browseId)) return '';
      return 'https://music.youtube.com/browse/$browseId';

    case PostcardKind.playlist:
      // `VL` is the browse-prefix form of a playlist id; the ?list= parameter
      // wants the bare id. Same strip the library import does.
      var listId = id;
      if (listId.startsWith('VL')) listId = listId.substring(2);
      if (!_isCatalogPlaylistId(listId)) return '';
      return 'https://music.youtube.com/playlist?list=$listId';

    default:
      return '';
  }
}

/// Ids this app mints itself, which never exist on the source.
///
/// Kept as one list so the track, album and playlist cases agree about what
/// "not a real catalog id" means.
bool _isAppLocalId(String id) =>
    id.startsWith('local_') ||
    id.startsWith('local:') ||
    id.startsWith('album_') ||
    id.startsWith('playlist_') ||
    id.startsWith('imported_');

/// Does this look like a real album browse id, rather than a local placeholder?
///
/// Locally-created and imported albums have ids like `local_…` or a bare title,
/// and there is nothing on the source to point at, so they must produce no
/// link at all rather than a 404.
bool _isCatalogBrowseId(String id) =>
    RegExp(r'^(OLAK5uy|MPREb)[A-Za-z0-9_-]+$').hasMatch(id);

/// Same test for playlists. A user's own playlist lives only on this device, so
/// `playlist_share` and friends correctly yield nothing.
bool _isCatalogPlaylistId(String id) =>
    RegExp(r'^(PL|RD|OLAK5uy)[A-Za-z0-9_-]{6,}$').hasMatch(id);

/// What a [Song] actually is, for labelling a card. Podcast episodes and live
/// stations are Songs internally (their ids are the enclosure / stream URL; see
/// `PodcastEpisode.toSong` / `RadioStation.toSong`), so deriving the kind here keeps
/// every share path correct. Podcasts also have `http` ids, so they're checked
/// before radio.
PostcardKind postcardKindForSong(Song song) {
  if (song.albumTitle == 'Podcast') return PostcardKind.podcast;
  if (song.id.startsWith('http')) return PostcardKind.radio;
  return PostcardKind.track;
}

Future<void> _handlePostcardShare(
    BuildContext context, GlobalKey key, Song song, PostcardKind kind) async {
  try {
    final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;

    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    // Native image memory, not GC'd by Dart. Every share leaked one 1020x1812
    // texture without this.
    image.dispose();
    final pngBytes = byteData!.buffer.asUint8List();

    final tempDir = await getTemporaryDirectory();
    // Clean up old share images first. Each PNG is 1.5–4 MB (1020×1812 at 3x) with a
    // unique timestamped name, so without cleanup every share ever made would stay in
    // the cache directory. Swept before sharing as well as deleted after.
    try {
      for (final f in tempDir.listSync()) {
        if (f is File && f.path.contains('auvy_share_')) {
          try { f.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}

    final file = File('${tempDir.path}/auvy_share_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(pngBytes);

    if (context.mounted) Navigator.pop(context);

    // Image plus a tappable link. An image can't carry a hyperlink, so the link travels
    // as share text, last and on its own line, which most targets treat as a caption.
    // (A QR code on the card was dropped: the recipient would need a second device to
    // scan it.)
    final link = _universalLink(song, kind);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'image/png')],
      // Title and artist too: targets that keep only the text (SMS, notes) would
      // otherwise reduce the share to a bare URL.
      text: link.isEmpty ? null : '${song.title} — ${song.displayArtist}\n$link',
      // Required on iPad, ignored elsewhere (see shareOriginOf); without it sharing
      // fails on iPad.
      sharePositionOrigin: shareOriginOf(context),
    );
  } catch (e) {
    AnimatedToast.message('Failed to share: $e');
  }
}

void showSharePostcardDialog(
  BuildContext context,
  Song song,
  Color themeColor, {
  PostcardKind kind = PostcardKind.track,
  List<String> lyricLines = const [],
  String lyricLanguage = 'original',
  @Deprecated('Use kind: PostcardKind.artist') bool isArtist = false,
}) {
  final GlobalKey repaintKey = GlobalKey();
  // Back-compat for call sites still passing the old flag.
  var resolved = isArtist ? PostcardKind.artist : kind;
  // Upgrade ONLY a plain `track`. Everything else — album, playlist, artist,
  // lyrics — was asked for explicitly and must stay what the caller said, but
  // `track` is the default, which is how episodes and stations ended up labelled
  // SONG. Resolving it here fixes every share entry point at once.
  if (resolved == PostcardKind.track) resolved = postcardKindForSong(song);

  showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.75),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SharePostcard(
            song: song,
            themeColor: themeColor,
            repaintKey: repaintKey,
            kind: resolved,
            lyricLines: lyricLines,
            lyricLanguage: lyricLanguage,
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // "Cancel" rather than a bare close icon. Same 52px pill, same weight and
              // size as the Share label beside it, so the two read as a matched
              // pair of choices instead of an icon and a button.
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    // Pill, not a circle — a circle cannot hold a word without
                    // either clipping it or ballooning.
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      // Matches the Share label exactly, except the colour: this
                      // is the secondary choice and should not compete with it.
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: () {
                  HapticService.medium();
                  _handlePostcardShare(ctx, repaintKey, song, kind);
                },
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 34),
                  decoration: BoxDecoration(
                    color: themeColor,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(
                          color: themeColor.withOpacity(0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 6)),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.ios_share_rounded, size: 19, color: Colors.black),
                      SizedBox(width: 9),
                      Text(
                        'Share',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: Colors.black,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
