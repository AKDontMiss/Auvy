import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/pages/podcast_page.dart' show podcastPositionsProvider, EpisodeProgress;
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/presentation/widgets/hub_kit.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/providers/audiobook_provider.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/audiobook_service.dart';
import 'package:auvy/services/haptic_service.dart';

/// Audiobooks: the LibriVox catalogue (about 21,600 free, public-domain books).
///
/// Laid out like Podcasts: the listener's own books first (in progress, saved),
/// then rails of what is most listened, best rated and newest (each with a full
/// list behind "See all"), then genres. A language chip applies to all of it.
/// Search pages through the whole catalogue.
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
    final language = ref.watch(audiobookLanguageProvider);
    final searching = _query.trim().length >= 2;

    return BrowseHubScaffold(
      title: 'Audiobooks',
      subtitle: 'Free, public-domain books read by LibriVox volunteers',
      accent: accent,
      onRefresh: () async {
        AudiobookService.clearCache();
        for (final sort in AudiobookSort.values) {
          ref.invalidate(audiobookListProvider(audiobookBrowse(sort: sort, language: language)));
        }
      },
      searchField: AuvySearchField(
        controller: _search,
        hint: 'Search books or authors',
        height: 48,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v),
      ),
      chips: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        children: [
          _Chip(
            label: language ?? 'All languages',
            on: true,
            accent: accent,
            dropdown: true,
            onTap: () => pickAudiobookLanguage(context, ref, accent),
          ),
        ],
      ),
      body: searching
          ? _BookList(
              query: (
                sort: AudiobookSort.popular,
                genre: null,
                language: language,
                search: _query.trim(),
                author: '',
              ),
              accent: accent,
              emptyMessage:
                  'No books match "${_query.trim()}"${language == null ? '' : ' in $language'}',
            )
          : _AudiobookHome(accent: accent, language: language),
    );
  }
}

/// The hub without a search.
class _AudiobookHome extends ConsumerWidget {
  final Color accent;
  final String? language;
  const _AudiobookHome({required this.accent, required this.language});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(audiobookLibraryProvider);
    HubRailItem item(Audiobook b, {String? caption, VoidCallback? onLongPress}) => HubRailItem(
          art: hubArt(b.coverUrl),
          title: b.title,
          subtitle: caption ?? b.author,
          highlight: caption != null,
          onTap: () => openAudiobook(context, ref, b),
          onLongPress: onLongPress,
        );
    Widget rail(String title, AudiobookSort sort) => _CatalogueRail(
          title: title,
          query: audiobookBrowse(sort: sort, language: language),
          accent: accent,
          item: item,
        );

    return CustomScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        if (library.inProgress.isNotEmpty)
          SliverToBoxAdapter(
            child: HubRail(
              title: 'Continue listening',
              accent: accent,
              items: [
                for (final p in library.inProgress)
                  item(p.book, caption: p.chapterTitle, onLongPress: () async {
                    HapticService.medium();
                    await ref.read(audiobookLibraryProvider.notifier).forget(p.book.id);
                    AnimatedToast.message('Removed from Continue listening');
                  }),
              ],
            ),
          ),
        if (library.saved.isNotEmpty)
          SliverToBoxAdapter(
            child: HubRail(
              title: 'Your books',
              accent: accent,
              items: [for (final b in library.saved) item(b)],
            ),
          ),
        SliverToBoxAdapter(child: rail('Most listened', AudiobookSort.popular)),
        SliverToBoxAdapter(child: rail('Top rated', AudiobookSort.rated)),
        SliverToBoxAdapter(child: rail('New recordings', AudiobookSort.newest)),
        const SliverToBoxAdapter(child: HubTitle('Browse genres')),
        HubCategoryGrid(tiles: [
          for (final g in AudiobookService.genres)
            HubTile(
              g,
              () => AppNavigation.push(
                  context, AudiobookListPage(title: g, genre: g), name: 'audiobook-genre:$g'),
              // The genre's most listened books: the same request its page
              // starts with, so opening it costs nothing more.
              preview: () async => [
                for (final b in (await AudiobookService.browse(genre: g, language: language)).take(2))
                  b.coverUrl
              ],
              previewKey: 'audiobook:$g:${language ?? ''}',
            ),
        ]),
        const SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
    );
  }
}

/// A rail of the first books of a catalogue list, with the full list behind
/// "See all" (the same list, so it costs no second request).
class _CatalogueRail extends ConsumerWidget {
  final String title;
  final AudiobookQuery query;
  final Color accent;
  final HubRailItem Function(Audiobook b, {String? caption, VoidCallback? onLongPress}) item;
  const _CatalogueRail({required this.title, required this.query, required this.accent, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(audiobookListProvider(query));
    if (s.books.isEmpty && s.loading) return HubRailSkeleton(title: title);
    if (s.books.isEmpty) return const SizedBox.shrink();
    return HubRail(
      title: title,
      accent: accent,
      onSeeAll: () => AppNavigation.push(
          context, AudiobookListPage(title: title, sort: query.sort), name: 'audiobooks:$title'),
      items: [for (final b in s.books.take(15)) item(b)],
    );
  }
}

/// A full catalogue list (a genre, or "See all" behind a rail), sortable.
class AudiobookListPage extends ConsumerStatefulWidget {
  final String title;
  final String? genre;
  final AudiobookSort sort;
  const AudiobookListPage({super.key, required this.title, this.genre, this.sort = AudiobookSort.popular});

  @override
  ConsumerState<AudiobookListPage> createState() => _AudiobookListPageState();
}

class _AudiobookListPageState extends ConsumerState<AudiobookListPage> {
  late AudiobookSort _sort = widget.sort;

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final language = ref.watch(audiobookLanguageProvider);
    return DynamicBackground(
      child: HubListPage(
        title: widget.title,
        subtitle: language ?? 'All languages',
        body: Column(
          children: [
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  for (final (sort, label) in const [
                    (AudiobookSort.popular, 'Most listened'),
                    (AudiobookSort.rated, 'Top rated'),
                    (AudiobookSort.newest, 'Newest'),
                  ])
                    _Chip(
                      label: label,
                      on: _sort == sort,
                      accent: accent,
                      onTap: () => setState(() => _sort = sort),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _BookList(
                query: audiobookBrowse(sort: _sort, genre: widget.genre, language: language),
                accent: accent,
                emptyMessage: 'Nothing here in ${language ?? 'any language'}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The language filter, shared by the hub and the lists.
Future<void> pickAudiobookLanguage(BuildContext context, WidgetRef ref, Color accent) async {
  HapticService.selection();
  final current = ref.read(audiobookLanguageProvider) ?? '';
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF161616),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Language',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            for (final l in ['', ...AudiobookService.languages.keys])
              ListTile(
                title: Text(l.isEmpty ? 'All languages' : l, style: const TextStyle(color: Colors.white)),
                trailing: l == current ? Icon(Icons.check_rounded, color: accent) : null,
                onTap: () => Navigator.pop(ctx, l),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked != null) {
    ref.read(audiobookLanguageProvider.notifier).state = picked.isEmpty ? null : picked;
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool on;
  final bool dropdown;
  final Color accent;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.on,
    required this.accent,
    required this.onTap,
    this.dropdown = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: AuvyPill(label: label, selected: on, accent: accent, dropdown: dropdown, onTap: onTap),
      );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
      );
}

/// A paged list of books. The next page loads as the end comes near.
class _BookList extends ConsumerWidget {
  final AudiobookQuery query;
  final Color accent;
  final String emptyMessage;
  const _BookList({
    required this.query,
    required this.accent,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(audiobookListProvider(query));
    final notifier = ref.read(audiobookListProvider(query).notifier);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 900) notifier.loadMore();
        return false;
      },
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          if (s.books.isEmpty && s.loading)
            const SliverToBoxAdapter(child: HubRowsSkeleton(art: 58))
          else if (s.books.isEmpty && s.failed)
            SliverToBoxAdapter(child: BrowseHubStatus(
                        icon: Icons.cloud_off_rounded,
                        title: "Couldn't reach the audiobook library",
                        actionLabel: 'Try again',
                        onAction: notifier.reload))
          else if (s.books.isEmpty && s.done)
            SliverToBoxAdapter(child: BrowseHubStatus(icon: Icons.menu_book_rounded, title: emptyMessage))
          else
            SliverList.builder(
              itemCount: s.books.length,
              itemBuilder: (_, i) => _BookRow(book: s.books[i], accent: accent),
            ),
          if (s.books.isNotEmpty && s.loading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                    child: SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: accent))),
              ),
            ),
          if (s.books.isNotEmpty && s.failed)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton(
                  onPressed: notifier.loadMore,
                  child: Text("Couldn't load more. Try again", style: TextStyle(color: accent)),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 150)),
        ],
      ),
    );
  }
}

/// Opens a book's page, lending it what the list knew while its details load.
void openAudiobook(BuildContext context, WidgetRef ref, Audiobook book) {
  final listed = ref.read(audiobookListedProvider);
  if (!listed.containsKey(book.id)) {
    ref.read(audiobookListedProvider.notifier).state = {...listed, book.id: book};
  }
  AppNavigation.push(context, AudiobookDetailPage(book: book), name: 'audiobook:${book.id}');
}

String _hm(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

class _BookRow extends ConsumerWidget {
  final Audiobook book;
  final Color accent;
  const _BookRow({required this.book, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = [
      book.author,
      if (book.totalTime > Duration.zero) _hm(book.totalTime),
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticService.light();
          openAudiobook(context, ref, book);
        },
        child: Padding(
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
                    Text(book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              if (book.rating > 0) ...[
                const SizedBox(width: 8),
                Icon(Icons.star_rounded, size: 14, color: accent),
                const SizedBox(width: 2),
                Text(book.rating.toStringAsFixed(1),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One book: its description, its chapters with progress, and more by its
/// author. Plays as one queue from any chapter, and offers to continue where
/// the listener left off.
class AudiobookDetailPage extends ConsumerStatefulWidget {
  final Audiobook book;
  const AudiobookDetailPage({super.key, required this.book});

  @override
  ConsumerState<AudiobookDetailPage> createState() => _AudiobookDetailPageState();

  /// Queue the whole book from [start], as the book's own queue (not mixed into
  /// the listener's Up next).
  static void playFrom(WidgetRef ref, Audiobook book, AudiobookChapter start,
      List<AudiobookChapter> all) {
    final songs = [
      for (final c in all)
        c.toSong(bookTitle: book.title, author: book.author, image: book.coverUrl, bookId: book.id)
    ];
    ref.read(playerProvider.notifier).playSong(
          songs[start.index],
          newQueue: songs,
          index: start.index,
          source: 'Audiobook',
          locationName: book.title,
          contextId: book.id,
          contextType: 'audiobook',
          contextTitle: book.title,
        );
  }
}

class _AudiobookDetailPageState extends ConsumerState<AudiobookDetailPage> {
  bool _moreText = false;

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final detailsAsync = ref.watch(audiobookDetailsProvider(widget.book.id));
    final book = detailsAsync.asData?.value ?? widget.book;
    final chapters = book.chapters;
    final library = ref.watch(audiobookLibraryProvider);
    final progress = library.progress[book.id];
    final saved = library.isSaved(book.id);
    final positions = ref.watch(podcastPositionsProvider).asData?.value ??
        const <String, EpisodeProgress>{};
    final resumeIndex = progress == null || progress.finished
        ? -1
        : chapters.indexWhere((c) => c.streamUrl == progress.chapterUrl);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              flexibleSpace: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.92),
                      Colors.black.withValues(alpha: 0.8),
                      Colors.black.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.62, 1],
                  ),
                ),
              ),
              leading: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.maybePop(context),
              ),
              title: Text(book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
            ),
            SliverToBoxAdapter(
                child: _hero(book, chapters, accent, saved, progress, resumeIndex)),
            if (detailsAsync.isLoading && chapters.isEmpty)
              const SliverToBoxAdapter(child: HubRowsSkeleton(art: 58))
            else if (chapters.isEmpty)
              SliverToBoxAdapter(
                child: detailsAsync.hasError || detailsAsync.asData?.value == null
                    ? BrowseHubStatus(
                        icon: Icons.cloud_off_rounded,
                        title: "Couldn't reach the audiobook library",
                        actionLabel: 'Try again',
                        onAction: () => ref.invalidate(audiobookDetailsProvider(book.id)))
                    : const BrowseHubStatus(icon: Icons.menu_book_rounded, title: 'This recording has no playable chapters'),
              )
            else ...[
              _SliverTitle('${chapters.length} chapters'),
              SliverList.builder(
                itemCount: chapters.length,
                itemBuilder: (_, i) {
                  final c = chapters[i];
                  return _ChapterRow(
                    book: book,
                    chapter: c,
                    all: chapters,
                    accent: accent,
                    progress: positions[c.streamUrl.hashCode.toString()] ?? EpisodeProgress.none,
                    played: resumeIndex >= 0 && i < resumeIndex ||
                        (progress?.finished ?? false),
                  );
                },
              ),
            ],
            SliverToBoxAdapter(child: _MoreByAuthor(book: book, accent: accent)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  'Public-domain recording, read by LibriVox volunteers · hosted by the Internet Archive',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10.5),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 150)),
          ],
        ),
      ),
    );
  }

  Widget _hero(Audiobook book, List<AudiobookChapter> chapters, Color accent, bool saved,
      BookProgress? progress, int resumeIndex) {
    final meta = [
      if (book.totalTime > Duration.zero) _hm(book.totalTime),
      if (chapters.isNotEmpty) '${chapters.length} ${chapters.length == 1 ? 'chapter' : 'chapters'}',
      book.language,
    ].join(' · ');
    final canResume = resumeIndex >= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AuvyImage(path: book.coverUrl, width: 132, height: 132, borderRadius: 14, decodeWidth: 300),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(book.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, height: 1.2)),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () {
                        HapticService.light();
                        AppNavigation.push(context, AudiobookAuthorPage(author: book.author),
                            name: 'audiobook-author:${book.author}');
                      },
                      child: Text(book.author,
                          style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 13.5)),
                    ),
                    const SizedBox(height: 6),
                    Text(meta, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    if (book.rating > 0) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.star_rounded, size: 15, color: accent),
                        const SizedBox(width: 3),
                        Text(
                            '${book.rating.toStringAsFixed(1)}'
                            '${book.reviews > 0 ? ' (${book.reviews})' : ''}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: chapters.isEmpty
                      ? null
                      : () {
                          HapticService.medium();
                          AudiobookDetailPage.playFrom(
                              ref, book, chapters[canResume ? resumeIndex : 0], chapters);
                        },
                  style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  icon: const Icon(Icons.play_arrow_rounded, size: 22),
                  label: Text(canResume ? 'Continue chapter ${resumeIndex + 1}' : 'Play',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.outlined(
                tooltip: saved ? 'Remove from your books' : 'Save to your books',
                onPressed: () async {
                  HapticService.selection();
                  await ref.read(audiobookLibraryProvider.notifier).toggleSaved(book);
                  AnimatedToast.message(saved ? 'Removed from your books' : 'Saved to your books');
                },
                icon: Icon(saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                    color: saved ? accent : Colors.white),
              ),
            ],
          ),
          if (canResume)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(progress!.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          if (book.description.isNotEmpty) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => setState(() => _moreText = !_moreText),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.description,
                      maxLines: _moreText ? null : 4,
                      overflow: _moreText ? null : TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.45)),
                  const SizedBox(height: 4),
                  Text(_moreText ? 'Less' : 'More',
                      style: TextStyle(color: accent, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SliverTitle extends StatelessWidget {
  final String text;
  const _SliverTitle(this.text);
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(child: _SectionTitle(text));
}

class _ChapterRow extends ConsumerWidget {
  final Audiobook book;
  final AudiobookChapter chapter;
  final List<AudiobookChapter> all;
  final Color accent;
  final EpisodeProgress progress;
  final bool played;
  const _ChapterRow({
    required this.book,
    required this.chapter,
    required this.all,
    required this.accent,
    required this.progress,
    required this.played,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = progress.durationMs > 0 ? progress.durationMs : chapter.duration.inMilliseconds;
    final frac = total > 0 && progress.positionMs > 0
        ? (progress.positionMs / total).clamp(0.0, 1.0)
        : 0.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticService.light();
          AudiobookDetailPage.playFrom(ref, book, chapter, all);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 7 + densityNow.rowVerticalPadding),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: played
                    ? Icon(Icons.check_rounded, size: 16, color: accent.withValues(alpha: 0.8))
                    : Text('${chapter.index + 1}',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NowPlayingTitle(
                      rowId: chapter.streamUrl,
                      title: chapter.title,
                      artist: book.author,
                      style: TextStyle(
                          color: played ? Colors.white60 : Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600),
                    ),
                    if (frac > 0) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: frac,
                          minHeight: 3,
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation(accent),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (chapter.duration > Duration.zero)
                Text(_clock(chapter.duration),
                    style: const TextStyle(color: Colors.white60, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }
}

/// Other books by the same author, under a book.
class _MoreByAuthor extends ConsumerWidget {
  final Audiobook book;
  final Color accent;
  const _MoreByAuthor({required this.book, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (book.author.isEmpty || book.author == 'Unknown author') return const SizedBox.shrink();
    final s = ref.watch(audiobookListProvider(
        (sort: AudiobookSort.popular, genre: null, language: null, search: '', author: book.author)));
    // Other recordings of this very book are listed too: LibriVox often has
    // several readings, and choosing a reader is a real choice.
    final others = s.books.where((b) => b.id != book.id).take(12).toList();
    if (others.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: HubRail(
        title: 'More by ${book.author}',
        accent: accent,
        items: [
          for (final b in others)
            HubRailItem(
              art: hubArt(b.coverUrl),
              title: b.title,
              subtitle: b.totalTime > Duration.zero ? _hm(b.totalTime) : '',
              onTap: () => openAudiobook(context, ref, b),
            ),
        ],
      ),
    );
  }
}

/// Everything recorded of one author.
class AudiobookAuthorPage extends ConsumerWidget {
  final String author;
  const AudiobookAuthorPage({super.key, required this.author});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        body: _BookList(
          query: (sort: AudiobookSort.popular, genre: null, language: null, search: '', author: author),
          accent: accent,
          emptyMessage: 'No recordings of $author',
        ),
      ),
    );
  }
}

/// Opens the book a chapter Song belongs to (the player title, the song menu,
/// the queue): its page if the chapter knows its book, else the hub.
Future<void> openAudiobookOfSong(WidgetRef ref, Song song) async {
  final id = audiobookIdOf(song);
  if (id.isEmpty) {
    AppNavigation.pushOnActiveTab(const AudiobooksPage());
    return;
  }
  final book = Audiobook(
      id: id, title: song.albumTitle, author: song.artist, coverUrl: song.image, archiveId: id);
  final listed = ref.read(audiobookListedProvider);
  if (!listed.containsKey(id)) {
    ref.read(audiobookListedProvider.notifier).state = {...listed, id: book};
  }
  AppNavigation.pushOnActiveTab(AudiobookDetailPage(book: listed[id] ?? book),
      name: 'audiobook:$id');
}
