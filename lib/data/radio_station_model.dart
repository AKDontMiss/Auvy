import 'package:auvy/data/dummy_data.dart'; // Adjust import to where your Song model lives

/// A live internet radio station from radio-browser.info.
///
/// `urlResolved` is the stream to play (the directory has already followed any
/// playlist file or redirect). A station becomes a [Song] whose id is the stream
/// URL; live audio has no duration and cannot be cached or seeked.
class RadioStation {
  final String id;
  final String name;
  final String urlResolved;
  final String favicon;
  final String country;
  final String tags;
  final int votes;

  RadioStation({
    required this.id,
    required this.name,
    required this.urlResolved,
    required this.favicon,
    required this.country,
    required this.tags,
    required this.votes,
  });

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    // Prefer `url_resolved`, unless it swaps a working https URL for plain http:
    // the directory's crawler often ends on the http mirror of a station that also
    // serves https.
    final resolved = (json['url_resolved'] ?? '').toString().trim();
    final published = (json['url'] ?? '').toString().trim();
    final preferHttps = resolved.startsWith('http://') &&
        published.startsWith('https://');

    return RadioStation(
      id: json['stationuuid'] ?? '',
      name: json['name']?.toString().trim() ?? 'Unknown Station',
      urlResolved: preferHttps
          ? published
          : (resolved.isNotEmpty ? resolved : published),
      favicon: json['favicon'] ?? '',
      country: json['country'] ?? 'Unknown',
      tags: json['tags'] ?? '',
      votes: json['votes'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'stationuuid': id,
    'name': name,
    'url_resolved': urlResolved,
    'favicon': favicon,
    'country': country,
    'tags': tags,
    'votes': votes,
  };

  /// Converts the station to a Song the player can handle.
  Song toSong() {
    return Song(
      // The stream URL is the id; the player plays http ids directly.
      id: urlResolved, 
      title: name,
      artist: 'Live Radio • $country',
      albumTitle: tags.isNotEmpty ? tags.split(',').first.toUpperCase() : 'RADIO',
      image: favicon,
      duration: '0:00',
      loudness: -14.0, // Default normalization
    );
  }
}