import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:auvy/presentation/widgets/item_transfer_overlay.dart';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
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
import 'package:auvy/services/haptic_service.dart';
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
  // YouTube ids are by far the common case, so browse them FIRST. The old
  // "contains a letter → Spotify" check matched EVERY YouTube id, which made
  // each playlist open pay for a doomed Spotify lookup before falling back.
  final ytTracks = await ref.read(searchServiceProvider).getPlaylistTracks(id);
  if (ytTracks.isNotEmpty) return ytTracks;

  // Spotify playlist ids are bare 22-char base62 (no PL/VL/RDCLAK prefix).
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

  /// "Don't sort" — show the collection in its OWN order. For a library playlist
  /// that is the order tracks were added; for My Top 50 it is play count; for a
  /// remote playlist it is the publisher's order. It was previously called
  /// "Custom order" and, more importantly, was reachable only as the initial
  /// state: nothing in the sort menu offered it, so choosing any sort was a
  /// one-way door until the page was reopened.
  static const String _kDefaultSort = "Default";

  String _currentSort = _kDefaultSort;
  bool _isAscending = true;

  // Multi-select
  //
  // Entered from a button in the app bar, NOT by long-press: long-press already
  // opens the track's content menu, and a gesture that means two different
  // things depending on invisible state is how you get accidental selections.
  // ONE MODE, NOT TWO. There used to be a separate multi-select button in
  // the toolbar beside Edit and Share. Two buttons that both mean "change this
  // playlist" is one too many, and the owner read the second as redundant —
  // long-press already gives per-track actions.
  //
  // Selection now lives INSIDE edit mode, where it belongs: enter edit and you
  // can rename (tap the title), reorder (drag the handle) and tick rows for the
  // bulk actions that long-press cannot do — queueing ten tracks at once rather
  // than ten times.
  //
  // The gestures do not collide: the handle has its own drag recogniser and only
  // reacts to a drag that STARTS on it, while a tap anywhere else on the row
  // ticks it.

  /// Reordering is EDIT-MODE ONLY.
  ///
  /// The drag handle used to sit on every row of every editable playlist, all
  /// the time. That put a grab target next to a tap target in a scrolling list —
  /// easy to nudge a track out of place while flicking, and no way to tell the
  /// app you only meant to scroll. Spotify gates it behind an explicit Edit, and
  /// so does this: outside edit mode the list is a plain, un-draggable list.
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
  int _suggestionSeed = 0;
  final Set<String> _addedSuggestionIds = {};

  /// The track list as last rendered, so the RELATED-PLAYLISTS query can be
  /// built from this playlist's own contents. That request doesn't receive the
  /// tracks (unlike `_getTrackSuggestions`), which is how it ended up querying
  /// an arbitrary artist from global metadata instead.
  List<Song> _lastRenderedTracks = const [];

  /// Last completed suggestion set, kept so a refresh can leave the current rows
  /// on screen instead of collapsing the section to a spinner, which is what
  /// used to shove the scroll position up. See `_buildSuggestionsSection`.
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
    // NOTE: we intentionally do NOT record this playlist as "recently played"
    // just because the user OPENED it — only actually PLAYING a track from it
    // qualifies (see _recordPlayFromPlaylist, called from a track's onTap). This
    // fixes the Home mosaic listing playlists the user merely browsed.
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

  /// Offer the ready-made library first, the camera roll second.
  ///
  /// Creating a playlist used to mean accepting the default artwork or going
  /// hunting in your photos, so most playlists kept the default. A curated set
  /// makes the good outcome the easy one.
  /// Rename the playlist itself (not its tracks).
  ///
  /// Reachable only from edit mode, and only for playlists the user owns —
  /// renamePlaylist refuses system folders, so the button is hidden for them
  /// rather than offered and then denied.
  Future<void> _renamePlaylist(String currentTitle) async {
    final controller = TextEditingController(text: currentTitle);
    final themeColor = ref.read(themeProvider);
    final next = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF17171C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Rename playlist",
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: Colors.white),
          maxLength: 60,
          decoration: InputDecoration(
            counterStyle: const TextStyle(color: Colors.white24, fontSize: 11),
            hintText: "Playlist name",
            hintStyle: const TextStyle(color: Colors.white24),
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
    );
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

  /// "Remove N duplicates", shown only when there ARE duplicates.
  ///
  /// Offered rather than done automatically, and it states the COUNT rather than
  /// just the action: silently rewriting someone's playlist is not a tidy-up, and
  /// "Remove duplicates" with no number asks them to take it on faith.
  ///
  /// Exists because of a real consequence of the import retry pass: a track that
  /// missed on the first attempt and matched on the second can resolve to a
  /// DIFFERENT video id, so the same song lands twice. Those read as duplicates
  /// to a person and as distinct rows to an id comparison — see
  /// LibraryNotifier.removeDuplicatesFromPlaylist for how they are matched.
  /// RETURNS A SLIVER. Its siblings in that list do too — see
  /// _buildPremiumSearchAndSort, because the page body is a slivers array, not a
  /// Column. Handing a plain box to a viewport throws "expected a child of type
  /// RenderSliver", which is the red error screen this produced in edit mode, and
  /// it did so whether or not there were duplicates: the empty case was a bare
  /// SizedBox, which is just as wrong.
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

  Future<void> _chooseCover(String title) async {
    HapticService.light();
    final choice = await showModalBottomSheet<String>(
      context: context,
      // Same reason as the picker: keep the mini player behind the barrier.
      useRootNavigator: true,
      backgroundColor: const Color(0xFF17171C),
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
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
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

  /// Stage a cover chosen from the library, downloading it first.
  ///
  /// Deliberately not stored as a URL. The override store re-encodes to a
  /// bounded PNG on disk AND keeps the bytes base64 in a backed-up key, so the
  /// cover survives a reinstall and works offline. Saving the remote URL would
  /// look identical today and break the moment the Worker, the repo or the
  /// network is unavailable.
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

  /// Staged, NOT committed
  ///
  /// Picking a cover used to write it straight into the override store.
  ///
  /// So the change stuck even when the user backed out without ever pressing
  /// the check — an edit mode whose edits could not be abandoned. The pick is
  /// now held here, previewed in the header, and only written by
  /// [_commitPendingCover] when the check is pressed.
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

      // This used to be `intel.trackMetadata.values.first.artist` — an
      // ARBITRARY artist out of the global metadata map, with no relationship to
      // the playlist being viewed at all. Two playlists side by side got the
      // same "related playlists", and neither was related to anything.
      //
      // Query from the playlist's own dominant artists instead, falling back to
      // global taste only when the playlist has nothing to say (empty, or all
      // tracks missing artists).
      final fp = _fingerprint(_lastRenderedTracks);
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

  /// What this playlist actually IS, derived from every track in it.
  ///
  /// The old suggestion code read `existingTracks.map((s) => s.artist).toSet()
  /// .take(2)` — the artists of the first two tracks in list order. For a
  /// 60-track playlist it looked at two names, and because `Set` preserves
  /// insertion order, "which two" depended entirely on how the list happened to
  /// be sorted. Sort by title and you got different suggestions for the same
  /// playlist.
  _PlaylistFingerprint _fingerprint(List<Song> tracks) {
    final artistWeight = <String, double>{};
    final albumCount = <String, int>{};
    final years = <int>[];
    var explicitCount = 0;

    for (var i = 0; i < tracks.length; i++) {
      final s = tracks[i];
      if (s.artist.trim().isEmpty) continue;

      // Every credited artist counts, not just the primary. A playlist full of
      // features is characterised by the collaborators too, and `artist` alone
      // throws that away.
      final credited = <String>{
        s.artist,
        ...s.artists.map((a) => a.name).where((n) => n.trim().isNotEmpty),
      };
      // Recency bias: tracks added most recently describe where the playlist is
      // GOING, which is what a suggestion should extend. Oldest entries still
      // count, at about half the weight.
      final recency = 0.5 + 0.5 * (i / math.max(1, tracks.length - 1));
      for (final name in credited) {
        // Secondary credits count less than the lead.
        final w = name == s.artist ? recency : recency * 0.45;
        artistWeight[name] = (artistWeight[name] ?? 0) + w;
      }

      if (s.albumTitle.trim().isNotEmpty) {
        albumCount[s.albumTitle] = (albumCount[s.albumTitle] ?? 0) + 1;
      }
      final year = int.tryParse(
          RegExp(r'(19|20)\d{2}').firstMatch(s.releaseDate)?.group(0) ?? '');
      if (year != null) years.add(year);
      if (s.isExplicit == true) explicitCount++;
    }

    final ranked = artistWeight.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // How much should this playlist be trusted over general taste?
    //
    // A FIXED ratio is the wrong shape, and this is the part worth getting right.
    // Spotify's exact production weights aren't published, but the principle from
    // their automatic-playlist-continuation work, and from recommender practice
    // generally — is that confidence in a playlist's own signal SCALES WITH THE
    // EVIDENCE IT PROVIDES. A 3-track playlist cannot describe a sound; a
    // 60-track playlist with a tight artist distribution describes it better than
    // any global profile can. So the blend moves.
    //
    // Two independent inputs:
    //
    //  • EVIDENCE — how many tracks there are, on a saturating curve. Going from
    //    5 to 15 tracks tells you far more than 50 to 60 does, so it must not be
    //    linear.
    //
    //  • COHERENCE — how concentrated the artist distribution is (top-3 share of
    //    total weight). 40 tracks spread over 38 artists is a shelf, not a sound;
    //    40 tracks over 6 artists is a strong statement about what belongs.
    // This is a PROXY. A genuinely coherent playlist can be artist-diverse
    //    (one genre, forty artists) and this will under-rate it — Auvy has no
    //    reliable per-track genre to measure the real thing with. Under-rating
    //    fails safe: it leans on global taste, which is still a decent answer.
    final n = tracks.length;
    final evidence = n / (n + 12.0); // 10→0.45, 25→0.68, 60→0.83
    final totalWeight =
        artistWeight.values.fold<double>(0, (a, b) => a + b);
    final top3 = ranked.take(3).fold<double>(0, (a, e) => a + e.value);
    final coherence =
        totalWeight <= 0 ? 0.0 : (top3 / totalWeight).clamp(0.0, 1.0);
    final confidence =
        (evidence * 0.55 + coherence * 0.45).clamp(0.0, 1.0);
    // Never below 0.45: even a thin playlist is the thing the user is looking at,
    // so it always outweighs or matches general taste. Never above 0.95: keeping a
    // sliver of taste in the mix is what stops a tight playlist from only ever
    // suggesting the same three adjacent artists.
    final playlistWeight = 0.45 + 0.50 * confidence;

    years.sort();
    return _PlaylistFingerprint(
      playlistWeight: playlistWeight,
      confidence: confidence,
      artistWeight: artistWeight,
      topArtists: ranked.map((e) => e.key).toList(),
      // Median year, not mean: one 1972 track in a playlist of 2023 releases
      // should not drag the whole profile back fifty years.
      medianYear: years.isEmpty ? null : years[years.length ~/ 2],
      // A playlist that is entirely one album is a listening context, not a
      // taste profile — suggestions should reach outside it.
      dominatedBySingleAlbum: albumCount.isNotEmpty &&
          albumCount.values.reduce(math.max) >= tracks.length * 0.7,
      mostlyExplicit: tracks.isNotEmpty && explicitCount > tracks.length * 0.5,
      trackCount: tracks.length,
    );
  }

  /// Signature that survives the same song appearing under different ids.
  ///
  /// De-duplication used to be `c.id == e.id` only, so the identical track
  /// resolved from another source (a different video id for the same recording)
  /// was happily "suggested" for a playlist it was already in.
  static String _songSig(Song s) =>
      '${s.title.toLowerCase().trim()}|${s.artist.toLowerCase().trim()}';

  Future<List<Song>> _getTrackSuggestions(List<Song> existingTracks) {
    if (_trackSuggestionsFuture != null && _trackSuggestionsSeed == _suggestionSeed) {
      return _trackSuggestionsFuture!;
    }
    _trackSuggestionsSeed = _suggestionSeed;
    final seed = _suggestionSeed;
    _trackSuggestionsFuture = () async {
      final searchService = ref.read(searchServiceProvider);
      final intel = ref.read(intelligenceProvider.notifier);

      if (existingTracks.isEmpty) return <Song>[];
      final fp = _fingerprint(existingTracks);

      // Seeds
      //
      // REFRESH VARIETY COMES FROM HERE, not from the shuffle.
      //
      // The first version queried a FIXED `topArtists.take(4)` + their
      // complements on every refresh. Those searches are deterministic, so the
      // candidate pool was byte-identical each time, and because a pool built
      // from ~6 artist queries only spans ~6–10 distinct artists, the
      // one-per-artist diversity pass then admitted nearly all of them on every
      // refresh. Reshuffling identical answers cannot produce new suggestions,
      // which is exactly why refreshing barely changed the list (and why the tail
      // rows looked pinned).
      //
      // So the refresh ROTATES which part of the fingerprint gets explored. A
      // playlist usually has far more than 4 meaningful artists; each refresh
      // takes a different window over them, plus complements of a different
      // subset. Different queries → genuinely different candidates.
      final ranked = fp.topArtists;
      final window = math.max(1, math.min(8, ranked.length));
      final offset = ranked.isEmpty ? 0 : (seed * 2) % ranked.length;
      List<String> rotate(List<String> xs, int by) =>
          xs.isEmpty ? xs : [...xs.skip(by), ...xs.take(by)];

      final rotated = rotate(ranked.take(window).toList(), offset % window);
      final seedArtists = <String>[
        // The playlist's own artists, from a moving window.
        ...rotated.take(3),
        // Complements of a DIFFERENT slice each time. These are where new music
        // actually comes from — searching an artist already in the playlist
        // mostly returns tracks you either have or deliberately skipped.
        for (final a in rotate(rotated, 1).take(3))
          ...intel.getComplementaryArtists(a, limit: 2),
      ];
      // An all-one-album playlist has almost no internal variety to learn from,
      // so lean harder on complements than on its own single artist.
      final queries = (fp.dominatedBySingleAlbum
              ? seedArtists.reversed.toList()
              : seedArtists)
          .toSet()
          .take(7)
          .toList();

      // Seeded from the tracks themselves, NOT just their artist names
      //
      // THIS IS WHAT MAKES A SUGGESTION BELONG TO THIS PLAYLIST. The artist
      // searches below are recall, not relevance: "Fleetwood Mac" as a text query
      // returns that artist's popular catalogue, which is either already here or
      // was deliberately not added. And the complements used to collapse to the
      // user's overall favourites regardless of the artist asked about (see
      // `getComplementaryArtists`), so the section filled with tracks that
      // matched the user's taste and had nothing to do with the playlist open in
      // front of them. Exactly the reported complaint.
      //
      // `getSongRadio` asks YouTube "what goes with THIS recording" for actual
      // tracks in the playlist. That is derived from the playlist's contents by
      // construction, not from a name that happens to appear in it, and it
      // understands adjacency no text search can express.
      //
      // Which tracks get used ROTATES with the refresh seed, so refreshing
      // explores a different corner of the playlist rather than re-ranking the
      // same answer. Ids that cannot have a radio (local imports, podcasts, live
      // streams) are skipped rather than requested and discarded.
      final radioSeeds = existingTracks
          .where((s) => s.id.length == 11 && !s.id.startsWith('http'))
          .toList();
      final chosenSeeds = <Song>[];
      if (radioSeeds.isNotEmpty) {
        for (var i = 0; i < math.min(3, radioSeeds.length); i++) {
          chosenSeeds.add(radioSeeds[(seed * 3 + i) % radioSeeds.length]);
        }
      }

      final candidates = <Song>[];
      // Tracked separately so scoring can prefer them: a catalogue-certified
      // neighbour of a track in this playlist is better evidence than a name match.
      final radioIds = <String>{};

      // Concurrent: this used to be a sequential await inside a for-loop, so six
      // searches cost six round-trips end to end while the section sat empty. The
      // radio calls join the same wave rather than adding a round-trip in front.
      final results = await Future.wait([
        ...chosenSeeds.map((s) async {
          try {
            return (radio: true, songs: await searchService.getSongRadio(s.id));
          } catch (_) {
            return (radio: true, songs: <Song>[]);
          }
        }),
        ...queries.map((q) async {
          try {
            return (radio: false, songs: await searchService.search(q, 'track'));
          } catch (_) {
            return (radio: false, songs: <Song>[]);
          }
        }),
      ], eagerError: false);
      for (final r in results) {
        candidates.addAll(r.songs);
        if (r.radio) radioIds.addAll(r.songs.map((s) => s.id));
      }

      // Exclude what's already here
      final haveIds = existingTracks.map((e) => e.id).toSet();
      final haveSigs = existingTracks.map(_songSig).toSet();
      final seen = <String>{};
      candidates.removeWhere((c) {
        final sig = _songSig(c);
        if (haveIds.contains(c.id) || haveSigs.contains(sig)) return true;
        if (_addedSuggestionIds.contains(c.id)) return true;
        // Also de-dupe the candidate pool against ITSELF: overlapping artist
        // searches return the same popular tracks repeatedly.
        return !seen.add(sig);
      });

      // Second half of the variety fix: actively avoid what the LAST refresh
      // showed. Rotating the seeds changes the pool, but the strongest few
      // candidates still tend to score their way back to the top, so without
      // this the same one or two rows survive every refresh.
      //
      // Applied as a preference, not a filter — if avoiding them would leave too
      // little to show, they come back rather than the section going empty.
      if (_shownSuggestionIds.isNotEmpty) {
        final fresh =
            candidates.where((c) => !_shownSuggestionIds.contains(c.id)).toList();
        if (fresh.length >= 10) {
          candidates
            ..clear()
            ..addAll(fresh);
        }
      }

      // Score against the PLAYLIST, then against global taste
      // The old code ranked purely by `intel.getSongScore`, which is the user's
      // overall taste. That is why a focused playlist got the same suggestions
      // as everything else: the playlist's own character never entered the sort.
      final maxWeight = fp.artistWeight.values.isEmpty
          ? 1.0
          : fp.artistWeight.values.reduce(math.max);
      // Blend, scaled by how much this playlist actually tells us
      //
      // Both halves are normalised to 0..1 FIRST, then mixed. That is the only
      // way any ratio means anything: the original version summed raw terms of
      // different magnitudes (a 0..1 fit next to an unbounded taste score next to
      // popularity/100), so the effective balance was whatever the numbers
      // happened to be rather than a decision.
      //
      // The weights come from the fingerprint, not from a constant — see
      // `_fingerprint` for the evidence/coherence reasoning. In practice: a
      // 5-track scratch list lands near 0.55 playlist / 0.45 taste, a 60-track
      // playlist built around a handful of artists near 0.92 / 0.08.
      final double kPlaylistWeight = fp.playlistWeight;
      final double kTasteWeight = fp.tasteWeight;

      // Global taste needs a normaliser, since getSongScore is unbounded.
      final rawTaste = {for (final s in candidates) s.id: intel.getSongScore(s)};
      final maxTaste = rawTaste.values.isEmpty
          ? 1.0
          : math.max(1e-6, rawTaste.values.reduce(math.max));

      final scored = candidates.map((s) {
        // Playlist component (80%)
        // How much this artist already defines the playlist.
        final familiarity = (fp.artistWeight[s.artist] ?? 0) / maxWeight;
        // Peaks at partial familiarity: an artist adjacent to the playlist beats
        // both a stranger and one already all over it.
        final fit = (1.0 - (familiarity - 0.35).abs() * 1.4).clamp(0.0, 1.0);
        // Era agreement, softened so it nudges rather than filters.
        double era = 0.5; // neutral when either side has no date
        final y = int.tryParse(
            RegExp(r'(19|20)\d{2}').firstMatch(s.releaseDate)?.group(0) ?? '');
        if (fp.medianYear != null && y != null) {
          era = 1.0 - ((y - fp.medianYear!).abs() / 25).clamp(0.0, 1.0);
        }
        final explicitFit =
            (s.isExplicit == true) == fp.mostlyExplicit ? 1.0 : 0.0;
        // Weighted inside the playlist half: artist fit is what "sounds like this
        // playlist" mostly means; era and explicitness are supporting evidence.
        var playlistScore =
            (fit * 0.65 + era * 0.25 + explicitFit * 0.10).clamp(0.0, 1.0);

        // The playlist's own evidence outranks a name match
        //
        // A track YouTube itself puts next to a recording IN this playlist is the
        // strongest "belongs here" signal available, and the artist-fit curve above
        // cannot see it: a genuinely adjacent artist who appears nowhere in the
        // playlist scores as a stranger. Without this lift the name-matched
        // candidates — mostly the playlist's own artists' back catalogue, and the
        // user's global favourites — kept out-ranking them, which is how the
        // section came to look untethered from the playlist in the first place.
        //
        // A LIFT TOWARD 1.0, not a flat bonus: it cannot push a score past the
        // maximum, and it lifts a weak-but-adjacent candidate more than one that
        // already scores well, so it changes the ORDER at the bottom without
        // flattening the top into a tie.
        if (radioIds.contains(s.id)) {
          playlistScore = (playlistScore + (1.0 - playlistScore) * 0.45)
              .clamp(0.0, 1.0);
        }

        // Taste component (20%)
        // Popularity lives here, not in the playlist half: a track being widely
        // liked says nothing about whether it belongs in THIS playlist.
        final taste = ((rawTaste[s.id] ?? 0) / maxTaste).clamp(0.0, 1.0);
        final tasteScore =
            (taste * 0.75 + (s.popularity / 100.0).clamp(0.0, 1.0) * 0.25);

        return (
          song: s,
          score: playlistScore * kPlaylistWeight + tasteScore * kTasteWeight,
        );
      }).toList();
      scored.sort((a, b) => b.score.compareTo(a.score));

      // Shuffle only the top slice, so refreshing gives variety without ever
      // surfacing the genuinely poor matches at the tail.
      final pool = scored.take(45).toList();
      pool.shuffle(math.Random(seed));

      // Diversity pass. ONE per artist for the first 8, two after.
      //
      // A flat cap of 2 looked fine against the 15-item pool but not against what
      // is actually SHOWN: the strip displays 5, and observed live it filled with
      // Rihanna ×2 + Katy Perry ×2 — four of five slots from two artists, which
      // reads as "we found two bands" rather than a suggestion set. The tighter
      // cap only applies while it can affect the visible rows.
      final out = <Song>[];
      final perArtist = <String, int>{};
      for (final item in pool) {
        if (out.length >= 15) break;
        final n = perArtist[item.song.artist] ?? 0;
        final cap = out.length < 8 ? 1 : 2;
        if (n >= cap) continue;
        out.add(item.song);
        perArtist[item.song.artist] = n + 1;
      }

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

    // DEFAULT MEANS "DON'T SORT" — it must return early, not sort with a
    // comparator that answers 0.
    //
    // `List.sort` in Dart is NOT stable. The old code handled the default case as
    // `default: return 0`, which tells an unstable sort that every pair is
    // interchangeable, so it was free to permute the list, and the "unsorted"
    // view could come back in a different order than the playlist actually has.
    //
    // Returning the source order untouched is also what makes Default correct
    // per-collection without special cases: a library playlist arrives in the
    // order tracks were added, and My Top 50 arrives in play-count order. Default
    // is whatever that collection's own order is.
    if (_currentSort == _kDefaultSort) return results;

    // "Recently added" used to live here too, comparing `a.id` to `b.id` —
    // YouTube video ids in alphabetical order, which has nothing to do with when
    // anything was added. It was dropped rather than repaired: tracks are
    // APPENDED, so the collection's own order already IS added-order, and Default
    // shows exactly that.
    // The key is lowercased once per track, NOT once per comparison
    //
    // THE COST THIS REMOVES. This ran `toLowerCase()` on BOTH sides inside the
    // comparator, and `toLowerCase()` allocates a new string every call. A sort
    // makes about n·log n comparisons, so a 500-track playlist sorted by title
    // allocated roughly nine thousand throwaway strings, and this method is
    // called from build(), so that happened again on every rebuild: a keystroke
    // in the search field, a scroll, any provider change.
    //
    // Decorating first makes it n allocations instead of 2·n·log n, and the
    // comparator becomes a plain string compare.
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

  /// The last (sort, size, direction) reported, so the line above says something
  /// when the sort CHANGES rather than on every rebuild.
  String _lastSortLogged = '';

  void _sharePlaylist(String title, String image, String subtitle) {
    final themeColor = ref.read(themeProvider);
    // The real playlist ID, NOT a placeholder.
    //
    // This passed the literal string "playlist_share", so the postcard had
    // nothing to identify the playlist by and could never print a link — the
    // card travelled with no way to reach what it depicted. externalId is the
    // catalog playlist id for a remote playlist; a LOCAL playlist has no
    // source to point at, and the empty string correctly yields no link.
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
    //`currentLibItem`, NOT `widget.libraryPlaylist`.
    //
    // The widget parameter is the LibraryItem captured when this page was pushed,
    // so it never changes while the page is open. Every other field here already
    // reads the live item from `libState` (see title/subtitle above) — the image
    // was the one that did not, which is why setting a new cover appeared to do
    // nothing until you went to the library and came back: the state HAD updated,
    // this page just wasn't looking at it.
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
    //"IS THIS A BUILT-IN FOLDER?" IS ANSWERED BY THE KNOWN SET, NOT BY A
    // PERSISTED FLAG.
    //
    // Editability used to trust `isSystemFolder` alone. That flag is stored in
    // the row and therefore corruptible — a duplicate cleanup set it on a user
    // playlist by reusing a helper meant for built-in folders, and the playlist
    // silently lost delete, rename and every customisation, on disk and in the
    // cloud. Repairing the data fixes the instance; deriving the answer fixes the
    // CLASS, because the built-in folders are a closed, known set
    // (kSystemLibraryTitles) and anything else cannot be one however its flag
    // reads.
    //
    // The flag is still required to be set — a genuine built-in folder has both —
    // so this only ever GRANTS editing that was wrongly withheld, and never the
    // reverse.
    final bool rowIsBuiltIn = (currentLibItem?.isSystemFolder ?? true) &&
        kSystemLibraryTitles.contains(currentLibItem?.title ?? '');
    final bool isEditable = !isRemote && !rowIsBuiltIn && !isPodcast;
    if (!isEditable) {
      print('playlist "${currentLibItem?.title ?? "?"}" NOT editable: '
          'isRemote=$isRemote (external=$isExternal local=$isLocal) '
          'flag=${currentLibItem?.isSystemFolder} '
          'knownBuiltIn=${kSystemLibraryTitles.contains(currentLibItem?.title ?? '')} '
          'isPodcast=$isPodcast');
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
            // Universal premium header
            // Tracks (not just their count) so the header can also show the
            // collection's live running time.
            _buildPremiumHeader(title, subtitle, themedIconPath, isEditable, themeColor, filteredTracks),

            // SEARCH & ACTION ROW (Pass the new flag here!)
            // While selecting, the batch bar REPLACES the Play row rather than
            // sitting beside it — the two would compete for the same tap, and
            // "Play" during a selection has no obvious meaning.
            if (_editMode)
              _buildSelectionBar(themeColor, filteredTracks, title,
                  isEditable || title == "Liked Songs")
            else
              _buildPremiumActionRow(themeColor, filteredTracks, isShuffleOn, title, isExternal, image, subtitle, showDownload),

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
              else if (filteredTracks.isNotEmpty && title != "Downloads" && title != "Cached" && title != "My Top 50")
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

  // --- PREMIUM SPOTIFY/APPLE UI REDESIGN ---

  /// Opens the downloads folder in the user's file manager.
  ///
  /// Goes through a NATIVE intent rather than `url_launcher`. url_launcher can
  /// only fire a plain ACTION_VIEW, which Google's DocumentsUI claims, so the
  /// button landed in "Files" instead of Samsung's "My Files", the app a Samsung
  /// owner actually browses with. The native side tries the OEM's own
  /// jump-to-path intent first. See MainActivity.openFolder.
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

  /// Playlist header, rebuilt to speak the same language as [AlbumPage].
  ///
  /// It used to be a 380px tower: a 192×192 cover floating dead centre with the
  /// title and meta stacked and centred under it. That is the layout every other
  /// music app uses, and it had two problems here — it cost more than half a
  /// screen before a single track was visible, and it looked like it came from a
  /// different app than the album page sitting one tap away.
  ///
  /// Now: album's LEFT-ALIGNED ROW — cover beside a metadata column, the
  /// small-caps type overline, the same title weight and the same muted meta
  /// line. 300px instead of 380, and a 128px cover instead of 192.
  ///
  /// Deliberately NOT identical to the album header, because a playlist is
  /// not an album:
  ///   • The cover is SMALLER again (128 vs album's 148). An album cover is the
  ///     artwork of the record; a playlist cover is a label on a container, and
  ///     sizing it like art oversells it.
  ///   • No artist link row — a playlist has no single artist.
  ///   • It carries the edit affordance, which an album can never have.
  ///   • The overline names the collection ("PLAYLIST", "DOWNLOADS"…), where the
  ///     album's names a record type.
  /// Seconds from a duration string — "m:ss", "h:mm:ss", or raw seconds.
  /// 0 when nothing parses.
  int _durationSeconds(String raw) {
    final d = raw.trim();
    if (d.isEmpty) return 0;
    if (!d.contains(':')) return int.tryParse(d) ?? 0;
    final parts = d.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  /// Total running time of the collection — "1 hr 12 min" / "43 min".
  ///
  /// Unlike an album's, a playlist's length is DYNAMIC: this is recomputed from
  /// the live track list on every build, so adding, removing or reordering a
  /// track moves the number immediately, with no cache to invalidate.
  ///
  /// Playlist rows come from mixed sources and some carry no duration at all
  /// (imported local files, rows saved before durations were stored). Summing
  /// over a partial set understates the real length, so the label is prefixed
  /// with "~" whenever a track didn't contribute — an approximation that says so
  /// is worth more than a confident wrong total.
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

  Widget _buildPremiumHeader(String title, String subtitle, String imagePath,
      bool isEditable, Color themeColor, List<Song> tracks) {
    final int trackCount = tracks.length;
    final String durationLabel = _totalDurationLabel(tracks);
    // Sized to the CONTENT, not to a round number: status bar + toolbar (~90)
    // + the 128 cover + 18 of breathing room. 300 left an obvious empty band
    // above the cover, which is the same "too much space" problem in a new
    // place. Album needs its 316 because its column carries an extra artist row.
    const double expanded = 250.0;
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
        // Multi-select entry point. In the app bar, not on long-press: long-press
        // opens the track's content menu, and one gesture meaning two things
        // depending on invisible state produces accidental selections.
        // Edit belongs to every playlist that is ours to change — NOT only the
        // ones with something to reorder.
        //
        // THIS WAS GATED ON `trackCount > 1`, WHICH AGED BADLY. It was written
        // when edit mode meant one thing, reordering, where a lone track really
        // is a no-op. Edit mode has since grown rename, cover art and bulk
        // selection, so the gate was hiding the ONLY way to rename a playlist
        // from exactly the playlists most likely to need it: the one you just
        // made, which has nothing in it yet.
        //
        // Worse, `trackCount` is the FILTERED count, so typing in the search box
        // until one track matched made the button disappear mid-edit.
        //
        // Reordering one track is harmless; being unable to rename is not.
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
            // OPENS the folder rather than reciting its path.
            //
            // It used to show a dialog quoting "/storage/emulated/0/Music/Auvy" —
            // information the user then had to carry to a file manager by hand.
            // A button that names a destination should go there.
            onTap: () async {
              HapticService.selection();
              final opened = await _openDownloadsFolder();
              if (!opened) {
                // No file manager answered the intent. Fall back to telling them
                // where it is — the old behaviour, now only for the case where it
                // is genuinely the best available answer.
                AnimatedToast.message('Saved in Music/Auvy on this device');
              }
            },
          ),
        const SizedBox(width: 8),
      ],
      // No blur here at all: the page already sits on the (cached, blurred)
      // DynamicBackground. The old header re-blurred the cover at sigma 50 on
      // every collapse/stretch frame — pure jank for near-zero visual gain.
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
                                Container(
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
                                // Editing the cover is playlist-only, so it gets
                                // to be the one thing the album header has no
                                // equivalent for. Smaller than before: it is an
                                // affordance on the artwork, not a feature of it.
                                //
                                // EDIT MODE ONLY, like the rename and the
                                // reorder handles. A pencil sitting permanently
                                // on the artwork is a live control on a screen
                                // you are usually just browsing — one stray tap
                                // opens a full-screen cover picker over the
                                // playlist you were reading. Everything that
                                // CHANGES the playlist now lives behind the same
                                // single switch.
                                if (isEditable && _editMode)
                                  Positioned(
                                    bottom: 6,
                                    right: 6,
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
                                  // In edit mode the NAME is the control.
                                  //
                                  // A separate rename button inside edit mode
                                  // read as a mode within a mode — you press
                                  // edit, then hunt for a second button. Tapping
                                  // the thing you want to change is the whole
                                  // point of an edit mode, so the title carries
                                  // it, with a pencil so it is visibly tappable
                                  // rather than a hidden gesture.
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

  /// Batch actions over the current selection — the row that replaces the Play
  /// pill while [_editMode] is on.
  ///
  /// Every action here is one the user would otherwise repeat per track, which is
  /// the entire reason to have selection at all. "Remove" only appears for lists
  /// the user actually owns; you cannot delete out of someone else's playlist or
  /// out of My Top 50.
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
      backgroundColor: const Color(0xFF161616),
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

  Widget _buildPremiumActionRow(Color themeColor, List<Song> filteredTracks, bool isShuffleOn, String title, bool isExternal, String image, String subtitle, bool showDownload) {
    // select() — the old whole-provider watch rebuilt this row (and the whole
    // page body with it) on every periodic PlayerState write.
    final isThisPlaylistActive =
        ref.watch(playerProvider.select((s) => s.playbackSource == title));
    final isPlaying =
        ref.watch(playerProvider.select((s) => s.isPlaying)) && isThisPlaylistActive;
    final isLiked = ref.watch(libraryProvider.select((s) => s.likedPlaylists.any((p) => p.title == title)));

    // Layout adopted from the album page
    // Play LEADS as a full-width pill, and every secondary action is an equal
    // quiet circle after it. The old row put utilities on the left, a Spacer in
    // the middle and an oversized 54px FAB on the right, so the two pages read
    // as different apps, and the primary action sat at the far edge, furthest
    // from the thumb's resting arc on a one-handed grip.
    //
    // Order matches the album page exactly: Play · Shuffle · Queue · Like ·
    // Download. Only the pill's LABEL differs, because a playlist page can be
    // the thing currently playing, so it doubles as pause.
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
                      // `source` is the KIND of place ("PLAYING FROM PLAYLIST")
                      // and `locationName` is its NAME — the header renders them
                      // as two separate lines. Passing the title as `source` put
                      // the name on the kind line and left the name line falling
                      // back to the track's own albumTitle.
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
                // Shuffle the queue we are about to hand over
                //
                // This used to call toggleShuffle() and then playSong(newQueue:
                // filteredTracks). toggleShuffle reorders the queue that exists
                // AT THAT MOMENT — the previous one, and playSong then replaced
                // it with this playlist in its original order, so the shuffle was
                // applied to the wrong queue and thrown away.
                //
                // Worse, it was conditional on the GLOBAL shuffle flag: with
                // shuffle already on, the toggle was skipped entirely and the
                // playlist played in order from a random starting track. That is
                // the "sometimes it shuffles, sometimes it doesn't" report — the
                // behaviour depended on state left over from somewhere else.
                //
                // Shuffling here makes it deterministic: the list handed to
                // playSong is already in the order it should play, whatever the
                // flag was before.
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
            const SizedBox(width: 10),
            _ActionIcon(
              icon: Icons.queue_music_rounded,
              color: _isQueued ? themeColor : Colors.white.withOpacity(0.85),
              onTap: () async {
                if (filteredTracks.isEmpty) return;
                HapticService.medium();
                final notifier = ref.read(playerProvider.notifier);
                // The toast reports what happened, NOT what was intended
                //
                // The remove branch used to show "Removed from Queue" and call
                // nothing at all — there was no bulk remove to call, so the
                // tracks stayed queued while the UI said they had gone.
                // [removeListFromQueue] returns a COUNT so this can say the true
                // thing, including when nothing matched.
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
                        // Await and report: a silent failure here is what made
                        // "Downloads" look empty with no explanation.
                        // Declared as a playlist so the files land in
                        // Playlists/<name> with the numbered convention, instead
                        // of a flat pile in Singles/.
                        // Drive the progress banner: this path downloads
                        // serially and reported nothing at all until it
                        // finished, which on a long playlist is minutes of
                        // apparent inactivity.
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
                          // Without this the banner would outlive a throw —
                          // the stuck-indicator bug, reintroduced by the one
                          // path that does not go through library_provider.
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
              // Shared pill. See [AuvySearchField] for why the hint used to sit
              // off-centre here and on every other search box in the app.
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
                // No scroll while typing.
                //
                // This called _autoScrollToSearch() on EVERY keystroke — a fresh
                // 500ms animateTo per character, each one interrupting the last,
                // while the result list simultaneously grew and shrank underneath.
                // That is the page "jumping up and down as you type". Filtering
                // now only rebuilds the list; the viewport stays where the user
                // put it.
                onChanged: (v) => setState(() => _searchQuery = v),
                // Submitting is the deliberate "take me to the results" gesture,
                // so that, and only that — moves the page.
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _autoScrollToSearch(),
                trailing: _searchQuery.isEmpty
                    ? null
                    : GestureDetector(
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
            const SizedBox(width: 10),
            _buildSortButton(),
          ],
        ),
      ),
    );
  }

  // --- REST OF FILE REMAINS IDENTICAL TO YOUR PREVIOUS LOGIC ---

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

  /// The suggestion strip, rebuilt.
  ///
  /// THE REFRESH JUMP. This used to hang `key: ValueKey(_suggestionSeed)` on
  /// the FutureBuilder. Changing a key DESTROYS the subtree, so every refresh
  /// replaced five rows with a small spinner — the sliver's height collapsed by
  /// several hundred pixels, the scroll view clamped the offset to the new
  /// extent, and the user was yanked up a section. The key was never needed:
  /// `_getTrackSuggestions` is memoised on `_suggestionSeed`, so bumping the seed
  /// already yields a new future.
  ///
  /// Now the previous results stay on screen while the next set loads, so the
  /// section's height never changes and the scroll position cannot move. Only the
  /// refresh icon indicates work.
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
    final c = _fingerprint(tracks).confidence;
    if (c >= 0.72) return 'Closely matched to what’s already in this playlist';
    if (c >= 0.45) return 'Based on this playlist, tuned by your taste';
    return 'Mostly your taste — add more tracks to sharpen this';
  }

  /// Adds a suggestion, reporting what actually happened.
  ///
  /// `addSongToPlaylist` returns false when the playlist already had the track,
  /// and this used to claim "Added to X" either way.
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
          // Spotify behavior: the rest of the DISPLAYED list (current sort /
          // filter) queues up after the tapped track. playSong finds the song
          // by id and slices the list there. Podcasts keep their own flow.
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

/// Flat 44px action icon used in the playlist action row.
/// One suggested track.
///
/// Lighter than the playlist's own track tiles on purpose: these are candidates,
/// not contents, so they get smaller artwork, no index number and no swipe
/// actions. The whole row previews the track; only the ring adds it, so tapping
/// to hear something can never silently change your playlist.
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
              builder: (btnContext) => GestureDetector(
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
          ],
        ),
      ),
    );
  }
}

/// A playlist described by its own contents, for suggestion ranking.
/// Built by `_PlaylistPageState._fingerprint`. See there for why each field
/// exists and what it replaced.
class _PlaylistFingerprint {
  /// Artist → weight, over EVERY track, counting featured credits and biased
  /// toward recently-added entries.
  final Map<String, double> artistWeight;

  /// [artistWeight] keys, heaviest first. The suggestion seeds.
  final List<String> topArtists;

  /// Median release year, or null when no track carries a parseable date.
  final int? medianYear;

  /// ≥70% of tracks share one album — a listening context rather than a taste
  /// profile, so suggestions should reach outside it.
  final bool dominatedBySingleAlbum;

  final bool mostlyExplicit;
  final int trackCount;

  /// How far to trust this playlist over general taste, 0.45…0.95. Derived from
  /// evidence (track count, saturating) and coherence (artist concentration)
  /// rather than fixed. See `_fingerprint` for why a constant ratio is the wrong
  /// shape.
  final double playlistWeight;

  /// The 0…1 confidence [playlistWeight] was derived from. Drives the header
  /// copy, so the blend the ranking is using is visible rather than hidden.
  final double confidence;

  double get tasteWeight => 1.0 - playlistWeight;

  const _PlaylistFingerprint({
    required this.artistWeight,
    required this.topArtists,
    required this.medianYear,
    required this.dominatedBySingleAlbum,
    required this.mostlyExplicit,
    required this.trackCount,
    required this.playlistWeight,
    required this.confidence,
  });
}

/// Quiet circular secondary action — the playlist page's counterpart to its Play
/// pill, and deliberately identical to the album page's `_circleAction` (46px,
/// 7% white fill, 8% hairline border, 20px glyph) so the two pages' action rows
/// are the same control at the same size in the same order.
///
/// These used to be bare 26px glyphs with no chip behind them, which is why the
/// row read as a loose collection of icons rather than a set of buttons.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool disabled;
  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
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

  const _SwipeablePlaylistTile({super.key, required this.index, required this.song, required this.onTap, required this.onDelete, required this.onQueue, required this.onInfo, this.isInfoOnly = false, this.canReorder = true, this.selectable = false, this.selected = false, this.onToggleSelect});

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
        // Swipe actions WITHDRAWN while selecting — a stray horizontal drag would
        // otherwise delete a track the user was only trying to tick.
        //
        // APP-WIDE SWIPE CONVENTION — DO NOT MAKE THIS PAGE AN EXCEPTION.
        //
        //   drag RIGHT (leftAction)  = QUEUE on any track row, on every page.
        //                              PIN on a library folder tile — that page
        //                              has no queue action, and pinning is its
        //                              equivalent everyday, harmless one.
        //   drag LEFT  (rightAction) = the row's secondary action: add to
        //                              playlist, like, or the DESTRUCTIVE one
        //                              where the row has one (always red).
        //
        // Queue is the action you repeat dozens of times a session, so it gets
        // the one direction that never changes meaning. Everything destructive
        // shares the OTHER side, and nothing harmless is mixed in with it.
        //
        // The sides were the other way round, AND the comment here claimed a
        // CONSISTENCY THAT DID NOT EXIST. It said every destructive swipe lived
        // on one side, while this page put DELETE on a right-drag and the library
        // page put REMOVE on a left-drag — a direct contradiction between two
        // screens, described as a convention. Both now agree.
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
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w500)),
            subtitle: TrackDownloadBar(
              songId: song.id,
              fallback: Text(song.displayArtist, style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12)),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Play count, the same field on every page. See [trackRowViews].
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
                // Drag handle withdrawn while selecting: reordering and selecting
                // are different jobs, and the handle's own drag recogniser would
                // compete with the row's tap-to-tick.
                // Shown whenever the list is reorderable, which is edit mode only.
                // It used to be withdrawn while selecting, back when those were
                // separate modes; they are the same mode now and the gestures do
                // not compete (drag must start ON the handle).
                if (canReorder) ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle, color: Colors.white54)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
