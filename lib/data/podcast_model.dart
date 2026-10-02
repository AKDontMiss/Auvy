import 'package:auvy/data/dummy_data.dart';

/// A podcast series from an iTunes search or lookup.
///
/// iTunes provides the artwork, genre and `feedUrl` (the show's RSS feed);
/// episodes are read from the feed itself.
class PodcastShow {
  final String collectionName;
  final String artistName;
  final String artworkUrl;
  final String feedUrl;
  // iTunes primaryGenreName ('' when absent), used for podcast recommendations.
  final String genre;
  /// iTunes collectionId, used to restore chart order after a lookup (which
  /// returns results in arbitrary order).
  final String trackId;

  PodcastShow({
    required this.collectionName,
    required this.artistName,
    required this.artworkUrl,
    required this.feedUrl,
    this.genre = '',
    this.trackId = '',
  });

  factory PodcastShow.fromJson(Map<String, dynamic> json) {
    String baseImage = json['artworkUrl600'] ?? json['artworkUrl100'] ?? json['artworkUrl'] ?? '';
    if (baseImage.isNotEmpty) {
      baseImage = baseImage.replaceAll(RegExp(r'\d+x\d+bb'), '1200x1200bb');
    }

    return PodcastShow(
      collectionName: json['collectionName'] ?? 'Unknown Podcast',
      artistName: json['artistName'] ?? 'Unknown Artist',
      artworkUrl: baseImage, //  FIX: Now strictly high-res!
      feedUrl: json['feedUrl'] ?? '',
      trackId: (json['collectionId'] ?? json['trackId'] ?? '').toString(),
      genre: (json['primaryGenreName'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'collectionName': collectionName,
    'artistName': artistName,
    'artworkUrl600': artworkUrl,
    'feedUrl': feedUrl,
    'primaryGenreName': genre,
    'collectionId': trackId,
  };

  // Equal by feed URL: podcastEpisodesProvider is keyed by PodcastShow, so the
  // same feed must map to the same entry.
  @override
  bool operator ==(Object other) =>
      other is PodcastShow && other.feedUrl == feedUrl;
  @override
  int get hashCode => feedUrl.hashCode;
}

/// A show as a chart lists it: enough to show a tile. The feed comes from a
/// lookup when the show is opened (see PodcastService.lookupShow), so browsing
/// a chart costs one request.
class ChartShow {
  final String id;
  final String name;
  final String artist;
  final String image;
  const ChartShow({required this.id, required this.name, required this.artist, required this.image});
}

/// One episode, parsed from a show's RSS feed.
///
/// `streamUrl` is the publisher's audio file, played directly. `description` is
/// the show notes, which are also scanned for chapter and sponsor timestamps.
class PodcastEpisode {
  final String title;
  final String streamUrl;
  final String pubDate;
  final String podcastName;
  final String imageUrl;
  final String duration;
  // Show notes; chapter and sponsor timestamps are read from it.
  final String description;
  // Podcasting 2.0 extras (empty when the feed does not publish them).
  final String transcriptUrl; // <podcast:transcript url=...> (SRT/VTT/JSON)
  final String chaptersUrl;   // <podcast:chapters url=...> (JSON)

  /// The show's feed, carried into the Song (as its albumId) so the player can
  /// find the episode's show without searching for it by name.
  final String feedUrl;

  PodcastEpisode({
    required this.title,
    required this.streamUrl,
    required this.pubDate,
    required this.podcastName,
    required this.imageUrl,
    required this.duration,
    this.description = '',
    this.transcriptUrl = '',
    this.chaptersUrl = '',
    this.feedUrl = '',
  });

  Song toSong() {
    return Song(
      id: streamUrl,
      title: title,
      artist: podcastName,
      albumTitle: 'Podcast',
      albumId: feedUrl,
      releaseDate: pubDate,
      image: imageUrl,
      duration: duration,
      loudness: -14.0,
    );
  }
}

/// One titled segment of an episode. [isAd] marks sponsor segments so the player
/// can shade them on the seek bar and offer a skip.
class PodcastChapter {
  final Duration start;
  final Duration? end; // null = runs until the next chapter (or episode end)
  final String title;
  final bool isAd;

  const PodcastChapter({
    required this.start,
    this.end,
    required this.title,
    required this.isAd,
  });
}