import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/browse_hub_scaffold.dart';
import 'package:auvy/presentation/widgets/grouped_browse_view.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/radio_provider.dart';
import 'package:auvy/services/radio_service.dart';
import '../../providers/player_provider.dart';
import '../widgets/playing_equalizer.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/density_provider.dart';

/// Live Radio — worldwide station browser.
///
/// Redesign notes: genre chips (tag-based filtering), search that also matches
/// station tags, skeleton loaders, real error/empty states with retry, and
/// station cards with a branded gradient fallback for the many stations whose
/// favicon links are dead.
class RadioPage extends ConsumerStatefulWidget {
  const RadioPage({Key? key}) : super(key: key);

  @override
  ConsumerState<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends ConsumerState<RadioPage> {
  final TextEditingController _nameController = TextEditingController();

  // Label → tag token matched against the station's tag list. 'hip' also
  // catches the "hiphop" spelling radio-browser uses.
  // Label -> tag token matched against the station's tag list.
  //
  // CHOSEN FROM THE DIRECTORY, NOT INVENTED. Every token below was checked
  // against radio-browser's own tag census
  // (/json/tags?order=stationcount) so each chip leads to real stations — a
  // hand-written genre that nobody tags produces an empty page and looks
  // broken. Re-run that endpoint before adding more.
  //
  // The census also carries plenty of NON-genres near the top (station names,
  // language and region words, 'entretenimiento', 'programas en vivo'), which
  // is why this is a curated list rather than the raw top-N.
  //
  // Matching is by SUBSTRING, so 'hip' catches the 'hiphop' spelling the
  // directory actually uses.
  static const List<MapEntry<String, String>> _genres = [
    MapEntry('All', ''),
    MapEntry('Pop', 'pop'),
    MapEntry('Rock', 'rock'),
    MapEntry('News', 'news'),
    MapEntry('Talk', 'talk'),
    MapEntry('Classical', 'classical'),
    MapEntry('Dance', 'dance'),
    MapEntry('Jazz', 'jazz'),
    MapEntry('Hip-Hop', 'hip'),
    MapEntry('Electronic', 'electronic'),
    MapEntry('Country', 'country'),
    MapEntry('Metal', 'metal'),
    MapEntry('Indie', 'indie'),
    MapEntry('Alternative', 'alternative'),
    MapEntry('Soul', 'soul'),
    MapEntry('Blues', 'blues'),
    MapEntry('Reggae', 'reggae'),
    MapEntry('Folk', 'folk'),
    MapEntry('Funk', 'funk'),
    MapEntry('Punk', 'punk'),
    MapEntry('Disco', 'disco'),
    MapEntry('House', 'house'),
    MapEntry('Techno', 'techno'),
    MapEntry('Trance', 'trance'),
    MapEntry('Ambient', 'ambient'),
    MapEntry('Chillout', 'chillout'),
    MapEntry('Lounge', 'lounge'),
    MapEntry('Latin', 'latin'),
    MapEntry('Salsa', 'salsa'),
    MapEntry('Gospel', 'gospel'),
    MapEntry('Christian', 'christian'),
    MapEntry('Sports', 'sports'),
    MapEntry('Oldies', 'oldies'),
    MapEntry('Classic Rock', 'classic rock'),
    MapEntry('Pop Rock', 'pop rock'),
    MapEntry('Adult Contemporary', 'adult contemporary'),
    MapEntry('Easy Listening', 'easy listening'),
    MapEntry('Top 40', 'top 40'),
    MapEntry('Hits', 'hits'),
    MapEntry('Retro', 'retro'),
    MapEntry('70s', '70s'),
    MapEntry('80s', '80s'),
    MapEntry('90s', '90s'),
    MapEntry('2000s', '2000s'),
  ];


  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final activeGenre = ref.watch(radioGenreFilterProvider);
    // Watched here as well as in _buildBody so the header can report the
    // directory size; the provider is shared, so this costs nothing extra.
    final countriesAsync = ref.watch(radioCountriesProvider);

    return BrowseHubScaffold(
      title: 'Live Radio',
      // The directory's own count. A page of collapsed rows reads as empty
      // without it; "218 countries" says how much is behind them.
      subtitle: countriesAsync.maybeWhen(
        data: (c) => '${c.length} countries · tap one to open it',
        orElse: () => null,
      ),
      accent: themeColor,
      onRefresh: () async {
        ref.invalidate(radioCountriesProvider);
        try { await ref.read(radioCountriesProvider.future); } catch (_) {}
      },
      onCollapseAll: () => setState(_openCountries.clear),
      canCollapse: _openCountries.isNotEmpty,
      searchField: AuvySearchField(
        controller: _nameController,
        hint: 'Search stations',
        height: 48,
        radius: 24,
        fontSize: 14.5,
        onChanged: (val) {
          ref.read(radioSearchQueryProvider.notifier).state = val;
          setState(() {});
        },
        trailing: _nameController.text.isEmpty
            ? null
            : IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white38, size: 18),
                onPressed: () {
                  HapticService.selection();
                  _nameController.clear();
                  ref.read(radioSearchQueryProvider.notifier).state = '';
                  setState(() {});
                },
              ),
      ),
      chips: _buildGenreChips(themeColor, activeGenre),
      body: _buildBody(themeColor, activeGenre),
    );
  }


  Widget _buildGenreChips(Color themeColor, String activeGenre) {
    // Height comes from BrowseHubScaffold's chip slot, so radio and podcasts
    // reserve exactly the same vertical space whatever they put in it.
    return ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          itemCount: _genres.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final genre = _genres[index];
            final bool selected = activeGenre == genre.value;
            return GestureDetector(
              onTap: () {
                HapticService.selection();
                ref.read(radioGenreFilterProvider.notifier).state = genre.value;
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 15),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? themeColor : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected ? Colors.transparent : Colors.white.withOpacity(0.08),
                  ),
                ),
                child: Text(
                  genre.key,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white.withOpacity(0.75),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          },
    );
  }

  /// The hub
  ///
  /// Three states, in priority order:
  ///   1. a search query or a genre chip → server-side results, flat list
  ///   2. otherwise → the country directory, sections loaded on expand
  ///
  /// The directory itself is tiny (a name and a count per country), so the page
  /// paints almost immediately and only the country you open costs a request.
  Widget _buildBody(Color themeColor, String activeGenre) {
    final searching =
        _nameController.text.trim().isNotEmpty || activeGenre.isNotEmpty;

    if (searching) {
      final results = ref.watch(radioSearchResultsProvider);
      return results.when(
        skipLoadingOnReload: true,
        loading: () => const _RadioSkeletonGrid(),
        error: (e, _) => _StatusBox(
          icon: Icons.cloud_off_rounded,
          title: "Couldn't search stations",
          subtitle: "Check your connection and try again.",
          actionLabel: "Retry",
          onAction: () => ref.invalidate(radioSearchResultsProvider),
        ),
        data: (stations) {
          if (stations.isEmpty) {
            return const _StatusBox(
              icon: Icons.search_off_rounded,
              title: "No stations found",
              subtitle: "Try a different name, genre or spelling.",
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 180),
            itemCount: stations.length,
            itemBuilder: (context, i) =>
                _RadioRow(station: stations[i], themeColor: themeColor),
          );
        },
      );
    }

    final countriesAsync = ref.watch(radioCountriesProvider);
    return countriesAsync.when(
      skipLoadingOnReload: true,
      loading: () => const _RadioSkeletonGrid(),
      error: (e, _) => _StatusBox(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load the directory",
        subtitle: "Check your connection and try again.",
        actionLabel: "Retry",
        onAction: () => ref.invalidate(radioCountriesProvider),
      ),
      data: (countries) {
        if (countries.isEmpty) {
          return const _StatusBox(
            icon: Icons.radio_rounded,
            title: "No stations available",
            subtitle: "The radio directory could not be reached.",
          );
        }
        return _buildCountryBrowser(countries, themeColor);
      },
    );
  }

  /// Sections the user has opened. Survives rebuilds, not navigation.
  final Set<String> _openCountries = {};

  Widget _buildCountryBrowser(List<RadioCountry> countries, Color themeColor) {
    final groups = <BrowseGroup>[];
    for (final c in countries) {
      final open = _openCountries.contains(c.name);
      // Only the OPEN country is watched, so closed sections cost nothing.
      final async = open ? ref.watch(radioByCountryProvider(c.name)) : null;
      groups.add(BrowseGroup(
        key: c.name,
        title: c.name,
        // The directory's own count, so a closed section is honest about how
        // much is in there before you open it.
        count: c.stationCount,
        subtitle: c.code.isNotEmpty ? c.code : null,
        loading: open && (async?.isLoading ?? false),
        buildItems: () => [
          for (final st in (async?.valueOrNull ?? const []))
            _RadioRow(station: st, themeColor: themeColor),
        ],
      ));
    }

    return GroupedBrowseView(
      groups: groups,
      expanded: _openCountries,
      accent: themeColor,
      onToggle: (k) => setState(() {
        if (!_openCountries.remove(k)) _openCountries.add(k);
      }),
    );
  }


}


// Station ROW
//
// The grid card is still used nowhere else, but a country section is a LIST:
// two-across cards inside an expandable section make each country a wall of
// tiles you have to scan, while rows read top-to-bottom in popularity order,
// which is exactly how they are sorted.
class _RadioRow extends ConsumerWidget {
  final dynamic station;
  final Color themeColor;
  const _RadioRow({required this.station, required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select(), not a whole-provider watch: a country can hold hundreds of rows
    // and PlayerState is written on a timer.
    final bool isPlaying = ref.watch(playerProvider
        .select((p) => p.currentSong?.id == station.id && p.isPlaying));
    final String tag = (station.tags as String).isNotEmpty
        ? (station.tags as String).split(',').first.trim()
        : 'radio';

    return GestureDetector(
      onTap: () {
        HapticService.light();
        FocusScope.of(context).unfocus();
        ref.read(playerProvider.notifier).playSong(
              station.toSong(),
              isManual: true,
              source: "Live Radio",
            );
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        // Hand-built row: the ListTile theme funnel cannot reach it, so it
// reads the density setting directly.
        padding: EdgeInsets.fromLTRB(
            20, 4 + densityNow.rowVerticalPadding, 14,
            4 + densityNow.rowVerticalPadding),
        color: isPlaying ? themeColor.withOpacity(0.07) : Colors.transparent,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: densityNow.artwork(44),
                height: densityNow.artwork(44),
                child: (station.favicon as String).isNotEmpty
                    ? Image.network(
                        station.favicon,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        // Station favicons are third-party and frequently dead;
                        // the generated gradient is the same one the grid card
                        // uses, so a missing icon still looks deliberate.
                        errorBuilder: (_, __, ___) =>
                            _StationArtFallback(name: station.name),
                      )
                    : _StationArtFallback(name: station.name),
              ),
            ),
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
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            if (isPlaying)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: PlayingEqualizer(size: 10, color: themeColor),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Icon(Icons.play_arrow_rounded,
                    color: Colors.white.withOpacity(0.28), size: 22),
              ),
          ],
        ),
      ),
    );
  }
}

// Status box
// The non-sliver twin of [_StatusSliver], for the Column-based layout.
class _StatusBox extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StatusBox({
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.white.withOpacity(0.25)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66), fontSize: 13),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

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

/// A box, NOT a sliver.
///
/// This used to return a SliverPadding, which was correct while the page was a
/// CustomScrollView. Converting the page to a Column left it a sliver inside a
/// Flex, and Flutter threw "A RenderFlex expected a child of type RenderBox but
/// received a child of type RenderSliverPadding" on EVERY load — the flash of
/// red seen for an instant when the radio page opened. Debug mode surfaced it;
/// release mode swallowed it into a blank moment.
///
/// It also now mirrors the ROW list it stands in for, rather than the grid the
/// page stopped using.
class _RadioSkeletonGrid extends StatelessWidget {
  const _RadioSkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 120),
      itemCount: 9,
      itemBuilder: (context, i) => const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            SkeletonLoader(width: 44, height: 44, borderRadius: 10),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLoader(width: 160, height: 12, borderRadius: 6),
                  SizedBox(height: 7),
                  SkeletonLoader(width: 90, height: 10, borderRadius: 5),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


