import 'package:auvy/data/dummy_data.dart';

/// A podcast SERIES, as returned by an iTunes search or lookup.
///
/// iTunes is used for discovery only. It gives Auvy the artwork, the genre and
/// the important part, `feedUrl` — the show's RSS address. Episodes are then
/// fetched from that feed directly, because iTunes does not serve them.
class PodcastShow {
  final String collectionName;
  final String artistName;
  final String artworkUrl;
  final String feedUrl;
  // iTunes primaryGenreName ('' when absent) — feeds the For-You taste
  // profile (similar-station discovery + topic-chip ordering).
  final String genre;
  /// iTunes collectionId, as a string. Used to restore CHART ORDER after a
  /// lookup call, which returns records in an arbitrary order.
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
    String baseImage = json['artworkUrl600'] ?? json['artworkUrl100'] ?? '';
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

  // VALUE equality on the feed URL: podcastEpisodesProvider is a family keyed
  // on PodcastShow, so identity equality minted (and leaked) a new 24h-alive
  // entry per reconstruction, and made ref.invalidate from another page a
  // no-op. Same feed → same show.
  @override
  bool operator ==(Object other) =>
      other is PodcastShow && other.feedUrl == feedUrl;
  @override
  int get hashCode => feedUrl.hashCode;
}

/// One episode, parsed out of a show's RSS feed.
///
/// `streamUrl` is the audio, served by the publisher rather than by YouTube, so
/// it plays without any of the stream-resolving machinery music needs.
///
/// `description` is the show notes, and it is mined rather than merely
/// displayed: chapter and sponsor timestamps are extracted from it, which is
/// how skippable ad segments get marked on the seek bar.
class PodcastEpisode {
  final String title;
  final String streamUrl;
  final String pubDate;
  final String podcastName;
  final String imageUrl;
  final String duration;
  // Show-notes body — chapter/sponsor timestamps get mined out of it.
  final String description;
  // Podcasting 2.0 extras (empty when the feed doesn't publish them).
  final String transcriptUrl; // <podcast:transcript url=...> (SRT/VTT/JSON)
  final String chaptersUrl;   // <podcast:chapters url=...> (JSON)

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
  });

  Song toSong() {
    return Song(
      id: streamUrl,
      title: title,
      artist: podcastName,
      albumTitle: 'Podcast',
      image: imageUrl,
      duration: duration,
      loudness: -14.0,
    );
  }
}

/// One titled segment of an episode. [isAd] marks sponsor/ad segments so the
/// player can shade them on the seek bar and offer a skip.
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