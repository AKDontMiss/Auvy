import 'dart:async';

import 'package:flutter/material.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/data/radio_station_model.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/hub_kit.dart';
import 'package:auvy/services/catalog_api_clients.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/radio_provider.dart';
import 'package:auvy/services/radio_service.dart';
import '../../providers/player_provider.dart';
import '../widgets/playing_equalizer.dart';
import 'package:auvy/presentation/widgets/interactive_pressable.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/density_provider.dart';

/// Live Radio: the listener's own stations first (recently played, saved),
/// then what is popular now where they are and worldwide, then genres and
/// countries. Every list is ranked by the last 24 hours of listening
/// (radio-browser's click count), so "top" means what people are tuning in to
/// now. Search is debounced: a word is one search, not one per letter.
class RadioPage extends ConsumerStatefulWidget {
  const RadioPage({Key? key}) : super(key: key);

  @override
  ConsumerState<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends ConsumerState<RadioPage> {
  final TextEditingController _nameController = TextEditingController();
  Timer? _debounce;

  /// Genre tiles on the hub; the full list is behind "All genres". Label → tag,
  /// matched as part of a station's tags ('hip' also catches "hiphop"). From
  /// radio-browser's tag census (/json/tags?order=stationcount): re-check there
  /// before adding more.
  static const List<(String, String)> _topGenres = [
    ('Pop', 'pop'), ('Rock', 'rock'), ('News', 'news'), ('Talk', 'talk'),
    ('Dance', 'dance'), ('Hip-Hop', 'hip'), ('Jazz', 'jazz'), ('Classical', 'classical'),
    ('Electronic', 'electronic'), ('Chillout', 'chillout'), ('Latin', 'latin'),
    ('Oldies', 'oldies'), ('80s', '80s'), ('Sports', 'sports'),
  ];

  static const List<(String, String)> allGenres = [
    ..._topGenres,
    ('Country', 'country'), ('Metal', 'metal'), ('Indie', 'indie'),
    ('Alternative', 'alternative'), ('Soul', 'soul'), ('Blues', 'blues'),
    ('Reggae', 'reggae'), ('Folk', 'folk'), ('Funk', 'funk'), ('Punk', 'punk'),
    ('Disco', 'disco'), ('House', 'house'), ('Techno', 'techno'), ('Trance', 'trance'),
    ('Ambient', 'ambient'), ('Lounge', 'lounge'), ('Salsa', 'salsa'), ('Gospel', 'gospel'),
    ('Christian', 'christian'), ('Classic Rock', 'classic rock'), ('Pop Rock', 'pop rock'),
    ('Adult Contemporary', 'adult contemporary'), ('Easy Listening', 'easy listening'),
    ('Top 40', 'top 40'), ('Hits', 'hits'), ('Retro', 'retro'), ('70s', '70s'),
    ('90s', '90s'), ('2000s', '2000s'),
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  void _onQuery(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) ref.read(radioSearchQueryProvider.notifier).state = value.trim();
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final query = ref.watch(radioSearchQueryProvider);
    final searching = _nameController.text.trim().length >= 2;

    return BrowseHubScaffold(
      title: 'Live Radio',
      subtitle: 'Your stations, and what people are listening to now',
      accent: themeColor,
      onRefresh: () async {
        ref.invalidate(radioTrendingProvider);
        final code = _countryCode();
        if (code != null) ref.invalidate(radioHotInCountryProvider(code));
        if (query.isNotEmpty) ref.invalidate(radioSearchResultsProvider);
        try { await ref.read(radioTrendingProvider.future); } catch (_) {}
      },
      searchField: AuvySearchField(
        controller: _nameController,
        hint: 'Search stations or genres',
        height: 48,
        radius: 24,
        fontSize: 14.5,
        onChanged: _onQuery,
        trailing: _nameController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                onPressed: () {
                  HapticService.selection();
                  _nameController.clear();
                  _debounce?.cancel();
                  ref.read(radioSearchQueryProvider.notifier).state = '';
                  setState(() {});
                },
              ),
      ),
      body: searching ? _searchResults(themeColor) : _home(themeColor),
    );
  }

  /// The listener's country (SIM or network, see ListeningPolicy), or null.
  static String? _countryCode() {
    final c = CatalogApiClients.contentCountry.trim().toUpperCase();
    return c.length == 2 ? c : null;
  }

  Widget _searchResults(Color themeColor) {
    final results = ref.watch(radioSearchResultsProvider);
    return results.when(
      skipLoadingOnReload: true,
      loading: () => const HubRowsSkeleton(art: 44),
      error: (e, _) => BrowseHubStatus(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't search stations",
        subtitle: 'Check your connection and try again.',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(radioSearchResultsProvider),
      ),
      data: (stations) {
        if (stations.isEmpty) {
          return const BrowseHubStatus(
            icon: Icons.search_off_rounded,
            title: 'No stations found',
            subtitle: 'Try a different name, genre or spelling.',
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(top: 4, bottom: 180),
          itemCount: stations.length,
          itemBuilder: (context, i) => _RadioRow(station: stations[i], themeColor: themeColor),
        );
      },
    );
  }

  Widget _home(Color themeColor) {
    final pinned = ref.watch(pinnedRadioStationsProvider);
    final history = ref.watch(playerProvider.select((s) => s.history));
    final seen = <String>{};
    final recent = <RadioStation>[
      for (final song in history)
        if (song.mediaKind == MediaKind.liveStream && seen.add(song.id))
          RadioStation(
            id: song.id,
            name: song.title,
            urlResolved: song.id,
            favicon: song.image,
            country: song.artist.replaceFirst('Live Radio • ', '').trim(),
            tags: song.albumTitle,
            votes: 0,
          ),
    ];
    final code = _countryCode();
    final countryName = code == null ? null : _countryNameFor(code);

    HubRailItem item(RadioStation st, {int? rank}) => HubRailItem(
          art: _StationArt(station: st, size: 112),
          title: st.name,
          subtitle: st.tags.isNotEmpty ? st.tags.split(',').first.trim() : st.country,
          rank: rank,
          onTap: () => _play(st),
        );

    return CustomScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        if (recent.isNotEmpty)
          SliverToBoxAdapter(
            child: HubRail(
                title: 'Recently played', accent: themeColor,
                items: [for (final st in recent.take(12)) item(st)]),
          ),
        if (pinned.isNotEmpty)
          SliverToBoxAdapter(
            child: HubRail(
                title: 'Your stations', accent: themeColor,
                items: [for (final st in pinned) item(st)]),
          ),
        if (code != null)
          SliverToBoxAdapter(
            child: _ChartRail(
              title: 'Popular in ${countryName ?? code}',
              async: ref.watch(radioHotInCountryProvider(code)),
              item: item,
              accent: themeColor,
              onSeeAll: countryName == null
                  ? null
                  : () => AppNavigation.push(context, RadioCountryPage(country: countryName),
                      name: 'radio-country:$countryName'),
            ),
          ),
        SliverToBoxAdapter(
          child: _ChartRail(
            title: 'Trending worldwide',
            async: ref.watch(radioTrendingProvider),
            item: item,
            accent: themeColor,
          ),
        ),
        const SliverToBoxAdapter(child: HubTitle('Browse genres')),
        HubCategoryGrid(
          tiles: [
            for (final (label, tag) in _topGenres)
              HubTile(label, () => AppNavigation.push(context, RadioGenrePage(label: label, tag: tag),
                  name: 'radio-genre:$tag')),
            HubTile('All genres', () => AppNavigation.push(context, const RadioGenresPage(),
                name: 'radio-genres'), more: true),
          ],
        ),
        const SliverToBoxAdapter(child: HubTitle('Browse countries')),
        HubCategoryGrid(
          tiles: [
            if (countryName != null)
              HubTile(countryName, () => AppNavigation.push(context, RadioCountryPage(country: countryName),
                  name: 'radio-country:$countryName')),
            HubTile('All countries', () => AppNavigation.push(context, const RadioCountriesPage(),
                name: 'radio-countries'), more: true),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
    );
  }

  /// The country's name in the directory (the names are radio-browser's, which
  /// the country page queries by), from the country list once it has loaded.
  String? _countryNameFor(String code) {
    final countries = ref.watch(radioCountriesProvider).asData?.value ?? const <RadioCountry>[];
    return countries.where((c) => c.code.toUpperCase() == code).firstOrNull?.name;
  }

  void _play(RadioStation st) {
    ref.read(playerProvider.notifier).playSong(st.toSong(), isManual: true, source: 'Live Radio');
  }
}

/// A rail of a ranked station list.
class _ChartRail extends StatelessWidget {
  final String title;
  final AsyncValue<List<RadioStation>> async;
  final HubRailItem Function(RadioStation st, {int? rank}) item;
  final Color accent;
  final VoidCallback? onSeeAll;
  const _ChartRail({
    required this.title,
    required this.async,
    required this.item,
    required this.accent,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    final stations = async.asData?.value ?? const <RadioStation>[];
    if (async.isLoading && stations.isEmpty) return HubRailSkeleton(title: title);
    return HubRail(
      title: title,
      accent: accent,
      onSeeAll: onSeeAll,
      items: [for (final (i, st) in stations.take(25).indexed) item(st, rank: i + 1)],
    );
  }
}

/// A station's logo, decoded at the size it is drawn (some are 1000 px), with
/// the generated gradient where it is missing or broken.
class _StationArt extends StatelessWidget {
  final RadioStation station;
  final double size;
  const _StationArt({required this.station, required this.size});

  @override
  Widget build(BuildContext context) {
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 60 ? 12 : 10),
      child: SizedBox(
        width: size,
        height: size,
        child: station.favicon.isNotEmpty
            ? Image.network(
                station.favicon,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: px,
                errorBuilder: (_, __, ___) => _StationArtFallback(name: station.name),
              )
            : _StationArtFallback(name: station.name),
      ),
    );
  }
}

/// A ranked station list page (a country, a genre).
class _StationListPage extends ConsumerWidget {
  final String title;
  final String subtitle;
  final AsyncValue<List<RadioStation>> async;
  final VoidCallback onRetry;
  const _StationListPage({
    required this.title,
    required this.subtitle,
    required this.async,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    return DynamicBackground(
      child: HubListPage(
        title: title,
        subtitle: subtitle,
        body: async.when(
          loading: () => const HubRowsSkeleton(art: 44),
          error: (_, __) => BrowseHubStatus(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load stations",
            subtitle: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction: onRetry,
          ),
          data: (stations) => stations.isEmpty
              ? const BrowseHubStatus(icon: Icons.radio_rounded, title: 'No stations here')
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 180),
                  itemCount: stations.length,
                  itemBuilder: (_, i) =>
                      _RadioRow(station: stations[i], themeColor: themeColor, rank: i + 1),
                ),
        ),
      ),
    );
  }
}

/// One country's stations, popular now first.
class RadioCountryPage extends ConsumerWidget {
  final String country;
  const RadioCountryPage({super.key, required this.country});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _StationListPage(
        title: country,
        subtitle: 'Most listened in the last 24 hours',
        async: ref.watch(radioByCountryProvider(country)),
        onRetry: () => ref.invalidate(radioByCountryProvider(country)),
      );
}

/// One genre's stations worldwide, popular now first.
class RadioGenrePage extends ConsumerWidget {
  final String label;
  final String tag;
  const RadioGenrePage({super.key, required this.label, required this.tag});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _StationListPage(
        title: label,
        subtitle: 'Most listened in the last 24 hours, worldwide',
        async: ref.watch(radioByTagProvider(tag)),
        onRetry: () => ref.invalidate(radioByTagProvider(tag)),
      );
}

/// Every genre.
class RadioGenresPage extends StatelessWidget {
  const RadioGenresPage({super.key});

  @override
  Widget build(BuildContext context) {
    final genres = [..._RadioPageState.allGenres]..sort((a, b) => a.$1.compareTo(b.$1));
    return DynamicBackground(
      child: HubListPage(
        title: 'All genres',
        body: ListView.builder(
          padding: const EdgeInsets.only(bottom: 180),
          itemCount: genres.length,
          itemBuilder: (_, i) => ListTile(
            title: Text(genres[i].$1, style: const TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            onTap: () => AppNavigation.push(
                context, RadioGenrePage(label: genres[i].$1, tag: genres[i].$2),
                name: 'radio-genre:${genres[i].$2}'),
          ),
        ),
      ),
    );
  }
}

/// Every country, A to Z, with how many stations it has.
class RadioCountriesPage extends ConsumerWidget {
  const RadioCountriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countries = ref.watch(radioCountriesProvider);
    return DynamicBackground(
      child: HubListPage(
        title: 'All countries',
        subtitle: countries.asData == null ? null : '${countries.asData!.value.length} countries',
        body: countries.when(
          loading: () => const HubRowsSkeleton(art: 44),
          error: (_, __) => BrowseHubStatus(
            icon: Icons.cloud_off_rounded,
            title: "Couldn't load the directory",
            subtitle: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(radioCountriesProvider),
          ),
          data: (list) => ListView.builder(
            padding: const EdgeInsets.only(bottom: 180),
            itemCount: list.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(list[i].name, style: const TextStyle(color: Colors.white)),
              subtitle: Text('${list[i].stationCount} stations',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              onTap: () => AppNavigation.push(context, RadioCountryPage(country: list[i].name),
                  name: 'radio-country:${list[i].name}'),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadioRow extends ConsumerWidget {
  final RadioStation station;
  final Color themeColor;

  /// Chart position, before the art on a ranked list.
  final int? rank;
  const _RadioRow({required this.station, required this.themeColor, this.rank});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select(), not a whole-provider watch: a country can hold hundreds of rows
    // and PlayerState is written on a timer.
    final bool isPlaying = ref.watch(playerProvider.select((p) =>
        (p.currentSong?.id == station.urlResolved ||
            p.currentSong?.id == station.id) &&
        p.isPlaying));
    final bool isPinned = ref.watch(pinnedRadioStationsProvider.select((list) =>
        list.any((s) =>
            s.id == station.id ||
            (s.urlResolved.isNotEmpty && s.urlResolved == station.urlResolved))));
    final String tag =
        station.tags.isNotEmpty ? station.tags.split(',').first.trim() : 'radio';

    return InteractivePressable(
      scaleDown: 0.98,
      highlightColor: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        FocusScope.of(context).unfocus();
        ref.read(playerProvider.notifier).playSong(
              station.toSong(),
              isManual: true,
              source: "Live Radio",
            );
      },
      child: Container(
        // Hand-built row: the ListTile theme funnel cannot reach it, so it
        // reads the density setting directly.
        padding: EdgeInsets.fromLTRB(
            rank == null ? 20 : 10, 4 + densityNow.rowVerticalPadding, 10,
            4 + densityNow.rowVerticalPadding),
        color: isPlaying ? themeColor.withValues(alpha: 0.08) : Colors.transparent,
        child: Row(
          children: [
            if (rank != null)
              SizedBox(
                width: 30,
                child: Text('$rank',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
            if (rank != null) const SizedBox(width: 6),
            // Station favicons are third-party and frequently dead; the generated
            // gradient keeps a missing icon looking deliberate.
            _StationArt(station: station, size: densityNow.artwork(44)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isPlaying ? themeColor : Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.66),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            // Pin toggle button
            IconButton(
              tooltip: isPinned ? 'Unpin station' : 'Pin station',
              icon: Icon(
                isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                color: isPinned ? themeColor : Colors.white24,
                size: 19,
              ),
              onPressed: () {
                HapticService.selection();
                ref.read(pinnedRadioStationsProvider.notifier).togglePin(station);
                AnimatedToast.show(
                  context,
                  text: isPinned ? 'Unpinned station' : 'Pinned station',
                  icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                  color: themeColor,
                );
              },
              splashRadius: 18,
            ),
            if (isPlaying)
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 6),
                child: PlayingEqualizer(size: 10, color: themeColor),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 6),
                child: Icon(Icons.play_arrow_rounded,
                    color: Colors.white.withValues(alpha: 0.28), size: 22),
              ),
          ],
        ),
      ),
    );
  }
}

// Status box
// The non-sliver twin of [_StatusSliver], for the Column-based layout.
// Station card


/// Branded fallback art for stations without a working favicon: a deep
/// two-tone gradient derived from the station name, so every card gets a
/// stable, unique color instead of a flat grey box.
class _StationArtFallback extends StatelessWidget {
  final String name;
  const _StationArtFallback({required this.name});

  @override
  Widget build(BuildContext context) {
    final double hue = (name.hashCode % 360).abs().toDouble();
    final Color a = HSLColor.fromAHSL(1, hue, 0.42, 0.30).toColor();
    final Color b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.45, 0.14).toColor();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ),
      ),
      child: Center(
        child: Icon(Icons.radio_rounded, color: Colors.white.withOpacity(0.35), size: 36),
      ),
    );
  }
}
