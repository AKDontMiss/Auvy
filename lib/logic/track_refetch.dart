import 'package:auvy/data/dummy_data.dart';

/// What a refetch actually changed, so the toast can say something true instead
/// of a generic "done".
class RefetchDelta {
  final bool cover;
  final bool title;
  final bool artist;
  final bool album;
  final bool details; // release date / explicit flag / duration

  const RefetchDelta({
    this.cover = false,
    this.title = false,
    this.artist = false,
    this.album = false,
    this.details = false,
  });

  bool get any => cover || title || artist || album || details;

  /// Human summary, most-noticeable first. Empty when nothing changed.
  String get summary {
    final parts = <String>[
      if (cover) 'cover art',
      if (title) 'title',
      if (artist) 'artist',
      if (album) 'album',
      if (details) 'details',
    ];
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }
}

/// Is [url] a 16:9 VIDEO still rather than a square sleeve?
///
/// The whole reason artwork goes wrong in this app is that YouTube hands out
/// video thumbnails for tracks that have a real album cover, and a refetch that
/// replaced a good square cover with a letterboxed video frame would be a
/// downgrade the user asked for by pressing a button labelled "fix this".
bool isVideoThumbnail(String url) =>
    url.contains('ytimg.com') || url.contains('/vi/');

/// Merge a freshly-resolved [candidate] onto the [original] the user pressed
/// Refetch on.
///
/// THE ID NEVER CHANGES. A refetch on a music video CAN find its studio-audio
/// twin, and adopting that id would be "better" data, but the id is what is
/// PLAYING. Swapping it would restart the track from zero, and off the player
/// page it would silently change the identity a queue, a playlist and the
/// listening history are all keyed by. Refetch corrects what the track SAYS
/// about itself, not which track it is; the existing audio-only conform already
/// owns the id swap, at play time, where restarting is expected.
///
/// Everything else is taken from [candidate] whenever it is non-empty — that is
/// the point of the button. The one exception is artwork, guarded below.
Song mergeRefetched(Song original, Song candidate) {
  var image = original.image;
  final fresh = candidate.image.trim();
  if (fresh.isNotEmpty && fresh != original.image) {
    // Accept the new cover unless it would trade a square sleeve for a video
    // still. An empty original always accepts anything: something beats nothing.
    final downgrade = original.image.isNotEmpty &&
        !isVideoThumbnail(original.image) &&
        isVideoThumbnail(fresh);
    if (!downgrade) image = fresh;
  }

  String pick(String fresh, String old) {
    final f = fresh.trim();
    return f.isEmpty ? old : f;
  }

  // 'Unknown Artist' is a placeholder the parsers fall back to, not information —
  // letting it win would make a refetch actively erase a correct artist name.
  String pickArtist(String fresh, String old) {
    final f = fresh.trim();
    final low = f.toLowerCase();
    if (f.isEmpty || low == 'unknown artist' || low == 'unknown') return old;
    return f;
  }

  // '0:00' is the Song default, not a measured length.
  String pickDuration(String fresh, String old) {
    final f = fresh.trim();
    if (f.isEmpty || f == '0:00') return old;
    return f;
  }

  return original.copyWith(
    title: pick(candidate.title, original.title),
    artist: pickArtist(candidate.artist, original.artist),
    image: image,
    albumId: pick(candidate.albumId, original.albumId),
    albumTitle: pick(candidate.albumTitle, original.albumTitle),
    releaseDate: pick(candidate.releaseDate, original.releaseDate),
    duration: pickDuration(candidate.duration, original.duration),
    isExplicit: candidate.isExplicit ?? original.isExplicit,
    artists: candidate.artists.isNotEmpty ? candidate.artists : original.artists,
    viewCount: pick(candidate.viewCount, original.viewCount),
    musicVideoType:
        pick(candidate.musicVideoType, original.musicVideoType),
  );
}

/// What differs between the track before and after a refetch.
RefetchDelta describeRefetch(Song before, Song after) => RefetchDelta(
      cover: before.image != after.image,
      title: before.title != after.title,
      artist: before.artist != after.artist,
      album: before.albumTitle != after.albumTitle ||
          before.albumId != after.albumId,
      details: before.releaseDate != after.releaseDate ||
          before.isExplicit != after.isExplicit ||
          before.duration != after.duration,
    );

/// The catalog query a refetch should search with.
///
/// Deliberately NOT the raw YouTube title: those carry "(Official Video)",
/// "[4K Remaster]", "| Lyrics" and a channel suffix, and searching for that text
/// finds the same wrong row again, which is exactly what the user is pressing
/// Refetch to escape.
String refetchQuery(Song song) {
  var t = song.title
      .replaceAll(RegExp(r'\((?:[^()]*\b(?:official|video|audio|lyrics?|visualizer|hd|4k|remaster(?:ed)?|mv)\b[^()]*)\)',
          caseSensitive: false), '')
      .replaceAll(RegExp(r'\[(?:[^\[\]]*\b(?:official|video|audio|lyrics?|visualizer|hd|4k|remaster(?:ed)?|mv)\b[^\[\]]*)\]',
          caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[|·]\s*.*$'), '')
      .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) t = song.title.trim();

  final a = song.artist.trim();
  final clean = (a.toLowerCase() == 'unknown artist' || a.toLowerCase() == 'unknown')
      ? ''
      : a.split(RegExp(r'\s*(?:,|&|feat\.?|ft\.?)\s+', caseSensitive: false)).first.trim();
  return clean.isEmpty ? t : '$t $clean';
}

/// Is [candidate] plausibly the same recording as [song]?
///
/// A refetch that accepts the top search result unconditionally is how you end up
/// with a cover from a different album and a title for a different song — the
/// failure the user is already complaining about for lyrics. Requires the titles
/// to overlap; when both sides name an artist, requires that to overlap too.
bool isPlausibleRefetch(Song song, Song candidate) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(RegExp(r'\[.*?\]'), '')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final a = norm(song.title);
  final b = norm(candidate.title);
  if (a.isEmpty || b.isEmpty) return false;
  final titleOk = a == b || a.contains(b) || b.contains(a) || _wordOverlap(a, b) >= 0.6;
  if (!titleOk) return false;

  final sa = norm(song.artist);
  final ca = norm(candidate.artist);
  if (sa.isEmpty || ca.isEmpty) return true; // nothing to contradict
  return sa == ca ||
      sa.contains(ca) ||
      ca.contains(sa) ||
      _wordOverlap(sa, ca) >= 0.5;
}

double _wordOverlap(String a, String b) {
  final wa = a.split(' ').where((w) => w.length > 1).toSet();
  final wb = b.split(' ').where((w) => w.length > 1).toSet();
  if (wa.isEmpty || wb.isEmpty) return 0;
  return wa.intersection(wb).length / (wa.length > wb.length ? wa.length : wb.length);
}
