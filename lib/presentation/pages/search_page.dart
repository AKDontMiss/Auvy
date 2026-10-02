import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart'; 
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/theme_provider.dart'; 
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart'; 
import 'package:auvy/presentation/widgets/animated_toast.dart'; 
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/pages/moods_page.dart';
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/presentation/widgets/song_recognition_sheet.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/services/haptic_service.dart'; // Phase 7

class SearchPage extends ConsumerStatefulWidget {
  /// Words to search for as soon as the page opens, so other surfaces can hand free
  /// text to search instead of building their own (e.g. a typed phrase on the moods
  /// page that names no category). Null leaves the page empty, waiting for input.
  final String? initialQuery;

  const SearchPage({super.key, this.initialQuery});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late TextEditingController _searchController;
  /// Search scope, fixed at 'All': every search is a mixed search. Still a field
  /// because it gates the results builder; the scope-specific branches below are
  /// unused but kept so scope chips could be added back easily.
  final String _selectedFilter = 'All';
  final FocusNode _searchFocusNode = FocusNode();

  // Ignores a second navigation within a short window, so a double tap can't
  // push the same page twice.
  DateTime? _lastNavTime;
  void _safeNavigate(VoidCallback action) {
    final now = DateTime.now();
    if (_lastNavTime == null || now.difference(_lastNavTime!) > const Duration(milliseconds: 400)) {
      _lastNavTime = now;
      action();
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery ?? '');
    // Arrived with words already: run them, so the page opens on results
    // rather than on a filled field the reader has to submit themselves.
    // Deferred by a frame because _onSearchChanged touches providers, which
    // must not happen during initState.
    final seed = widget.initialQuery?.trim() ?? '';
    if (seed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onSearchChanged(seed);
      });
    }
    // NO autofocus here: this page is built at app START (inside the tab
    // IndexedStack), so requesting focus in initState grabbed the keyboard on
    // launch — while the HOME tab was showing. The user taps the field when
    // they want to type.

    // Needed for the suggestion list to appear and disappear: _buildSuggestions reads
    // _searchFocusNode.hasFocus, which doesn't subscribe to changes, and the search
    // bar's AnimatedBuilder only rebuilds the bar itself.
    _searchFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    // Rebuild only: flips the idle↔results branch and the clear button. It rebuilds
    // the whole page, which is why the ranking below is cached.
    setState(() {});
  }

  // Cached ranking and interleave for the All filter, keyed on the identities it
  // reads: the result lists and the affinity map. Typing changes none of them, so
  // keystrokes don't re-sort results. SearchState replaces its lists on every new
  // result set, so identity changing is exactly the signal to recompute.
  Object? _splitFromSongs;
  Object? _splitFromArtists;
  Object? _splitFromAlbums;
  Object? _splitFromPlaylists;
  Object? _splitFromAffinities;
  List<Song>? _splitSongs;
  List<Map<String, dynamic>>? _splitTop;
  List<Map<String, dynamic>>? _splitOther;

  void _handleRecentSearchTap(String query) {
    _searchController.text = query;
    setState(() {});
    
    // Trigger actual search
    String type = _selectedFilter == 'All' ? 'all' : _selectedFilter.toLowerCase().substring(0, _selectedFilter.length - 1);
    ref.read(searchProvider.notifier).performSearch(query, type: type);
    
    // When tapping history, we also update it to the top
    ref.read(searchProvider.notifier).saveSearch(query);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final themeColor = ref.watch(themeProvider);
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return DynamicBackground(child: Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildSearchBar(themeColor)),
            // No scope filter chips: search always runs in "All" mode (`_selectedFilter`
            // stays 'All'), and the results already separate Top Results from the rest.
            const SliverToBoxAdapter(child: SizedBox(height: 14)),

            // Toggle between History List and Search Results
            if (_searchController.text.isEmpty)
              _buildRecentSearches(searchState, themeColor)
            else ...[
              // Completions sit ABOVE the results, not instead of them: results
              // for the previous query stay visible and usable while the user
              // keeps typing, which is what makes refining a search feel instant
              // rather than like starting over.
              _buildSuggestions(themeColor),
              ..._buildSliverResults(searchState, themeColor),
            ],
              
            SliverPadding(
              padding: EdgeInsets.only(bottom: keyboardHeight > 0 ? keyboardHeight + 20 : 120),
              sliver: const SliverToBoxAdapter(child: SizedBox.shrink()),
            ),
          ],
        ),
      ),
    ),
    );
  }

  List<Widget> _buildSliverResults(SearchState state, Color themeColor) {
  // Use optimized skeleton while loading
  if (state.isLoading) return [_buildSliverSkeleton()];
  
  if (state.results.isEmpty && state.songs.isEmpty) {
    return [
      SliverToBoxAdapter(
        child: Container(
          padding: const EdgeInsets.only(top: 100),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A failed search and an empty one are different: state.error carries the reason
              // (offline, rate-limited, …) and the message follows it.
              Icon(
                  state.error == null
                      ? Icons.search_off_rounded
                      : Icons.cloud_off_rounded,
                  size: 48,
                  color: Colors.white.withOpacity(0.25)),
              const SizedBox(height: 12),
              Text(state.error == null ? "No results found" : "Search unavailable",
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.7), fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                    state.error ?? "Try a different keyword or filter",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 12.5)),
              ),
            ],
          ),
        ),
      )
    ];
  }

  // --- ALL FILTER: Sectioned & Ranked UI ---
  if (_selectedFilter == 'All') {
    final trackAffinities = ref.watch(
        intelligenceProvider.select((s) => s.trackAffinities)); // Inject listening history
    final bool splitIsFresh = _splitTop != null &&
        identical(_splitFromSongs, state.songs) &&
        identical(_splitFromArtists, state.artists) &&
        identical(_splitFromAlbums, state.albums) &&
        identical(_splitFromPlaylists, state.playlists) &&
        identical(_splitFromAffinities, trackAffinities);
    final songs =
        splitIsFresh ? _splitSongs! : List<Song>.from(state.songs);
    // Declared out here so the slivers below read the same names in both cases:
    // the cached lists when nothing changed, freshly built ones when it did.
    final List<Map<String, dynamic>> topResults =
        splitIsFresh ? _splitTop! : <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> otherResults =
        splitIsFresh ? _splitOther! : <Map<String, dynamic>>[];
    
    // Hits/Affinity Ranking: Sort songs by your personal listening frequency
    if (!splitIsFresh) {
      songs.sort((a, b) {
        final affinityA = trackAffinities[a.id] ?? 0.0;
        final affinityB = trackAffinities[b.id] ?? 0.0;
        // Only affinity-boost songs where user has meaningful history (>0.3 affinity)
        // Otherwise preserve original search order via stable index comparison
        final aHasHistory = affinityA > 0.3;
        final bHasHistory = affinityB > 0.3;
        if (aHasHistory && !bHasHistory) return -1;
        if (bHasHistory && !aHasHistory) return 1;
        if (aHasHistory && bHasHistory) return affinityB.compareTo(affinityA);
        return 0; // Both unknown — keep original search-service order
      });

      // Split Logic: Categorize into Top Results and Other

    
      int sIdx = 0, artIdx = 0, albIdx = 0, plIdx = 0;
      const maxHits = 200; // Increased depth for comprehensive results
    
      // Fill "Top Results" section (First 5 highly relevant/high-stream matches)
      while (topResults.length < 5) {
        if (sIdx < songs.length) {
          topResults.add({'type': 'song', 'data': songs[sIdx++]});
        }
        if (artIdx < state.artists.length && topResults.length < 5) {
          topResults.add({'type': 'artist', 'data': state.artists[artIdx++]});
        }
        if (albIdx < state.albums.length && topResults.length < 5) {
          topResults.add({'type': 'album', 'data': state.albums[albIdx++]});
        }
        if (sIdx >= songs.length && artIdx >= state.artists.length && albIdx >= state.albums.length) break;
      }

      // Fill "Other" section (The remaining 195+ items)
      while (otherResults.length < maxHits) {
        if (sIdx < songs.length) {
          otherResults.add({'type': 'song', 'data': songs[sIdx++]});
        }
        if (artIdx < state.artists.length) {
          otherResults.add({'type': 'artist', 'data': state.artists[artIdx++]});
        }
        if (albIdx < state.albums.length) {
          otherResults.add({'type': 'album', 'data': state.albums[albIdx++]});
        }
        if (plIdx < state.playlists.length) {
          otherResults.add({'type': 'playlist', 'data': state.playlists[plIdx++]});
        }
        if (sIdx >= songs.length && artIdx >= state.artists.length && albIdx >= state.albums.length && plIdx >= state.playlists.length) break;
      }
      _splitFromSongs = state.songs;
      _splitFromArtists = state.artists;
      _splitFromAlbums = state.albums;
      _splitFromPlaylists = state.playlists;
      _splitFromAffinities = trackAffinities;
      _splitSongs = songs;
      _splitTop = topResults;
      _splitOther = otherResults;
      print('search results ranked: ${songs.length} song(s) sorted, '
          '${topResults.length} top + ${otherResults.length} other — '
          'cached until the results or the taste profile change');
    }

    return [
      // Section 1: Top Matches
      _buildSectionHeader("Top Results", themeColor),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildMixedResultItem(
            topResults[index]['type'], 
            topResults[index]['data'], 
            songs, 
            index, 
            themeColor
          ),
          childCount: topResults.length,
        ),
      ),

      // Surprise SHELF: Horizontal Featured Artists
      if (state.artists.length > 3)
        SliverToBoxAdapter(
          child: _buildHorizontalCategory(
            "Featured Artists", 
            state.artists, 
            (artist) => ArtistPage(artist: artist)
          ),
        ),

      // Surprise SHELF: Horizontal Explore Albums
      if (state.albums.length > 2)
        SliverToBoxAdapter(
          child: _buildHorizontalCategory(
            "Explore Albums", 
            state.albums, 
            (album) => AlbumPage(
              album: Album(
                id: album.id.replaceFirst('album_', ''), 
                title: album.title, 
                image: album.image, 
                releaseDate: album.releaseDate, 
                recordType: 'album'
              ),
              artistName: album.artist,
            ),
          ),
        ),

      // Section 2: Deep Results (Other Hits)
      _buildSectionHeader("Other", themeColor),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildMixedResultItem(
            otherResults[index]['type'], 
            otherResults[index]['data'], 
            songs, 
            index, 
            themeColor
          ),
          childCount: otherResults.length,
        ),
      ),
    ];
  }

  // --- SPECIFIC FILTERS: Tracks ---
  if (_selectedFilter == 'Tracks') {
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildTrackTile(state.results[index], state.results, index, themeColor),
          childCount: state.results.length,
        ),
      ),
    ];
  }

  // --- SPECIFIC FILTERS: Artists ---
  if (_selectedFilter == 'Artists') {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, 
            childAspectRatio: 0.8, 
            crossAxisSpacing: 16, 
            mainAxisSpacing: 16,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildArtistCircle(state.artists[index]),
            childCount: state.artists.length,
          ),
        ),
      ),
    ];
  }

  // --- SPECIFIC FILTERS: Albums ---
  if (_selectedFilter == 'Albums') {
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildSwipeableAlbumTile(state.albums[index], themeColor),
          childCount: state.albums.length,
        ),
      ),
    ];
  }

  // --- SPECIFIC FILTERS: Playlists ---
  if (_selectedFilter == 'Playlists') {
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildPlaylistListTile(state.playlists[index]),
          childCount: state.playlists.length,
        ),
      ),
    ];
  }
  return [];
}

// Auvy's section voice: quiet small-caps overlines (same recipe as
// artist_page) — ONE helper for every header on this page.
Widget _sectionHeader(String title, {String? actionLabel, VoidCallback? onAction}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8)),
        ),
        if (actionLabel != null && onAction != null)
          GestureDetector(
            onTap: () {
              HapticService.selection();
              onAction();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(actionLabel.toUpperCase(),
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.72),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2)),
            ),
          ),
      ],
    ),
  );
}

Widget _buildSectionHeader(String title, Color themeColor) {
  return SliverToBoxAdapter(child: _sectionHeader(title));
}

Widget _buildSwipeableAlbumTile(Song album, Color themeColor) {
  return _SwipeableAlbumSearchTile(
    album: album,
    onTap: () {
      FocusScope.of(context).unfocus();
      HapticService.selection();
      _safeNavigate(() {
        final a = Album(
          id: album.id.replaceFirst('album_', ''),
          title: album.title,
          image: album.image,
          releaseDate: album.releaseDate,
          recordType: 'album',
        );
        AppNavigation.push(
          context,
          AlbumPage(album: a, artistName: album.artist, fallbackTrack: album),
          name: AppNavigation.albumTag(a),
        );
      },
      );
    },
    onQueue: (pos) async {
      // Get album tracks and add to queue
      final tracks = await ref.read(searchServiceProvider).getAlbumTracks(album.id.replaceFirst('album_', ''));
      if (tracks.isNotEmpty) {
        ref.read(playerProvider.notifier).addListToQueue(tracks);
        // message(), not show(): this follows an await, and every argument
        // show() takes besides the text is discarded anyway. See the note on
        // AnimatedToast.show.
        AnimatedToast.message("Album added to queue");
      }
    },
    onFavorite: (pos) {
      final albumModel = Album(
        id: album.id.replaceFirst('album_', ''),
        title: album.title,
        image: album.image,
        releaseDate: album.releaseDate,
        recordType: 'album',
      );
      ref.read(libraryProvider.notifier).toggleAlbumLike(albumModel, album.artist);
      final isLiked = ref.read(libraryProvider.notifier).isAlbumLiked(album.title);
      AnimatedToast.show(
        context,
        text: isLiked ? "Added to Liked Albums" : "Removed from Liked Albums",
        icon: isLiked ? Icons.favorite : Icons.favorite_border,
        color: themeColor,
        startOffset: pos,
      );
    },
  );
}

// Helper to build mixed result items
Widget _buildMixedResultItem(String type, Song data, List<Song> allSongs, int index, Color themeColor) {
  switch (type) {
    case 'song':
      return _buildTrackTile(data, allSongs, index, themeColor);
    case 'artist':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: _buildArtistListItem(data),
      );
    case 'album':
      return _buildSwipeableAlbumTile(data, themeColor);
    case 'playlist':
      return _buildPlaylistListTile(data);
    default:
      return const SizedBox.shrink();
  }
}

Widget _buildTrackTile(Song song, List<Song> allSongs, int index, Color themeColor) {
return TweenAnimationBuilder<double>(
  key: ValueKey('search_anim_${song.id}'), // Crucial for performance and correctness
  duration: Duration(milliseconds: 300 + (index.clamp(0, 6) * 50)),
  tween: Tween(begin: 0.0, end: 1.0),
  builder: (context, value, child) => Opacity(
    opacity: value,
    child: Transform.translate(
      offset: Offset(0, 15 * (1 - value)),
      child: child,
    ),
  ),
  child: _SwipeableSearchTile(
    key: ValueKey('search_tile_${song.id}'),
    song: song,
    onTap: () {
      FocusScope.of(context).unfocus();
      HapticService.selection();
      _safeNavigate(() {
      ref.read(playerProvider.notifier).playSong(
        song,
        source: "Search",
      );
      },
      );
    },
    onQueue: (pos) {
      HapticService.medium();
      final wasAdded = ref.read(playerProvider.notifier).toggleQueue(song);
      AnimatedToast.show(context, text: wasAdded ? "Added to queue" : "Removed from queue", icon: wasAdded ? Icons.queue_music : Icons.remove_circle_outline, color: themeColor, startOffset: pos);
    },
    onPlaylist: (pos) => _handleAddToPlaylist(context, ref, song, pos),
    ),
  );
}

  // Helper to build artist list item (horizontal)
  Widget _buildArtistListItem(Song artist) {
    return InkWell(
      onTap: () {
      FocusScope.of(context).unfocus();
      HapticService.selection(); //
      _safeNavigate(() {
        AppNavigation.push(context, ArtistPage(artist: artist),
            name: AppNavigation.artistTag(artist));
        },
      );
      },
      child: Row(
        children: [
          ClipOval(
            child: AuvyImage(
              path: artist.image,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artist.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Text(
                  "Artist",
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white54),
        ],
      ),
    );
  }

  // CHANGE 6: Playlist list tile builder
  Widget _buildPlaylistListTile(Song playlist) {
    return ListTile(
      // Vertical from the density setting, not a literal. A ListTile's own
      // contentPadding REPLACES the themed one, so a hardcoded 8 here pinned the
      // row height at every density. See AppDensity for why that made the whole
      // setting look broken everywhere except the album page.
      contentPadding: EdgeInsets.symmetric(
          horizontal: 16, vertical: densityNow.rowVerticalPadding),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(8)),
        child: AuvyImage(
            path: playlist.image,
            width: densityNow.artwork(56),
            height: densityNow.artwork(56),
            fit: BoxFit.cover),
      ),
      title: Text(
        playlist.title,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        (playlist.songCount != null && playlist.songCount! > 0)
            ? "Playlist • ${playlist.songCount} tracks"
            : "Playlist • ${playlist.artist}",
        style: const TextStyle(color: Colors.white54, fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        FocusScope.of(context).unfocus();
        HapticService.selection();
        _safeNavigate(() {
        AppNavigation.push(
          context,
          PlaylistPage(
            externalId: playlist.id.replaceFirst('playlist_', ''),
            externalTitle: playlist.title,
            externalImage: playlist.image,
            externalSubtitle: "${playlist.songCount ?? 0} tracks",
            isAlbumView: false,
          ),
          name: AppNavigation.playlistTag(playlist.id.replaceFirst('playlist_', '')),
        );
        });
      },
    );
  }

  Widget _buildSliverSkeleton() {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(children: [
              const SkeletonLoader(width: 56, height: 56, borderRadius: 8),
              const SizedBox(width: 16),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SkeletonLoader(width: MediaQuery.of(context).size.width * 0.5, height: 16),
                const SizedBox(height: 8),
                SkeletonLoader(width: MediaQuery.of(context).size.width * 0.3, height: 12),
              ]),
            ]),
          ),
          childCount: 8,
        ),
      ),
    );
  }

  Widget _buildSearchBar(Color themeColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      // Rebuilds only on focus flips — drives the pill's accent treatment.
      child: AnimatedBuilder(
        animation: _searchFocusNode,
        builder: (context, child) {
          final focused = _searchFocusNode.hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: focused ? themeColor.withOpacity(0.35) : Colors.white.withOpacity(0.10),
              ),
              boxShadow: [
                BoxShadow(
                  color: themeColor.withOpacity(focused ? 0.10 : 0.0),
                  blurRadius: 18,
                  spreadRadius: -2,
                ),
              ],
            ),
            child: child,
          );
        },
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search, // Keyboard shows "Search"
          onSubmitted: (query) {
            if (query.trim().isNotEmpty) {
              HapticService.medium();
              // Save to history only when submitted from the search box.
              ref.read(searchProvider.notifier).saveSearch(query);

              String type = _selectedFilter == 'All' ? 'all' : _selectedFilter.toLowerCase().substring(0, _selectedFilter.length - 1);
              ref.read(searchProvider.notifier).performSearch(query, type: type);
              FocusScope.of(context).unfocus();
            }
          },
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: "What do you want to listen to?",
            hintStyle: const TextStyle(color: Colors.white60),
            prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, color: Colors.white38),
                    onPressed: () {
                      _searchController.clear();
                      ref.read(searchProvider.notifier).performSearch("");
                      setState(() {});
                    },
                  )
                // Idle state: the song recognition button. Tap = microphone (music in the room);
                // long-press = capture this device's audio (playing in another app). One control
                // for both, since the mic is what people use most. An InkWell handles both
                // gestures itself; a GestureDetector around an IconButton would lose the
                // long-press to the button's own tap recognizer.
                : Semantics(
                    button: true,
                    label: 'Identify song. Hold to capture this device\'s audio.',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => showSongRecognitionSheet(context),
                      onLongPress: () => showSongRecognitionSheet(context,
                          source: ListenSource.device),
                      child: Padding(
                        // Keeps the 48dp minimum touch target the IconButton gave
                        // us for free.
                        padding: const EdgeInsets.all(13.5),
                        // A neutral glyph rather than the Shazam logo: Auvy has no agreement with
                        // Shazam/Apple, so it shouldn't carry their trademark.
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 21,
                          color: themeColor.withOpacity(0.9),
                        ),
                      ),
                    ),
                  ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  // Search always shows one blended list; the results view groups Top Results /
  // Other across types. `_selectedFilter` stays at 'All'.

  // Idle state: moods, then recent searches. Both work with no network. (Artist
  // rails built from playback history had no real artist images to show, so there
  // isn't one.)

  Widget _buildRecentSearches(SearchState state, Color themeColor) {
    final recent = state.recentQueries.take(12).toList();

    // Most-recent artists, deduped, artwork required — straight from history.
    final history = ref.watch(playerProvider.select((s) => s.history));
    final seenArtists = <String>{};
    final artists = <({String name, String image})>[];
    for (final s in history) {
      final name = s.artist.split(',').first.trim();
      if (name.isEmpty || name.toLowerCase().startsWith('unknown')) continue;
      if (s.image.isEmpty) continue;
      if (seenArtists.add(name.toLowerCase())) {
        artists.add((name: name, image: s.image));
        if (artists.length >= 14) break;
      }
    }

    // Brand-new user: nothing to personalize with yet.
    if (recent.isEmpty && artists.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.travel_explore_rounded, size: 48, color: Colors.white.withOpacity(0.25)),
              const SizedBox(height: 12),
              Text("Find something to play",
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.7), fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text("Search songs, artists and albums",
                  style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 12.5)),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        // Browse by mood/genre — YouTube Music's own categories. Auvy had no
        // genre browsing at all before this; discovery was search or the home
        // feed, which meant no way to go looking for a vibe you can't name.
        Padding(
          // Breathing room above and below: this row sits directly under the
          // search bar now, and 4px looked cramped against it.
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
          child: GestureDetector(
            onTap: () {
              HapticService.selection();
              Navigator.push(context, MainLayout.smoothRoute(const MoodsPage()));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.07)),
              ),
              child: Row(children: [
                Icon(Icons.grid_view_rounded, size: 19, color: themeColor),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Moods & genres',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700)),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: Colors.white.withOpacity(0.35), size: 20),
              ]),
            ),
          ),
        ),
        if (recent.isNotEmpty) ...[
          _sectionHeader(
            "Recent searches",
            actionLabel: "Clear all",
            onAction: () => ref.read(searchProvider.notifier).clearHistory(),
          ),
          // A LIST, not a chip cloud. As history accumulates, wrapped pills
          // reflow into an untidy block of ragged rows that pushes everything
          // else off screen; rows scan top-to-bottom in recency order, stay
          // aligned however long the queries are, and give the remove button a
          // fixed place.
          for (final q in recent) _buildRecentRow(q),
        ],
      ]),
    );
  }

  /// YouTube Music's query completions for what's typed. Shows nothing while
  /// loading or on error, so nothing flickers next to the field as you type;
  /// suggestions are an accelerator, and their absence should be silent.
  Widget _buildSuggestions(Color themeColor) {
    // Only while the field has focus: after a search is submitted they'd just push
    // results down. Both submit paths unfocus, so this gives the right behaviour both
    // ways, and tapping the field again brings them back. Rebuilt via the focus
    // listener registered in initState.
    if (!_searchFocusNode.hasFocus) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final query = _searchController.text;
    final async = ref.watch(searchSuggestionsProvider(query));
    final items = async.asData?.value ?? const <String>[];

    // Drop a completion identical to what is already typed — it would look like
    // a row that does nothing.
    final shown = items
        .where((s) => s.toLowerCase() != query.trim().toLowerCase())
        .take(6)
        .toList();
    if (shown.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in shown) _buildSuggestionRow(s, themeColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
            child: Divider(color: Colors.white.withOpacity(0.07), height: 1),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionRow(String suggestion, Color themeColor) {
    return InkWell(
      // Same handler as a history row: fills the field, runs the search, and
      // records it, so a suggestion the user acted on becomes history like any
      // other query rather than being a special case.
      onTap: () => _handleRecentSearchTap(suggestion),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 11, 12, 11),
        child: Row(
          children: [
            Icon(Icons.search_rounded,
                size: 18, color: themeColor.withOpacity(0.75)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                suggestion,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 10),
            // Fills the field WITHOUT searching, so a suggestion can be used as a
            // starting point to refine — the standard behaviour of this glyph in
            // every search UI, and the reason it points up-left.
            Semantics(
              label: 'Use this suggestion',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _searchController.text = suggestion;
                  _searchController.selection = TextSelection.fromPosition(
                      TextPosition(offset: suggestion.length));
                  setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.north_west_rounded,
                      size: 16, color: Colors.white.withOpacity(0.4)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One recent-search row: a history glyph, the query, and a button that removes
  /// it. Tapping the row re-runs the search. Full width, so the remove button is
  /// always in the same place and long queries are truncated.
  Widget _buildRecentRow(String query) {
    return InkWell(
      onTap: () => _handleRecentSearchTap(query),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 11, 12, 11),
        child: Row(
          children: [
            Icon(Icons.history_rounded,
                size: 18, color: Colors.white.withOpacity(0.35)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                query,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 10),
            // Generous tap target — a 15px glyph alone was easy to miss and easy
            // to hit by accident when it sat inline in a pill.
            Semantics(
              label: 'Remove from search history',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    ref.read(searchProvider.notifier).removeHistoryItem(query),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.close_rounded,
                      color: Colors.white.withOpacity(0.35), size: 17),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildHorizontalCategory(String title, List<Song> items, Widget Function(Song) targetBuilder) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(title),
        SizedBox(
          height: 140,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: items.length,
            itemBuilder: (context, i) {
              if (title == "Featured Artists" || title == "Artists") return _buildArtistCircle(items[i]);
              
              return _PressableScale(
                onTap: () => AppNavigation.push(context, targetBuilder(items[i])),
                child: Container(
                  width: 100, margin: const EdgeInsets.only(right: 12),
                  child: Column(children: [
                    AuvyImage(path: items[i].image, width: 100, height: 100, borderRadius: 12),
                    const SizedBox(height: 8),
                    Text(items[i].title, style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // A round artist result that scales slightly when pressed.
  Widget _buildArtistCircle(Song artist) {
    return _PressableScale(
      onTap: () {
        HapticService.selection();
        _safeNavigate(() {
        AppNavigation.push(context, ArtistPage(artist: artist),
            name: AppNavigation.artistTag(artist));
        },
      );
      },
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            ClipOval(
              child: AuvyImage(path: artist.image, width: 80, height: 80, fit: BoxFit.cover),
            ),
            const SizedBox(height: 8),
            Text(
              artist.title,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Delegates to the shared sheet. See [showAddToPlaylistSheet]. Was one of five
  /// hand-rolled copies; this one carried its own create-playlist dialog too.
  void _handleAddToPlaylist(BuildContext context, WidgetRef ref, Song song, Offset tapPos) {
    showAddToPlaylistSheet(context, ref, song, ref.read(themeProvider),
        toastOrigin: tapPos);
  }
}

// Scales its child down slightly while pressed.
class _PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressableScale({required this.child, required this.onTap});
  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  double _scale = 1.0;
  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _scale,
      duration: const Duration(milliseconds: 100),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _scale = 0.95),
        onTapUp: (_) => setState(() => _scale = 1.0),
        onTapCancel: () => setState(() => _scale = 1.0),
        onTap: widget.onTap,
        child: widget.child,
      ),
    );
  }
}

class _SwipeableSearchTile extends ConsumerWidget {
  final Song song;
  final VoidCallback onTap;
  final Function(Offset) onQueue;
  final Function(Offset) onPlaylist;

  const _SwipeableSearchTile({super.key, required this.song, required this.onTap, required this.onQueue, required this.onPlaylist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    // Show the audio track's square cover + clean title once resolved; playback
    // still targets the original row (onTap) so queue logic is unchanged.
    final display = conformedForDisplay(ref, song);
    return SwipeActionTile(
      swipeId: song.id,
      onTap: onTap,
      // Press-and-hold opens the song options menu (same ContentMenu as home).
      // HoldToOpen inside SwipeActionTile fires the haptic as the charge lands.
      onLongPress: () => ContentMenus.showSongMenu(context, song, ref),
      flyImageUrl: display.image,
      // Queue is the LEFT pill on every page. See _SwipeableAlbumTrackTile.
      leftAction: SwipeAction(
        icon: Icons.queue_music_rounded,
        label: "QUEUE",
        color: const Color(0xFFFFD740),
        flyToMiniPlayer: true,
        onTap: (pos) => onQueue(pos),
      ),
      rightAction: SwipeAction(
        icon: Icons.playlist_add_rounded,
        label: "PLAYLIST",
        color: themeColor,
        onTap: (pos) => onPlaylist(pos),
      ),
      child: Container(
        color: Colors.transparent,
        child: ListTile(
          leading: Stack(
            children: [
              // Scaled: the cover is the row's real height floor, so trimming
              // padding alone could not make a compact row compact.
              AuvyImage(
                  path: display.image,
                  width: densityNow.artwork(56),
                  height: densityNow.artwork(56),
                  borderRadius: 8),
              NowPlayingArtOverlay(
                  rowId: song.id,
                  altId: display.id,
                  title: display.title,
                  artist: song.displayArtist,
                  duration: song.duration,
                  size: 56,
                  barSize: 12),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: NowPlayingTitle(
                  title: display.title,
                  rowId: song.id,
                  altId: display.id,
                  artist: song.displayArtist,
                  duration: song.duration,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          // EXPLICIT marker beside the artist. `ExplicitBadge` already existed in
          // the codebase but was never used ANYWHERE, so `Song.isExplicit` was
          // parsed, carried and stored, then never shown outside the song-details
          // sheet. That's why explicit and clean editions looked identical in
          // search results.
          subtitle: Row(
            children: [
              ExplicitBadge(isExplicit: song.isExplicit == true, size: 13),
              Expanded(
                child: Text(
                  song.displayArtist,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          // Stream/view count (e.g. "12M plays") when YouTube exposes it —
          // matches the album page. The options menu opens on press-and-hold
          // (long-press on the whole tile, wired below).
          trailing: () {
            final v = watchTrackViews(ref, song.id, song.viewCount);
            return v == null
                ? null
                : Text(v,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 11));
          }(),
        ),
      ),
    );
  }
}

class _SwipeableAlbumSearchTile extends ConsumerWidget {
  final Song album;
  final VoidCallback onTap;
  final Function(Offset) onQueue;
  final Function(Offset) onFavorite;

  const _SwipeableAlbumSearchTile({
    required this.album,
    required this.onTap,
    required this.onQueue,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return SwipeActionTile(
      swipeId: album.id,
      onTap: onTap,
      enableTapShrink: true,
      flyImageUrl: album.image,
      // Queue is the LEFT pill on every page. See _SwipeableAlbumTrackTile.
      leftAction: SwipeAction(
        icon: Icons.queue_music_rounded,
        label: "QUEUE",
        color: const Color(0xFFFFD740),
        flyToMiniPlayer: true,
        onTap: (pos) => onQueue(pos),
      ),
      rightAction: SwipeAction(
        icon: Icons.favorite,
        label: "LIKE",
        color: themeColor,
        onTap: (pos) => onFavorite(pos),
      ),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(8)),
              child: AuvyImage(
                path: album.image,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    "Album • ${album.artist}",
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
