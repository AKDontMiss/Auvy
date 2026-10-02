import 'package:auvy/data/dummy_data.dart';

/// What a metadata refetch changed, so the confirmation can say so.
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

  /// Summary of the changes, most noticeable first; empty when nothing changed.
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

/// Whether [url] is a 16:9 video still rather than square album art. A refetch
/// must not replace a good square cover with a video frame.
bool isVideoThumbnail(String url) =>
    url.contains('ytimg.com') || url.contains('/vi/');

/// Applies a freshly resolved [candidate] onto the [original] track.
///
/// The id never changes: it is what is playing, and queues, playlists and
/// history are keyed by it. A refetch corrects what the track says about itself,
/// not which track it is. Other fields take the candidate's value when non-empty;
/// artwork is guarded below.
Song mergeRefetched(Song original, Song candidate) {
  var image = original.image;
  final fresh = candidate.image.trim();
  if (fresh.isNotEmpty && fresh != original.image) {
    // Accept the new cover unless it swaps square art for a video still. An empty
    // original accepts anything.
    final downgrade = original.image.isNotEmpty &&
        !isVideoThumbnail(original.image) &&
        isVideoThumbnail(fresh);
    if (!downgrade) image = fresh;
  }

  String pick(String fresh, String old) {
    final f = fresh.trim();
    return f.isEmpty ? old : f;
  }

  // 'Unknown Artist' is a parser placeholder and must not replace a real name.
  String pickArtist(String fresh, String old) {
    final f = fresh.trim();
    final low = f.toLowerCase();
    if (f.isEmpty || low == 'unknown artist' || low == 'unknown') return old;
    return f;
  }

  // '0:00' is the default, not a measured length.
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

/// The search query for a refetch: the cleaned title and artist rather than
/// YouTube's raw title, whose "(Official Video)" and similar noise would find the
/// same wrong result again.
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

/// Whether [candidate] is plausibly the same recording as [song]: titles must
/// overlap, and artists too when both are known, so a refetch never adopts an
/// unrelated top search result.
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
