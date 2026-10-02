/// Decides whether a row shows the track that is playing.
///
/// The same song often has different ids in different places (playlist entry,
/// album edition, search result, the audio version swapped in at play time), so
/// ids alone would leave the playing row unmarked. Title plus primary artist is
/// treated as the identity, as the queue already does. Tested in
/// test/track_identity_test.dart.
library;

/// Bracketed text describing the upload rather than the song, such as
/// "(Official Video)", "[Lyrics]" or "(4K Remaster)". Only these are removed, so
/// "Song (Remix)" stays different from "Song".
final RegExp _noiseBracket = RegExp(
    r'[\(\[][^\)\]]*\b(?:official|officiel|video|audio|lyrics?|lyric|'
    r'visuali[sz]er|hd|hq|4k|mv|explicit|clean|remaster|remastered|'
    r'colou?r coded|full (?:song|album)|topic)\b[^\)\]]*[\)\]]',
    caseSensitive: false);

/// "feat. X" / "(ft. Y)": credited either way depending on the source, so not
/// part of the identity.
final RegExp _featClause = RegExp(
    r'[\(\[]?\s*\b(?:feat|ft|featuring)\b\.?\s[^\)\]]*[\)\]]?',
    caseSensitive: false);

/// Apostrophes are removed rather than replaced by a space, so "Don't" and
/// "Dont" match.
final RegExp _apostrophe = RegExp(r"['‘’ʼ`´]");
final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');

/// Where a credit list moves past the primary artist. Only the first artist is
/// compared ("Metro Boomin, 21 Savage" vs "Metro Boomin" is the same recording).
final RegExp _artistSplit = RegExp(
    r'\s*(?:,|&|;|/|\bx\b|\bvs\.?\b|\bfeat\b\.?|\bft\b\.?|·)\s*',
    caseSensitive: false);

String _normTitle(String raw) => raw
    .toLowerCase()
    .replaceAll(_noiseBracket, ' ')
    .replaceAll(_featClause, ' ')
    .replaceAll(_apostrophe, '')
    .replaceAll(_nonAlnum, ' ')
    .trim();

/// The first credited artist in its original spelling, for looking the artist up
/// in a metadata service (normalising would break names like "where.t.at").
/// Shares [_artistSplit] with [normalizedPrimaryArtist].
String primaryArtistOf(String credit) =>
    credit.split(_artistSplit).first.trim();

String _normArtist(String raw) {
  final first = primaryArtistOf(raw).toLowerCase();
  final a = first.replaceAll(_apostrophe, '').replaceAll(_nonAlnum, ' ').trim();
  // "Unknown Artist" is a display placeholder, not a credit, so treat it as
  // absent.
  return a == 'unknown artist' || a == 'unknown' ? '' : a;
}

/// How far two runtimes may differ and still be the same recording. Different
/// catalogues report the same master a second or two apart. Also used by the
/// lyrics scorer.
const int kDifferentRecordingMs = 8000;

/// `"3:47"` / `"1:02:11"` → milliseconds, or 0 when not a duration. Shared by
/// [isSameTrack] and the lyrics scorer. Returns 0 rather than guessing.
int durationMsFromDisplayString(String? display) {
  if (display == null || display.isEmpty) return 0;
  final parts = display.split(':');
  if (parts.length < 2 || parts.length > 3) return 0;
  var total = 0;
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0 || n > 59 && p != parts.first) return 0;
    total = total * 60 + n;
  }
  return total * 1000;
}

/// Bounded memo of normalised strings. This runs for every visible row on every
/// player update, so caching avoids repeating the regexes.
final Map<String, String> _titleMemo = {};
final Map<String, String> _artistMemo = {};

String normalizedTrackTitle(String title) {
  final hit = _titleMemo[title];
  if (hit != null) return hit;
  if (_titleMemo.length > 800) _titleMemo.clear();
  return _titleMemo[title] = _normTitle(title);
}

String normalizedPrimaryArtist(String artist) {
  final hit = _artistMemo[artist];
  if (hit != null) return hit;
  if (_artistMemo.length > 800) _artistMemo.clear();
  return _artistMemo[artist] = _normArtist(artist);
}

/// Whether two rows name the same recording.
///
/// Matching ids win. Otherwise the normalised titles must match and the primary
/// artists must not contradict each other; a missing artist is not a
/// contradiction (album tracklists often lack per-track credits). An empty title
/// never matches.
///
/// [requireArtist] turns off the title-only fallback. Use it where a match
/// highlights something that is not a track row, such as a home tile for a
/// playlist or station that happens to share a song's title.
///
/// [playingDurationMs] / [rowDurationMs]: when both lengths are known and differ
/// by more than [kDifferentRecordingMs], the title fallback is rejected. This
/// separates, for example, a solo track and a collaboration with the same title.
/// It never overrides matching ids, and an unknown length decides nothing.
bool isSameTrack({
  required String? playingId,
  required String playingTitle,
  required String playingArtist,
  required String rowId,
  String? rowAltId,
  required String rowTitle,
  required String rowArtist,
  bool requireArtist = false,
  int playingDurationMs = 0,
  int rowDurationMs = 0,
}) {
  if (playingId != null && playingId.isNotEmpty) {
    if (playingId == rowId) return true;
    if (rowAltId != null && rowAltId.isNotEmpty && playingId == rowAltId) {
      return true;
    }
  }

  // A URL id is a stream (radio station, podcast episode), identified by its
  // address alone, which the id comparison already settled.
  if (rowId.startsWith('http')) return false;

  final rowT = normalizedTrackTitle(rowTitle);
  if (rowT.isEmpty) return false;
  if (rowT != normalizedTrackTitle(playingTitle)) return false;

  // Checked after the titles agree and before the artists: only the fallback path
  // reaches here, and runtime is the one input that can contradict it.
  if (playingDurationMs > 0 &&
      rowDurationMs > 0 &&
      (playingDurationMs - rowDurationMs).abs() > kDifferentRecordingMs) {
    return false;
  }

  final rowA = normalizedPrimaryArtist(rowArtist);
  final playA = normalizedPrimaryArtist(playingArtist);
  if (rowA.isEmpty || playA.isEmpty) return !requireArtist;
  return rowA == playA;
}
