import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:auvy/presentation/widgets/item_transfer_overlay.dart';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:auvy/presentation/widgets/cover_picker_sheet.dart';
import 'package:auvy/logic/download_helper.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/recent_playlists_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:auvy/logic/library_integrity.dart';
import 'package:auvy/logic/playlist_suggester.dart';
import 'package:auvy/providers/keep_fresh_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/fullscreen_artwork.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/presentation/widgets/undo_toast.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart'; 
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/services/external_catalog_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/track_download_overlay.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/providers/download_provider.dart';
import 'package:auvy/providers/density_provider.dart';

String getThemedIcon(String originalPath, String title, Color themeColor) {
  if (!originalPath.startsWith('assets/')) return originalPath;

  String suffix = "cyan";
  if (themeColor.value == Colors.purpleAccent.value) suffix = "purple";
  else if (themeColor.value == Colors.greenAccent.value) suffix = "green";
  else if (themeColor.value == Colors.orangeAccent.value) suffix = "orange";
  else if (themeColor.value == Colors.redAccent.value) suffix = "red";
  else if (themeColor.value == Colors.pinkAccent.value) suffix = "pink";

  if (title == "Liked Songs") return "assets/images/liked_songs_$suffix.webp";
  if (title == "My Top 50") return "assets/images/top_50_$suffix.webp";
  if (title == kWeeklyDiscoveryTitle) return "assets/images/weekly_discovery_$suffix.webp";
  // Both titles map here while the rename migration is pending. See the longer
  // note on the same mapping in library_page.dart.
  if (title == "Followed Artists" || title == "Your Artists") {
    return "assets/images/followed_artists_$suffix.webp";
  }
  if (title == "Followed Podcasts") {
    return "assets/images/followed_podcasts_$suffix.webp";
  }
  if (title == "Liked Albums") return "assets/images/liked_albums_$suffix.webp";
  if (title == "Liked Playlists") return "assets/images/playlist_$suffix.webp"; 
  if (title == "Cached") return "assets/images/cached_$suffix.webp";
  if (title == "Downloads") return "assets/images/download_$suffix.webp";

  return "assets/images/playlist_$suffix.webp";
}

final playlistTracksProvider = FutureProvider.family<List<Song>, String>((ref, id) async {
  // YouTube ids are the common case, so browse them first.
  final ytTracks = await ref.read(searchServiceProvider).getPlaylistTracks(id);
  if (ytTracks.isNotEmpty) return ytTracks;

  // Spotify playlist ids are bare 22-character base62 (no PL/VL/RDCLAK prefix).
  if (RegExp(r'^[0-9A-Za-z]{22}$').hasMatch(id)) {
    final tracks = await ExternalCatalogService().getPlaylistTracks(id);
    if (tracks.isNotEmpty) return tracks;
  }
  return ytTracks;
});


class PlaylistPage extends ConsumerStatefulWidget {
  final LibraryItem? libraryPlaylist;
  final String? externalId;
  final String? externalTitle;
  final String? externalImage;
  final String? externalSubtitle;
  final bool isAlbumView;
  /// An ad-hoc, read-only collection of tracks to display directly (no fetch,
  /// no library). Used by Home's "recently played" mosaic to open a title-only
  /// bundle as a proper playlist view — it has no fetchable playlist id, so the
  /// songs are handed in as-is. Pair with [externalTitle]/[externalImage].
  final List<Song>? localTracks;

  const PlaylistPage({
    super.key,
    this.libraryPlaylist,
    this.externalId,
    this.externalTitle,
    this.externalImage,
    this.externalSubtitle,
    this.isAlbumView = false,
    this.localTracks,
  });

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';

  /// The last "not editable" verdict logged, so it isn't repeated on every rebuild.
  /// See where it's assigned in [build].
  String? _lastEditabilityVerdict;

  /// "Don't sort" — show the collection in its OWN order. For a library playlist
  /// that is the order tracks were added; for My Top 50 it is play count; for a
  /// remote playlist it is the publisher's order. The sort menu offers it too, so
  /// choosing a sort is never a one-way door until the page is reopened.
  static const String _kDefaultSort = "Default";

  String _currentSort = _kDefaultSort;
  bool _isAscending = true;

  // Multi-select lives inside edit mode (entered from the app bar, not long-press,
  // which opens the track menu). In edit mode you can rename (tap the title),
  // reorder (drag the handle) and tick rows for bulk actions long-press can't do,
  // like queueing ten tracks at once. The gestures don't collide: the handle only
  // reacts to a drag that starts on it, and a tap elsewhere on the row ticks it.

  /// Reordering is edit-mode only, so a grab handle isn't sitting next to tap
  /// targets in a scrolling list, where tracks get nudged out of place by accident.
  bool _editMode = false;

  /// A cover picked in edit mode but not yet confirmed. Null means nothing is
  /// staged. See _stageCover for why this exists.
  String? _pendingCoverPath;

  /// Set after a successful rename. The page finds its playlist by TITLE, so
  /// the moment the name changes the original lookup matches nothing and the
  /// page would blank out. This keeps it pointed at the same playlist.
  String? _renamedTitle;


  /// Selected track ids. Ids, not indices — the list re-sorts and re-filters
  /// underneath, and indices would silently point at different tracks.
  final Set<String> _selectedIds = {};

  void _exitEditMode() {
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
  }
  bool _isQueued = false;

  /// The songs Keep fresh is rotating in this playlist, marked with a sparkle in
  /// their rows. Set from the provider in build.
  Set<String> _freshIds = const {};
  int _suggestionSeed = 0;
  final Set<String> _addedSuggestionIds = {};

  /// The track list as last rendered, so the RELATED-PLAYLISTS query can be
  /// built from this playlist's own contents. That request doesn't receive the
  /// tracks (unlike `_getTrackSuggestions`), which is how it ended up querying
  /// an arbitrary artist from global metadata instead.
  List<Song> _lastRenderedTracks = const [];

  /// The last completed suggestion set, kept so a refresh leaves the current rows on
  /// screen instead of collapsing the section to a spinner (which moved the scroll
  /// position). See `_buildSuggestionsSection`.
  List<Song>? _lastSuggestions;

  /// Ids already surfaced in this session, so a refresh reaches for new material
  /// instead of re-ranking the same winners. Bounded — a long session shouldn't
  /// starve the pool, and once it's this large there is plenty of variety anyway.
  final Set<String> _shownSuggestionIds = {};

  // Memoized suggestion futures. Handing FutureBuilder a fresh async closure
  // on every build meant EVERY page rebuild (each search keystroke, every
  // swipe setState) re-fired the whole multi-request suggestion pipeline and
  // flashed its loading spinner. Regenerate only when the seed changes.
  Future<List<Song>>? _trackSuggestionsFuture;
  int _trackSuggestionsSeed = -1;
  Future<List<dynamic>>? _playlistSuggestionsFuture;
  int _playlistSuggestionsSeed = -1;

  @override
  void initState() {
    super.initState();
    // Opening a playlist doesn't record it as recently played; only playing a track
    // from it does (see _recordPlayFromPlaylist, called from a track's onTap), so the
    // home mosaic doesn't list playlists that were merely browsed.
  }

  /// A track was PLAYED from this playlist → record the playlist in the Home
  /// "recently played" store AND remember that [playedSong] came from it, so the
  /// mosaic shows only the playlist tile (never the playlist AND the song). Skips
  /// ad-hoc local collections, albums (album_page handles those), and podcasts.
  void _recordPlayFromPlaylist(Song playedSong) {
    if (!mounted) return;
    if (widget.localTracks != null || widget.isAlbumView) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    RecentPlaylist? entry;

    if (widget.externalId != null) {
      final sub = (widget.externalSubtitle ?? '').toLowerCase();
      if (sub.contains('podcast')) return;
      entry = RecentPlaylist(
        externalId: widget.externalId,
        title: widget.externalTitle ?? 'Playlist',
        image: widget.externalImage ?? '',
        subtitle: widget.externalSubtitle ?? 'Playlist',
        playedAt: now,
      );
    } else if (widget.libraryPlaylist != null) {
      final item = widget.libraryPlaylist!;
      // System folders (Downloads/Cached/etc.) and podcasts aren't "playlists".
      if (item.isSystemFolder || item.subtitle.toLowerCase().contains('podcast')) {
        return;
      }
      entry = RecentPlaylist(
        libraryTitle: item.title,
        title: item.title,
        image: item.image,
        subtitle: item.subtitle,
        playedAt: now,
      );
    }

    if (entry != null) {
      final sig =
          '${playedSong.title.toLowerCase()}|${playedSong.artist.toLowerCase()}';
      ref.read(recentPlaylistsProvider.notifier).recordPlayedFrom(
            entry,
            songId: playedSong.id,
            songSig: sig,
          );
    }
  }

  /// Renames the playlist itself (not its tracks). Only reachable from edit mode and
  /// only for playlists the user owns (renamePlaylist refuses system folders, so the
  /// button is hidden for them).
  Future<void> _renamePlaylist(String currentTitle) async {
    final controller = TextEditingController(text: currentTitle);
    final themeColor = ref.read(themeProvider);
    final next = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Rename playlist",
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          // `onSubmitted` below already saves, so the action key needs to say
          // "done" rather than offering a newline in a one-line name field.
          textInputAction: TextInputAction.done,
          style: const TextStyle(color: Colors.white),
          maxLength: 60,
          decoration: InputDecoration(
            counterStyle: const TextStyle(color: Colors.white54, fontSize: 11),
            hintText: "Playlist name",
            hintStyle: const TextStyle(color: Colors.white54),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: themeColor, width: 2)),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white24)),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel",
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text("Save",
                style: TextStyle(
                    color: themeColor, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    ).whenComplete(() => Future.delayed(
        const Duration(milliseconds: 600), controller.dispose));
    if (!mounted || next == null) return;

    final ok = await ref
        .read(libraryProvider.notifier)
        .renamePlaylist(currentTitle, next);
    if (!mounted) return;
    if (ok) {
      setState(() => _renamedTitle = next.trim());
      AnimatedToast.show(context,
          text: "Renamed", icon: Icons.edit_rounded, color: themeColor);
    } else {
      // renamePlaylist refuses empties, no-ops, collisions and system folders.
      AnimatedToast.show(context,
          text: next.trim().isEmpty
              ? "Name cannot be empty"
              : "That name is already taken",
          icon: Icons.error_outline_rounded,
          color: Colors.orange);
    }
  }

  /// "Remove N duplicates", shown only when there are duplicates. Offered rather than
  /// done automatically, and it states the count. Duplicates happen when an import
  /// retry resolves the same song to a different video id (see
  /// LibraryNotifier.removeDuplicatesFromPlaylist for how they're matched).
  ///
  /// Returns a sliver (the empty case too), because the page body is a slivers array
  /// (see _buildPremiumSearchAndSort).
  Widget _buildDuplicateBanner(String title, Color themeColor) {
    final dupes =
        ref.read(libraryProvider.notifier).countDuplicatesInPlaylist(title);
    if (dupes <= 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverToBoxAdapter(
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: themeColor.withOpacity(0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: themeColor.withOpacity(0.30)),
        ),
        child: Row(
          children: [
            Icon(Icons.filter_none_rounded, color: themeColor, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                dupes == 1
                    ? '1 track appears twice in this playlist'
                    : '$dupes tracks appear more than once',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.82), fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: () {
                HapticService.selection();
                final removed = ref
                    .read(libraryProvider.notifier)
                    .removeDuplicatesFromPlaylist(title);
                if (removed > 0) {
                  AnimatedToast.message(
                      'Removed $removed duplicate${removed == 1 ? '' : 's'}');
                  // The banner reads from the provider, so a rebuild is what
                  // makes it disappear.
                  setState(() {});
                }
              },
              style: TextButton.styleFrom(foregroundColor: themeColor),
              child: const Text('Clean up'),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Offers the ready-made cover library first and the camera roll second, so
  /// picking good artwork is the easy option.
  Future<void> _chooseCover(String title) async {
    HapticService.light();
    final choice = await showModalBottomSheet<String>(
      context: context,
      // Same reason as the picker: keep the mini player behind the barrier.
      useRootNavigator: true,
      backgroundColor: AppColors.modalPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.auto_awesome_mosaic_rounded,
                  color: Colors.white70),
              title: const Text('Choose from Auvy covers',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('A curated set, searchable',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'library'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded,
                  color: Colors.white70),
              title: const Text('Choose from your photos',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'gallery') return _pickImage(title);

    final url = await showCoverPickerSheet(context);
    if (!mounted || url == null) return;
    await _applyCoverFromUrl(title, url);
  }

  /// Stages a cover chosen from the library, downloading it first. Not stored as a
  /// URL: the override store keeps a bounded PNG on disk and the bytes in a
  /// backed-up key, so the cover survives reinstalls and works offline.
  Future<void> _applyCoverFromUrl(String title, String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception(res.statusCode);

      final tmp = File(
          '${(await getTemporaryDirectory()).path}/cover_${DateTime.now().millisecondsSinceEpoch}.webp');
      await tmp.writeAsBytes(res.bodyBytes);
      if (!mounted) {
        try { await tmp.delete(); } catch (_) {}
        return;
      }
      _stageCover(tmp.path);
    } catch (_) {
      if (!mounted) return;
      AnimatedToast.show(context,
          text: "Couldn't download that cover",
          icon: Icons.cloud_off_rounded,
          color: Colors.orange);
    }
  }

  Future<void> _pickImage(String title) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile == null || !mounted) return;
      _stageCover(pickedFile.path);
    } catch (_) {
      // Was an empty catch, so a failed pick (permission denied, unreadable
      // file, encode error) looked exactly like the user quietly changing their
      // mind — tap the button, nothing happens, no reason given.
      if (!mounted) return;
      AnimatedToast.show(context,
          text: "Couldn't use that image",
          icon: Icons.broken_image_rounded,
          color: Colors.orange);
    }
  }

  /// Staged, not committed: the pick is held here and previewed in the header, and
  /// only written by [_commitPendingCover] when the check is pressed, so backing out
  /// of edit mode discards it.
  void _stageCover(String sourcePath) {
    // Replacing one staged pick with another: the earlier temp file is ours and
    // nothing points at it any more, so it goes now rather than being left for
    // the OS to reclaim whenever.
    _dropStagedFile();
    setState(() => _pendingCoverPath = sourcePath);
  }

  void _dropStagedFile() {
    final path = _pendingCoverPath;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Throw the staged pick away — the user left edit mode without confirming.
  void _discardPendingCover() {
    if (_pendingCoverPath == null) return;
    _dropStagedFile();
    _pendingCoverPath = null;
  }

  /// Write the staged pick into the override store. Called by the check.
  Future<void> _commitPendingCover(String title) async {
    final source = _pendingCoverPath;
    if (source == null) return;
    setState(() => _pendingCoverPath = null);
    try {
      final key = 'playlist:$title';
      final notifier = ref.read(artworkOverrideProvider.notifier);
      final ok = await notifier.setOverride(key, source);
      final durable = ref.read(artworkOverrideProvider)[key];
      try {
        final f = File(source);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
      if (!ok || durable == null) throw Exception("could not store cover");
      ref.read(libraryProvider.notifier).updatePlaylistImage(title, durable);
      if (!mounted) return;
      AnimatedToast.show(context,
          text: 'Cover art updated!',
          icon: Icons.image,
          color: ref.read(themeProvider));
    } catch (_) {
      if (!mounted) return;
      AnimatedToast.show(context,
          text: "Couldn't use that image",
          icon: Icons.broken_image_rounded,
          color: Colors.orange);
    }
  }

  @override
  void dispose() {
    // Left the page without pressing the check: the staged cover was never
    // meant to stick.
    _discardPendingCover();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScrollToSearch() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        360, // just past the (380px) header so the search field sits at top
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<List<dynamic>> _getPlaylistSuggestions() {
    if (_playlistSuggestionsFuture != null && _playlistSuggestionsSeed == _suggestionSeed) {
      return _playlistSuggestionsFuture!;
    }
    _playlistSuggestionsSeed = _suggestionSeed;
    final seed = _suggestionSeed;
    _playlistSuggestionsFuture = () async {
      final searchService = ref.read(searchServiceProvider);
      final intel = ref.read(intelligenceProvider);

      // Query from the playlist's own dominant artists, falling back to global taste
      // only when the playlist has nothing to say (empty, or tracks without artists).
      final fp = fingerprintPlaylist(_lastRenderedTracks);
      final seeds = <String>[
        ...fp.topArtists.take(2),
        if (fp.topArtists.isEmpty && intel.trackMetadata.isNotEmpty)
          intel.trackMetadata.values.first.artist,
      ];
      if (seeds.isEmpty) seeds.add('Mix');

      try {
        final batches = await Future.wait(
          seeds.map((q) async {
            try {
              return await searchService.search(q, 'playlist');
            } catch (_) {
              return <dynamic>[];
            }
          }),
        );
        final results = <dynamic>[];
        final seenTitles = <String>{};
        for (final b in batches) {
          for (final item in b) {
            // Overlapping artist queries return the same big playlists.
            final title = '${item.title}'.toLowerCase().trim();
            if (title.isEmpty || !seenTitles.add(title)) continue;
            results.add(item);
          }
        }
        results.shuffle(math.Random(seed));
        return results.take(5).toList();
      } catch (_) {
        return <dynamic>[];
      }
    }();
    return _playlistSuggestionsFuture!;
  }



  Future<List<Song>> _getTrackSuggestions(List<Song> existingTracks) {
    if (_trackSuggestionsFuture != null && _trackSuggestionsSeed == _suggestionSeed) {
      return _trackSuggestionsFuture!;
    }
    _trackSuggestionsSeed = _suggestionSeed;
    final seed = _suggestionSeed;
    _trackSuggestionsFuture = () async {
      final out = await suggestTracksForPlaylist(
        search: ref.read(searchServiceProvider),
        intel: ref.read(intelligenceProvider.notifier),
        existing: existingTracks,
        seed: seed,
        exclude: _addedSuggestionIds,
        avoid: _shownSuggestionIds,
      );
      // Remember what this round produced so the NEXT refresh reaches past it.
      // Cleared when it grows large: by then the pool has been well explored, and
      // an ever-growing exclusion set would eventually starve the section.
      if (_shownSuggestionIds.length > 120) _shownSuggestionIds.clear();
      _shownSuggestionIds.addAll(out.take(8).map((s) => s.id));
      return out;
    }();
    return _trackSuggestionsFuture!;
  }

  List<Song> _applyFilterAndSort(List<Song> tracks) {
    List<Song> results;
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      results = tracks.where((s) => 
        s.title.toLowerCase().contains(query) || 
        s.artist.toLowerCase().contains(query)
      ).toList(); 
    } else {
      results = List<Song>.from(tracks); 
    }

    // Default means "don't sort": return the source order. Dart's List.sort isn't
    // stable, so a comparator returning 0 could permute the list. The source order is
    // each collection's own (added order for a library playlist, play-count order for
    // My Top 50).
    if (_currentSort == _kDefaultSort) return results;

    // Sort keys are lowercased once per track, not once per comparison: this runs from
    // build(), and lowercasing inside the comparator allocated thousands of strings
    // per sort. (There's no "recently added" sort: tracks are appended, so Default
    // already shows added order.)
    String keyOf(Song s) {
      switch (_currentSort) {
        case "Title":
          return s.title.toLowerCase();
        case "Artist":
          return s.artist.toLowerCase();
        case "Album":
          return s.albumTitle.toLowerCase();
      }
      return '';
    }

    final keys = <String, String>{for (final s in results) s.id: keyOf(s)};
    results.sort((a, b) {
      final cmp = (keys[a.id] ?? '').compareTo(keys[b.id] ?? '');
      return _isAscending ? cmp : -cmp;
    });
    // Said once per (sort, size) rather than per build: the point is to prove
    // this path is not re-sorting on every frame, and a line per rebuild would
    // be the noise it is meant to detect.
    if (_lastSortLogged != '$_currentSort/${results.length}/$_isAscending') {
      _lastSortLogged = '$_currentSort/${results.length}/$_isAscending';
      print('playlist sorted by $_currentSort '
          '(${results.length} tracks, ${_isAscending ? "asc" : "desc"}) — '
          '${results.length} keys built, not ${results.length * 2} per compare');
    }

    return results;
  }

  /// The last (sort, size, direction) logged, so the log line only appears when the
  /// sort changes.
  String _lastSortLogged = '';

  void _sharePlaylist(String title, String image, String subtitle) {
    final themeColor = ref.read(themeProvider);
    // The real playlist id, so the postcard can print a link. `externalId` is the
    // catalogue id for a remote playlist; a local playlist has none, and an empty
    // string correctly yields no link.
    final playlistSong = Song(
      id: widget.externalId ?? '',
      title: title,
      artist: subtitle,
      image: image,
    );
    showSharePostcardDialog(context, playlistSong, themeColor,
        kind: PostcardKind.playlist);
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider); 
    final isShuffleOn = ref.watch(playerProvider.select((s) => s.isShuffle));
    final libState = ref.watch(libraryProvider);
    
    final bool isExternal = widget.externalId != null;
    final bool isLocal = widget.localTracks != null;
    // "Remote" = anything that is NOT a real library folder: a fetched external
    // playlist OR an ad-hoc local collection (Home's recently-played bundle).
    // Both are read-only and never touch the library.
    final bool isRemote = isExternal || isLocal;

    final currentLibItem = !isRemote ? libState.allItems.cast<LibraryItem?>().firstWhere(
      (i) => i?.title == (_renamedTitle ?? widget.libraryPlaylist!.title),
      orElse: () => widget.libraryPlaylist
    ) : null;

    final String title = isRemote ? (widget.externalTitle ?? 'Playlist') : currentLibItem!.title;
    String subtitle = isRemote ? (widget.externalSubtitle ?? '') : currentLibItem!.subtitle;
    if (isRemote && (subtitle.contains('0 songs') || subtitle.contains('0 tracks'))) {
      subtitle = "";
    }
    // Read the live item from `libState` (`currentLibItem`), not
    // `widget.libraryPlaylist`, which was captured when the page was pushed, so a new
    // cover shows immediately.
    final String image = isRemote
        ? (widget.externalImage ?? '')
        : (currentLibItem?.image ?? widget.libraryPlaylist!.image);

    bool isDownloadFolder = !isRemote && title == "Downloads";
    bool isCachedFolder = !isRemote && title == "Cached";

    List<Song> tracks = [];
    AsyncValue<List<Song>>? externalTracksAsync;

    if (isLocal) {
      // Ad-hoc collection: show exactly the tracks we were handed, no fetch.
      tracks = widget.localTracks!;
    } else if (isExternal) {
      externalTracksAsync = ref.watch(playlistTracksProvider(widget.externalId!));
      tracks = externalTracksAsync?.value ?? [];
    } else {
      if (title == "Liked Songs") {
        tracks = libState.likedSongs;
      } else if (title == "My Top 50") {
        // Same shared ranking (by real listen count) the library folder uses,
        // so the list and its song-count subtitle always match.
        final intel = ref.read(intelligenceProvider);
        tracks = computeTop50(intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
      } else if (isCachedFolder) {
        tracks = AudioCacheManager().getCachedTracksSorted();
      } else if (isDownloadFolder) {
        tracks = libState.playlistSongs["Downloads"] ?? [];
      } else {
        tracks = libState.playlistSongs[title] ?? [];
      }
    }

    final filteredTracks = _applyFilterAndSort(tracks);
    final themedIconPath = isRemote ? image : getThemedIcon(image, title, themeColor);

    final bool isPodcast = subtitle.toLowerCase().contains('podcast');
    // Whether this is a built-in folder is decided by the known set
    // (kSystemLibraryTitles), not only by the stored `isSystemFolder` flag, which can
    // be wrong. The flag must also be set, so this only ever grants editing that was
    // wrongly withheld.
    final bool rowIsBuiltIn = (currentLibItem?.isSystemFolder ?? true) &&
        kSystemLibraryTitles.contains(currentLibItem?.title ?? '');
    final bool isEditable = !isRemote && !rowIsBuiltIn && !isPodcast;
    final freshEntry = isEditable
        ? ref.watch(keepFreshProvider.select((s) => s.playlists[title]))
        : null;
    _freshIds = freshEntry?.suggestionIds.toSet() ?? const {};
    // Logged once per playlist (and again only if the verdict changes), not on every
    // rebuild.
    if (!isEditable) {
      final verdict = 'playlist "${currentLibItem?.title ?? "?"}" NOT editable: '
          'isRemote=$isRemote (external=$isExternal local=$isLocal) '
          'flag=${currentLibItem?.isSystemFolder} '
          'knownBuiltIn=${kSystemLibraryTitles.contains(currentLibItem?.title ?? '')} '
          'isPodcast=$isPodcast';
      if (verdict != _lastEditabilityVerdict) {
        _lastEditabilityVerdict = verdict;
        print(verdict);
      }
    }
    // Local ad-hoc collections aren't downloadable (no library entry to attach
    // to); only genuine external playlists and editable library ones are.
    final bool showDownload = isExternal || isEditable;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: CustomScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Header. Gets the tracks (not just their count) so it can show the
            // total running time.
            _buildPremiumHeader(title, subtitle, themedIconPath, isEditable, themeColor, filteredTracks),

            // SEARCH & ACTION ROW (Pass the new flag here!)
            // While selecting, the batch bar REPLACES the Play row rather than
            // sitting beside it — the two would compete for the same tap, and
            // "Play" during a selection has no obvious meaning.
            if (_editMode)
              _buildSelectionBar(themeColor, filteredTracks, title,
                  isEditable || title == "Liked Songs")
            else
              _buildPremiumActionRow(themeColor, filteredTracks, isShuffleOn, title, isExternal, image, subtitle, showDownload,
                  canKeepFresh: isEditable, freshOn: freshEntry != null),

            // Offered only when there is something to remove, and it says how
            // many. See _buildDuplicateBanner.
            if (_editMode && isEditable)
              _buildDuplicateBanner(title, themeColor),

            _buildPremiumSearchAndSort(),

            // TRACK LIST
            _buildTracksList(filteredTracks, title, isRemote, externalTracksAsync, isPodcast),

            if (!isRemote && !isPodcast)
              if (title == "Liked Playlists")
                _buildPlaylistSuggestionsSection(title, themeColor)
              else if (filteredTracks.isNotEmpty && title != "Downloads" && title != "Cached" && title != "My Top 50" && title != kWeeklyDiscoveryTitle)
                _buildSuggestionsSection(filteredTracks, title, themeColor),

            SliverToBoxAdapter(
              child: SizedBox(
                  height: ref.watch(playerProvider
                              .select((p) => p.currentSong != null))
                      ? 100
                      : 20),
            ),
          ],
        ),
      ),
    );
  }


  /// Opens the downloads folder in the user's file manager via a native intent, so
  /// the OEM's own file app can be tried first (url_launcher can only fire a plain
  /// ACTION_VIEW, which Google's Files claims). See MainActivity.openFolder.
  Future<bool> _openDownloadsFolder() async {
    try {
      return await const MethodChannel('com.auvy.app/folder')
              .invokeMethod<bool>('open',
                  {'path': '/storage/emulated/0/Music/Auvy'}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The overline word, mirroring the album header's record-type line.
  ///
  /// The built-in collections aren't playlists in any meaningful sense, and
  /// labelling Downloads "PLAYLIST" was the kind of small lie that makes a UI
  /// feel generated rather than designed.
  String _collectionKind(String title) {
    switch (title) {
      case 'Downloads':
        return 'Downloaded';
      case 'Cached':
        return 'Cached';
      case 'Liked Songs':
        return 'Liked';
      case 'My Top 50':
        return 'Your top tracks';
      case 'Your Artists':
        return 'Artists';
      default:
        return 'Playlist';
    }
  }

  /// Seconds from a duration string: "m:ss", "h:mm:ss", or raw seconds. 0 when
  /// nothing parses.
  int _durationSeconds(String raw) {
    final d = raw.trim();
    if (d.isEmpty) return 0;
    if (!d.contains(':')) return int.tryParse(d) ?? 0;
    final parts = d.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  /// Total running time of the collection ("1 hr 12 min" / "43 min"), recomputed from
  /// the live track list on every build. Some rows have no duration (imported files,
  /// older saved rows), so the label is prefixed with "~" when a track didn't
  /// contribute.
  String _totalDurationLabel(List<Song> tracks) {
    int total = 0;
    int counted = 0;
    for (final t in tracks) {
      final secs = _durationSeconds(t.duration);
      if (secs <= 0) continue;
      total += secs;
      counted++;
    }
    if (total <= 0) return '';
    final String body;
    if (total < 60) {
      body = '$total sec';
    } else {
      final h = total ~/ 3600;
      final m = (total % 3600) ~/ 60;
      body = h > 0 ? '$h hr $m min' : '$m min';
    }
    return counted == tracks.length ? body : '~$body';
  }

  /// Playlist header in the same style as [AlbumPage]: a left-aligned row with
  /// the cover beside a metadata column (small-caps overline, title, muted meta
  /// line). Differences from the album header: a smaller cover (128 vs 148),
  /// since a playlist cover labels a container rather than being a record's
  /// artwork; no artist row; the edit affordance; and an overline naming the
  /// collection ("PLAYLIST", "DOWNLOADS"…).
  Widget _buildPremiumHeader(String title, String subtitle, String imagePath,
      bool isEditable, Color themeColor, List<Song> tracks) {
    final int trackCount = tracks.length;
    final String durationLabel = _totalDurationLabel(tracks);
    // Expanded header height, derived from the same numbers the padding uses (top
    // inset + toolbar + 128 cover + 18), because the top inset differs between devices
    // (e.g. Dynamic Island).
    final double expanded = MediaQuery.of(context).padding.top +
        kToolbarHeight -
        6 + // the padding below trims 6 off the toolbar allowance
        128 + // the cover
        18; // bottom breathing room
    // Stored subtitles often already end in their own "N songs/tracks" chunk
    // (LibraryItem subtitles do), which doubled up with the live count below:
    // "PLAYLIST • 6 SONGS • 6 SONGS". Strip it — the live count is the one
    // that matches the rendered list.
    final baseSubtitle = subtitle
        .replaceAll(RegExp(r'\s*[•·]?\s*\d+\s+(songs?|tracks?)\s*$', caseSensitive: false), '')
        .trim();
    final String meta = [
      if (baseSubtitle.isNotEmpty) baseSubtitle,
      if (trackCount > 0) trackCount == 1 ? '1 song' : '$trackCount songs',
      if (durationLabel.isNotEmpty) durationLabel,
    ].join('  •  ');

    return SliverAppBar(
      expandedHeight: expanded,
      pinned: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: _CircleGlassButton(
        icon: Icons.arrow_back_rounded,
        onTap: () => Navigator.pop(context),
      ),
      actions: [
        // Edit is available for every playlist the user can change, not only ones with
        // something to reorder: edit mode also holds rename, cover art and bulk selection.
        // The button stays visible regardless of the search filter.
        if (isEditable || title == "Liked Songs")
          _CircleGlassButton(
            icon: _editMode ? Icons.check_rounded : Icons.edit_rounded,
            onTap: () {
              // The check is the commit point for the cover.
              // Leaving edit mode any other way (back out of the page) discards
              // the staged pick in dispose — an edit you can abandon.
              if (_editMode && _pendingCoverPath != null) {
                _commitPendingCover(title);
              }
              HapticService.selection();
              setState(() {
                _editMode = !_editMode;
                // Leaving edit mode drops any ticks with it — a selection that
                // survived into normal browsing would act on rows the user can
                // no longer see is selected.
                if (!_editMode) _selectedIds.clear();
              });
            },
          ),
        _CircleGlassButton(
          icon: Icons.ios_share_rounded,
          onTap: () => _sharePlaylist(title, imagePath, subtitle),
        ),
        if (title == "Downloads")
          _CircleGlassButton(
            icon: Icons.folder_open_rounded,
            // Opens the folder instead of just showing its path.
            onTap: () async {
              HapticService.selection();
              final opened = await _openDownloadsFolder();
              if (!opened) {
                // No file manager answered the intent: tell the user where the files are.
                AnimatedToast.message('Saved in Music/Auvy on this device');
              }
            },
          ),
        const SizedBox(width: 8),
      ],
      // No blur here: the page already sits on the blurred DynamicBackground, and
      // re-blurring the cover on every collapse frame caused jank.
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final double topPad = MediaQuery.of(context).padding.top;
          final double collapsedH = kToolbarHeight + topPad;
          // 1.0 fully expanded → 0.0 fully collapsed.
          final double t = ((constraints.maxHeight - collapsedH) /
                  (expanded - collapsedH))
              .clamp(0.0, 1.0);
          final double contentOpacity = Curves.easeIn.transform(t);
          final double barOpacity = 1.0 - Curves.easeOut.transform((t * 2).clamp(0.0, 1.0));

          return Stack(
            fit: StackFit.expand,
            children: [
              // Soft theme wash for depth (cheap — a single gradient).
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      themeColor.withOpacity(0.22 * contentOpacity),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              // Expanded header content.
              Opacity(
                opacity: contentOpacity,
                child: OverflowBox(
                  minHeight: expanded,
                  maxHeight: expanded,
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    // Bottom-aligned row, matching the album header's rhythm so
                    // the two pages sit at the same optical height.
                    padding: EdgeInsets.fromLTRB(
                        20, topPad + kToolbarHeight - 6, 20, 18),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Stack(
                              children: [
                                // Tap the cover to see it full screen, as on artist and album headers. A pending
                                // cover pick is shown, not the saved one it's replacing.
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    final cover = _pendingCoverPath ?? imagePath;
                                    if (cover.isEmpty) return;
                                    HapticService.light();
                                    showFullScreenArtwork(
                                      context,
                                      path: cover,
                                      caption: title,
                                    );
                                  },
                                  child: Container(
                                  width: 128,
                                  height: 128,
                                  decoration: BoxDecoration(
                                    // Rounder than the album's 20. An album cover
                                    // is a reproduction of a physical sleeve, so
                                    // it wants to stay square-ish; a playlist
                                    // cover is a soft container label, and the
                                    // extra curvature is a quiet way to tell the
                                    // two apart at a glance.
                                    borderRadius: BorderRadius.circular(28),
                                    border: Border.all(
                                        color: Colors.white.withOpacity(0.08)),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black.withOpacity(0.5),
                                          blurRadius: 24,
                                          offset: const Offset(0, 10)),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(28)),
                                    child: AuvyImage(
                                       // The staged pick previews in place
                                       // of the saved cover until it is confirmed.
                                       path: _pendingCoverPath ?? imagePath,
                                        width: 128,
                                        height: 128,
                                        fit: BoxFit.cover),
                                  ),
                                  ),
                                ),
                                // Editing the cover is edit-mode only, like rename and reorder, so a stray tap
                                // while browsing can't open the cover picker.
                                if (isEditable && _editMode)
                                  Positioned(
                                    bottom: 6,
                                    right: 6,
                                    child: Semantics(
                                      label: 'Change cover',
                                      button: true,
                                      child: GestureDetector(
                                        onTap: () => _chooseCover(title),
                                        child: Container(
                                          padding: const EdgeInsets.all(7),
                                          decoration: BoxDecoration(
                                              color: themeColor,
                                              shape: BoxShape.circle,
                                              boxShadow: const [
                                                BoxShadow(
                                                    color: Colors.black54,
                                                    blurRadius: 8)
                                              ]),
                                          child: const Icon(Icons.edit_rounded,
                                              color: Colors.black, size: 14),
                                        ),
                                      ),
                                    ),
                                  )
                              ],
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Same small-caps voice as the album's
                                  // ALBUM / SINGLE / EP overline.
                                  Text(
                                    _collectionKind(title).toUpperCase(),
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.66),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 2.4),
                                  ),
                                  const SizedBox(height: 6),
                                  // In edit mode the name itself is the rename control, with a pencil so it's
                                  // visibly tappable.
                                  GestureDetector(
                                    onTap: (_editMode && isEditable)
                                        ? () => _renamePlaylist(title)
                                        : null,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            title,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 21,
                                                fontWeight: FontWeight.w800,
                                                height: 1.15),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (_editMode && isEditable) ...[
                                          const SizedBox(width: 8),
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 4),
                                            child: Icon(
                                                Icons
                                                    .drive_file_rename_outline_rounded,
                                                size: 17,
                                                color: themeColor),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (meta.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      meta,
                                      style: TextStyle(
                                          color: Colors.white.withOpacity(0.72),
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Collapsed pinned bar: scrim + centered small title fade in.
              IgnorePointer(
                child: Opacity(
                  opacity: barOpacity,
                  child: Container(
                    color: Colors.black.withOpacity(0.55),
                    padding: EdgeInsets.only(top: topPad),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 64),
                      child: Text(
                        title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Batch actions over the current selection, replacing the Play pill while
  /// [_editMode] is on. "Remove" only appears for lists the user owns (not someone
  /// else's playlist or My Top 50).
  Widget _buildSelectionBar(
      Color themeColor, List<Song> filteredTracks, String title, bool canRemove) {
    final selected = filteredTracks
        .where((s) => _selectedIds.contains(s.id))
        .toList(growable: false);
    final n = selected.length;
    final allSelected = n > 0 && n == filteredTracks.length;

    void done() => _exitEditMode();

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(n == 0 ? 'Select tracks' : '$n selected',
                    style: TextStyle(
                        color: n == 0 ? Colors.white54 : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    HapticService.selection();
                    setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(filteredTracks.map((s) => s.id));
                      }
                    });
                  },
                  child: Text(allSelected ? 'Clear' : 'All',
                      style: TextStyle(
                          color: themeColor, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: done,
                  child: const Text('Done',
                      style: TextStyle(
                          color: Colors.white70, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _ActionIcon(
                  icon: Icons.queue_play_next_rounded,
                  color: n == 0 ? Colors.white24 : Colors.white.withOpacity(0.85),
                  disabled: n == 0,
                  onTap: () {
                    HapticService.medium();
                    // Reversed: addToQueueNext puts each track immediately after
                    // the current one, so inserting in order would play the
                    // selection backwards.
                    for (final s in selected.reversed) {
                      if (!ref
                          .read(listenTogetherProvider.notifier)
                          .requestQueueAdd(s, playNext: true)) {
                        ref.read(playerProvider.notifier).addToQueueNext(s);
                      }
                    }
                    AnimatedToast.message('$n playing next');
                    done();
                  },
                ),
                const SizedBox(width: 10),
                _ActionIcon(
                  icon: Icons.queue_music_rounded,
                  color: n == 0 ? Colors.white24 : Colors.white.withOpacity(0.85),
                  disabled: n == 0,
                  onTap: () {
                    HapticService.medium();
                    ref.read(playerProvider.notifier).addListToQueue(selected);
                    AnimatedToast.message('$n added to queue');
                    done();
                  },
                ),
                const SizedBox(width: 10),
                _ActionIcon(
                  icon: Icons.library_add_rounded,
                  color: n == 0 ? Colors.white24 : Colors.white.withOpacity(0.85),
                  disabled: n == 0,
                  onTap: () async {
                    HapticService.selection();
                    // One picker for the whole selection, then add each — the
                    // shared sheet is single-track, so the pick happens here.
                    final target = await _pickPlaylistForBatch(themeColor);
                    if (target == null) return;
                    var added = 0;
                    for (final s in selected) {
                      if (ref
                          .read(libraryProvider.notifier)
                          .addSongToPlaylist(target, s)) {
                        added++;
                      }
                    }
                    AnimatedToast.message(added == n
                        ? '$added added to $target'
                        : '$added added · ${n - added} already there');
                    done();
                  },
                ),
                const SizedBox(width: 10),
                _ActionIcon(
                  icon: Icons.download_rounded,
                  color: n == 0 ? Colors.white24 : Colors.white.withOpacity(0.85),
                  disabled: n == 0,
                  onTap: () {
                    HapticService.medium();
                    AnimatedToast.message('Downloading $n…');
                    DownloadHelper.downloadCollection(
                      selected,
                      downloadType: widget.isAlbumView ? 'Album' : 'Playlist',
                      collectionName: title,
                    ).then((r) => AnimatedToast.message(r.summary));
                    done();
                  },
                ),
                if (canRemove) ...[
                  const SizedBox(width: 10),
                  _ActionIcon(
                    icon: Icons.delete_outline_rounded,
                    color: n == 0 ? Colors.white24 : Colors.redAccent,
                    disabled: n == 0,
                    onTap: () {
                      HapticService.heavy();
                      final lib = ref.read(libraryProvider.notifier);
                      for (final s in selected) {
                        if (title == "Liked Songs") {
                          lib.toggleSongLike(s);
                        } else {
                          lib.removeSongFromPlaylist(title, s.id);
                        }
                      }
                      AnimatedToast.message('$n removed');
                      done();
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Which playlist should a whole selection go into? A compact one-shot picker;
  /// the shared add-to-playlist sheet is per-track by design.
  Future<String?> _pickPlaylistForBatch(Color themeColor) {
    final playlists = ref
        .read(libraryProvider)
        .allItems
        .where((i) =>
            !i.isSystemFolder && i.category == LibraryCategory.playlist)
        .toList();
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.modalPanel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text('Add selection to…',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
            ),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 26),
                child: Text('No playlists yet.',
                    style: TextStyle(color: Colors.white54)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (_, i) {
                    final p = playlists[i];
                    return ListTile(
                      leading: AuvyImage(
                          path: p.image,
                          width: densityNow.artwork(42),
                          height: densityNow.artwork(42),
                          borderRadius: 8),
                      title: Text(p.title,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600)),
                      onTap: () => Navigator.pop(ctx, p.title),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openKeepFreshSheet(String title, Color themeColor) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.modalPanel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _KeepFreshSheet(title: title, themeColor: themeColor),
    );
  }

  /// The listener's songs in a playlist, counting any Keep fresh is resting.
  int _ownSongCount(String title) {
    final lib = ref.read(libraryProvider);
    final rotating = ref.read(keepFreshProvider).playlists[title]?.suggestionIds ?? const [];
    final inList = (lib.playlistSongs[title] ?? const <Song>[])
        .where((s) => !rotating.contains(s.id))
        .length;
    return inList + (lib.playlistSongs[freshReserveKey(title)]?.length ?? 0);
  }

  Future<void> _toggleKeepFresh(String title, Color themeColor) async {
    final notifier = ref.read(keepFreshProvider.notifier);
    if (ref.read(keepFreshProvider).busy.contains(title)) return;
    HapticService.selection();
    if (notifier.isOn(title)) {
      await notifier.disable(title);
      if (!mounted) return;
      AnimatedToast.show(context,
          text: 'Keep fresh off: all your songs are back',
          icon: Icons.auto_awesome_outlined,
          color: themeColor);
      return;
    }
    if (_ownSongCount(title) < KeepFreshNotifier.minOwnSongs) {
      AnimatedToast.show(context,
          text: 'Keep fresh needs at least ${KeepFreshNotifier.minOwnSongs} songs',
          icon: Icons.info_outline_rounded,
          color: themeColor);
      return;
    }
    final filled = await notifier.enable(title, FreshCadence.weekly);
    if (!mounted) return;
    final swapped = ref.read(keepFreshProvider).playlists[title]?.suggestionIds.length ?? 0;
    AnimatedToast.show(context,
        text: filled
            ? 'Keep fresh on: $swapped new songs in, swapped every Monday. Hold ✦ for options'
            : 'Keep fresh on: new songs will arrive when suggestions can be fetched',
        icon: Icons.auto_awesome_rounded,
        color: themeColor);
  }

  Future<void> _keepSuggestion(String title, Song song) async {
    HapticService.selection();
    await ref.read(keepFreshProvider.notifier).keep(title, song.id);
    if (!mounted) return;
    AnimatedToast.show(context,
        text: 'Kept in $title',
        icon: Icons.check_rounded,
        color: ref.read(themeProvider));
  }

  Widget _buildPremiumActionRow(Color themeColor, List<Song> filteredTracks, bool isShuffleOn, String title, bool isExternal, String image, String subtitle, bool showDownload,
      {bool canKeepFresh = false, bool freshOn = false}) {
    // select(), so this row doesn't rebuild on every PlayerState write.
    final isThisPlaylistActive =
        ref.watch(playerProvider.select((s) => s.playbackSource == title));
    final isPlaying =
        ref.watch(playerProvider.select((s) => s.isPlaying)) && isThisPlaylistActive;
    final isLiked = ref.watch(libraryProvider.select((s) => s.likedPlaylists.any((p) => p.title == title)));

    // Layout matches the album page: Play leads as a full-width pill, and secondary
    // actions follow as equal circles (Play · Shuffle · Queue · Like · Download). The
    // pill doubles as pause, since a playlist page can be what's playing.
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (filteredTracks.isNotEmpty) {
                    final player = ref.read(playerProvider.notifier);
                    if (!isThisPlaylistActive) {
                      // `source` is the kind of place ("PLAYING FROM PLAYLIST") and `locationName` its
                      // name; the header shows them as two lines.
                      if (ref.read(playerProvider).isShuffle) {
                        final shuffled = List<Song>.from(filteredTracks)..shuffle();
                        _recordPlayFromPlaylist(shuffled.first);
                        player.playSong(shuffled.first,
                            newQueue: shuffled,
                            source: "Playlist",
                            locationName: title,
                            contextId: title,
                            contextType: 'playlist',
                            contextTitle: title);
                      } else {
                        _recordPlayFromPlaylist(filteredTracks.first);
                        player.playSong(filteredTracks.first,
                            newQueue: filteredTracks,
                            source: "Playlist",
                            locationName: title,
                            contextId: title,
                            contextType: 'playlist',
                            contextTitle: title);
                      }
                    } else {
                      if (!ref
                          .read(listenTogetherProvider.notifier)
                          .scheduleToggle()) {
                        player.togglePlay();
                      }
                    }
                    HapticService.light();
                  }
                },
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: themeColor, borderRadius: BorderRadius.circular(23)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: AppColors.matteBlack, size: 22),
                      const SizedBox(width: 6),
                      Text(isPlaying ? "Pause" : "Play",
                          style: const TextStyle(
                              color: AppColors.matteBlack,
                              fontWeight: FontWeight.w800,
                              fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _ActionIcon(
              icon: Icons.shuffle_rounded,
              color: isShuffleOn && isThisPlaylistActive
                  ? themeColor
                  : Colors.white.withOpacity(0.85),
              onTap: () {
                if (filteredTracks.isEmpty) return;
                final player = ref.read(playerProvider.notifier);
                // Shuffle the list before handing it to playSong, so the result doesn't depend on
                // the global shuffle flag or on reordering the previous queue.
                final shuffled = List<Song>.from(filteredTracks)..shuffle();
                player.setShuffle(true);
                _recordPlayFromPlaylist(shuffled.first);
                player.playSong(shuffled.first,
                    newQueue: shuffled,
                    source: "Playlist",
                    locationName: title,
                    contextId: title,
                    contextType: 'playlist',
                    contextTitle: title);
                HapticService.medium();
              },
            ),
            if (canKeepFresh) ...[
              const SizedBox(width: 10),
              // One tap turns Keep fresh on or off; a long press opens its settings.
              _ActionIcon(
                icon: Icons.auto_awesome_rounded,
                color: freshOn ? themeColor : Colors.white.withOpacity(0.85),
                onTap: () => _toggleKeepFresh(title, themeColor),
                onLongPress: () {
                  HapticService.medium();
                  _openKeepFreshSheet(title, themeColor);
                },
              ),
            ],
            const SizedBox(width: 10),
            _ActionIcon(
              icon: Icons.queue_music_rounded,
              color: _isQueued ? themeColor : Colors.white.withOpacity(0.85),
              onTap: () async {
                if (filteredTracks.isEmpty) return;
                HapticService.medium();
                final notifier = ref.read(playerProvider.notifier);
                // The toast reports what actually happened: [removeListFromQueue] returns a count,
                // including when nothing matched.
                if (_isQueued) {
                  final removed =
                      await notifier.removeListFromQueue(filteredTracks);
                  // BOTH guards, because both things are used after the await.
                  // `mounted` is the State's and is what setState requires;
                  // `context.mounted` covers this particular element, which is
                  // not necessarily the State's own. Checking one and using the
                  // other is what the analyzer calls an unrelated guard.
                  if (!mounted || !context.mounted) return;
                  setState(() => _isQueued = false);
                  AnimatedToast.show(context,
                      text: removed > 0
                          ? "Removed $removed from queue"
                          : "Nothing from here was queued",
                      icon: removed > 0
                          ? Icons.remove_circle
                          : Icons.info_outline,
                      color: themeColor);
                } else {
                  final added =
                      await notifier.addListToQueue(filteredTracks);
                  if (!mounted || !context.mounted) return;
                  // Both outcomes mean the same thing for the ICON: tracks went
                  // in, or they were already there. `added > 0 || _isQueued`
                  // left it un-highlighted after "already queued", which is the
                  // one case where it was most obviously wrong — the flag starts
                  // false and nothing else ever sets it.
                  setState(() => _isQueued = true);
                  if (added == 0) {
                    AnimatedToast.show(context,
                        text: "Already in your queue",
                        icon: Icons.playlist_add_check,
                        color: themeColor);
                  } else if (!QueueFlyOverlay.flyFrom(context,
                      imageUrl: filteredTracks.first.image)) {
                    // The art flying into the mini-player IS the confirmation;
                    // the toast is only for when there is nothing to fly to.
                    AnimatedToast.show(context,
                        text: "Added $added to queue",
                        icon: Icons.queue_music,
                        color: themeColor);
                  }
                }
              },
            ),
            if (isExternal) ...[
              const SizedBox(width: 10),
              _ActionIcon(
                icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: isLiked ? themeColor : Colors.white.withOpacity(0.85),
                onTap: () {
                  HapticService.selection();
                  final item = widget.libraryPlaylist ?? LibraryItem(title: title, subtitle: subtitle, image: image, category: LibraryCategory.playlist, dateAdded: DateTime.now());
                  ref.read(libraryProvider.notifier).togglePlaylistLike(item, tracks: filteredTracks);
                  AnimatedToast.show(context, text: isLiked ? "Removed from Library" : "Added to Library", icon: isLiked ? Icons.favorite_border : Icons.favorite, color: themeColor);
                },
              ),
            ],

            // Only show download button for external or user-editable folders.
            // Disabled (inert checkmark) once every track is already an explicit
            // download, so a fully-downloaded playlist can't be re-downloaded.
            if (showDownload)
              ValueListenableBuilder<int>(
                  valueListenable: AudioCacheManager.cacheEpoch,
                  builder: (context, _, __) {
                final cache = AudioCacheManager();
                final fullyDownloaded = filteredTracks.isNotEmpty &&
                    filteredTracks.every((s) => cache.isExplicitlyDownloaded(s.id));
                return _ActionIcon(
                  icon: fullyDownloaded
                      ? Icons.download_done_rounded
                      : Icons.download_rounded,
                  color: fullyDownloaded
                      ? themeColor
                      : Colors.white.withOpacity(0.85),
                  disabled: fullyDownloaded,
                  onTap: () {
                    if (filteredTracks.isNotEmpty) {
                      HapticService.selection();
                      // One bulk download at a time — the progress banner has a
                      // single set of counters, and two runs driving it reset
                      // each other. Same guard as the album page.
                      final running = ref.read(downloadProvider);
                      if (running.isDownloading) {
                        AnimatedToast.show(context,
                            text: 'Already downloading '
                                '${running.currentItemName}',
                            icon: Icons.downloading_rounded,
                            color: themeColor);
                        return;
                      }
                      if (isExternal) {
                        // downloadFullPlaylist drives the banner itself.
                        ref.read(libraryProvider.notifier).downloadFullPlaylist(LibraryItem(title: title, subtitle: subtitle, image: image, category: LibraryCategory.playlist, dateAdded: DateTime.now()), filteredTracks);
                        AnimatedToast.show(context, text: "Saving & Downloading", icon: Icons.downloading, color: themeColor);
                      } else {
                        AnimatedToast.show(context, text: "Downloading tracks", icon: Icons.downloading, color: themeColor);
                        // Awaited and reported. Declared as a playlist so files go to Playlists/<name>
                        // with numbered names. Drives the progress banner, since this path downloads one
                        // track at a time.
                        final dl = ref.read(downloadProvider.notifier);
                        dl.startDownload(filteredTracks.length, title,
                            kind: widget.isAlbumView ? 'Album' : 'Playlist');
                        dl.beginTransfer(filteredTracks.length);
                        DownloadHelper.downloadCollection(
                          filteredTracks,
                          downloadType: widget.isAlbumView ? 'Album' : 'Playlist',
                          collectionName: title,
                          onProgress: (done, total) => dl.updateProgress(done),
                        ).then((r) {
                          dl.finishDownload(failed: r.failures.length);
                          AnimatedToast.message(r.summary);
                        }).catchError((Object e) {
                          // Dismiss the banner even if something throws.
                          dl.finishDownload();
                          AnimatedToast.message('Download failed');
                        });
                      }
                    }
                  },
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildPremiumSearchAndSort() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Row(
          children: [
            Expanded(
              // Shared search pill (see [AuvySearchField]).
              child: AuvySearchField(
                controller: _searchController,
                hint: "Find in playlist",
                height: 42,
                radius: 13,
                hintColor: Colors.white30,
                iconColor: Colors.white30,
                // Scroll the field into view ONCE, when it takes focus.
                onTap: () => Future.delayed(
                    const Duration(milliseconds: 300), _autoScrollToSearch),
                // No auto-scroll while typing: filtering only rebuilds the list, and the viewport
                // stays where the user put it.
                onChanged: (v) => setState(() => _searchQuery = v),
                // Submitting is the deliberate "take me to the results" gesture, so only that moves
                // the page.
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _autoScrollToSearch(),
                trailing: _searchQuery.isEmpty
                    ? null
                    : Semantics(
                      label: 'Clear search',
                      button: true,
                      child: GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                            FocusScope.of(context).unfocus();
                          },
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.close_rounded,
                                color: Colors.white38, size: 18),
                          ),
                        ),
                    ),
              ),
            ),
            const SizedBox(width: 10),
            _buildSortButton(),
          ],
        ),
      ),
    );
  }


  Widget _buildPlaylistSuggestionsSection(String playlistTitle, Color themeColor) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(color: Colors.white10, indent: 16, endIndent: 16),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Suggested Playlists", 
                    style: TextStyle(color: themeColor, fontSize: 18, fontWeight: FontWeight.bold)
                  ),
                  IconButton(
                    tooltip: 'Show different suggestions',
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    onPressed: () {
                      HapticService.light();
                      setState(() => _suggestionSeed++);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<dynamic>>(
              key: ValueKey(_suggestionSeed + 100),
              future: _getPlaylistSuggestions(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()));
                final suggestions = snapshot.data!;
                if (suggestions.isEmpty) return const SizedBox();
                
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: suggestions.length,
                  itemBuilder: (ctx, idx) {
                    final item = suggestions[idx];
                    return ListTile(
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: densityNow.rowVerticalPadding),
                      leading: AuvyImage(
                          path: item.image ?? '',
                          width: densityNow.artwork(50),
                          height: densityNow.artwork(50),
                          borderRadius: 8),
                      title: Text(item.title ?? 'Playlist', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      subtitle: Text(item.subtitle ?? 'Curated for you', style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      onTap: () {
                        AppNavigation.push(
                          context,
                          PlaylistPage(
                            externalId: item.id,
                            externalTitle: item.title,
                            externalImage: item.image,
                            externalSubtitle: item.subtitle,
                            isAlbumView: false,
                          ),
                          name: AppNavigation.playlistTag('${item.id}'),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The suggestion strip. Previous results stay on screen while the next set loads,
  /// so the section's height (and the scroll position) doesn't change on refresh;
  /// only the refresh icon shows work. No key on the FutureBuilder (a new key would
  /// destroy the subtree): `_getTrackSuggestions` is memoised on `_suggestionSeed`,
  /// so a new seed already gives a new future.
  Widget _buildSuggestionsSection(List<Song> existingTracks, String playlistTitle, Color themeColor) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 28, 0, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<List<Song>>(
              // The point the related-playlists query reads its seeds from (it
              // isn't handed the tracks). Assigned here rather than in build() so
              // it can never be a partially-filtered view.
              future: (() {
                _lastRenderedTracks = existingTracks;
                return _getTrackSuggestions(existingTracks);
              })(),
              builder: (context, snapshot) {
                final loading =
                    snapshot.connectionState == ConnectionState.waiting;
                // Retain the last good list across a refresh — this is what keeps
                // the height stable.
                if (snapshot.hasData) _lastSuggestions = snapshot.data;
                final source = snapshot.data ?? _lastSuggestions;

                final have = existingTracks.map((e) => e.id).toSet();
                final display = (source ?? const <Song>[])
                    .where((s) =>
                        !_addedSuggestionIds.contains(s.id) &&
                        !have.contains(s.id))
                    .take(5)
                    .toList();

                // Nothing yet and nothing before: stay out of the way entirely
                // rather than reserving space for an empty section.
                if (display.isEmpty && !loading) return const SizedBox.shrink();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'MORE LIKE THIS',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.66),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2.4),
                                ),
                                const SizedBox(height: 5),
                                // Says WHY these are here, and reflects the ACTUAL
                                // blend the ranking used. A strip of songs with no
                                // stated basis reads as filler, and a fixed
                                // caption would be a small lie now that the
                                // weighting adapts to the playlist.
                                Text(
                                  _suggestionBasis(existingTracks),
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.72),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                          // Spins in place. No layout change, so no scroll jump.
                          IconButton(
                            tooltip: 'Refresh suggestions',
                            icon: loading
                                ? const SizedBox(
                                    width: 17,
                                    height: 17,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 1.8,
                                        color: Colors.white38),
                                  )
                                : Icon(Icons.refresh_rounded,
                                    color: Colors.white.withOpacity(0.55),
                                    size: 21),
                            onPressed: loading
                                ? null
                                : () {
                                    HapticService.light();
                                    setState(() => _suggestionSeed++);
                                  },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final song in display)
                      _SuggestionRow(
                        song: song,
                        accent: themeColor,
                        onAdd: () => _addSuggestion(song, playlistTitle, themeColor),
                        onPlay: () => _playSuggestion(song, display),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Header caption describing the blend actually in use.
  ///
  /// Reads the same fingerprint the ranking does, so it can't drift from it. The
  /// low-confidence wording doubles as the fix: a thin playlist says so and tells
  /// you what would sharpen it, instead of quietly serving generic picks.
  String _suggestionBasis(List<Song> tracks) {
    if (tracks.isEmpty) return 'Add a few tracks and Auvy will suggest more';
    final c = fingerprintPlaylist(tracks).confidence;
    if (c >= 0.72) return 'Closely matched to what’s already in this playlist';
    if (c >= 0.45) return 'Based on this playlist, tuned by your taste';
    return 'Mostly your taste — add more tracks to sharpen this';
  }

  /// Adds a suggestion and reports what happened (`addSongToPlaylist` returns false if
  /// the playlist already had it).
  void _addSuggestion(Song song, String playlistTitle, Color themeColor) {
    HapticService.selection();
    final bool added;
    if (playlistTitle == "Liked Songs") {
      ref.read(libraryProvider.notifier).toggleSongLike(song);
      added = true;
    } else {
      added = ref
          .read(libraryProvider.notifier)
          .addSongToPlaylist(playlistTitle, song);
    }
    AnimatedToast.show(
      context,
      text: added ? "Added to $playlistTitle" : "Already in $playlistTitle",
      icon: added ? Icons.check : Icons.info_outline,
      color: themeColor,
    );
    // Dismissed either way: a row you've already got is not a suggestion.
    setState(() => _addedSuggestionIds.add(song.id));
  }

  /// Preview a suggestion without committing it to the playlist.
  void _playSuggestion(Song song, List<Song> siblings) {
    HapticService.selection();
    // Queued with its siblings so previewing one suggestion rolls into the rest
    // rather than dead-ending; source is labelled so it doesn't masquerade as
    // playback from the playlist itself.
    ref.read(playerProvider.notifier).playSong(
          song,
          newQueue: siblings,
          index: siblings.indexOf(song),
          source: 'Suggestions',
        );
  }

  Widget _buildTracksList(List<Song> filteredTracks, String title, bool isExternal, AsyncValue<List<Song>>? externalTracksAsync, bool isPodcast) {
    final bool isDownloadFolder = !isExternal && title == "Downloads";
    final bool isCachedFolder = !isExternal && title == "Cached";
    // _editMode is the gate. See the field. Everything downstream (the
    // SliverReorderableList and the per-row drag handle) already keys off this
    // one flag, so there is nothing else to switch.
    final bool canReorder =
        _editMode && !isExternal && !isCachedFolder && title != "My Top 50";

    if (isExternal && externalTracksAsync != null) {
      return externalTracksAsync.when(
        data: (extTracks) {
          final filtered = _applyFilterAndSort(extTracks);
          if (filtered.isEmpty) return _buildListMessage(Icons.search_off_rounded, "No matching songs");
          return SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildTrackTile(context, ref, filtered[index], index, title, false, isPodcast, queue: filtered),
              childCount: filtered.length,
            ),
          );
        },
        loading: () => SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Column(children: [
                CircularProgressIndicator(color: ref.watch(themeProvider), strokeWidth: 3),
                const SizedBox(height: 16),
                Text("Loading tracks…",
                    style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13)),
              ]),
            ),
          ),
        ),
        error: (e, s) => _buildListMessage(Icons.cloud_off_rounded, "Couldn't load this playlist"),
      );
    }

    if (filteredTracks.isEmpty) {
      return _buildListMessage(Icons.music_off_rounded, "No songs here yet");
    }

    if (isDownloadFolder) {
     return _buildReorderableGroupedDownloads(context, ref, filteredTracks, isPodcast);
    }

    return _buildStandardTrackList(context, ref, filteredTracks, title, canReorder, isPodcast);
  }

  Widget _buildListMessage(IconData icon, String text) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Center(
          child: Column(children: [
            Icon(icon, size: 44, color: Colors.white.withOpacity(0.18)),
            const SizedBox(height: 12),
            Text(text,
                style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 14)),
          ]),
        ),
      ),
    );
  }

  Widget _buildReorderableGroupedDownloads(BuildContext context, WidgetRef ref, List<Song> tracks, bool isPodcast) {
    final Map<String, List<Song>> albumMap = {};
    for (var s in tracks) {
      final key = (s.albumTitle.isEmpty || s.albumTitle == 'null') ? "Singles" : s.albumTitle;
      albumMap.putIfAbsent(key, () => []).add(s);
    }

    final List<dynamic> displayList = [];
    final Set<String> processedAlbums = {};

    for (var song in tracks) {
      final albumName = (song.albumTitle.isEmpty || song.albumTitle == 'null') ? "Singles" : song.albumTitle;
      if (albumName == "Singles") {
        displayList.add(song);
        continue;
      }
      if (processedAlbums.contains(albumName)) continue;
      final albumTracks = albumMap[albumName]!;
      if (albumTracks.length >= 2) {
        displayList.add(MapEntry(albumName, albumTracks));
        processedAlbums.add(albumName);
      } else {
        displayList.add(song);
      }
    }

    return SliverReorderableList(
      itemCount: displayList.length,
      onReorder: (oldIdx, newIdx) => ref.read(libraryProvider.notifier).reorderDownloadedTracks(oldIdx, newIdx),
      itemBuilder: (context, index) {
        final item = displayList[index];
        if (item is Song) {
          return _buildTrackTile(context, ref, item, index, "Downloads", true, isPodcast, queue: tracks);
        } else {
          final entry = item as MapEntry<String, List<Song>>;
          final albumCoverArt = AudioCacheManager().getAlbumCoverArt(entry.key);
          return ReorderableDelayedDragStartListener(
            key: ValueKey('folder_${entry.key}'),
            index: index,
            child: Material(
              color: Colors.transparent,
              child: ExpansionTile(
                leading: albumCoverArt != null
                    ? AuvyImage(path: albumCoverArt, width: 50, height: 50, borderRadius: 8, fit: BoxFit.cover)
                    : Container(width: 50, height: 50, decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.album, color: Colors.white24)),
                title: Text(entry.key, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text("${entry.value.length} tracks", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                trailing: const Icon(Icons.drag_handle, color: Colors.white24),
                children: entry.value.asMap().entries.map((e) => _buildTrackTile(context, ref, e.value, tracks.indexOf(e.value), "Downloads", false, isPodcast, queue: tracks)).toList(),
              ),
            ),
          );
        }
      },
    );
  }

  Widget _buildStandardTrackList(BuildContext context, WidgetRef ref, List<Song> tracks, String playlistTitle, bool canReorder, bool isPodcast) {
    if (tracks.isEmpty) {
      return const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text("No tracks found", style: TextStyle(color: Colors.white54)))));
    }

    if (canReorder) {
      return SliverReorderableList(
        itemCount: tracks.length,
        onReorder: (oldIdx, newIdx) {
          final notifier = ref.read(libraryProvider.notifier);
          if (playlistTitle == "Liked Songs") notifier.reorderLikedSongs(oldIdx, newIdx);
          else notifier.reorderPlaylistTracks(playlistTitle, oldIdx, newIdx);
        },
        itemBuilder: (context, index) {
          return KeyedSubtree(
            key: ValueKey('track_${tracks[index].id}_$index'),
            child: _buildTrackTile(context, ref, tracks[index], index, playlistTitle, true, isPodcast, queue: tracks),
          );
        },
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          // Conform a few rows ahead of this one. See [warmAhead].
          warmAhead(ref, tracks, index);
          return _buildTrackTile(context, ref, tracks[index], index, playlistTitle, false, isPodcast, queue: tracks);
        },
        childCount: tracks.length,
      ),
    );
  }

  Widget _buildSortButton() {
    final themeColor = ref.watch(themeProvider);
    final bool sorted = _currentSort != _kDefaultSort;
    return PopupMenuButton<String>(
      color: Color.lerp(const Color(0xFF1E1E2A), themeColor, 0.15),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onOpened: () => FocusScope.of(context).unfocus(),
      onSelected: (value) {
        FocusScope.of(context).unfocus();
        HapticService.selection();
        setState(() {
          // Default has no direction to reverse, so re-picking it must not
          // silently flip _isAscending under the user.
          if (value == _kDefaultSort) {
            _currentSort = _kDefaultSort;
            _isAscending = true;
          } else if (_currentSort == value) {
            _isAscending = !_isAscending;
          } else {
            _currentSort = value;
            _isAscending = true;
          }
        });
      },
      // No "Recently added" entry: Default already IS the collection's own order,
      // which for a library playlist is the order tracks were added. It was the
      // same information, reversed, presented as a separate mode.
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        _sortEntry(_kDefaultSort),
        const PopupMenuDivider(height: 6),
        _sortEntry("Title"),
        _sortEntry("Artist"),
        _sortEntry("Album"),
      ],
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: sorted ? themeColor.withOpacity(0.15) : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
              color: sorted ? themeColor.withOpacity(0.5) : Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              sorted
                  ? (_isAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)
                  : Icons.sort_rounded,
              color: sorted ? themeColor : Colors.white70,
              size: 17,
            ),
            if (sorted) ...[
              const SizedBox(width: 6),
              Text(_currentSort,
                  style: TextStyle(
                      color: themeColor, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
  }
  
  PopupMenuItem<String> _sortEntry(String val) {
    final bool isSelected = _currentSort == val;
    return PopupMenuItem(
      value: val,
      child: Row(
        children: [
          Text(val, style: TextStyle(color: isSelected ? ref.read(themeProvider) : Colors.white70, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          const Spacer(),
          // Default has no direction — a checkmark, not an arrow, or the row
          // would advertise a reversal that tapping it doesn't perform.
          if (isSelected)
            Icon(
              val == _kDefaultSort
                  ? Icons.check_rounded
                  : (_isAscending ? Icons.arrow_upward : Icons.arrow_downward),
              size: 16,
              color: ref.read(themeProvider),
            ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(BuildContext context, WidgetRef ref, Song song, int index, String playlistTitle, bool canReorder, bool isPodcast, {List<Song>? queue}) {
    final libraryNotifier = ref.read(libraryProvider.notifier);
    final themeColor = ref.read(themeProvider);
    final cacheManager = AudioCacheManager();
    final displayImage = cacheManager.getDisplayImage(song.id, song.image);

    return _SwipeablePlaylistTile(
      onKeepSuggestion: _freshIds.contains(song.id)
          ? () => _keepSuggestion(playlistTitle, song)
          : null,
      key: ValueKey('tile_${playlistTitle}_${song.id}_$index'),
      index: index,
      song: song.copyWith(image: displayImage),
      canReorder: canReorder,
      isInfoOnly: playlistTitle == "My Top 50" || isPodcast,
      selectable: _editMode,
      selected: _selectedIds.contains(song.id),
      onToggleSelect: () {
        HapticService.selection();
        setState(() {
          if (!_selectedIds.remove(song.id)) _selectedIds.add(song.id);
        });
      },
     onTap: () {
        // Playing a track from this playlist is what qualifies it as "recently
        // played" for the Home mosaic (not merely opening the page), and links
        // this track to the playlist so the mosaic shows only the playlist tile.
        if (!isPodcast) _recordPlayFromPlaylist(song);
        ref.read(playerProvider.notifier).playSong(
          song,
          // The rest of the displayed list (current sort and filter) queues up after the
          // tapped track; playSong finds the song by id and slices there. Podcasts keep
          // their own flow.
          newQueue: isPodcast ? null : queue,
          isManual: true,
          source: "Playlist",
          locationName: playlistTitle,
          contextId: playlistTitle,
          contextType: 'playlist',
          contextTitle: playlistTitle,
        );
      },
      onDelete: (Offset deleteOrigin) {
        if (playlistTitle == "Liked Songs") {
          // Snapshot the position FIRST so Undo restores it in place
          // (re-liking normally hoists to the top of the list).
          final likedIdx = ref
              .read(libraryProvider)
              .likedSongs
              .indexWhere((s) => s.id == song.id);
          // 1. Optimistically remove from UI
          libraryNotifier.toggleSongLike(song);
          // 2. Show Undo Toast
          UndoToast.show(
            context,
            text: "Removed from Liked Songs",
            onUndo: () =>
                libraryNotifier.toggleSongLike(song, restoreAt: likedIdx),
          );
        }
        else if (playlistTitle == "Downloads" || playlistTitle == "Cached") {
          if (playlistTitle == "Downloads") {
            // Hide from UI immediately, but defer actual disk wipe!
            final removedIdx =
                libraryNotifier.removeSongFromPlaylist("Downloads", song.id);
            UndoToast.show(
              context,
              text: "Removed from Downloads",
              onUndo: () => libraryNotifier.addSongToPlaylist("Downloads", song,
                  atIndex: removedIdx),
              onExpire: () => AudioCacheManager().removeFromCache(song.id), // Wipes disk ONLY if timer expires
            );
          } else {
            // Cached folder lists disk state directly, so the row is hidden via
            // the cache manager's pending-delete set (not a real wipe). The file
            // is only deleted when the undo window expires; Undo just unhides.
            AudioCacheManager().hidePendingDelete(song.id);
            UndoToast.show(
              context,
              text: "Deleted from cache",
              onUndo: () => AudioCacheManager().restorePendingDelete(song.id),
              onExpire: () => AudioCacheManager().removeFromCache(song.id),
            );
          }
        } 
        else {
          // Standard Custom Playlist — Undo returns the song to its old slot.
          final removedIdx =
              libraryNotifier.removeSongFromPlaylist(playlistTitle, song.id);
          ItemTransferOverlay.discard(context,
              imageUrl: song.image, origin: deleteOrigin);
          UndoToast.show(
            context,
            text: "Removed from Playlist",
            onUndo: () => libraryNotifier.addSongToPlaylist(playlistTitle, song,
                atIndex: removedIdx),
          );
        }
      },
      onQueue: () {
        // Asked before the add, so the toast reports what actually happened
        // rather than always claiming success.
        final already = ref.read(playerProvider.notifier).isPendingInQueue(song);
        if (!ref
            .read(listenTogetherProvider.notifier)
            .requestQueueAdd(song)) {
          ref.read(playerProvider.notifier).addToQueue(song);
        }
        HapticService.medium();
        AnimatedToast.show(context,
            text: already ? "Already in Queue" : "Added to Queue",
            icon: already ? Icons.playlist_add_check : Icons.queue_music,
            color: themeColor);
      },
      onInfo: () {
        final intel = ref.read(intelligenceProvider);
        final affinity = intel.trackAffinities[song.id] ?? 0.0;
        final playCount = (affinity / 1.5).round().clamp(0, 9999);
        final history = intel.listeningHistory;
        final timesInHistory = history.where((s) => s.id == song.id).length;
        
        showDialog(
          context: context,
          useRootNavigator: true, 
          builder: (dialogContext) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
            title: Text(song.title, style: const TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Artist: ${song.artist}', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                Text('Estimated plays: $playCount', style: const TextStyle(color: Colors.white)),
                Text('In recent history: $timesInHistory times', style: const TextStyle(color: Colors.white70)),
                Text('Affinity score: ${affinity.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
          ),
        );
      },
    );
  }
}

/// One suggested track. Lighter than the playlist's own rows (smaller artwork, no
/// index, no swipe actions) because these are candidates. Tapping the row previews
/// the track; only the ring adds it.
class _SuggestionRow extends StatelessWidget {
  final Song song;
  final Color accent;
  final VoidCallback onAdd;
  final VoidCallback onPlay;

  const _SuggestionRow({
    required this.song,
    required this.accent,
    required this.onAdd,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        child: Row(
          children: [
            AuvyImage(path: song.image, width: 44, height: 44, borderRadius: 10),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  ExplicitArtistLine(
                    isExplicit: song.isExplicit == true,
                    text: song.displayArtist,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // A ring rather than a filled button: adding is available, not urged.
            //
            // Builder so the ghost can start from THIS button's own position —
            // the enclosing context is the whole row, whose centre would put it
            // over the artwork instead of where the finger was.
            Builder(
              builder: (btnContext) => Semantics(
                label: 'Add to library',
                button: true,
                child: GestureDetector(
                  onTap: () {
                    ItemTransferOverlay.toLibrary(btnContext,
                        imageUrl: song.image, accent: accent);
                    onAdd();
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: accent.withOpacity(0.55), width: 1.5),
                    ),
                    child: Icon(Icons.add_rounded, color: accent, size: 18),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// Quiet circular secondary action, identical to the album page's `_circleAction`
/// (46 px, 7% white fill, 8% hairline border, 20 px glyph), so the two pages'
/// action rows match.
/// Keep fresh settings for one playlist: on/off, how often, and a manual swap.
class _KeepFreshSheet extends ConsumerWidget {
  final String title;
  final Color themeColor;
  const _KeepFreshSheet({required this.title, required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(keepFreshProvider.select((s) => s.playlists[title]));
    final busy = ref.watch(keepFreshProvider.select((s) => s.busy.contains(title)));
    final total = ref.watch(
        libraryProvider.select((s) => s.playlistSongs[title]?.length ?? 0));
    final resting = ref.watch(libraryProvider
        .select((s) => s.playlistSongs[freshReserveKey(title)]?.length ?? 0));
    final own = total - (entry?.suggestionIds.length ?? 0) + resting;
    final tooFew = own < KeepFreshNotifier.minOwnSongs;
    final notifier = ref.read(keepFreshProvider.notifier);
    final on = entry != null;
    final muted = TextStyle(
        color: Colors.white.withOpacity(0.7), fontSize: 13, height: 1.35);

    Future<void> toggle(bool value) async {
      HapticService.selection();
      if (!value) {
        await notifier.disable(title);
        return;
      }
      final filled = await notifier.enable(title, FreshCadence.weekly);
      if (!filled && context.mounted) {
        AnimatedToast.show(context,
            text: "Couldn't find suggestions right now. It will try again later.",
            icon: Icons.info_outline_rounded,
            color: themeColor);
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: themeColor),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Keep fresh',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                ),
                Switch(
                  value: on,
                  activeThumbColor: themeColor,
                  onChanged: busy || (!on && tooFew) ? null : toggle,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
                'Rests a few of your songs and puts suggestions that fit in their '
                'places, so the playlist stays the same size. Resting songs come '
                'back at the next swap, and turning this off brings them all '
                "back. Tap a suggestion's sparkle to keep it, or like it.",
                style: muted),
            if (!on && tooFew) ...[
              const SizedBox(height: 10),
              Text(
                  'Needs at least ${KeepFreshNotifier.minOwnSongs} songs of your '
                  'own to know what fits.',
                  style: muted.copyWith(color: themeColor)),
            ],
            if (on) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in FreshCadence.values)
                    AuvyPill(
                      label: c == FreshCadence.weekly ? 'Every Monday' : 'Every day',
                      selected: entry.cadence == c,
                      accent: themeColor,
                      onTap: () => notifier.setCadence(title, c),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        HapticService.selection();
                        notifier.refreshPlaylist(title, force: true);
                      },
                icon: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: themeColor))
                    : Icon(Icons.refresh_rounded, color: themeColor),
                label: Text(busy ? 'Finding songs…' : 'Swap suggestions now',
                    style: TextStyle(color: themeColor)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool disabled;
  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        onLongPress: disabled ? null : onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.07),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

/// Small circular scrim behind app-bar icons so they stay readable over any
/// artwork without needing a blur.
class _CircleGlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleGlassButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38, height: 38,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.30),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _SwipeablePlaylistTile extends ConsumerWidget {
  final int index;
  final Song song;
  final VoidCallback onTap;
  /// Takes the release position: the removal ghost must start at the row, and
  /// the handler upstream only has the page context.
  final Function(Offset) onDelete;
  final VoidCallback onQueue;
  final bool canReorder;
  final bool isInfoOnly;
  final VoidCallback onInfo;

  /// Multi-select. While [selectable] the tile stops being a play button: tap
  /// toggles [selected], the swipe actions and the drag handle are withdrawn, and
  /// a check replaces the count. Leaving them live would mean a stray swipe could
  /// delete a track the user was only trying to tick.
  final bool selectable;
  final bool selected;
  final VoidCallback? onToggleSelect;

  /// Set when Keep fresh added this song; tapping its sparkle keeps it.
  final VoidCallback? onKeepSuggestion;

  const _SwipeablePlaylistTile({super.key, required this.index, required this.song, required this.onTap, required this.onDelete, required this.onQueue, required this.onInfo, this.isInfoOnly = false, this.canReorder = true, this.selectable = false, this.selected = false, this.onToggleSelect, this.onKeepSuggestion});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Show the audio track's square cover + clean title once resolved; playback
    // still targets the original row (onTap) so queue logic is unchanged.
    final display = conformedForDisplay(ref, song);

    return Material(
      color: Colors.transparent,
      child: SwipeActionTile(
        swipeId: song.id,
        onTap: selectable ? (onToggleSelect ?? onTap) : onTap,
        // Press-and-hold opens the song options menu (same ContentMenu as search
        // and home). Passes the ORIGINAL row song, not `display` — the menu's
        // actions must target the same track playback does.
        //
        // Suppressed while selecting: a per-track menu on top of a multi-track
        // selection offers actions for the wrong scope.
        onLongPress: selectable
            ? null
            : () {
                HapticService.medium();
                ContentMenus.showSongMenu(context, song, ref);
              },
        enableTapShrink: true,
        flyImageUrl: display.image,
        // Swipe actions are withdrawn while selecting, so a stray drag can't delete a
        // track being ticked.
        //
        // App-wide swipe convention:
        //
        //   drag right (leftAction) = queue, on any track row on every page (pin on a
        //                             library folder tile, which has no queue action).
        //   drag left (rightAction)  = the row's secondary action: add to playlist,
        //                             like, or the destructive one where the row has one
        //                             (always red).
        leftAction: selectable
            ? null
            : SwipeAction(
                icon: Icons.queue_music,
                label: "QUEUE",
                color: const Color(0xFFFFD740),
                flyToMiniPlayer: true,
                onTap: (pos) => onQueue(),
              ),
        rightAction: selectable
            ? null
            : SwipeAction(
                icon: isInfoOnly ? Icons.info_outline : Icons.delete_outline,
                label: isInfoOnly ? "INFO" : "DELETE",
                color: isInfoOnly ? Colors.blueAccent : Colors.redAccent,
                onTap: (pos) => isInfoOnly ? onInfo() : onDelete(pos),
              ),
        child: Container(
          color: Colors.transparent,
          child: ListTile(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The check takes the track number's slot rather than being added
                // beside it, so rows don't shift horizontally when selection mode
                // turns on — the list stays where the user's eye left it.
                SizedBox(
                  width: 26,
                  child: selectable
                      ? Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          size: 20,
                          color: selected
                              ? ref.watch(themeProvider)
                              : Colors.white.withOpacity(0.35),
                        )
                      : Text("${index + 1}",
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.66),
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center),
                ),
                const SizedBox(width: 10),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Hero(
                        tag: 'list_artwork_${song.id}',
                        child: AuvyImage(
                            path: display.image,
                            width: densityNow.artwork(48),
                            height: densityNow.artwork(48),
                            borderRadius: 8)),
                    NowPlayingArtOverlay(
                        rowId: song.id,
                        altId: display.id,
                        title: display.title,
                        artist: song.displayArtist,
                        duration: song.duration,
                        barSize: 12),
                  ],
                ),
              ],
            ),
            title: NowPlayingTitle(
                title: display.title,
                rowId: song.id,
                altId: display.id,
                artist: song.displayArtist,
                duration: song.duration,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w500)),
            subtitle: TrackDownloadBar(
              songId: song.id,
              fallback: ExplicitArtistLine(
                isExplicit: song.isExplicit == true,
                text: song.displayArtist,
                style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12),
                badgeSize: 12,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A Keep fresh suggestion: rotates out at the next refresh unless kept.
                if (onKeepSuggestion != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onKeepSuggestion,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'Suggested by Keep fresh. Tap to keep it',
                        child: Icon(Icons.auto_awesome_rounded,
                            size: 17, color: ref.read(themeProvider)),
                      ),
                    ),
                  ),
                // Play count, the same field on every page. See [watchTrackViews].
                if (watchTrackViews(ref, song.id, song.viewCount) != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(watchTrackViews(ref, song.id, song.viewCount)!,
                        style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 11)),
                  ),
                ValueListenableBuilder<int>(
                  valueListenable: AudioCacheManager.cacheEpoch,
                  builder: (_, __, ___) {
                    final cm = AudioCacheManager();
                    final dl = cm.isExplicitlyDownloaded(song.id);
                    final ac = cm.isCached(song.id) && !dl;
                    if (!dl && !ac) return const SizedBox.shrink();
                    return Padding(padding: const EdgeInsets.only(right: 8), child: Icon(dl ? Icons.download_done_outlined : Icons.offline_bolt_outlined, color: Colors.white24, size: 18));
                  },
                ),
                // Shown whenever the list is reorderable (edit mode only). Selection and dragging
                // share edit mode without conflict, since a drag must start on the handle.
                if (canReorder) ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle, color: Colors.white54)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
