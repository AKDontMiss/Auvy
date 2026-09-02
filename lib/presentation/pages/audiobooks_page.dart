import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/providers/audiobook_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/audiobook_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/density_provider.dart';

/// Audiobooks — free, public-domain works from LibriVox.
///
/// Deliberately the same shape as Podcasts and Live Radio: a browse hub with a
/// search field, genre chips and a list, so the third button behaves like the two
/// the user already knows. What differs is the unit of playback — a book is a
/// LIST of chapters, so opening one shows its chapters and playing queues the
/// whole book from that point rather than a single item.
class AudiobooksPage extends ConsumerStatefulWidget {
  const AudiobooksPage({super.key});

  @override
  ConsumerState<AudiobooksPage> createState() => _AudiobooksPageState();
}

class _AudiobooksPageState extends ConsumerState<AudiobooksPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final genre = ref.watch(audiobookGenreProvider);
    final searching = _query.trim().length >= 2;
    final listAsync = searching
        ? ref.watch(audiobookSearchProvider(_query.trim()))
        : ref.watch(audiobookListProvider);

    return BrowseHubScaffold(
      title: 'Audiobooks',
      subtitle: listAsync.maybeWhen(
        data: (books) => books.isEmpty
            ? null
            : '${books.length} ${books.length == 1 ? "book" : "books"} · '
                'public domain, free forever',
        orElse: () => null,
      ),
      accent: accent,
      onRefresh: () async {
        AudiobookService.clearCache();
        ref.invalidate(audiobookListProvider);
        try {
          await ref.read(audiobookListProvider.future);
        } catch (_) {
          // The list below renders the error state; this only awaits the refresh
          // indicator so it does not spin forever.
        }
      },
      searchField: AuvySearchField(
        controller: _search,
        hint: 'Search books or authors',
        height: 48,
        onChanged: (v) => setState(() => _query = v),
      ),
      chips: searching ? null : _genreChips(accent, genre),
      body: listAsync.when(
        loading: () => const _BookListSkeleton(),
        error: (e, _) => _ErrorState(
          accent: accent,
          onRetry: () {
            AudiobookService.clearCache();
            ref.invalidate(searching
                ? audiobookSearchProvider(_query.trim())
                : audiobookListProvider);
          },
        ),
        data: (books) {
          if (books.isEmpty) {
            return _EmptyState(
              message: searching
                  ? 'No books match "${_query.trim()}"'
                  : 'Nothing here yet — pull to refresh',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 120, top: 4),
            itemCount: books.length,
            itemBuilder: (_, i) => _BookRow(book: books[i], accent: accent),
          );
        },
      ),
    );
  }

  Widget _genreChips(Color accent, String? selected) {
    // 'All' is a null genre rather than a magic string, so the provider's own
    // branch decides between latest() and byGenre().
    final entries = <MapEntry<String, String?>>[
      const MapEntry('Newest', null),
      for (final g in AudiobookService.genres) MapEntry(_shortGenre(g), g),
    ];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final e = entries[i];
          final on = selected == e.value;
          return GestureDetector(
            onTap: () {
              HapticService.selection();
              ref.read(audiobookGenreProvider.notifier).state = e.value;
            },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: on ? accent.withValues(alpha: 0.22) : Colors.white10,
                borderRadius: BorderRadius.circular(19),
                border: Border.all(
                  color: on ? accent : Colors.white24,
                  width: on ? 1.4 : 1,
                ),
              ),
              child: Text(
                e.key,
                style: TextStyle(
                  color: on ? accent : Colors.white70,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// LibriVox genre names are long ("Myths, Legends & Fairy Tales"). Chips are
  /// read at a glance, so the leading clause is enough.
  static String _shortGenre(String g) {
    final cut = g.split(RegExp(r'[,(&]')).first.trim();
    return cut.isEmpty ? g : cut;
  }
}

class _BookRow extends ConsumerWidget {
  final Audiobook book;
  final Color accent;
  const _BookRow({required this.book, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticService.light();
          AppNavigation.push(context, AudiobookDetailPage(book: book),
              name: 'audiobook:${book.id}');
        },
        child: Padding(
          // Hand-built row: the ListTile theme funnel cannot reach it, so it
// reads the density setting directly.
          padding: EdgeInsets.symmetric(
              horizontal: 16, vertical: 4 + densityNow.rowVerticalPadding / 2),
          child: Row(
            children: [
              AuvyImage(
                path: book.coverUrl,
                width: densityNow.artwork(58),
                height: densityNow.artwork(58),
                borderRadius: 10,
                decodeWidth: 120,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      book.totalTime > Duration.zero
                          ? '${book.author} · ${_hm(book.totalTime)}'
                          : book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }

  static String _hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

/// One book: its description and its chapters.
class AudiobookDetailPage extends ConsumerWidget {
  final Audiobook book;
  const AudiobookDetailPage({super.key, required this.book});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final chaptersAsync = ref.watch(audiobookChaptersProvider(book));

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: chaptersAsync.when(
        loading: () => const _BookListSkeleton(),
        error: (_, __) => _ErrorState(
          accent: accent,
          onRetry: () => ref.invalidate(audiobookChaptersProvider(book)),
        ),
        data: (chapters) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(context, ref, accent, chapters)),
            if (chapters.isEmpty)
              const SliverToBoxAdapter(
                child: _EmptyState(
                    message: 'This edition has no playable chapters'),
              )
            else
              SliverList.builder(
                itemCount: chapters.length,
                itemBuilder: (_, i) => _ChapterRow(
                  book: book,
                  chapter: chapters[i],
                  all: chapters,
                  accent: accent,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, Color accent,
      List<AudiobookChapter> chapters) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AuvyImage(
                path: book.coverUrl,
                width: 104,
                height: 104,
                borderRadius: 12,
                decodeWidth: 220,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(book.author,
                        style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (chapters.isNotEmpty)
                          '${chapters.length} '
                              '${chapters.length == 1 ? "chapter" : "chapters"}',
                        if (book.totalTime > Duration.zero)
                          _BookRow._hm(book.totalTime),
                        book.language,
                      ].join(' · '),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    if (chapters.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () {
                          HapticService.medium();
                          AudiobookDetailPage.playFrom(ref, book, chapters.first, chapters);
                        },
                        style: FilledButton.styleFrom(backgroundColor: accent),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Play'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (book.description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              book.description,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12.5, height: 1.45),
            ),
          ],
          const SizedBox(height: 6),
          // Provenance, stated plainly. These recordings are free because their
          // source works are out of copyright and the narrators released them —
          // saying so is both honest and the reason the section can exist.
          Text(
            'Public-domain recording · LibriVox / Internet Archive',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35), fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  /// Queue the whole book from [start] — shared by the header Play button and by
  /// tapping a chapter, so the two can never diverge into different behaviour.
  static void playFrom(WidgetRef ref, Audiobook book, AudiobookChapter start,
      List<AudiobookChapter> all) {
    Song asSong(AudiobookChapter c) => c.toSong(
        bookTitle: book.title, author: book.author, image: book.coverUrl);
    final rest = all.skip(start.index).toList();
    ref.read(playerProvider.notifier).playSong(
          asSong(start),
          source: 'Audiobook',
          locationName: book.title,
        );
    // A book without the following chapters queued is just a list of unrelated
    // files: a listener starting at chapter 12 expects 13 to follow.
    if (rest.length > 1) {
      ref
          .read(playerProvider.notifier)
          .addListToQueue([for (final c in rest.skip(1)) asSong(c)]);
    }
  }
}

class _ChapterRow extends ConsumerWidget {
  final Audiobook book;
  final AudiobookChapter chapter;
  final List<AudiobookChapter> all;
  final Color accent;
  const _ChapterRow({
    required this.book,
    required this.chapter,
    required this.all,
    required this.accent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = chapter.toSong(
        bookTitle: book.title, author: book.author, image: book.coverUrl);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticService.light();
          // Delegated so the header Play button and a chapter tap can never
          // drift into different behaviour. See playFrom.
          AudiobookDetailPage.playFrom(ref, book, chapter, all);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: 16, vertical: 7 + densityNow.rowVerticalPadding),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text('${chapter.index + 1}',
                    style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: NowPlayingTitle(
                  rowId: song.id,
                  title: chapter.title,
                  artist: book.author,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 10),
              if (chapter.duration > Duration.zero)
                Text(_ms(chapter.duration),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }

  static String _ms(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _BookListSkeleton extends StatelessWidget {
  const _BookListSkeleton();
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 8,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SkeletonLoader(width: 58, height: 58, borderRadius: 10),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLoader(width: 180, height: 13, borderRadius: 6),
                  SizedBox(height: 8),
                  SkeletonLoader(width: 110, height: 11, borderRadius: 5),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Color accent;
  final VoidCallback onRetry;
  const _ErrorState({required this.accent, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 44),
          const SizedBox(height: 12),
          const Text("Couldn't reach the audiobook library",
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
                foregroundColor: accent, side: BorderSide(color: accent)),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 56),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_rounded,
                color: Colors.white24, size: 42),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
