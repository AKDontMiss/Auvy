import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';

/// One chapter of an audiobook: the unit that plays.
///
/// Its id is its audio URL (chapters have no YouTube id), which `isSameTrack`
/// treats as identity, so two chapters called "Chapter 1" from different books
/// are never confused.
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

  /// [bookId] travels in the Song's albumId (see audiobookAlbumId), so the
  /// player, Home and "Continue listening" can find the book again.
  Song toSong({
    required String bookTitle,
    required String author,
    String image = '',
    String bookId = '',
  }) {
    return Song(
      id: streamUrl,
      title: title,
      artist: author,
      albumTitle: bookTitle,
      // Marks the chapter as spoken word (see kAudiobookMarker), so the player treats
      // it like a podcast rather than a live stream.
      albumId: audiobookAlbumId(bookId),
      image: image,
      audioUrl: streamUrl,
      duration: _fmt(duration),
      // Same loudness target as podcasts, so levels match between the two.
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

/// A free, public-domain audiobook: narrated by LibriVox volunteers, with the
/// audio hosted by the Internet Archive.
class Audiobook {
  final String id;
  final String title;
  final String author;
  final String description;
  final String coverUrl;
  final Duration totalTime;

  /// Display name ("English"), not the catalogue's code ("eng").
  final String language;

  /// The Internet Archive item holding the audio files. Books without one cannot
  /// play and are filtered out.
  final String archiveId;

  /// Listener rating out of 5 on the Archive, 0 when unrated.
  final double rating;
  final int reviews;

  /// Filled when a book is opened (see AudiobookService.byId and chaptersFor);
  /// listings do not include file lists.
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
    this.rating = 0,
    this.reviews = 0,
    this.chapters = const [],
  });

  Audiobook copyWith({
    List<AudiobookChapter>? chapters,
    String? coverUrl,
    String? description,
    Duration? totalTime,
  }) {
    return Audiobook(
      id: id,
      title: title,
      author: author,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      totalTime: totalTime ?? this.totalTime,
      language: language,
      archiveId: archiveId,
      rating: rating,
      reviews: reviews,
      chapters: chapters ?? this.chapters,
    );
  }

  /// Saved with the listener's books (no chapters: they are fetched on opening).
  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'cover': coverUrl,
        'secs': totalTime.inSeconds,
        'lang': language,
        if (rating > 0) 'rating': rating,
      };

  static Audiobook? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || id.isEmpty || title is! String) return null;
    return Audiobook(
      id: id,
      title: title,
      author: (raw['author'] as String?) ?? '',
      coverUrl: (raw['cover'] as String?) ?? '',
      totalTime: Duration(seconds: (raw['secs'] as num?)?.toInt() ?? 0),
      language: (raw['lang'] as String?) ?? 'English',
      archiveId: id,
      rating: (raw['rating'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Parses one result of the Internet Archive `advancedsearch` API.
  static Audiobook? fromArchive(Map<String, dynamic> m) {
    final id = (m['identifier'] ?? '').toString().trim();
    final rawTitle = (m['title'] ?? '').toString().trim();
    if (id.isEmpty || rawTitle.isEmpty) return null;
    final author = _first(m['creator'], 'Unknown author');
    return Audiobook(
      id: id,
      title: cleanTitle(rawTitle, author),
      author: author,
      description: stripHtml((m['description'] ?? '').toString()),
      totalTime: parseLength(m['runtime']),
      language: languageName(_first(m['language'], 'eng')),
      archiveId: id,
      coverUrl: 'https://archive.org/services/img/$id',
      rating: (m['avg_rating'] is num) ? (m['avg_rating'] as num).toDouble() : 0,
      reviews: (m['num_reviews'] is num) ? (m['num_reviews'] as num).toInt() : 0,
    );
  }

  /// Parses an item's `metadata` block (`archive.org/metadata/{id}`), for a book
  /// opened by id with no listing to come from.
  static Audiobook? fromMetadata(String id, Map<String, dynamic> md) {
    final rawTitle = _first(md['title'], '');
    if (id.isEmpty || rawTitle.isEmpty) return null;
    final author = _first(md['creator'], 'Unknown author');
    return Audiobook(
      id: id,
      title: cleanTitle(rawTitle, author),
      author: author,
      description: stripHtml(_first(md['description'], '')),
      totalTime: parseLength(md['runtime']),
      language: languageName(_first(md['language'], 'eng')),
      archiveId: id,
      coverUrl: 'https://archive.org/services/img/$id',
    );
  }

  static String _first(Object? v, String fallback) {
    if (v is List) return v.isEmpty ? fallback : v.first.toString().trim();
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? fallback : s;
  }

  /// "Alice's Adventures in Wonderland, by Lewis Carroll" → the title alone.
  static String cleanTitle(String title, String author) {
    final t = title.trim();
    final byAuthor = RegExp(r',?\s+by\s+' + RegExp.escape(author) + r'\s*$', caseSensitive: false);
    final cleaned = t.replaceFirst(byAuthor, '').trim();
    return cleaned.isEmpty ? t : cleaned;
  }

  /// A length given as seconds ("4334", 4334.5) or as a clock ("1:12:14",
  /// "26:22"), which is how the Archive reports LibriVox runtimes.
  static Duration parseLength(Object? raw) {
    if (raw is num) return Duration(seconds: raw.round());
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return Duration.zero;
    final plain = double.tryParse(s);
    if (plain != null) return Duration(seconds: plain.round());
    final parts = s.split(':');
    if (parts.length < 2 || parts.length > 3) return Duration.zero;
    var secs = 0.0;
    for (final p in parts) {
      final v = double.tryParse(p.trim());
      if (v == null) return Duration.zero;
      secs = secs * 60 + v;
    }
    return Duration(seconds: secs.round());
  }

  /// The catalogue's language codes (ISO 639-2, as LibriVox items carry them)
  /// to names. An unknown code is shown as given.
  static String languageName(String code) {
    final c = code.trim().toLowerCase();
    return _languages[c] ?? (c.length > 3 ? code.trim() : code.trim().toUpperCase());
  }

  /// The languages offered in the filter, by the code the catalogue uses.
  static const Map<String, String> _languages = {
    'eng': 'English', 'english': 'English',
    'ger': 'German', 'deu': 'German', 'german': 'German',
    'fre': 'French', 'fra': 'French', 'french': 'French',
    'spa': 'Spanish', 'spanish': 'Spanish',
    'ita': 'Italian', 'italian': 'Italian',
    'dut': 'Dutch', 'nld': 'Dutch', 'dutch': 'Dutch',
    'por': 'Portuguese', 'portuguese': 'Portuguese',
    'rus': 'Russian', 'russian': 'Russian',
    'chi': 'Chinese', 'zho': 'Chinese', 'chinese': 'Chinese',
    'jpn': 'Japanese', 'japanese': 'Japanese',
    'lat': 'Latin', 'latin': 'Latin',
    'gre': 'Greek', 'ell': 'Greek', 'grc': 'Ancient Greek', 'greek': 'Greek',
    'pol': 'Polish', 'polish': 'Polish',
    'fin': 'Finnish', 'finnish': 'Finnish',
    'swe': 'Swedish', 'swedish': 'Swedish',
    'dan': 'Danish', 'danish': 'Danish',
    'nor': 'Norwegian', 'norwegian': 'Norwegian',
    'heb': 'Hebrew', 'hebrew': 'Hebrew',
    'ara': 'Arabic', 'arabic': 'Arabic',
    'tur': 'Turkish', 'turkish': 'Turkish',
    'cze': 'Czech', 'ces': 'Czech', 'czech': 'Czech',
    'hun': 'Hungarian', 'hungarian': 'Hungarian',
    'bul': 'Bulgarian', 'bulgarian': 'Bulgarian',
    'ukr': 'Ukrainian', 'ukrainian': 'Ukrainian',
    'tag': 'Tagalog', 'tgl': 'Tagalog', 'tagalog': 'Tagalog',
    'epo': 'Esperanto', 'esperanto': 'Esperanto',
  };

  /// Descriptions arrive as HTML; strip the tags for display.
  static String stripHtml(String s) {
    if (s.isEmpty) return '';
    return s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>\s*', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}

/// The albumId an audiobook chapter carries: the marker, and the book's id.
String audiobookAlbumId(String bookId) =>
    bookId.isEmpty ? kAudiobookMarker : '$kAudiobookMarker:$bookId';

/// The book a chapter Song belongs to, or '' (a chapter saved before chapters
/// carried it).
String audiobookIdOf(Song song) {
  const prefix = '$kAudiobookMarker:';
  return song.albumId.startsWith(prefix) ? song.albumId.substring(prefix.length) : '';
}
