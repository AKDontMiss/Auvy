import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/data/lyrics_model.dart';

/// Chapters (with ad/sponsor classification) and transcripts for podcast
/// episodes, sourced from Podcasting 2.0 feed extras and show-notes
/// timestamps.
///
/// Reliability note: this only works for BAKED-IN ads that the show itself
/// timestamps (chapter JSON or "(00:02:12) Sponsors: …" show notes, e.g.
/// Huberman Lab). Dynamically-inserted ads shift per download and can't be
/// marked from feed data.
class PodcastExtrasService {
  static final RegExp _adTitle = RegExp(
      r'\bsponsors?\b|\badvertis|\bads?\b|\bad break\b|\bpromo\b|\bcommercial\b',
      caseSensitive: false);

  bool _titleIsAd(String title) => _adTitle.hasMatch(title);

  // Chapters

  /// Chapters for [episode]: the `<podcast:chapters>` JSON when present,
  /// otherwise timestamps mined from the show notes. `[]` when neither exists.
  Future<List<PodcastChapter>> getChapters(PodcastEpisode episode) async {
    if (episode.chaptersUrl.isNotEmpty) {
      final fromJson = await _fetchChaptersJson(episode.chaptersUrl);
      if (fromJson.isNotEmpty) return fromJson;
    }
    return parseChaptersFromNotes(episode.description);
  }

  /// Podcast Index chapters format:
  /// `{"chapters":[{"startTime":123.0,"title":"...","endTime":...}, ...]}`.
  Future<List<PodcastChapter>> _fetchChaptersJson(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = (data is Map ? data['chapters'] : null) as List? ?? [];
      final chapters = <PodcastChapter>[];
      for (final c in raw) {
        if (c is! Map) continue;
        final startSec = (c['startTime'] as num?)?.toDouble();
        if (startSec == null) continue;
        final endSec = (c['endTime'] as num?)?.toDouble();
        final title = (c['title'] ?? '').toString().trim();
        chapters.add(PodcastChapter(
          start: Duration(milliseconds: (startSec * 1000).round()),
          end: endSec != null
              ? Duration(milliseconds: (endSec * 1000).round())
              : null,
          title: title.isEmpty ? 'Chapter ${chapters.length + 1}' : title,
          isAd: _titleIsAd(title),
        ));
      }
      chapters.sort((a, b) => a.start.compareTo(b.start));
      return _fillEnds(chapters);
    } catch (_) {
      return [];
    }
  }

  /// Mines "(00:02:12) Sponsors: AG1…" / "00:02:12 Sponsors" style timestamp
  /// lines out of show notes (HTML allowed — tags are stripped first).
  List<PodcastChapter> parseChaptersFromNotes(String notesHtml) {
    if (notesHtml.trim().isEmpty) return [];
    // <br>/<p>/<li> are the line separators in HTML notes — convert them to
    // newlines BEFORE stripping tags, or every timestamp lands on one line.
    var text = notesHtml
        .replaceAll(RegExp(r'<\s*(br|/p|/li|/div|/h\d)\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"');

    // (00:02:12) Title • 00:02:12 Title • [1:02:12] Title • 02:12 - Title
    final line = RegExp(
        r'^\s*[\(\[]?(\d{1,2}):(\d{2})(?::(\d{2}))?[\)\]]?\s*[-–—:•]?\s*(\S.*)$');
    final chapters = <PodcastChapter>[];
    for (final row in text.split('\n')) {
      final m = line.firstMatch(row.trim());
      if (m == null) continue;
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      final c = m.group(3) != null ? int.parse(m.group(3)!) : null;
      // h:mm:ss when three parts, else m:ss.
      final start = c != null
          ? Duration(hours: a, minutes: b, seconds: c)
          : Duration(minutes: a, seconds: b);
      final title = m.group(4)!.trim();
      if (title.isEmpty || title.length > 120) continue;
      chapters.add(PodcastChapter(
          start: start, title: title, isAd: _titleIsAd(title)));
    }
    // A real chapter list is monotonic; timestamp-looking noise isn't. Keep
    // the longest sorted run by simply requiring ascending starts.
    final filtered = <PodcastChapter>[];
    for (final ch in chapters) {
      if (filtered.isEmpty || ch.start >= filtered.last.start) filtered.add(ch);
    }
    if (filtered.length < 2) return [];
    return _fillEnds(filtered);
  }

  /// Every chapter without an explicit end runs until the next one starts.
  List<PodcastChapter> _fillEnds(List<PodcastChapter> chapters) {
    return [
      for (var i = 0; i < chapters.length; i++)
        PodcastChapter(
          start: chapters[i].start,
          end: chapters[i].end ??
              (i + 1 < chapters.length ? chapters[i + 1].start : null),
          title: chapters[i].title,
          isAd: chapters[i].isAd,
        )
    ];
  }

  // Transcripts

  /// Downloads and parses a `<podcast:transcript>` file into timed lines.
  /// Handles SRT, WebVTT and the Podcast Index JSON transcript format.
  Future<List<LyricLine>> fetchTranscript(String url) async {
    if (url.isEmpty) return [];
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final trimmed = body.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        return _parseJsonTranscript(trimmed);
      }
      return _parseSrtVtt(body);
    } catch (_) {
      return [];
    }
  }

  /// `{"segments":[{"startTime":1.2,"body":"..."} ...]}` (Podcast Index).
  List<LyricLine> _parseJsonTranscript(String body) {
    try {
      final data = jsonDecode(body);
      final segments =
          (data is Map ? data['segments'] : data) as List? ?? [];
      final lines = <LyricLine>[];
      for (final s in segments) {
        if (s is! Map) continue;
        final start = (s['startTime'] as num?)?.toDouble();
        final text = (s['body'] ?? '').toString().trim();
        if (start == null || text.isEmpty) continue;
        lines.add(LyricLine(
            startTime: Duration(milliseconds: (start * 1000).round()),
            words: text));
      }
      return _mergeShortLines(lines);
    } catch (_) {
      return [];
    }
  }

  /// SRT (`00:00:01,000 --> …`) and WebVTT (`00:00:01.000 --> …`) both reduce
  /// to "timestamp line, then text lines until a blank".
  List<LyricLine> _parseSrtVtt(String body) {
    final ts = RegExp(r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->');
    final lines = <LyricLine>[];
    Duration? current;
    final buf = StringBuffer();

    void flush() {
      final text = buf.toString().trim();
      if (current != null && text.isNotEmpty) {
        lines.add(LyricLine(startTime: current, words: text));
      }
      buf.clear();
    }

    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final row = raw.trim();
      final m = ts.firstMatch(row);
      if (m != null) {
        flush();
        final h = int.tryParse(m.group(1) ?? '') ?? 0;
        current = Duration(
          hours: h,
          minutes: int.parse(m.group(2)!),
          seconds: int.parse(m.group(3)!),
          milliseconds: int.parse(m.group(4)!.padRight(3, '0')),
        );
        continue;
      }
      if (row.isEmpty) {
        flush();
        current = null;
        continue;
      }
      // Skip cue indexes ("42"), VTT headers and metadata rows.
      if (current == null) continue;
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(row.replaceAll(RegExp(r'<[^>]*>'), ''));
    }
    flush();
    return _mergeShortLines(lines);
  }

  /// ASR transcripts often come word-by-word or in tiny fragments — unreadable
  /// as scrolling lines. Merge fragments into ~sentence-sized lines.
  List<LyricLine> _mergeShortLines(List<LyricLine> lines) {
    if (lines.length < 3) return lines;
    final merged = <LyricLine>[];
    Duration? start;
    final buf = StringBuffer();
    for (final l in lines) {
      start ??= l.startTime;
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(l.words);
      final text = buf.toString();
      final sentenceEnd = RegExp(r'[.!?…]"?$').hasMatch(text.trimRight());
      if (text.length >= 90 || (sentenceEnd && text.length >= 35)) {
        merged.add(LyricLine(startTime: start, words: text.trim()));
        buf.clear();
        start = null;
      }
    }
    if (buf.isNotEmpty && start != null) {
      merged.add(LyricLine(startTime: start, words: buf.toString().trim()));
    }
    return merged;
  }
}
