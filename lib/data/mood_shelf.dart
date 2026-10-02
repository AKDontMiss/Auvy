import 'package:auvy/data/dummy_data.dart';

/// One row of a mood or genre category.
///
/// Unlike [HomeSection], which only holds songs, a mood shelf is usually a row of
/// playlists, so it holds [MoodItem]s that keep their own type: a playlist
/// opens, a track plays.
class MoodShelf {
  final String title;
  final List<MoodItem> items;

  const MoodShelf({required this.title, required this.items});

  /// True when every item is a track, so the shelf can be played as a queue.
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

  /// Second line: the artist for a track, the curator for a collection.
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
