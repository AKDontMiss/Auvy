/// Is this row the track that is playing?
///
/// An id comparison alone cannot answer that, and assuming it could is why the
/// playing indicator kept disappearing. THE SAME SONG HAS DIFFERENT IDS IN
/// DIFFERENT PLACES: a playlist row is whatever entry the playlist stored, the
/// album tracklist is the album edition, search returns yet another, and the
/// audio-only swap replaces the id again the moment playback starts. So play a
/// song from a playlist, open its album from the player page, and the row for
/// the very track being heard carried an id the player had never seen — no
/// highlight, no equalizer.
///
/// The queue already resolves this the same way (see `player_playback._sig`:
/// the now-playing track must not reappear in the queue as a "different-id
/// TWIN"), so treating title + primary artist as one identity is how the app
/// ALREADY thinks about tracks. This file is that rule, in one place, pure and
/// covered by test/track_identity_test.dart.
library;

/// Parenthetical noise that describes the UPLOAD, not the song: "(Official
/// Video)", "[Lyrics]", "(Audio)", "(4K Remaster)". Two rows for one song
/// routinely differ by nothing else.
///
/// ONLY noise is stripped, never every bracket. Dropping all parentheticals
/// would make "Song (Remix)" identical to "Song", and then playing the original
/// would light up the remix. A wrong highlight is a small thing, but it is
/// avoidable, so it is avoided.
final RegExp _noiseBracket = RegExp(
    r'[\(\[][^\)\]]*\b(?:official|officiel|video|audio|lyrics?|lyric|'
    r'visuali[sz]er|hd|hq|4k|mv|explicit|clean|remaster|remastered|'
    r'colou?r coded|full (?:song|album)|topic)\b[^\)\]]*[\)\]]',
    caseSensitive: false);

/// "feat. X", "(ft. Y)" — the same song is credited both ways depending on
/// where the row came from, so the clause is not part of its identity.
final RegExp _featClause = RegExp(
    r'[\(\[]?\s*\b(?:feat|ft|featuring)\b\.?\s[^\)\]]*[\)\]]?',
    caseSensitive: false);

/// Apostrophes vanish rather than becoming a space, so "Don't Stop" and "Dont
/// Stop" are one title instead of "don t stop" and "dont stop".
final RegExp _apostrophe = RegExp(r"['‘’ʼ`´]");
final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');

/// Where a credit list stops being the PRIMARY artist.
///
/// Only the first artist is compared: an album may credit "Metro Boomin, 21
/// Savage" for a track a playlist filed under "Metro Boomin", and they are the
/// same recording.
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

String _normArtist(String raw) {
  final first = raw.toLowerCase().split(_artistSplit).first;
  final a = first.replaceAll(_apostrophe, '').replaceAll(_nonAlnum, ' ').trim();
  // "Unknown Artist" is Song.displayArtist's placeholder, not a credit — see
  // Song.displayArtist. Treated as absent so it never counts as a mismatch.
  return a == 'unknown artist' || a == 'unknown' ? '' : a;
}

/// Bounded normalisation memos.
///
/// This runs inside a Riverpod `select` for every visible row, and the player
/// writes state on every position tick, so without a memo a scrolling list
/// would re-run four regexes per row per tick. Bounded on purpose: a cache that
/// grows with everything the user has ever scrolled past is a leak, and this is
/// a text comparison, not something worth leaking memory over.
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

/// Do these two rows name the same recording?
///
/// Ids win when they agree; otherwise the normalised title must match exactly
/// and the primary artists must not CONTRADICT each other. An absent artist is
/// not a contradiction: album tracklists sometimes carry no per-track credit,
/// and refusing to match there is exactly what leaves the row the user is
/// listening to unmarked.
///
/// An empty title never matches — a row with nothing to compare can only ever
/// be identified by its id.
/// [requireArtist] disables the title-only fallback.
///
/// Pass it wherever a match lights up something that is NOT a track row.
///
/// Observed on the home mosaic: recently-played entries store a radio station or
/// a playlist as a `Song` (a station's id is its stream URL), so a COLLECTION
/// named after a song — "I Think We're Alone Now" — has a matching title and no
/// real artist credit. The lenient rule then lit that tile up whenever a song of
/// that name played, and two tiles claimed to be the current track at once.
///
/// The leniency is right for a track row inside a list, where the alternative is
/// an album tracklist with no per-track credit showing no indicator at all. It is
/// wrong for a tile that represents a whole collection, where one false positive
/// is more misleading than a missing highlight.
bool isSameTrack({
  required String? playingId,
  required String playingTitle,
  required String playingArtist,
  required String rowId,
  String? rowAltId,
  required String rowTitle,
  required String rowArtist,
  bool requireArtist = false,
}) {
  if (playingId != null && playingId.isNotEmpty) {
    if (playingId == rowId) return true;
    if (rowAltId != null && rowAltId.isNotEmpty && playingId == rowAltId) {
      return true;
    }
  }

  // A URL-keyed row is a STREAM, not a recording: radio stations and podcast
  // episodes carry their address as an id (see RadioStation.toSong and
  // PodcastEpisode.toSong). Two stations can carry the same title as a song, and
  // an episode title is not a track title, so identity for these is the address
  // alone, which the id comparison above already settled.
  if (rowId.startsWith('http')) return false;

  final rowT = normalizedTrackTitle(rowTitle);
  if (rowT.isEmpty) return false;
  if (rowT != normalizedTrackTitle(playingTitle)) return false;

  final rowA = normalizedPrimaryArtist(rowArtist);
  final playA = normalizedPrimaryArtist(playingArtist);
  if (rowA.isEmpty || playA.isEmpty) return !requireArtist;
  return rowA == playA;
}
