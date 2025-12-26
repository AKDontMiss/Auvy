// Model representing a single line of lyrics with a timestamp.
class LyricsLine {
  final String words;      
  final Duration startTime; 

  LyricsLine({required this.words, required this.startTime});
}

// Model for the complete lyrics data of a track.
class LyricsData {
  final int id;
  final String trackName;
  final String artistName;
  final String plainLyrics;
  final List<LyricsLine> lines; 
  final bool isSynced;

  LyricsData({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.plainLyrics,
    required this.lines,
    required this.isSynced,
  });

  // Factory method to create a LyricsData instance from JSON data.
  factory LyricsData.fromJson(Map<String, dynamic> json) {
    List<LyricsLine> parsedLines = [];
    
    // Parses raw synced lyrics strings into individual line objects.
    if (json['syncedLyrics'] != null) {
      final String raw = json['syncedLyrics'];
      final regex = RegExp(r'^\[(\d{2}):(\d{2})\.(\d{2})\](.*)$');

      for (var line in raw.split('\n')) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final millis = int.parse(match.group(3)!);
          final content = match.group(4)!.trim();

          if (content.isNotEmpty) {
            parsedLines.add(LyricsLine(
              startTime: Duration(
                minutes: minutes,
                seconds: seconds,
                milliseconds: millis * 10, 
              ),
              words: content,
            ));
          }
        }
      }
    }

    return LyricsData(
      id: json['id'] ?? 0,
      trackName: json['trackName'] ?? '',
      artistName: json['artistName'] ?? '',
      plainLyrics: json['plainLyrics'] ?? '',
      lines: parsedLines,
      isSynced: parsedLines.isNotEmpty,
    );
  }
}