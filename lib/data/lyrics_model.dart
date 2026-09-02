/// One song's lyrics as a provider returned them.
///
/// Auvy asks several sources (lrclib, NetEase, KuGou, lyrics.ovh) and scores
/// the replies, so this is the SHAPE they are normalised into rather than any
/// one API's response. `trackName`, `artistName` and `duration` come from the
/// provider, not from Auvy, and are what the scorer compares against the track
/// actually playing to decide whether the match is real.
///
/// Three representations of the same words, and which one is present matters:
///
///   plainLyrics   the text, no timing. Always safe to show.
///   syncedLyrics  raw LRC, still as the provider sent it.
///   lines         syncedLyrics parsed into timed [LyricLine]s.
///
/// An empty `lines` means the source had no timing, so the player shows the
/// plain text instead of scrolling. `instrumental` is the provider saying the
/// track has no words at all, which is a real answer and not a failure.
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

  // ADDED: Method to convert object back to JSON for storage
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
      // We don't need to save 'lines' explicitly as they are parsed from syncedLyrics
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

  /// Inline word timestamps of ENHANCED LRC (the "A2" extension):
  ///
  ///     [00:12.34] <00:12.34>Never <00:12.71>gonna <00:13.02>give
  ///
  /// Word-level timing cannot be derived from a plain line-timed file, so this is
  /// the only thing that unlocks the karaoke-style highlight. See [LyricLine].
  static final RegExp _wordTag = RegExp(r'<(\d+):(\d+)(?:\.(\d+))?>');

  static List<LyricLine> _parseSyncedLyrics(String syncedLyrics) {
    final lines = <LyricLine>[];
    // IMPROVED: Flexible regex for [m:s.ms], [mm:ss.ss], [mm:ss.sss] etc.
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

        // Word timings, when the provider supplies them. `text` is always the
        // tags STRIPPED, so every existing consumer (plain rendering, share
        // cards, translation, romanisation) is unaffected by their presence.
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
    // Sort lines by time to ensure smooth UI transitions
    lines.sort((a, b) => a.startTime.compareTo(b.startTime));
    return lines;
  }

  /// Split one enhanced-LRC line into timed words, or return null when it carries
  /// no inline tags (an ordinary line-timed lyric).
  ///
  /// Returns null rather than an empty list on purpose: null means "this line has
  /// no word data", which the renderer must treat differently from "this line has
  /// zero words".
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
      // Whitespace-only fragments carry no word but their trailing space matters
      // for layout, so keep the text verbatim and let the renderer decide.
      if (text.trim().isEmpty) continue;
      out.add(LyricWord(start: start, text: text));
    }
    return out.isEmpty ? null : out;
  }
}

/// One timed word of an enhanced-LRC line.
class LyricWord {
  final Duration start;

  /// Verbatim, INCLUDING any trailing space — the renderer lays these out in
  /// sequence, and stripping the spacing here would run the words together.
  final String text;

  const LyricWord({required this.start, required this.text});
}

/// A single timed line: when to highlight it, and the words to show.
class LyricLine {
  final Duration startTime;
  final String words;

  /// Per-word timings when the source was ENHANCED LRC, else null.
  ///
  /// NOT SYNTHESISED. Word times are only ever populated from inline
  /// `<mm:ss.xx>` tags the provider actually sent. It is tempting to fake them by
  /// dividing a line's duration across its characters — several players do — but
  /// that invents timing data and then highlights words at moments the singer
  /// isn't on, which is worse than an honest line highlight: it looks precise
  /// while being wrong. When this is null the renderer falls back to per-LINE
  /// highlighting, which is what the data actually supports.
  final List<LyricWord>? timedWords;

  LyricLine({required this.startTime, required this.words, this.timedWords});

  bool get hasWordTiming => timedWords != null && timedWords!.isNotEmpty;
}