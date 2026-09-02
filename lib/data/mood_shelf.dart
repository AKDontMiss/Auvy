import 'package:auvy/data/dummy_data.dart';

/// One row of a mood/genre category, preserving WHAT the row actually holds.
///
/// WHY THIS EXISTS INSTEAD OF [HomeSection]. `HomeSection` carries
/// `List<Song>` — songs and nothing else. Mood and genre shelves are almost
/// entirely PLAYLISTS ("Feel-good favourites", "Chill hits", "Sleep sounds"),
/// so squeezing them through a songs-only model forced the old parser to pick
/// the FIRST playlist in each shelf and replace the whole row with that one
/// playlist's tracks. The row kept its heading and lost its contents: a shelf
/// titled "Feel-good favourites" rendered 25 songs from one unrelated playlist,
/// and the other nine playlists were dropped on the floor. That is the
/// "content doesn't correspond to the section" bug.
///
/// A shelf therefore holds [MoodItem]s that keep their own identity, and the UI
/// decides how to present each kind — a playlist opens, a track plays.
class MoodShelf {
  final String title;
  final List<MoodItem> items;

  const MoodShelf({required this.title, required this.items});

  /// True when every item is a track, i.e. the shelf really is a track list and
  /// can be treated as a playable queue.
  bool get isTrackShelf => items.isNotEmpty && items.every((i) => i.isTrack);
}

/// A single tile in a [MoodShelf]: either a playable track or a collection
/// (playlist / album) to navigate into.
class MoodItem {
  /// Browse id for a collection, or the video id for a track.
  final String id;

  /// 'track' | 'playlist' | 'album'.
  final String type;

  final String title;

  /// Second line — the artist for a track, the curator/artist for a collection.
  final String subtitle;

  final String image;

  /// Present only when [isTrack]; this is what gets played.
  final Song? song;

  const MoodItem({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.image,
    this.song,
  });

  bool get isTrack => type == 'track';
  bool get isAlbum => type == 'album';

  factory MoodItem.fromSong(Song s) => MoodItem(
        id: s.id,
        type: 'track',
        title: s.title,
        subtitle: s.displayArtist,
        image: s.image,
        song: s,
      );
}
