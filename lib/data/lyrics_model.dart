/// One song's lyrics as returned by a lyrics source.
///
/// Several sources are queried and scored, and each reply is normalised into
/// this shape. `trackName`, `artistName` and `duration` come from the source and
/// are compared with the playing track to check the match.
///
///   plainLyrics   the text with no timing
///   syncedLyrics  raw LRC as the source sent it
///   lines         syncedLyrics parsed into timed [LyricLine]s
///
/// Empty `lines` means no timing, so the player shows plain text. `instrumental`
/// means the track has no lyrics at all.
class LyricsData {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double duration;
  final bool instrumental;
  final String plainLyrics;
  final String syncedLyrics;
  final List<LyricLine> lines;

  LyricsData({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.duration,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.lines,
  });

  factory LyricsData.fromJson(Map<String, dynamic> json) {
    List<LyricLine> parsedLines = [];
    if (json['syncedLyrics'] != null) {
      parsedLines = _parseSyncedLyrics(json['syncedLyrics']);
    }

    return LyricsData(
      id: json['id'] ?? 0,
      trackName: json['trackName'] ?? '',
      artistName: json['artistName'] ?? '',
      albumName: json['albumName'] ?? '',
      duration: (json['duration'] ?? 0).toDouble(),
      instrumental: json['instrumental'] ?? false,
      plainLyrics: json['plainLyrics'] ?? '',
      syncedLyrics: json['syncedLyrics'] ?? '',
      lines: parsedLines,
    );
  }

  // Converts back to JSON for storage.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trackName': trackName,
      'artistName': artistName,
      'albumName': albumName,
      'duration': duration,
      'instrumental': instrumental,
      'plainLyrics': plainLyrics,
      'syncedLyrics': syncedLyrics,
      // `lines` is not stored; it is re-parsed from syncedLyrics.
    };
  }

  /// Milliseconds from an LRC fraction, whose digit count is not fixed:
  /// `.5` = 500ms, `.05` = 50ms, `.005` = 5ms.
  static int _fractionToMs(String? s) {
    if (s == null || s.isEmpty) return 0;
    final v = int.tryParse(s) ?? 0;
    switch (s.length) {
      case 1: return v * 100;
      case 2: return v * 10;
      case 3: return v;
      default: return 0;
    }
  }

  /// Inline word timestamps from enhanced LRC:
  ///
  ///     [00:12.34] <00:12.34>Never <00:12.71>gonna <00:13.02>give
  ///
  /// Only these enable word-by-word highlighting (see [LyricLine]).
  static final RegExp _wordTag = RegExp(r'<(\d+):(\d+)(?:\.(\d+))?>');

  static List<LyricLine> _parseSyncedLyrics(String syncedLyrics) {
    final lines = <LyricLine>[];
    // Accepts [m:s], [mm:ss.xx], [mm:ss.xxx] and similar.
    final regex = RegExp(r'\[(\d+):(\d+)(?:\.(\d+))?\](.*)');

    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final raw = match.group(4)!;
        final milliseconds = _fractionToMs(match.group(3));

        final start = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );

        // Word timings when the source supplies them. `text` always has the tags
        // removed, so plain rendering, sharing, translation and romanisation are
        // unaffected.
        final timed = _parseWords(raw);
        final text = raw.replaceAll(_wordTag, '').trim();

        if (text.isNotEmpty) {
          lines.add(LyricLine(
            startTime: start,
            words: text,
            timedWords: timed,
          ));
        }
      }
    }
    // Sort by time.
    lines.sort((a, b) => a.startTime.compareTo(b.startTime));
    return lines;
  }

  /// Splits one enhanced-LRC line into timed words, or returns null when it has no
  /// word tags. Null ("no word data") is handled differently from an empty list.
  static List<LyricWord>? _parseWords(String raw) {
    final matches = _wordTag.allMatches(raw).toList();
    if (matches.isEmpty) return null;

    final out = <LyricWord>[];
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      final start = Duration(
        minutes: int.parse(m.group(1)!),
        seconds: int.parse(m.group(2)!),
        milliseconds: _fractionToMs(m.group(3)),
      );
      // Text runs from the end of this tag to the start of the next.
      final from = m.end;
      final to = (i + 1 < matches.length) ? matches[i + 1].start : raw.length;
      final text = raw.substring(from, to);
      // Keep whitespace-only fragments: their spacing matters for layout.
      if (text.trim().isEmpty) continue;
      out.add(LyricWord(start: start, text: text));
    }
    return out.isEmpty ? null : out;
  }
}

/// One timed word of an enhanced-LRC line.
class LyricWord {
  final Duration start;

  /// Verbatim, including any trailing space, so words don't run together.
  final String text;

  const LyricWord({required this.start, required this.text});
}

/// A single timed line: when to highlight it, and the words to show.
class LyricLine {
  final Duration startTime;
  final String words;

  /// Per-word timings from enhanced LRC, else null.
  ///
  /// Only ever taken from tags the source sent, never estimated by splitting a
  /// line's duration, which would highlight words at the wrong moments. When null
  /// the whole line is highlighted instead.
  final List<LyricWord>? timedWords;

  LyricLine({required this.startTime, required this.words, this.timedWords});

  bool get hasWordTiming => timedWords != null && timedWords!.isNotEmpty;
}