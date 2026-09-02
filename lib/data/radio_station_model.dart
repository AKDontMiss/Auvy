import 'package:auvy/data/dummy_data.dart'; // Adjust import to where your Song model lives

/// A live internet radio station from radio-browser.info.
///
/// `urlResolved` is the one to play. The directory also returns a plain `url`,
/// which is often a playlist file or a redirect; radio-browser resolves that
/// ahead of time and hands back the actual stream here.
///
/// A station becomes a [Song] with its stream URL as the id, which is what the
/// `id.startsWith('http')` checks throughout the app are detecting. Live audio
/// has no duration and cannot be cached or seeked, so those checks exist to
/// keep the music paths away from it.
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
    // PREFER url_resolved, BUT NOT WHEN IT DOWNGRADES A WORKING HTTPS URL.
    //
    // The directory reports both: `url` is what the station published, and
    // `url_resolved` is where the directory's own crawler ended up after
    // redirects. Following the resolved one is normally right — it skips a hop —
    // but the crawler often lands on the plain-http mirror of a station that also
    // serves https, and taking it means the stream is unencrypted for no reason.
    //
    // Measured on the top-80 most-voted stations: 53 are http. Cleartext is
    // permitted for stations now (see network_security_config.xml), so those play
    // either way — this only ensures we do not CHOOSE cleartext when the station
    // itself offered encryption.
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

  /// Converts this Radio Station into a native Auvy Song object so the 
  /// existing player can handle it flawlessly.
  Song toSong() {
    return Song(
      // CRITICAL: We pass the direct stream URL as the ID. 
      // We will tell the player to use this directly if it starts with 'http'
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