import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/services/audiobook_service.dart';

/// What a list shows: a browse view (sort, genre, language), a search, or one
/// author. Records compare by value, so the same query reuses its provider.
typedef AudiobookQuery = ({
  AudiobookSort sort,
  String? genre,
  String? language,
  String search,
  String author,
});

AudiobookQuery audiobookBrowse({
  AudiobookSort sort = AudiobookSort.popular,
  String? genre,
  String? language,
}) =>
    (sort: sort, genre: genre, language: language, search: '', author: '');

/// Null means every language. English until the listener picks another.
final audiobookLanguageProvider = StateProvider<String?>((_) => 'English');

class AudiobookListState {
  final List<Audiobook> books;
  final bool loading;
  final bool done;
  final bool failed;
  const AudiobookListState({
    this.books = const [],
    this.loading = false,
    this.done = false,
    this.failed = false,
  });

  AudiobookListState copyWith({List<Audiobook>? books, bool? loading, bool? done, bool? failed}) =>
      AudiobookListState(
        books: books ?? this.books,
        loading: loading ?? this.loading,
        done: done ?? this.done,
        failed: failed ?? this.failed,
      );
}

/// A list that pages in as it is scrolled: 30 books at a time, the next page
/// when the end comes near, until the catalogue has no more.
class AudiobookListNotifier extends StateNotifier<AudiobookListState> {
  AudiobookListNotifier(this.query) : super(const AudiobookListState()) {
    loadMore();
  }

  final AudiobookQuery query;
  int _page = 0;

  Future<void> loadMore() async {
    if (state.loading || state.done) return;
    state = state.copyWith(loading: true, failed: false);
    final next = _page + 1;
    try {
      final page = query.author.isNotEmpty
          ? await AudiobookService.byAuthor(query.author, page: next)
          : query.search.isNotEmpty
              ? await AudiobookService.search(query.search, page: next, language: query.language)
              : await AudiobookService.browse(
                  sort: query.sort, genre: query.genre, language: query.language, page: next);
      if (!mounted) return;
      _page = next;
      final known = {for (final b in state.books) b.id};
      state = state.copyWith(
        books: [...state.books, ...page.where((b) => known.add(b.id))],
        loading: false,
        done: page.length < AudiobookService.pageSize,
      );
    } catch (_) {
      if (mounted) state = state.copyWith(loading: false, failed: true);
    }
  }

  /// Starts over (pull to refresh, retry after a failure).
  Future<void> reload() async {
    _page = 0;
    state = const AudiobookListState();
    await loadMore();
  }
}

final audiobookListProvider = StateNotifierProvider.autoDispose
    .family<AudiobookListNotifier, AudiobookListState, AudiobookQuery>(
        (ref, query) => AudiobookListNotifier(query));

/// One book with its description and chapters, fetched when its page opens.
/// Keyed by id; [audiobookListedProvider] lends the listing's details (rating)
/// while it loads.
final audiobookDetailsProvider =
    FutureProvider.autoDispose.family<Audiobook?, String>((ref, id) {
  final listed = ref.read(audiobookListedProvider)[id];
  return AudiobookService.details(id, listed: listed);
});

/// Books seen in lists this session, so a book page can show what the list knew
/// (title, cover, rating) before its own details arrive.
final audiobookListedProvider = StateProvider<Map<String, Audiobook>>((_) => const {});

/// Where the listener is in a book.
class BookProgress {
  final Audiobook book;
  final String chapterUrl;
  final String chapterTitle;
  final int updatedMs;
  final bool finished;
  const BookProgress({
    required this.book,
    required this.chapterUrl,
    required this.chapterTitle,
    required this.updatedMs,
    this.finished = false,
  });

  Map<String, Object> toJson() => {
        'book': book.toJson(),
        'url': chapterUrl,
        'chapter': chapterTitle,
        't': updatedMs,
        if (finished) 'done': true,
      };

  static BookProgress? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final book = Audiobook.fromJson(raw['book']);
    if (book == null) return null;
    return BookProgress(
      book: book,
      chapterUrl: (raw['url'] as String?) ?? '',
      chapterTitle: (raw['chapter'] as String?) ?? '',
      updatedMs: (raw['t'] as num?)?.toInt() ?? 0,
      finished: raw['done'] == true,
    );
  }
}

class AudiobookLibraryState {
  /// Books the listener saved, newest first.
  final List<Audiobook> saved;

  /// Book id → where they are in it.
  final Map<String, BookProgress> progress;
  const AudiobookLibraryState({this.saved = const [], this.progress = const {}});

  bool isSaved(String id) => saved.any((b) => b.id == id);

  /// Books started and not finished, most recent first, for "Continue listening".
  List<BookProgress> get inProgress => progress.values.where((p) => !p.finished).toList()
    ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
}

/// The listener's books: the ones they saved and how far they are in each. It
/// follows the player, so a chapter played from anywhere (the queue after a
/// restart, the lock screen) moves the bookmark. One small preference, backed
/// up with the account.
class AudiobookLibraryNotifier extends StateNotifier<AudiobookLibraryState> {
  AudiobookLibraryNotifier(this._ref) : super(const AudiobookLibraryState()) {
    _ready = _load();
    _ref.listen<Song?>(playerProvider.select((s) => s.currentSong), (prev, next) {
      if (next != null && next.mediaKind == MediaKind.audiobook && next.id != prev?.id) {
        unawaited(_ready.then((_) => _noteChapter(next)));
      }
    });
    SpokenWordHooks.chapterFinished =
        (song) => unawaited(_ready.then((_) => _chapterFinished(song)));
  }

  final Ref _ref;
  late final Future<void> _ready;
  static const kPrefsKey = 'auvy_audiobooks_v1';

  /// Books kept in "Continue listening" at most; the oldest drop off.
  static const _maxProgress = 40;

  @override
  void dispose() {
    SpokenWordHooks.chapterFinished = null;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPrefsKey);
      if (raw == null) {
        if (mounted) state = const AudiobookLibraryState();
        return;
      }
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      state = AudiobookLibraryState(
        saved: [for (final b in (m['saved'] as List?) ?? const []) ?Audiobook.fromJson(b)],
        progress: {
          for (final e in ((m['progress'] as Map?) ?? const {}).entries)
            if (BookProgress.fromJson(e.value) case final p?) e.key.toString(): p,
        },
      );
    } catch (e) {
      print('WARN: audiobooks: stored books unreadable ($e)');
    }
  }

  /// Re-reads after a restore or an account switch (which wipes the key).
  Future<void> reload() => _load();

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefsKey,
        jsonEncode({
          'saved': [for (final b in state.saved) b.toJson()],
          'progress': {for (final e in state.progress.entries) e.key: e.value.toJson()},
        }));
  }

  Future<void> toggleSaved(Audiobook book) async {
    await _ready;
    final saved = state.isSaved(book.id)
        ? state.saved.where((b) => b.id != book.id).toList()
        : [book.copyWith(chapters: const []), ...state.saved];
    state = AudiobookLibraryState(saved: saved, progress: state.progress);
    await _save();
  }

  /// Takes a book out of "Continue listening" (it stays saved if it was).
  Future<void> forget(String id) async {
    await _ready;
    state = AudiobookLibraryState(
        saved: state.saved, progress: {...state.progress}..remove(id));
    await _save();
  }

  void _noteChapter(Song song) {
    final id = audiobookIdOf(song);
    if (id.isEmpty || !mounted) return;
    final known = state.progress[id]?.book ??
        state.saved.where((b) => b.id == id).firstOrNull ??
        _ref.read(audiobookListedProvider)[id];
    final book = known ??
        Audiobook(
            id: id, title: song.albumTitle, author: song.artist, coverUrl: song.image, archiveId: id);
    final progress = {
      ...state.progress,
      id: BookProgress(
        book: book.copyWith(chapters: const []),
        chapterUrl: song.id,
        chapterTitle: song.title,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
      ),
    };
    if (progress.length > _maxProgress) {
      final oldest = progress.entries.reduce((a, b) => a.value.updatedMs < b.value.updatedMs ? a : b);
      progress.remove(oldest.key);
    }
    state = AudiobookLibraryState(saved: state.saved, progress: progress);
    unawaited(_save());
  }

  /// The last chapter played to its end finishes the book.
  Future<void> _chapterFinished(Song song) async {
    final id = audiobookIdOf(song);
    final p = state.progress[id];
    if (id.isEmpty || p == null || !mounted) return;
    final book = await AudiobookService.details(id);
    final chapters = book?.chapters ?? const [];
    if (chapters.isEmpty || chapters.last.streamUrl != song.id || !mounted) return;
    state = AudiobookLibraryState(saved: state.saved, progress: {
      ...state.progress,
      id: BookProgress(
          book: p.book,
          chapterUrl: song.id,
          chapterTitle: song.title,
          updatedMs: DateTime.now().millisecondsSinceEpoch,
          finished: true),
    });
    await _save();
    print('audiobooks: finished "${p.book.title}"');
  }
}

final audiobookLibraryProvider =
    StateNotifierProvider<AudiobookLibraryNotifier, AudiobookLibraryState>(
        (ref) => AudiobookLibraryNotifier(ref));
