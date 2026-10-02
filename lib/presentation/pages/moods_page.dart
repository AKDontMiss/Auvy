import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/mood_shelf.dart';
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/presentation/pages/search_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/presentation/widgets/hub_kit.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// YouTube Music's own mood & genre browser (`FEmusic_moods_and_genres`): its
/// real categories, in its colours, each opening its curated playlists.
///
/// Laid out to be worth opening: two picks for right now (the time of day and
/// the day of the week), the genres the listener actually plays, then YouTube's
/// own sections ("Moods & moments", "Genres", …) as tiles with an icon each.
/// The search box filters the categories as you type.
class MoodsPage extends ConsumerStatefulWidget {
  const MoodsPage({super.key});

  @override
  ConsumerState<MoodsPage> createState() => _MoodsPageState();
}

class _MoodsPageState extends ConsumerState<MoodsPage> {
  List<Map<String, dynamic>>? _categories;
  bool _failed = false;

  /// Moods and genres aren't free text: each category is a browse id plus params
  /// minted by the service, so a typed word can't become one. The search box
  /// filters the real categories as you type, and when nothing matches it offers
  /// an ordinary catalogue search, clearly labelled as such.
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cats = await ref.read(searchServiceProvider).getMoodCategories();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _failed = cats.isEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// YouTube ships an ARGB int; darkened a little so white text stays readable.
  static Color? _color(Map<String, dynamic> cat) {
    final raw = cat['color'];
    if (raw is! int) return null;
    return Color.alphaBlend(Colors.black.withValues(alpha: 0.2), Color(raw));
  }

  /// [withPreview]: show covers from inside it. Only for the highlighted tiles
  /// at the top: the preview is the category's own page (which opening it then
  /// reuses), and fetching all ~70 would cost megabytes.
  HubTile _tile(Map<String, dynamic> cat, {bool withPreview = false}) {
    final title = cat['title'].toString();
    final browseId = cat['browseId'].toString();
    final params = (cat['params'] ?? '').toString();
    return HubTile(
      title,
      () => Navigator.push(
        context,
        MainLayout.smoothRoute(_MoodCategoryPage(title: title, browseId: browseId, params: params)),
      ),
      color: _color(cat),
      preview: !withPreview
          ? null
          : () async {
              final shelves =
                  await ref.read(searchServiceProvider).getMoodCategoryShelves(browseId, params);
              return [
                for (final shelf in shelves)
                  for (final item in shelf.items.take(2)) item.image
              ].take(2).toList();
            },
      previewKey: 'mood:$browseId:$params',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final cats = _categories;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The keyboard must not resize this page: DynamicBackground sits outside
        // the Scaffold, so a resized body would leave a visible strip.
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('Moods & genres',
              style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
        ),
        body: cats == null && !_failed
            ? const HubRowsSkeleton()
            : _failed
                ? BrowseHubStatus(
                    icon: Icons.cloud_off_rounded,
                    title: "Couldn't load moods and genres",
                    subtitle: 'Check your connection and try again.',
                    actionLabel: 'Retry',
                    onAction: () {
                      setState(() {
                        _failed = false;
                        _categories = null;
                      });
                      _load();
                    },
                  )
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: AuvySearchField(
                        controller: _searchController,
                        hint: 'What are you in the mood for?',
                        height: 48,
                        textInputAction: TextInputAction.search,
                        onChanged: (v) => setState(() => _query = v),
                        onSubmitted: _searchCatalogue,
                      ),
                    ),
                    Expanded(child: _body(cats!, theme)),
                  ]),
      ),
    );
  }

  Widget _body(List<Map<String, dynamic>> cats, Color theme) {
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final matches = cats.where((c) => c['title'].toString().toLowerCase().contains(q)).toList();
      if (matches.isEmpty) {
        // No category matches: offered as what it is, an ordinary search.
        return BrowseHubStatus(
          icon: Icons.travel_explore_rounded,
          title: 'No category called “${_query.trim()}”',
          subtitle: 'Moods and genres are a fixed set. You can search everything else instead.',
          actionLabel: 'Search “${_query.trim()}”',
          onAction: () => _searchCatalogue(_query),
        );
      }
      return CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          HubCategoryGrid(tiles: [for (final c in matches) _tile(c)]),
          const SliverToBoxAdapter(child: SizedBox(height: 140)),
        ],
      );
    }

    final intel = ref.read(intelligenceProvider.notifier);
    final state = ref.read(intelligenceProvider);
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // The categories named like [names] (genres, loosely compared), best first.
    List<Map<String, dynamic>> matching(Iterable<String> names, int limit,
        {Set<Map<String, dynamic>> skip = const {}}) {
      final out = <Map<String, dynamic>>[];
      for (final name in names) {
        final key = norm(name);
        if (key.length < 3) continue;
        final hit = cats.where((c) {
          final t = norm(c['title'].toString());
          return (t == key || t.contains(key) || key.contains(t)) &&
              !out.contains(c) && !skip.contains(c);
        }).firstOrNull;
        if (hit != null) out.add(hit);
        if (out.length == limit) break;
      }
      return out;
    }

    // Right now: what the listener plays more than usual in this part of the
    // week (artists and genres, from the day-part signature), as genres.
    final signature = [for (final e in intel.dayPartSignature(limit: 30)) e['name'] as String];
    final nowGenres = <String>[
      for (final name in signature) ...[
        name,
        ...(state.artistGenres[name] ?? state.artistGenres[name.toLowerCase()] ?? const <String>[]),
      ]
    ];
    var picks = matching(nowGenres, 2);
    final caption = 'For ${intel.dayPartLabel()}';
    // Not enough history yet: YouTube's own first moods.
    if (picks.length < 2) {
      final moods = cats.where((c) =>
          (c['section'] ?? '').toString().toLowerCase().contains('mood') && !picks.contains(c));
      picks = [...picks, ...moods].take(2).toList();
    }

    // Your genres: the genres the listener plays most, overall.
    final affinities = state.genreAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final yours = matching([for (final g in affinities.take(12)) g.key], 6, skip: picks.toSet());

    // YouTube's sections, in its order.
    final sections = <String, List<Map<String, dynamic>>>{};
    for (final c in cats) {
      sections.putIfAbsent((c['section'] ?? 'More').toString(), () => []).add(c);
    }

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (picks.isNotEmpty) ...[
          SliverToBoxAdapter(child: HubTitle(caption)),
          HubCategoryGrid(aspectRatio: 1.45, tiles: [for (final c in picks) _tile(c, withPreview: true)]),
        ],
        if (yours.isNotEmpty) ...[
          const SliverToBoxAdapter(child: HubTitle('Your genres')),
          HubCategoryGrid(tiles: [for (final c in yours) _tile(c, withPreview: true)]),
        ],
        for (final e in sections.entries) ...[
          SliverToBoxAdapter(child: HubTitle(e.key)),
          HubCategoryGrid(tiles: [for (final c in e.value) _tile(c)]),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }

  /// Hand the typed words to the ordinary search, which is the only thing that
  /// can act on free text.
  void _searchCatalogue(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    HapticService.selection();
    Navigator.push(context, MainLayout.smoothRoute(SearchPage(initialQuery: q)));
  }
}

/// The playlists inside one mood/genre category.
class _MoodCategoryPage extends ConsumerStatefulWidget {
  final String title;
  final String browseId;
  final String params;
  const _MoodCategoryPage(
      {required this.title, required this.browseId, required this.params});

  @override
  ConsumerState<_MoodCategoryPage> createState() => _MoodCategoryPageState();
}


class _MoodCategoryPageState extends ConsumerState<_MoodCategoryPage> {
  List<MoodShelf>? _shelves;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await ref
        .read(searchServiceProvider)
        .getMoodCategoryShelves(widget.browseId, widget.params);
    if (!mounted) return;
    setState(() => _shelves = s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final shelves = _shelves;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // A large collapsing title: the category is the subject of the page.
            SliverAppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              pinned: true,
              expandedHeight: 132,
              leading: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsets.fromLTRB(20, 0, 20, 15),
                expandedTitleScale: 1.7,
                title: Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
              ),
            ),
            if (shelves == null)
              const SliverToBoxAdapter(child: HubRailSkeleton(title: '', size: 140))
            else if (shelves.isEmpty)
              const SliverToBoxAdapter(
                child: BrowseHubStatus(icon: Icons.queue_music_rounded, title: 'Nothing here right now'),
              )
            else
              // Each shelf a rail of covers: a playlist is chosen by its cover, and
              // rails show every shelf's heading within a scroll or two.
              for (final shelf in shelves)
                SliverToBoxAdapter(
                  child: HubRail(
                    title: shelf.title,
                    accent: theme,
                    size: 140,
                    items: [
                      for (final item in shelf.items)
                        HubRailItem(
                          art: hubArt(item.image, size: 140),
                          title: item.title,
                          subtitle: item.subtitle.isNotEmpty
                              ? item.subtitle
                              : (item.isTrack ? 'Track' : item.isAlbum ? 'Album' : 'Playlist'),
                          onTap: () => _openItem(shelf, item),
                        ),
                    ],
                  ),
                ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }

  /// What a tap on an entry does.
  ///
  /// One place, so the behaviour cannot differ between the layouts that draw
  /// an entry — duplicating it is how one of them ends up queueing the wrong
  /// thing.
  void _openItem(MoodShelf shelf, MoodItem item) {
    HapticService.selection();
    if (item.isTrack) {
      // Queue the shelf's OTHER TRACKS behind it — tracks only, so a mixed
      // shelf can never put a playlist entry into the play queue.
      final queue =
          shelf.items.where((e) => e.isTrack).map((e) => e.song!).toList();
      ref.read(playerProvider.notifier).playSong(
            item.song!,
            newQueue: queue,
            index: queue.indexWhere((s) => s.id == item.id),
            source: 'Moods & genres',
            locationName: shelf.title,
          );
      return;
    }
    // A playlist or album OPENS rather than playing, so the listener can see
    // what is in it before committing to it.
    Navigator.push(
      context,
      MainLayout.smoothRoute(PlaylistPage(
        externalId: item.id,
        externalTitle: item.title,
        externalImage: item.image,
        externalSubtitle: item.subtitle,
        isAlbumView: item.isAlbum,
      )),
    );
  }
}
