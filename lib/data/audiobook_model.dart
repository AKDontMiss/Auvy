import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';

/// One chapter of an audiobook — the unit that actually plays.
///
/// THE ID IS THE URL, like a podcast episode. Audiobook chapters have no
/// YouTube video id, so the stream address IS the identity. `isSameTrack` already
/// treats an `http`-prefixed id as address identity rather than trying to match
/// on title, which is what keeps two chapters called "Chapter 1" from different
/// books out of each other's now-playing highlight.
class AudiobookChapter {
  final String title;
  final String streamUrl;
  final Duration duration;
  final int index;

  const AudiobookChapter({
    required this.title,
    required this.streamUrl,
    required this.duration,
    required this.index,
  });

  Song toSong({required String bookTitle, required String author, String image = ''}) {
    return Song(
      id: streamUrl,
      title: title,
      artist: author,
      albumTitle: bookTitle,
      // See kAudiobookMarker: an invisible, persisted marker so the player page
      // treats a chapter as spoken word rather than a live stream.
      albumId: kAudiobookMarker,
      image: image,
      audioUrl: streamUrl,
      duration: _fmt(duration),
      // Spoken word, like a podcast: the same normalisation target so a book and
      // an episode do not jump in level between one another.
      loudness: -14.0,
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// A free, public-domain audiobook.
///
/// Sourced from LibriVox (volunteer-narrated public-domain works) with the audio
/// itself hosted on the Internet Archive. Both are genuinely free and legal to
/// stream — the recordings are released into the public domain, which is why this
/// section can exist at all without a licensing arrangement.
class Audiobook {
  final String id;
  final String title;
  final String author;
  final String description;
  final String coverUrl;
  final Duration totalTime;
  final String language;

  /// The Internet Archive item that holds the audio files. Empty when LibriVox
  /// did not report one — such a book cannot be played and is filtered out
  /// rather than shown as a dead row.
  final String archiveId;

  /// Filled by [AudiobookService.chaptersFor]; empty until then, because the
  /// listing endpoints do not carry a file list and fetching one per book would
  /// be dozens of requests for a screen the user has not scrolled yet.
  final List<AudiobookChapter> chapters;

  const Audiobook({
    required this.id,
    required this.title,
    required this.author,
    this.description = '',
    this.coverUrl = '',
    this.totalTime = Duration.zero,
    this.language = 'English',
    this.archiveId = '',
    this.chapters = const [],
  });

  Audiobook copyWith({List<AudiobookChapter>? chapters, String? coverUrl}) {
    return Audiobook(
      id: id,
      title: title,
      author: author,
      description: description,
      coverUrl: coverUrl ?? this.coverUrl,
      totalTime: totalTime,
      language: language,
      archiveId: archiveId,
      chapters: chapters ?? this.chapters,
    );
  }

  // The LibriVox API parser was removed with the LibriVox catalogue path: its
  // prefix-only search and catalogue-date ordering are what made browse and
  // search unusable (see AudiobookService). Everything now comes from the
  // Internet Archive, which hosts the same recordings. Git has the parser if a
  // second source is ever wanted.


  /// The Internet Archive `advancedsearch` shape — the catalogue. Was a fallback
  /// behind LibriVox until measurement showed the Archive is the better source.
  static Audiobook? fromArchive(Map<String, dynamic> m) {
    final id = (m['identifier'] ?? '').toString().trim();
    final title = (m['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;
    final creator = m['creator'];
    return Audiobook(
      id: id,
      title: title,
      author: creator is List
          ? (creator.isEmpty ? 'Unknown author' : creator.first.toString())
          : (creator?.toString().trim().isNotEmpty == true
              ? creator.toString()
              : 'Unknown author'),
      description: _stripHtml((m['description'] ?? '').toString()),
      totalTime: Duration(seconds: (m['runtime'] is num) ? (m['runtime'] as num).toInt() : 0),
      language: (m['language'] is List)
          ? ((m['language'] as List).isEmpty ? 'English' : (m['language'] as List).first.toString())
          : (m['language'] ?? 'English').toString(),
      archiveId: id,
      coverUrl: 'https://archive.org/services/img/$id',
    );
  }

  /// Descriptions arrive as HTML, and rendering the tags raw looked like a bug.
  static String _stripHtml(String s) {
    if (s.isEmpty) return '';
    return s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}
