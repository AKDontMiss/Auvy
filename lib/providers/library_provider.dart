import 'dart:convert';
import 'dart:async';
import 'dart:io' show File;
import 'package:http/http.dart' as http;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/services/external_catalog_service.dart';
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:auvy/data/podcast_model.dart'; 
import 'package:auvy/providers/podcast_provider.dart'; 
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/logic/library_integrity.dart';
import 'package:auvy/logic/stall_watchdog.dart';
import 'package:auvy/providers/recent_playlists_provider.dart'
    show recentPlaylistsProvider;
import 'package:auvy/providers/intelligence_provider.dart'
    show computeTop50, intelligenceProvider;
import 'package:auvy/services/audio_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/providers/download_provider.dart';

// Defines sorting options for library items.
/// The user's library: liked songs, playlists, albums, artists and downloads.
///
/// Saving is the dangerous part
///
/// This state is the one thing in the app that cannot be re-fetched — losing it
/// loses the user's own curation. An overnight wipe was traced to a save that
/// raced a load: a derived refresh wrote an empty library to disk before the real
/// one had finished loading, and the empty version then synced to the cloud.
///
/// Several guards exist because of that and must not be removed casually: the
/// save path snapshots before writing, refuses to persist a collection it did not
/// load, excludes derived folders, and compares before writing so an identical
/// save is a no-op. Read the notes on the save path before changing it.
///
/// Lifecycle is routed through [LibraryLifecycleHook] rather than raw
/// AppLifecycleState: Android sends hidden AND paused when the app backgrounds,
/// and treating those as two events used to double every cloud push.

enum SortOption { dateAdded, name, songCount }
final downloadProgressProvider = StateProvider<double>((ref) => 0.0);

// State container for all library-related data and UI preferences.
class LibraryState {
  final LibraryCategory selectedCategory;
  final SortOption sortOption;
  final bool isGrid;
  final String searchQuery;
  final List<LibraryItem> filteredItems;
  final List<LibraryItem> allItems;
  final Set<String> likedSongIds; 
  final List<Song> likedSongs; 
  final List<Album> likedAlbums;
  final List<Album> followedPodcasts;
  final List<LibraryItem> likedPlaylists;
  final List<Song> subscribedArtists;
  final Map<String, List<Song>> playlistSongs; 
  final Map<String, double> downloadProgressMap;

  LibraryState({
    this.selectedCategory = LibraryCategory.all,
    this.sortOption = SortOption.dateAdded,
    this.isGrid = false,
    this.searchQuery = '',
    this.filteredItems = const [],
    this.followedPodcasts = const [],
    this.allItems = const [],
    this.likedSongIds = const {},
    this.likedSongs = const [],
    this.likedAlbums = const [],
    this.likedPlaylists = const [],
    this.subscribedArtists = const [],
    this.playlistSongs = const {},
    this.downloadProgressMap = const {},
  });

  // Returns a new state instance with updated fields.
  LibraryState copyWith({
    LibraryCategory? selectedCategory,
    SortOption? sortOption,
    bool? isGrid,
    String? searchQuery,
    List<LibraryItem>? filteredItems,
    List<LibraryItem>? allItems,
    Set<String>? likedSongIds,
    List<Song>? likedSongs,
    List<Album>? likedAlbums,
    List<LibraryItem>? likedPlaylists,
    List<Song>? subscribedArtists,
    Map<String, List<Song>>? playlistSongs,
    Map<String, double>? downloadProgressMap, 
  }) {
    return LibraryState(
      selectedCategory: selectedCategory ?? this.selectedCategory,
      sortOption: sortOption ?? this.sortOption,
      isGrid: isGrid ?? this.isGrid,
      searchQuery: searchQuery ?? this.searchQuery,
      filteredItems: filteredItems ?? this.filteredItems,
      allItems: allItems ?? this.allItems,
      likedSongIds: likedSongIds ?? this.likedSongIds,
      likedSongs: likedSongs ?? this.likedSongs,
      likedAlbums: likedAlbums ?? this.likedAlbums,
      likedPlaylists: likedPlaylists ?? this.likedPlaylists,
      subscribedArtists: subscribedArtists ?? this.subscribedArtists,
      playlistSongs: playlistSongs ?? this.playlistSongs,
      downloadProgressMap: downloadProgressMap ?? this.downloadProgressMap
    );
  }
}

// Notifier that handles library persistence, playlist management, and user favorites.
/// Everything a [LibraryNotifier.deleteItem] removed, so
/// [LibraryNotifier.restoreItem] can put it all back (the Undo path).
class DeletedLibraryItem {
  final LibraryItem item;
  final List<Song>? songs;
  final Album? likedAlbum;
  final LibraryItem? likedPlaylist;

  /// Where [item] sat in allItems when deleted, so Undo puts it back in its
  /// original spot instead of appending it to the end of the library.
  final int index;

  const DeletedLibraryItem({
    required this.item,
    this.songs,
    this.likedAlbum,
    this.likedPlaylist,
    this.index = -1,
  });
}

class LibraryNotifier extends StateNotifier<LibraryState> {
  final Ref ref;
  Timer? _refreshTimer;
  /// Collapses a burst of cache events into one refresh. See onCacheUpdated.
  Timer? _cacheEventDebounce;

  /// Whether Auvy is the app in front. Gates the folder sweep. See the timer.
  bool _appInForeground = true;
  LibraryLifecycleHook? _lifecycleHook;
  DateTime? _lastPodcastRefresh; //  Tracks the 6-hour refresh interval

  AudioService? _audioService;
  AudioService get _audio => _audioService ??= AudioService();

  LibraryNotifier(this.ref) : super(LibraryState(
    filteredItems: libraryItems, 
    allItems: libraryItems,
    downloadProgressMap: const {}, 
  )) {
    _init(); 

    // SAFETY-NET polling only — 15 minutes, not 5.
    //
    // `cacheManager.onCacheUpdated` (wired in _init) already fires on every real
    // cache/download change, so this timer exists purely to catch changes made
    // outside the app (files copied into Music/Auvy by a file manager). Each tick
    // is two recursive DIRECTORY SCANS, and it kept firing every 5 minutes for as
    // long as the process lived — including fully idle in the background. Tripling
    // the interval cuts that idle disk/CPU churn ~3× with no functional change;
    // the podcast refresh below is gated on its own 12-hour check, so a slower
    // tick can't delay it meaningfully.
    // And it only scans while the app is in front.
    //
    // The point of the sweep is to notice files a FILE MANAGER put in
    // Music/Auvy. Nobody copies files into the folder and then keeps staring at
    // Auvy — they leave, do it, and come back, so a scan while Auvy is
    // backgrounded finds nothing that a scan on return would miss, and the
    // resume hook below covers exactly that case. Skipping it stops two
    // recursive directory walks every quarter of an hour on a phone in a pocket.
    _refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (!mounted) return;
      if (!_appInForeground) return;
      refreshCachedFolder();
      refreshDownloadsFolder();

      // Podcast episodes refresh at most twice a day, on its own clock.
      final now = DateTime.now();
      if (_lastPodcastRefresh == null ||
          now.difference(_lastPodcastRefresh!).inHours >= 12) {
        _lastPodcastRefresh = now;
        _refreshAllPodcasts();
      }
    });

    // Coming back to the app is when a change made elsewhere becomes worth
    // looking for, so the scan the timer skipped happens here instead.
    _lifecycleHook = LibraryLifecycleHook(
      onResume: () {
        _appInForeground = true;
        if (mounted) {
          refreshCachedFolder();
          refreshDownloadsFolder();
        }
      },
      onPause: () {
        _appInForeground = false;
        // The last moment this device is certain to get.
        //
        // A change schedules its cloud push on a Dart timer — 30s of debounce,
        // then possibly another wait for the 5-minute rate floor. Closing the
        // app kills the process and both timers, so the write was never issued
        // and the edit lived only in local prefs. It looked fine until anything
        // restored over it (a second device, a reinstall, signing in again),
        // and then it was gone with no trace that it had ever existed.
        //
        // Issuing the write here is enough even if the process dies a second
        // later: Firestore persists pending writes to disk and replays them on
        // the next launch or reconnect. That durable queue is the local buffer
        // this needs, and it was always there — nothing was ever handed to it.
        // Order matters: get the taste/history debounce onto DISK first, then
        // push. Pushing first would upload a snapshot that is missing whatever
        // the last few seconds recorded.
        ref.read(intelligenceProvider.notifier).flushPendingSave().whenComplete(
            () => CloudSyncService.instance
                .flushPendingNow(reason: 'app backgrounded'));
      },
    );
    WidgetsBinding.instance.addObserver(_lifecycleHook!);

    // CRITICAL: Cleanup timer when the provider is destroyed
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _cacheEventDebounce?.cancel();
      if (_lifecycleHook != null) {
        WidgetsBinding.instance.removeObserver(_lifecycleHook!);
        _lifecycleHook = null;
      }
    });
  }

  // Loads saved library data from local storage on startup.
  Future<void> _init() async {
    final cacheManager = AudioCacheManager();
    await cacheManager.initialize();
    
    // Event-driven update: Primary source of truth for UI refreshes.
    //
    // COALESCED, BECAUSE THIS ARRIVES IN BURSTS. The cache fires one event per
    // TRACK, so a queue top-up or a scan produces a storm — measured on device:
    //
    //     18:23:07.117 Cache update detected, refreshing library...
    //     …26 of them inside 250ms…
    //
    // and each one recomputed all five folder counts, re-sorted the library AND
    // took a `refreshDownloadsFolder` → `_saveToDisk` write. That is 26 library
    // serializations for one user action, every one of them also a chance to hit
    // the empty-save race described below.
    //
    // Debounced rather than dropped: the work still happens, once, just after the
    // burst ends. 300ms is well under the time it takes to notice a folder count
    // being stale and well over the width of these bursts.
    cacheManager.onCacheUpdated = () {
      _cacheEventDebounce?.cancel();
      _cacheEventDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        print("Cache update detected, refreshing library...");
        refreshCachedFolder();
        refreshDownloadsFolder();
        _ensureCachedExcludesDownloads();
        _applyFilterAndSort();
      });
    };

    // THE PERSISTED LIBRARY IS READ FIRST. DO NOT MOVE THE SCAN BACK ABOVE IT.
    //
    // `scanAndImportDownloads` is deliberately not awaited, and finding anything
    // fires `onCacheUpdated`, which calls refreshDownloadsFolder → _saveToDisk.
    // Started before the read below, that save could land while this method was
    // still awaiting prefs, writing the EMPTY startup state over the stored
    // library and then pushing the emptiness to the cloud on the next backup.
    // One unlucky interleave and every playlist, like and followed artist was
    // gone from both copies — the "it erased my library overnight" report.
    //
    // The scan now starts after the library is in memory, so the worst a cache
    // callback can do is persist the state that was just loaded. `_loaded`
    // below is the belt to this braces.
    final prefs = await SharedPreferences.getInstance();
    var savedData = prefs.getString(_kLibraryKey);

    // Last-known-good fallback
    // A copy of the last save that actually held user content. If the live blob
    // is missing or has been reduced to nothing, this is what the library comes
    // back from instead of starting empty. It is cleared with the rest of the
    // user's data on an account switch (see _userDataKeys in account_provider),
    // so it can never resurrect a previous account's library.
    final lastGood = prefs.getString(_kLibraryBackupKey);
    if (lastGood != null && lastGood.isNotEmpty && !_blobHasUserContent(savedData)) {
      if (_blobHasUserContent(lastGood)) {
        print("The stored library is empty but the last-known-good snapshot "
            "is not — restoring from the snapshot.");
        savedData = lastGood;
      }
    }

    // System folder initializers
    final cachedFolder = LibraryItem(
      title: "Cached",
      subtitle: "Playlist • 0 songs", 
      image: "assets/images/playlist_cyan.webp", 
      category: LibraryCategory.playlist,
      isSystemFolder: true,
      dateAdded: DateTime.now().add(const Duration(seconds: 1)),
    );

    final downloadsFolder = LibraryItem(
      title: "Downloads", 
      subtitle: "Playlist • 0 songs", 
      image: "assets/images/playlist_purple.webp",
      category: LibraryCategory.playlist,
      isSystemFolder: true, 
      dateAdded: DateTime.now().add(const Duration(seconds: 2)),
    );

    final likedPlaylistsFolder = LibraryItem(
      title: "Liked Playlists",
      subtitle: "Playlist • 0 playlists",
      image: "assets/images/playlist_orange.webp",
      category: LibraryCategory.playlist,
      isSystemFolder: true,
      dateAdded: DateTime.now().add(const Duration(seconds: 3)),
    );
    
    if (savedData != null) {
      try {
        final Map<String, dynamic> json = jsonDecode(savedData);
        var allItems = (json['allItems'] as List)
            .map((i) { try { return LibraryItem.fromMap(i); } catch (_) { return null; } })
            .whereType<LibraryItem>()
            .toList();
        
        allItems.removeWhere((item) => item.title == "Cached" || item.title == "Downloads" || item.title == "Liked Playlists");
        allItems.insert(0, likedPlaylistsFolder);
        allItems.insert(0, downloadsFolder);
        allItems.insert(0, cachedFolder);

        // MIGRATION: "Your Artists" → "Followed Artists"
        //
        // The folder title is persisted, so a rename needs a migration.
        //
        // The title is not just a label: it is the identity of the row inside
        // `allItems`, the key `_updateSystemFolder` looks up to write a new count,
        // and what `_getThemedIcon` and the tap handler switch on. Renaming the
        // constants alone would leave every existing install with a row still
        // called "Your Artists", so a second "Followed Artists" row would appear
        // beside it and the count on neither would update.
        //
        // Rewritten in place, which preserves the row's pin state and dateAdded
        // (so it keeps its position in the grid) rather than dropping and
        // re-adding it.
        for (var i = 0; i < allItems.length; i++) {
          if (allItems[i].title == "Your Artists") {
            final old = allItems[i];
            allItems[i] = LibraryItem(
              title: "Followed Artists",
              subtitle: old.subtitle,
              image: old.image,
              isPinned: old.isPinned,
              isCircle: old.isCircle,
              category: old.category,
              dateAdded: old.dateAdded,
              songCount: old.songCount,
              isSystemFolder: true,
            );
            print('Library migration: "Your Artists" → "Followed Artists"');
          }
        }

        // Followed Podcasts is NEW, so no install has it on disk. Added if
        // absent, positioned next to Followed Artists as its sibling.
        if (!allItems.any((i) => i.title == "Followed Podcasts")) {
          final artistIdx =
              allItems.indexWhere((i) => i.title == "Followed Artists");
          final podcastFolder = LibraryItem(
            title: "Followed Podcasts",
            subtitle: "Folder • 0 Podcasts",
            image: "assets/images/followed_podcasts_cyan.webp",
            isPinned: true,
            isCircle: false,
            category: LibraryCategory.folder,
            dateAdded: DateTime.now().add(const Duration(seconds: 4)),
            isSystemFolder: true,
          );
          allItems.insert(
              artistIdx >= 0 ? artistIdx + 1 : allItems.length, podcastFolder);
        }
        
        // One bad row must NOT cost the whole library.
        //
        // These five lists used to be parsed with a bare `.map(fromMap)`, so a
        // single unreadable entry — a song saved by an older build, a field that
        // changed shape, one truncated record — threw out of the whole `try`,
        // latched `_loadFailed`, and left EVERY collection empty on screen:
        // playlists, likes, followed artists, all of it, from one damaged row.
        // `allItems` and `playlistSongs` were already guarded per item; these
        // were the ones that weren't, which is why the loss always looked total.
        //
        // Skipping the unreadable row loses exactly that row and keeps the rest.
        List<T> parseEach<T>(dynamic raw, T Function(Map<String, dynamic>) from,
            String label) {
          if (raw is! List) return <T>[];
          final out = <T>[];
          var dropped = 0;
          for (final e in raw) {
            try {
              out.add(from(e as Map<String, dynamic>));
            } catch (_) {
              dropped++;
            }
          }
          if (dropped > 0) {
            print("WARN: library: skipped $dropped unreadable $label entr"
                "${dropped == 1 ? 'y' : 'ies'} (kept ${out.length})");
          }
          return out;
        }

        final likedSongs =
            parseEach(json['likedSongs'], Song.fromMap, 'liked song');
        final likedSongIds = Set<String>.from(likedSongs.map((s) => s.id));
        final likedAlbums =
            parseEach(json['likedAlbums'], Album.fromMap, 'liked album');
        final likedPlaylists = parseEach(
            json['likedPlaylists'], LibraryItem.fromMap, 'liked playlist');
        final subscribedArtists = parseEach(
            json['subscribedArtists'], Song.fromMap, 'followed artist');
        
        final Map<String, List<Song>> playlistSongs = {};
        final playlistJson = json['playlistSongs'] as Map<String, dynamic>? ?? {};
        playlistJson.forEach((key, value) {
          try {
            playlistSongs[key] = (value as List)
                .map((s) {
                  try { return Song.fromMap(s as Map<String, dynamic>); }
                  catch (_) { return null; }
                })
                .whereType<Song>()
                .toList();
          } catch (_) {}
        });
        
        // #18/#21 — DIAGNOSE + HEAL dead cover paths (see _healDeadImages).
        final stats = _ImageHealStats();
        final healedLikedSongs = likedSongs.map((s) => _healSong(s, stats)).toList();
        final healedItems = allItems.map((i) => _healItem(i, stats)).toList();
        final healedPlaylistSongs = <String, List<Song>>{};
        playlistSongs.forEach((k, v) {
          healedPlaylistSongs[k] = v.map((s) => _healSong(s, stats)).toList();
        });
        stats.report();

        // Repair: a user playlist wrongly marked as a system folder
        //
        // `isSystemFolder` is what `deletePlaylist` and the edit affordances gate
        // on, and it is PERSISTED, so anything that sets it by mistake takes
        // away delete, rename and every customisation permanently, and saves that
        // state to disk and to the cloud.
        //
        // A duplicate cleanup did exactly that by reusing `_updateSystemFolder`
        // (which hardcodes the flag) to refresh a playlist's count. The cause is
        // fixed, but installs that already ran it have the damaged row, so it is
        // repaired on load: the built-in folders are a KNOWN, closed set, and any
        // other row claiming to be one is wrong by definition.
        var unmarked = 0;
        for (var i = 0; i < allItems.length; i++) {
          final it = allItems[i];
          if (!it.isSystemFolder || kSystemLibraryTitles.contains(it.title)) {
            continue;
          }
          allItems[i] = LibraryItem(
            title: it.title,
            subtitle: it.subtitle,
            image: it.image,
            isPinned: it.isPinned,
            isCircle: it.isCircle,
            category: it.category,
            dateAdded: it.dateAdded,
            songCount: it.songCount,
            isSystemFolder: false,
          );
          unmarked++;
        }
        if (unmarked > 0) {
          print('library: restored $unmarked playlist(s) that had been '
              'wrongly locked as system folders — delete and edit work again');
          // WRITTEN BACK, NOT JUST PATCHED IN MEMORY. Without this the flag
          // stays wrong on disk AND in the cloud backup, so every launch repairs
          // it again and a restore onto another device brings the damage with it.
          // Scheduled after this load completes, because _saveToDisk refuses to
          // write until `_loaded` is set below.
          _pendingRepairSave = true;
        }

        // Orphaned playlists: songs with no row to open them from
        //
        // A PLAYLIST IS TWO SEPARATE PIECES OF STORAGE. Its tracks live in
        // `playlistSongs[name]`; the row the Library page actually renders lives
        // in `allItems`. They are also two separate CLOUD BLOBS —
        // `auvy_lib::pl.<hash>` per playlist and `auvy_lib::allItems` for the
        // rows, so any restore that lands one without the other leaves the
        // tracks present and completely unreachable. Reported as "where are my
        // library playlists, nothing is coming back restored" while the restore
        // log honestly said `11 playlist(s)`: the songs were there, the rows
        // were not.
        //
        // Rebuilding the row is safe and lossless — the name and the track list
        // are all a row needs, and a playlist that has tracks is by definition
        // one the user made. Matching on title, which is the identity
        // `playlistSongs` is keyed by and what every lookup here uses.
        final rows = List<LibraryItem>.from(healedItems);
        final haveRow = rows.map((i) => i.title).toSet();
        var rebuilt = 0;
        healedPlaylistSongs.forEach((name, songs) {
          if (haveRow.contains(name)) return;
          rows.add(LibraryItem(
            title: name,
            subtitle: 'Playlist • ${songs.length} songs',
            image: songs.isNotEmpty ? songs.first.image : '',
            category: LibraryCategory.playlist,
            songCount: songs.length,
            dateAdded: DateTime.now(),
          ));
          rebuilt++;
        });
        if (rebuilt > 0) {
          print('library: rebuilt $rebuilt playlist row(s) whose tracks were '
              'stored but had no row to open them from');
        }
        print('library loaded: ${rows.length} row(s), '
            '${healedPlaylistSongs.length} playlist(s) with tracks, '
            '${healedLikedSongs.length} liked song(s)');

        state = state.copyWith(
          allItems: rows,
          likedSongs: healedLikedSongs,
          likedSongIds: likedSongIds,
          likedAlbums: likedAlbums,
          likedPlaylists: likedPlaylists,
          subscribedArtists: subscribedArtists,
          playlistSongs: healedPlaylistSongs,
          downloadProgressMap: json['downloadProgressMap'] != null
              ? Map<String, double>.from(json['downloadProgressMap'])
              : const {},
        );
        // The stored library is now in memory, so saving is safe again.
        _loaded = true;
        // Now that saving is allowed, write back any repair made above — see
        // _pendingRepairSave.
        if (_pendingRepairSave) {
          _pendingRepairSave = false;
          _saveToDisk(userInitiated: true);
        }
        // Counts are recomputed on every load, NOT trusted from storage.
        // The subtitle is persisted inside the row, so a restore brings back
        // whatever number was written last, and _init re-inserts "Liked
        // Playlists" hard-coded to 0. Both were visible at once: albums said 2
        // over one row, podcasts and artists said 0 over several.
        _recomputeCollectionCounts();
        // A heal changed persisted data — write it back so the dead paths don't
        // get re-uploaded to the cloud on the next backup.
        if (stats.healed > 0 || stats.blanked > 0) {
          _saveToDisk(userInitiated: false);
        }
      } catch (e) {
        // THIS IS HOW A LIBRARY GETS DELETED. DO NOT JUST LOG AND CARRY ON.
        //
        // If parsing auvy_library_data throws partway, `state` is left empty or
        // half-populated, and execution used to continue straight into
        // refreshCachedFolder / refreshDownloadsFolder / _applyFilterAndSort.
        // Any write after that persists the EMPTY library over the good JSON, and
        // scheduleBackup then pushes the empty copy to the cloud, destroying the
        // only remaining copy. One bad parse and playlists are gone from both.
        //
        // Latching this makes the failure INERT instead of destructive: the state
        // in memory is wrong, but nothing overwrites what is on disk, so the next
        // launch (or a fix) can still read it.
        _loadFailed = true;
        print("ERROR: Error loading library: $e");
        print("STOP: LIBRARY LOAD FAILED — persistence is now DISABLED for this "
            "session so the saved copy is not overwritten. Restart the app; if "
            "this repeats, the stored library JSON is damaged.");
      }
    } else {
      state = state.copyWith(allItems: [cachedFolder, downloadsFolder, ...libraryItems]);
      // Nothing stored (a genuinely fresh install) — an empty library IS the
      // truth here, so persistence is safe.
      _loaded = true;
    }

    _reconcileCustomCovers();
    refreshCachedFolder();
    refreshDownloadsFolder();
    _applyFilterAndSort();
    _refreshAllPodcasts();

    // Recognise audio the user dropped into the Auvy folder by hand. Started
    // only now: it fires onCacheUpdated, which saves. See the note above the
    // prefs read for why that must not race the load.
    cacheManager.scanAndImportDownloads();
  }

  // #18 / #21 — DEAD COVER PATHS AFTER A CLOUD RESTORE
  // Root cause: `scanAndImportDownloads` writes a DEVICE-LOCAL absolute path
  // into `Song.image` when a disk-imported track has no network cover
  // (audio_cache_manager: `image: info.imageUrl.isNotEmpty ? info.imageUrl :
  // info.localImagePath`). `_saveToDisk` then serializes that path verbatim, and
  // CloudSyncService uploads the same blob, so after a reinstall + restore the
  // library points at `…/audio_cache/cover_local_<hash>.jpg` files that the
  // uninstall deleted. Result: no artwork (#18), and a restored album whose
  // tracks can't be matched back shows as a loose track (#21).
  //
  // The `.auvyid` sidecar already fixes this for downloads made SINCE that
  // feature shipped (it carries the real videoId + network cover, so the disk
  // scan re-keys them correctly). What it can't fix is a library blob that
  // ALREADY contains dead paths — older downloads, and anything restored from a
  // backup taken before the sidecar existed. That's what this heals, once, on
  // load: re-point at a live local cover if the disk scan regenerated one, else
  // at the network URL the cache index knows, else blank it so the UI shows a
  // clean placeholder instead of a broken image.

  /// True for a value that is a device path (not a network URL, not a bundled
  /// asset) which no longer exists on disk.
  bool _isDeadLocalImage(String image) {
    if (image.isEmpty) return false;
    if (image.startsWith('http')) return false;
    if (image.startsWith('assets/')) return false;
    try {
      return !File(image).existsSync();
    } catch (_) {
      return true;
    }
  }

  /// Best replacement for a dead path: a regenerated local cover for this id,
  /// then the network URL the cache index holds, else '' (clean placeholder).
  String _replacementImage(String songId) {
    if (songId.isEmpty) return '';
    final cache = AudioCacheManager();
    final live = cache.getDisplayImage(songId, '');
    if (live.isNotEmpty) return live;
    final net = cache.getTrackInfo(songId)?.imageUrl ?? '';
    return net.startsWith('http') ? net : '';
  }

  Song _healSong(Song s, _ImageHealStats stats) {
    if (!_isDeadLocalImage(s.image)) return s;
    stats.dead++;
    final replacement = _replacementImage(s.id);
    if (replacement.isNotEmpty) {
      stats.healed++;
    } else {
      stats.blanked++;
    }
    return s.copyWith(image: replacement);
  }

  LibraryItem _healItem(LibraryItem i, _ImageHealStats stats) {
    if (!_isDeadLocalImage(i.image)) return i;
    stats.dead++;
    // A playlist does have something to re-derive from
    //
    // The old note here said a LibraryItem has no song id, so a dead cover was
    // simply BLANKED, and that blank is persisted and uploaded, which makes a
    // recoverable cover permanently gone.
    //
    // It has a TITLE, and a manually-set playlist cover is stored under the key
    // `playlist:<title>` in ArtworkOverrideNotifier — as base64 BYTES, which are
    // in the cloud backup. So the one case that looked unrecoverable is the one
    // case with a durable copy: after a reinstall the bytes come down, _load
    // materialises a file, and this re-points at it instead of throwing the
    // user's own choice away.
    final override = ref.read(artworkOverrideProvider)['playlist:${i.title}'];
    if (override != null && override.isNotEmpty) {
      stats.healed++;
      return LibraryItem(
        title: i.title,
        subtitle: i.subtitle,
        image: override,
        isPinned: i.isPinned,
        isCircle: i.isCircle,
        category: i.category,
        dateAdded: i.dateAdded,
        songCount: i.songCount,
        isSystemFolder: i.isSystemFolder,
      );
    }
    stats.blanked++;
    // No override for it: the folder art is rebuilt from its tracks by the
    // normal refresh paths.
    return LibraryItem(
      title: i.title,
      subtitle: i.subtitle,
      image: '',
      isPinned: i.isPinned,
      isCircle: i.isCircle,
      category: i.category,
      dateAdded: i.dateAdded,
      songCount: i.songCount,
      isSystemFolder: i.isSystemFolder,
    );
  }

  void togglePlaylistLike(LibraryItem item, {List<Song>? tracks}) {
    final isLiked = state.likedPlaylists.any((p) => p.title == item.title);
    List<LibraryItem> newLiked = List.from(state.likedPlaylists);
    
    if (isLiked) {
      newLiked.removeWhere((p) => p.title == item.title);
    } else {
      newLiked.insert(0, item);
      if (tracks != null) {
        final newMap = Map<String, List<Song>>.from(state.playlistSongs);
        newMap[item.title] = tracks;
        state = state.copyWith(playlistSongs: newMap);
      }
    }
    
    state = state.copyWith(likedPlaylists: newLiked);
    _updateSystemFolder("Liked Playlists", "${newLiked.length} Playlists", null);
    _saveToDisk();
  }


  /// Resolve stream URLs for [tracks], reporting progress, and return what is
  /// fetchable alongside what could not be resolved.
  ///
  /// This was the slow, invisible half of every bulk download
  ///
  /// Both callers had their own copy of this loop, and both ran it SERIALLY with
  /// a 15-second ceiling per track. A twenty-track album where a few tracks are
  /// region-blocked therefore spent minutes resolving before one byte was
  /// written, and the UI said nothing at all, because the progress banner only
  /// counts SAVED tracks and none had been saved yet. "It doesn't look like it's
  /// downloading" was an accurate description of what the app was showing.
  ///
  /// Resolved six at a time. Six rather than unbounded: these go through the same
  /// shared RateLimiter as everything else, and the point is to overlap the
  /// waiting, not to flood it. Order is preserved because the results come back
  /// as a list, which matters — the caller pairs failures back to tracks by index.
  Future<({List<({Song song, String streamUrl, String? userAgent})> batch,
          List<Song> failed})>
      _resolveForDownload(List<Song> tracks, AudioCacheManager cache,
          {void Function(int done, int total)? onProgress}) async {
    final pending = tracks.where((s) => !cache.isCached(s.id)).toList();
    final batch = <({Song song, String streamUrl, String? userAgent})>[];
    final failed = <Song>[];
    if (pending.isEmpty) return (batch: batch, failed: failed);

    const lanes = 6;
    var done = 0;
    for (var i = 0; i < pending.length; i += lanes) {
      final chunk = pending.sublist(i, (i + lanes).clamp(0, pending.length));
      final resolved = await Future.wait(chunk.map((song) async {
        try {
          // preferMp4 — WITHOUT IT AN ALBUM DOWNLOAD HAS NO TAGS AT ALL.
          //
          // THE BUG THIS FIXES, caught live on device: one downloaded single
          // logged "Tagged with cover art" while a dozen tracks from an
          // album downloaded minutes earlier all logged "container holds no
          // tags". The difference was this argument. DownloadHelper passes
          // `preferMp4: isExplicit`; both bulk paths never did, so albums came
          // back as Opus-in-WebM.
          //
          // WebM cannot carry a title, artist or cover picture, so every album
          // download landed as bare audio: no metadata for other players, no
          // embedded art, and Android's media scanner refusing to index it.
          // AAC-in-MP4 is slightly less efficient and is the right trade for a
          // file the user keeps, copies to a car, or opens on a PC.
          final stream = await _audio
              .getStreamWithFallback(song.id, song.title, song.artist,
                  preferMp4: true)
              .timeout(const Duration(seconds: 15));
          final url = stream?['url'];
          if (url == null || url.isEmpty) return null;
          return (song: song, streamUrl: url, userAgent: stream?['user_agent']);
        } catch (_) {
          return null;
        }
      }));
      for (var k = 0; k < chunk.length; k++) {
        final r = resolved[k];
        if (r == null) {
          failed.add(chunk[k]);
        } else {
          batch.add(r);
        }
      }
      done += chunk.length;
      onProgress?.call(done, pending.length);
    }
    if (failed.isNotEmpty) {
      print('${failed.length}/${pending.length} track(s) could not be '
          'resolved to a stream');
    }
    return (batch: batch, failed: failed);
  }
  Future<void> downloadFullPlaylist(LibraryItem playlistItem, List<Song> tracks,
      {int attempt = 0}) async {
    // 1. Save to Library (ensures it shows up as a distinct playlist)
    savePlaylistFromSearch(
      Song(id: '', title: playlistItem.title, artist: '', image: playlistItem.image),
      tracks
    );
    
    // 2. Resolve Stream URLs (Identify which songs fail lookup immediately)
    final cache = AudioCacheManager();
    // Stream resolution lives in _resolveForDownload, which uses _audio.

    final dl = ref.read(downloadProvider.notifier);
    dl.startDownload(tracks.length, playlistItem.title, kind: 'Playlist');
    final resolved = await _resolveForDownload(tracks, cache,
        onProgress: (done, total) => dl.updateProgress(done));
    final batch = resolved.batch;
    final failedLookupSongs = resolved.failed;
    dl.beginTransfer(batch.length);

    // 3. Trigger Batch Download with explicit flag
    final List<bool> results = await cache.batchCacheTrack(
      batch,
      parallelDownloads: 3, 
      isExplicitDownload: true, // Mark as permanent download
      downloadType: 'Playlist',
      collectionName: playlistItem.title,
      onProgress: (done, total) => dl.updateProgress(done),
    );

    // 4. Identify tracks that failed during the actual audio transfer
    final List<Song> failedDownloadSongs = [];
    for (int i = 0; i < results.length; i++) {
      if (!results[i]) failedDownloadSongs.add(batch[i].song);
    }

    // 5. AUTOMATIC RETRY: capped at 3 attempts with growing spacing. The old
    // uncapped 3-min loop retried a permanently-failed track FOREVER (region-
    // blocked/removed video = endless background network + battery drain).
    final totalFailed = [...failedLookupSongs, ...failedDownloadSongs];
    if (totalFailed.isNotEmpty && mounted && attempt < 3) {
      final wait = Duration(minutes: 3 * (attempt + 1));
      print("${totalFailed.length} tracks failed in '${playlistItem.title}'. "
          "Retry ${attempt + 1}/3 in ${wait.inMinutes} min...");
      Timer(wait, () {
        if (mounted) {
          downloadFullPlaylist(playlistItem, totalFailed, attempt: attempt + 1);
        }
      });
    } else if (totalFailed.isNotEmpty) {
      print("STOP: Giving up on ${totalFailed.length} track(s) in '${playlistItem.title}' after 3 retries.");
    }

    // The banner is dismissed here AND nowhere else.
    //
    // It used to hide itself two seconds after `saved >= total`, which is a
    // condition a failed run never reaches: a resolve that found nothing, or a
    // throw anywhere above, left it on screen showing "7 of 20" until the app
    // restarted. Reporting the failure count as it goes also stops a run that
    // saved 17 of 20 reading as a clean success.
    dl.finishDownload(failed: totalFailed.length);

    // Cleanup progress after this attempt
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        final finalMap = Map<String, double>.from(state.downloadProgressMap);
        finalMap.remove(playlistItem.title);
        state = state.copyWith(downloadProgressMap: finalMap);
      }
    });
  }

  //  FIX: Properly supports authenticated Spotify AND native YouTube Links!
  /// Match "Title Artist" queries to real streams.
  ///
  /// Lifted verbatim out of [importPlaylistFromUrl] so that a Spotify DATA
  /// EXPORT — a file full of track NAMES with no ids in it anywhere — resolves
  /// through exactly the same matcher as a pasted Spotify link. A second copy of
  /// this would drift from the first, and the overlap-ratio scoring below is the
  /// part that stops an import filling a playlist with karaoke, live and tribute
  /// versions of the right song.
  ///
  /// Returns the matched songs and how many queries matched NOTHING, because a
  /// partial import that reports itself as complete is the failure this codebase
  /// keeps having to fix.
  Future<({List<Song> songs, int missing})> resolveQueriesToSongs(
      List<String> searchQueries, dynamic searchService,
      {void Function(int done, int total)? onProgress}) async {
    // Chunks of 10 with NO artificial sleep between them — the InnerTube
    // RateLimiter already paces requests, so the old 5-at-a-time + 500ms-per-
    // chunk loop just tripled the wall time of large imports (100 tracks:
    // ~90s → ~25s). Timeout is per-search and generous enough to cover limiter
    // queueing within a chunk. Failed lookups retry ONCE at the end (a single
    // flaky search shouldn't drop a track from the playlist).
    List<Song> matchedSongs = [];

    Future<Song?> matchQuery(String query,
        {Duration timeout = const Duration(seconds: 8)}) async {
      try {
        final results = await searchService.search(query, 'track').timeout(timeout);
        if (results.isNotEmpty) {
          // Best OVERLAP, not first hit.
          //
          // The query is "<title> <artist>", so the right track is the result
          // whose own title+artist covers the most of those words. Rank order
          // is popularity, which regularly puts a remix, a live version or a
          // cover above the studio track that was actually asked for.
          //
          // This can only improve on taking results.first: if the top hit IS
          // the best overlap it still wins, and a tie keeps the original
          // order. Nothing is ever DROPPED for failing to match — an import
          // that silently loses tracks is worse than one that occasionally
          // picks a different version.
          final wanted = query
              .toLowerCase()
              .split(RegExp(r'[^a-z0-9]+'))
              .where((w) => w.length > 1)
              .toSet();
          // A RATIO, not a raw count. Counting shared words alone rewards a
          // result that contains every query word PLUS extras, so
          // "Anybody (Live) Burna Boy Tribute Band" tied with the real
          // "Anybody - Burna Boy" and rank order broke the tie the wrong way.
          // Dividing by the UNION penalises the extras, which is exactly what
          // separates a track from its karaoke, live and tribute versions.
          Song bestMatch = results.first;
          if (wanted.isNotEmpty) {
            var bestScore = -1.0;
            for (final r in results) {
              final have = '${r.title} ${r.artist}'
                  .toLowerCase()
                  .split(RegExp(r'[^a-z0-9]+'))
                  .where((w) => w.length > 1)
                  .toSet();
              final inter = wanted.intersection(have).length;
              final union = wanted.length + have.length - inter;
              final score = union == 0 ? 0.0 : inter / union;
              if (score > bestScore) {
                bestScore = score;
                bestMatch = r;
              }
            }
          }
          return bestMatch.copyWith(
            image: bestMatch.image.replaceAll('small', 'large').replaceAll('50x50', '500x500'), // Force HQ
          );
        }
      } catch (_) {}
      return null;
    }

    final missed = <String>[];
    for (int i = 0; i < searchQueries.length; i += 10) {
      final chunk = searchQueries.skip(i).take(10).toList();
      final chunkResults = await Future.wait(chunk.map(matchQuery));
      for (int j = 0; j < chunkResults.length; j++) {
        final res = chunkResults[j];
        if (res != null) {
          matchedSongs.add(res);
        } else {
          missed.add(chunk[j]);
        }
      }
      // A file import can be hundreds of tracks and takes minutes; the caller
      // shows progress rather than an indefinite spinner.
      onProgress?.call(
          (i + chunk.length).clamp(0, searchQueries.length), searchQueries.length);
    }
    // Retry every miss, NOT only a small batch of them.
    //
    // This was gated on `missed.length <= 25`, so a BIG import — exactly the
    // case where misses accumulate — got NO retry at all and silently dropped
    // them. On a 210-track playlist, 40 first-pass misses meant 170 songs
    // imported and 40 gone with nothing said. From the outside that is
    // indistinguishable from a cap, which is what it was reported as.
    //
    // The guard was presumably there to bound the work, but concurrency is
    // already bounded by the chunking above, so chunk the retry the same way
    // instead of refusing it. 40 misses is four rounds of ten, not 40 at once.
    var stillMissing = 0;
    if (missed.isNotEmpty) {
      print('Retrying ${missed.length} missed track(s)');
      final recovered = <Song>[];
      for (int i = 0; i < missed.length; i += 10) {
        final chunk = missed.skip(i).take(10).toList();
        final retried = await Future.wait(chunk
            .map((q) => matchQuery(q, timeout: const Duration(seconds: 10))));
        recovered.addAll(retried.whereType<Song>());
      }
      matchedSongs.addAll(recovered);
      stillMissing = missed.length - recovered.length;
    }
    return (songs: matchedSongs, missing: stillMissing);
  }

  Future<int> importPlaylistFromUrl(String inputUrl, dynamic searchService) async {
    try {
      // 1. HANDLE YOUTUBE PLAYLISTS
      if (inputUrl.contains('youtube.com') || inputUrl.contains('youtu.be')) {
        final uri = Uri.parse(inputUrl);
        final playlistId = uri.queryParameters['list'];
        if (playlistId == null) throw 'Invalid YouTube Link. Must contain a playlist ID.';
        
        final ytTracks = await searchService.getPlaylistTracks(playlistId);
        if (ytTracks.isEmpty) throw 'No tracks found in this YouTube playlist. Is it private?';
        
        final playlistSong = Song(id: 'yt_$playlistId', title: 'YouTube Import', artist: 'YouTube', image: ytTracks.first.image);
        savePlaylistFromSearch(playlistSong, ytTracks);
        return ytTracks.length;
      }

      // 2. HANDLE SPOTIFY LINKS — KEYLESS. Users just paste a public Spotify
      // link; we read its track list from the PUBLIC open.spotify.com embed page
      // (no API key, no client secret needed). This is why import "didn't work":
      // the old path depended on Spotify client credentials bundled in .env,
      // which fail when missing/invalid or when Spotify throttles the
      // client-credentials flow. The credentialed API is kept only as a
      // best-effort fallback if keys happen to be configured.
      final regex = RegExp(r'(playlist|album|track)\/([a-zA-Z0-9]+)');
      final match = regex.firstMatch(inputUrl);
      if (match == null) throw 'Invalid Link. Please paste a valid Spotify or YouTube Playlist URL.';

      final type = match.group(1)!;
      final id = match.group(2)!;

      List<String> searchQueries = [];
      String collectionName = 'Spotify Import';
      String coverImage = '';

      // Primary: keyless Spotify Web API via the anonymous "transport" access
      // token (the same token the Spotify web player mints for itself — NO
      // client secret). This is the only keyless path that PAGINATES the FULL
      // playlist/album; the embed page below returns just a truncated preview
      // (~30-100 tracks), which is why large playlists were getting cut off.
      final api = await _spotifyApiTracks(type, id);
      if (api.name.isNotEmpty) collectionName = api.name;
      if (api.cover.isNotEmpty) coverImage = api.cover;
      searchQueries = api.queries;

      // Fallback 1: keyless embed scrape (preview list only) if the token/API
      // path returned nothing (e.g. Spotify changed the token endpoint).
      if (searchQueries.isEmpty) {
        final embed = await _spotifyEmbedTracks(type, id);
        if (embed.name.isNotEmpty) collectionName = embed.name;
        if (embed.cover.isNotEmpty) coverImage = embed.cover;
        searchQueries = embed.queries;
        // Say which source won AND how many tracks it found.
        //
        // The API path and the embed path differ by an order of magnitude in
        // completeness (full pagination vs a ~30–100 track preview), and until
        // now NOTHING distinguished them in the log, so "my 210-song playlist
        // imported short" and "the API silently failed" looked identical from the
        // outside. One line makes the difference visible.
        print('Spotify: API path returned nothing — embed fallback gave '
            '${searchQueries.length} track(s) (a preview, NOT the full list)');
      }

      // Fallback 2: credentialed Spotify API (only if keyless returned nothing
      // and valid keys are present — normally they're not, secret was removed).
      if (searchQueries.isEmpty) {
        final spotify = ExternalCatalogService();
        if (type == 'track') {
          final details = await spotify.getTrackDetails(id);
          if (details != null) {
            searchQueries.add("${details['title']} ${details['album']?['artist'] ?? ''}");
            collectionName = details['title'];
            coverImage = details['album']?['cover_medium'] ?? '';
          }
        } else if (type == 'album') {
          final tracks = await spotify.getAlbumTracks(id);
          if (tracks.isNotEmpty) {
            collectionName = tracks.first.albumTitle.isNotEmpty ? tracks.first.albumTitle : 'Spotify Album';
            coverImage = tracks.first.image;
            searchQueries = tracks.map((t) => "${t.title} ${t.artist}").toList();
          }
        } else if (type == 'playlist') {
          final tracks = await spotify.getPlaylistTracks(id);
          if (tracks.isNotEmpty) {
            collectionName = 'Spotify Playlist';
            coverImage = tracks.first.image;
            // No take(100). The fetch above now pages the whole playlist, and
            // truncating here was the SECOND cap on one import — a 400-track
            // playlist arrived complete and then had 300 thrown away.
            searchQueries = tracks.map((t) => "${t.title} ${t.artist}").toList();
          }
        }
      }

      if (searchQueries.isEmpty) throw 'No tracks found. Ensure the playlist is Public.';

      // Matching lives in [resolveQueriesToSongs] so a pasted link and a Spotify
      // DATA EXPORT resolve through the same matcher. See there.
      final resolved = await resolveQueriesToSongs(searchQueries, searchService);
      final matchedSongs = resolved.songs;
      if (resolved.missing > 0) {
        // Said out loud: a partial import must never look like a complete one.
        print('WARN: Spotify import: ${resolved.missing} of ${searchQueries.length} '
            'track(s) could not be matched to a stream');
      }

      if (matchedSongs.isNotEmpty) {
        final playlistSong = Song(id: 'spotify_$id', title: collectionName, artist: 'Spotify Import', image: coverImage);
        savePlaylistFromSearch(playlistSong, matchedSongs);
      }
      
      return matchedSongs.length;
    } catch (e, st) {
      // NEVER re-throw: an import error (bad/private link, a Spotify embed-JSON
      // reshuffle that breaks the keyless parse, a network/timeout, a type-cast)
      // must not escape into an uncaught exception — that's the Flutter "red
      // screen". Report failure as a 0-track result; the caller shows a friendly
      // "couldn't import" message.
      print('ERROR: Link Import Error: $e\n$st');
      return 0;
    }
  }

  /// KEYLESS full-list Spotify import. Mints the anonymous "transport" access
  /// token that Spotify's own web player uses (no client secret), then pages the
  /// public Web API to get the ENTIRE playlist/album (following the `next`
  /// cursor). Returns collection name, cover URL, and "Title Artist" queries.
  /// Best-effort: returns empty on any failure so the caller falls back to the
  /// embed preview. Only works for PUBLIC content (anonymous token has no user
  /// scope).
  /// Pull a session access token out of the embed page's `__NEXT_DATA__`.
  ///
  /// A fallback token source for [_spotifyApiTracks]. See the note at its call
  /// site for why depending on one token endpoint made large imports silently
  /// partial. Returns '' when nothing usable is there; the caller then falls back
  /// to the truncated embed track list as before.
  Future<String> _spotifyTokenFromEmbed(String type, String id) async {
    try {
      final resp = await http.get(
        Uri.parse('https://open.spotify.com/embed/$type/$id'),
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return '';
      final m = RegExp(r'<script id="__NEXT_DATA__"[^>]*>(.+?)</script>',
              dotAll: true)
          .firstMatch(resp.body);
      if (m == null) return '';
      final data = jsonDecode(m.group(1)!);

      // Recursive search: the token's PATH inside this blob has moved before and
      // will again, but the key name is stable. Bounded by depth so a
      // pathological document cannot spin here.
      String? find(dynamic node, int depth) {
        if (depth > 12) return null;
        if (node is Map) {
          for (final e in node.entries) {
            if (e.key == 'accessToken' &&
                e.value is String &&
                (e.value as String).isNotEmpty) {
              return e.value as String;
            }
            final hit = find(e.value, depth + 1);
            if (hit != null) return hit;
          }
        } else if (node is List) {
          for (final v in node) {
            final hit = find(v, depth + 1);
            if (hit != null) return hit;
          }
        }
        return null;
      }

      return find(data, 0) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<({String name, String cover, List<String> queries})> _spotifyApiTracks(
      String type, String id) async {
    const ua =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    try {
      // 1. Anonymous access token (same endpoint the web player/embeds call).
      final tokenResp = await http.get(
        Uri.parse(
            'https://open.spotify.com/get_access_token?reason=transport&productType=embed'),
        headers: const {'User-Agent': ua, 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      var token = '';
      if (tokenResp.statusCode == 200) {
        try {
          final tokenJson = jsonDecode(tokenResp.body);
          token =
              (tokenJson is Map ? tokenJson['accessToken'] : null)?.toString() ??
                  '';
        } catch (_) {}
      }

      // Second token source, because the first one is the single point of
      // Failure for importing a whole playlist.
      //
      // `get_access_token` is the ONLY thing standing between this paginating
      // path and the embed fallback, and the embed returns a truncated preview
      // by design (~30–100 tracks). So the moment Spotify moves or blocks that
      // one endpoint, every large import silently becomes a partial one, which
      // reads as "it capped my 210-song playlist at 100".
      //
      // The embed PAGE carries a session token of its own, and that page must be
      // reachable anyway or the fallback could not work either. Harvesting the
      // token from it therefore fails only when the whole import would fail
      // regardless — strictly better than depending on a separate endpoint.
      //
      // Searched recursively rather than by a fixed JSON path, for the same
      // reason _spotifyEmbedTracks locates its track list that way: the shape
      // moves, the key name does not.
      if (token.isEmpty) {
        token = await _spotifyTokenFromEmbed(type, id);
        if (token.isNotEmpty) {
          print('Spotify: token endpoint unavailable — using the embed '
              "page's session token so the FULL playlist can still paginate");
        }
      }
      if (token.isEmpty) return (name: '', cover: '', queries: <String>[]);
      final auth = {'Authorization': 'Bearer $token', 'User-Agent': ua};

      String name = '';
      String cover = '';
      final queries = <String>[];

      String coverFrom(dynamic images) {
        if (images is List && images.isNotEmpty && images.first is Map) {
          return (images.first['url'] ?? '').toString();
        }
        return '';
      }

      void addTrack(dynamic track) {
        if (track is! Map) return;
        final title = (track['name'] ?? '').toString().trim();
        String artist = '';
        final artists = track['artists'];
        if (artists is List && artists.isNotEmpty && artists.first is Map) {
          artist = (artists.first['name'] ?? '').toString().trim();
        }
        if (title.isNotEmpty) queries.add(artist.isNotEmpty ? '$title $artist' : title);
      }

      if (type == 'track') {
        final r = await http.get(Uri.parse('https://api.spotify.com/v1/tracks/$id'), headers: auth)
            .timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final t = jsonDecode(r.body);
          name = (t['name'] ?? '').toString();
          cover = coverFrom(t['album']?['images']);
          addTrack(t);
        }
      } else {
        // playlist or album → fetch name + cover, then PAGINATE all tracks.
        final metaUrl = 'https://api.spotify.com/v1/${type}s/$id';
        final meta = await http.get(Uri.parse(metaUrl), headers: auth)
            .timeout(const Duration(seconds: 10));
        if (meta.statusCode == 200) {
          final mj = jsonDecode(meta.body);
          name = (mj['name'] ?? '').toString();
          cover = coverFrom(mj['images']);
        }
        // Album tracks cap at 50/page, playlist at 100/page. Follow `next`.
        final pageLimit = type == 'album' ? 50 : 100;
        String? next = 'https://api.spotify.com/v1/${type}s/$id/tracks?limit=$pageLimit&offset=0';
        int guard = 0;
        while (next != null && guard < 50) {
          guard++;
          final tr = await http.get(Uri.parse(next), headers: auth)
              .timeout(const Duration(seconds: 12));
          // A SILENT `break` IS WHY A FAILED IMPORT LOOKED LIKE A CAPPED ONE.
          //
          // This exited the pagination loop without a word, so a rejected token
          // produced an empty result, no log line, and a quiet fall through to
          // the truncated embed scrape — indistinguishable from "the playlist
          // was short". Observed: the embed token was obtained successfully and
          // then NOTHING followed, because this break swallowed the reason.
          //
          // The status code is the whole diagnosis: 401/403 means the token is
          // not accepted for this endpoint, 404 means the playlist id did not
          // resolve, 429 means throttled. Say which.
          if (tr.statusCode != 200) {
            print('WARN: Spotify API: tracks page returned ${tr.statusCode} '
                'after $guard page(s) — falling back to the truncated embed '
                'list, so this import may be short');
            break;
          }
          final tj = jsonDecode(tr.body);
          final items = tj['items'] as List? ?? [];
          for (final it in items) {
            // Playlist items wrap the track under 'track'; album track items are
            // the track object directly.
            addTrack(type == 'playlist' ? (it is Map ? it['track'] : null) : it);
          }
          next = tj['next']?.toString();
        }
      }
      if (queries.isNotEmpty) {
        print('Spotify API: got ${queries.length} track(s) for $type/$id');
      }
      return (name: name, cover: cover, queries: queries);
    } catch (e) {
      print('WARN: Spotify API tracks failed (falling back to embed): $e');
      return (name: '', cover: '', queries: <String>[]);
    }
  }

  /// KEYLESS Spotify import: fetch a public playlist/album/track's track list
  /// from the open.spotify.com EMBED page and parse its `__NEXT_DATA__` JSON.
  /// No API key / client secret — the user just pastes a link. Returns the
  /// collection name, a cover URL, and "Title Artist" search queries (each is
  /// then matched to a YouTube stream by the caller). Defensive: if Spotify
  /// moves the JSON shape, it recursively locates the track list.
  Future<({String name, String cover, List<String> queries})> _spotifyEmbedTracks(
      String type, String id) async {
    try {
      final resp = await http.get(
        Uri.parse('https://open.spotify.com/embed/$type/$id'),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return (name: '', cover: '', queries: <String>[]);

      final m = RegExp(r'<script id="__NEXT_DATA__"[^>]*>(.+?)</script>',
              dotAll: true)
          .firstMatch(resp.body);
      if (m == null) return (name: '', cover: '', queries: <String>[]);
      final data = jsonDecode(m.group(1)!);

      // Current embeds put it at props.pageProps.state.data.entity; fall back to
      // a recursive search so a future re-shuffle of the JSON still works.
      dynamic entity = data['props']?['pageProps']?['state']?['data']?['entity'];
      entity ??= _findFirstMap(
          data, (mp) => mp.containsKey('trackList') || mp.containsKey('title'));

      String name = (entity?['name'] ?? entity?['title'] ?? '').toString();
      String cover = '';
      final sources = entity?['coverArt']?['sources'];
      if (sources is List && sources.isNotEmpty) {
        cover = (sources.last['url'] ?? sources.first['url'] ?? '').toString();
      }

      final queries = <String>[];
      void addTrack(dynamic t) {
        if (t is! Map) return;
        final title = (t['title'] ?? t['name'] ?? '').toString().trim();
        String sub = (t['subtitle'] ?? '').toString().trim();
        if (sub.isEmpty && t['artists'] is List && (t['artists'] as List).isNotEmpty) {
          sub = ((t['artists'] as List).first['name'] ?? '').toString().trim();
        }
        if (title.isNotEmpty) queries.add(sub.isNotEmpty ? '$title $sub' : title);
      }

      final trackList = entity?['trackList'] ?? _findFirstList(data, 'trackList');
      if (trackList is List) {
        for (final t in trackList) {
          addTrack(t);
        }
      } else if (type == 'track') {
        addTrack(entity);
      }
      return (name: name, cover: cover, queries: queries);
    } catch (e) {
      print('WARN: Spotify embed parse failed: $e');
      return (name: '', cover: '', queries: <String>[]);
    }
  }

  /// Recursively find the first List stored under [key] anywhere in a decoded
  /// JSON tree (used to locate Spotify's track list defensively).
  List? _findFirstList(dynamic node, String key) {
    if (node is Map) {
      if (node[key] is List) return node[key] as List;
      for (final v in node.values) {
        final r = _findFirstList(v, key);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirstList(v, key);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Recursively find the first Map satisfying [test] in a decoded JSON tree.
  Map? _findFirstMap(dynamic node, bool Function(Map) test) {
    if (node is Map) {
      if (test(node)) return node;
      for (final v in node.values) {
        final r = _findFirstMap(v, test);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirstMap(v, test);
        if (r != null) return r;
      }
    }
    return null;
  }

  void _ensureCachedExcludesDownloads() {
    final cacheManager = AudioCacheManager();
    final allDownloadIds = cacheManager.getDownloadedTracks().map((s) => s.id).toSet();
    
    final cachedSongs = state.playlistSongs["Cached"] ?? [];
    final filteredCached = cachedSongs.where((s) => !allDownloadIds.contains(s.id)).toList();
    
    if (filteredCached.length != cachedSongs.length) {
      final newMap = Map<String, List<Song>>.from(state.playlistSongs);
      newMap["Cached"] = filteredCached;
      state = state.copyWith(playlistSongs: newMap);
      _updateSystemFolder("Cached", "${filteredCached.length} songs", null);
      print("Removed ${cachedSongs.length - filteredCached.length} downloads from Cached folder");
    }
  }

  Future<void> downloadAlbumAsPlaylist(Album album, String artistName, List<Song> tracks, {int attempt = 0}) async {
    print("Downloading album as playlist: ${album.title}");
    
    // Logic for initializing album container
    final albumItem = LibraryItem(
      title: album.title,
      subtitle: "Album • $artistName • ${tracks.length} songs",
      image: album.image,
      category: LibraryCategory.album,
      dateAdded: DateTime.now(),
      songCount: tracks.length,
      isSystemFolder: false,
    );
    
    final existingAlbumIndex = state.allItems.indexWhere(
      (item) => item.title == album.title && item.category == LibraryCategory.album
    );
    
    List<LibraryItem> newAllItems = List.from(state.allItems);
    if (existingAlbumIndex != -1) newAllItems[existingAlbumIndex] = albumItem;
    else newAllItems.insert(0, albumItem);
    
    final newPlaylistMap = Map<String, List<Song>>.from(state.playlistSongs);
    newPlaylistMap[album.title] = tracks;
    
    state = state.copyWith(allItems: newAllItems, playlistSongs: newPlaylistMap);
    _saveToDisk();
    
    // 2. Resolve Stream URLs and identify failures
    final cache = AudioCacheManager();
    // Stream resolution lives in _resolveForDownload, which uses _audio.
    final dl = ref.read(downloadProvider.notifier);
    dl.startDownload(tracks.length, album.title, kind: 'Album');
    final resolved = await _resolveForDownload(tracks, cache,
        onProgress: (done, total) => dl.updateProgress(done));
    final batch = resolved.batch;
    final failedLookupSongs = resolved.failed;
    dl.beginTransfer(batch.length);

    // 3. Execute batch download with explicit download flag
    final results = await cache.batchCacheTrack(
      batch,
      parallelDownloads: 3,
      isExplicitDownload: true, 
      downloadType: 'Album',
      collectionName: album.title,
      onProgress: (done, total) => dl.updateProgress(done),
    );

    // 4. Handle failures and schedule retry
    final List<Song> failedDownloadSongs = [];
    for (int i = 0; i < results.length; i++) {
      if (!results[i]) failedDownloadSongs.add(batch[i].song);
    }

    final totalFailed = [...failedLookupSongs, ...failedDownloadSongs];
    // Cap retries at 3 total attempts (matches downloadFullPlaylist). Without a
    // cap this recursed every 3 min FOREVER on region-blocked/removed tracks —
    // a permanent battery + data drain. After the cap, give up (those tracks
    // genuinely can't be fetched).
    if (totalFailed.isNotEmpty && mounted && attempt < 2) {
      print("${totalFailed.length} tracks failed in album '${album.title}'. "
          "Retry ${attempt + 1}/2 in 3 mins...");
      Timer(const Duration(minutes: 3), () {
        if (mounted) {
          downloadAlbumAsPlaylist(album, artistName, totalFailed, attempt: attempt + 1);
        }
      });
    } else if (totalFailed.isNotEmpty) {
      print("STOP: ${totalFailed.length} tracks in '${album.title}' still failed after "
          "${attempt + 1} attempts — giving up (likely region-blocked/removed).");
    }

    // THE BANNER IS DISMISSED HERE AND NOWHERE ELSE. See downloadFullPlaylist.
    dl.finishDownload(failed: totalFailed.length);

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        final finalMap = Map<String, double>.from(state.downloadProgressMap);
        finalMap.remove(album.title);
        state = state.copyWith(downloadProgressMap: finalMap);
      }
    });

    // tracks minus what is still outstanding — already-cached tracks are on
    // disk too, so counting up from `batch` would under-report them.
    print('album attempt complete: "${album.title}" — '
        '${tracks.length - totalFailed.length}/${tracks.length} on disk, '
        '${totalFailed.length} outstanding');
  }

  void reorderLibraryItems({required bool isPinned, required int oldIndex, required int newIndex}) {
    // 1. Get the specific subset of items (pinned or unpinned) the user is reordering
    final segment = state.filteredItems.where((i) => i.isPinned == isPinned).toList();
    
    // Safety checks for valid indices
    if (oldIndex < 0 || oldIndex >= segment.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > segment.length) newIndex = segment.length;
    if (oldIndex == newIndex || oldIndex == newIndex - 1) return;

    final List<LibraryItem> newAllItems = List.from(state.allItems);
    final itemToMove = segment[oldIndex];

    // 2. Find the absolute position in the master list
    final int actualOldIdx = newAllItems.indexOf(itemToMove);
    if (actualOldIdx == -1) return;
    
    // Remove the item from its old position
    final movedItem = newAllItems.removeAt(actualOldIdx);

    // 3. Determine the target position in the master list
    int actualNewIdx;
    if (newIndex >= segment.length) {
      // If moving to the very end of the segment, find the last item of that segment in the master list
      final lastItemOfSegment = segment.last;
      actualNewIdx = newAllItems.indexOf(lastItemOfSegment) + 1;
    } else {
      // Flutter's ReorderableListView newIndex is the index before the item that will be at newIndex.
      // If we are moving forward (down the list), the index shifts because we removed the item earlier.
      int targetInSegment = newIndex;
      if (oldIndex < newIndex) targetInSegment--;
      
      final targetItem = segment[targetInSegment];
      actualNewIdx = newAllItems.indexOf(targetItem);
      
      // If we moved the item forward, we want it to land AFTER the target item
      if (oldIndex < newIndex) actualNewIdx++;
    }

    // 4. Update the master list and persist
    newAllItems.insert(actualNewIdx.clamp(0, newAllItems.length), movedItem);
    
    state = state.copyWith(allItems: newAllItems);
    _applyFilterAndSort(); 
    _saveToDisk();
  }

  void reorganizeDownloads() {
    final cacheManager = AudioCacheManager();
    final downloaded = cacheManager.getDownloadedTracks();
    
    // Group by album
    final Map<String, List<Song>> albumGroups = {};
    for (var song in downloaded) {
      final albumKey = (song.albumTitle.isEmpty || song.albumTitle == 'null') 
          ? "Singles" 
          : song.albumTitle;
      albumGroups.putIfAbsent(albumKey, () => []).add(song);
    }
    
    // Build organized list: albums with 2+ tracks become folders
    final List<Song> organized = [];
    albumGroups.forEach((albumName, tracks) {
      if (albumName == "Singles" || tracks.length == 1) {
        organized.addAll(tracks); // Singles stay as individual tracks
      } else {
        // Album folder - maintain order
        organized.addAll(tracks);
      }
    });
    
    // Update Downloads playlist with organized order
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap["Downloads"] = organized;
    
    state = state.copyWith(playlistSongs: newMap);
    _saveToDisk();
    
    print("Downloads reorganized: ${albumGroups.length} groups");
  }

  void reorderDownloadedTracks(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final current = List<Song>.from(state.playlistSongs["Downloads"] ?? []);
    if (current.isEmpty) {
        // Fallback: If no custom order exists, get from CacheManager first
        current.addAll(AudioCacheManager().getDownloadedTracks());
    }
    final moved = current.removeAt(oldIndex);
    current.insert(newIndex, moved);
    
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap["Downloads"] = current;
    state = state.copyWith(playlistSongs: newMap);
    _saveToDisk();
  }

  /// Whether two track lists are the same tracks in the same order.
  ///
  /// By id, because these lists are REBUILT from the cache index on every
  /// event: the Song objects are fresh instances describing the same tracks, so
  /// object equality would report a change every single time, which is exactly
  /// the false positive this is here to stop.
  static bool _sameTracks(List<Song> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void refreshCachedFolder() {
    final cacheManager = AudioCacheManager();
    final songs = cacheManager.getAutoCachedTracks();
    
    // CRITICAL: Exclude any songs that are marked as downloads
    final downloadIds = cacheManager.getDownloadedTracks().map((s) => s.id).toSet();
    final filteredSongs = songs.where((s) => !downloadIds.contains(s.id)).toList();
    
    // Nothing changed means touch nothing
    //
    // THE COST THIS REMOVES. This fires once per auto-cached track — 144 times
    // in the 2026-08-30 transcript, and it replaced the state unconditionally,
    // which rebuilds every library consumer and, through refreshDownloadsFolder
    // below, triggers a full 769KB re-encode of the library to discover the
    // bytes are identical. The transcript shows exactly that: dozens of
    // "library save skipped — byte-identical" lines, each one paid for with a
    // whole encode.
    //
    // A cache EVENT is not a cache CHANGE. The common one is a track being
    // re-touched, or an eviction plus an add that leaves the same set, and the
    // list is rebuilt from the index either way, so comparing it is the only way
    // to tell.
    final prev = state.playlistSongs["Cached"] ?? const <Song>[];
    if (_sameTracks(prev, filteredSongs)) return;

    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap["Cached"] = filteredSongs;
    state = state.copyWith(playlistSongs: newMap);
    
    _updateSystemFolder("Cached", "${filteredSongs.length} songs", null);
    
    print(" Cached folder synced: ${filteredSongs.length} auto-cached items (excluding ${songs.length - filteredSongs.length} downloads)");
  }

  /// Rebuilds the Downloads folder from what is actually downloaded on disk.
  ///
  /// THIS USED TO HIDE MOST DOWNLOADS. It collected every song id that
  /// belonged to any other container — liked songs and every playlist, and then
  /// removed those from the list:
  ///
  ///     final explicitDownloads = allExplicitDownloads
  ///         .where((song) => !assignedSongIds.contains(song.id));
  ///
  /// So downloading a track that was in ANY playlist, or that you had liked,
  /// filed it to disk, flipped its download indicator on, and then omitted it
  /// from Downloads. Since downloads are nearly always started FROM a playlist or
  /// an album, the folder read "0 songs" while the storage breakdown reported
  /// real downloaded bytes, and the per-track icon disagreed with the folder,
  /// which is the "download icon is not universal" symptom.
  ///
  /// The intent was presumably to avoid showing a track twice in the library. But
  /// "Downloads" answers ONE question — what do I have offline?, and a track
  /// being in a playlist has no bearing on the answer. Every explicit download is
  /// listed now, exactly like Spotify's and Apple Music's downloaded views.
  /// Whether a downloaded track may be left out of the Downloads folder.
  ///
  /// THE ONLY WAY TO HIDE ONE, AND IT CANNOT SAY YES WITHOUT PROOF. Every
  /// path returns false — keep it — except the single case where the track
  /// belongs to a collection whose name is present in the library, which is what
  /// makes it reachable by another route. Adding a new download kind therefore
  /// defaults to VISIBLE, which is the safe direction: a duplicate listing is
  /// untidy, an unreachable file is lost.
  static bool _hiddenBecauseReachable(
    ({String kind, String name})? collection,
    Set<String> reachable,
  ) {
    if (collection == null) return false; // a loose single: Downloads is home
    return reachable.contains(collection.name.trim().toLowerCase());
  }

  void refreshDownloadsFolder() {
    final cacheManager = AudioCacheManager();
    // An album you downloaded is NOT a pile of loose singles
    //
    // THE BUG THIS FIXES. This took EVERY explicitly-downloaded track, so
    // downloading an album put the album in the Library page (correct) AND
    // scattered all of its tracks into the Downloads folder as unrelated songs
    // — the same music listed twice, in two shapes, one of them meaningless.
    //
    // The download type is not in the cache index; it was only ever used to pick
    // a directory. So the directory IS the record, and it is ground truth rather
    // than a second copy that can disagree: Albums/<name>, Playlists/<name>,
    // Podcasts/<show>, or Singles. See downloadCollectionOf.
    //
    // AND ONLY EXCLUDED WHEN THE COLLECTION IS ACTUALLY REACHABLE. If a
    // download landed under Albums/<name> but no library row exists for it, its
    // tracks would become unreachable from the UI entirely — a worse bug than
    // the duplication. Downloads stays their home in that case.
    // Downloaded episodes belong to their show, NOT to a pile
    //
    // Two wrongs, in sequence, both mine. First I excluded Podcasts/ from
    // Downloads on the assumption the podcast page listed them — it does not, so
    // saved episodes became invisible. Putting them back made them VISIBLE and
    // wrong in the other direction: episodes from unrelated shows sitting
    // together as loose tracks, which is exactly the album complaint that
    // started all of this.
    //
    // The right answer was already in the codebase. A podcast show is a library
    // row whose subtitle starts 'Podcast • ' (see library_page, which reads the
    // show name back out of it), so a downloaded episode belongs under a row of
    // that shape. Grouped here, the reachability rule below then removes them
    // from Downloads on its own — no special case, which is the whole point of
    // making that rule structural.
    //
    // Grouped by the episode's `artist`, which IS the show name (see
    // PodcastEpisode.toSong), rather than by the folder name: the folder has been
    // through the sanitiser and would show a mangled title.
    final podsByShow = <String, List<Song>>{};
    for (final s in cacheManager.getDownloadedTracks()) {
      if (s.albumTitle != 'Podcast') continue;
      final show = s.artist.trim();
      if (show.isEmpty) continue;
      podsByShow.putIfAbsent(show, () => <Song>[]).add(s);
    }
    // Whether anything above this point has already altered state, so the tail
    // knows it must persist even when the Downloads list itself is unchanged.
    var podcastRowsChanged = false;
    if (podsByShow.isNotEmpty) {
      final items = List<LibraryItem>.from(state.allItems);
      final map = Map<String, List<Song>>.from(state.playlistSongs);
      var created = 0;
      for (final e in podsByShow.entries) {
        map[e.key] = e.value;
        if (items.any((i) => i.title.trim().toLowerCase() ==
            e.key.toLowerCase())) {
          continue; // already followed, or already made here
        }
        items.insert(
          0,
          LibraryItem(
            title: e.key,
            // The shape library_page parses to recover the show — keep it.
            subtitle: 'Podcast • ${e.key}',
            image: e.value.first.image,
            category: LibraryCategory.playlist,
            dateAdded: DateTime.now(),
            songCount: e.value.length,
          ),
        );
        created++;
      }
      state = state.copyWith(allItems: items, playlistSongs: map);
      podcastRowsChanged = true;
      print('downloads: ${podsByShow.length} show(s) with saved episodes '
          '($created new library row(s)) — episodes now live under their show '
          'rather than loose in Downloads');
    }

    // BOTH SPELLINGS OF EVERY TITLE. A download's collection comes from its
    // FOLDER name, which has been sanitised; a library title has not. Comparing
    // only the raw form fails for any title containing stripped punctuation, and
    // the track then stays in Downloads despite being perfectly reachable.
    final reachable = <String>{
      for (final i in state.allItems) i.title.trim().toLowerCase(),
      for (final i in state.allItems)
        AudioCacheManager.folderNameFor(i.title).trim().toLowerCase(),
      ...state.playlistSongs.keys.map((k) => k.trim().toLowerCase()),
      ...state.playlistSongs.keys
          .map((k) => AudioCacheManager.folderNameFor(k).trim().toLowerCase()),
    };
    // One exit can hide a track, AND it is gated on reachability
    //
    // THE MISTAKE THIS SHAPE PREVENTS, made here once already. The first version
    // of this filter carried a comment saying "only exclude when the collection
    // is actually reachable, or its tracks become unreachable from the UI
    // entirely", and then, three lines above that comment, hard-coded
    // `if (coll.kind == 'Podcasts') return false;` on the assumption that
    // podcasts have their own downloads view. They do not (podcast_page.dart has
    // no reference to downloads at all), so every saved episode became invisible:
    // the toast said saved, the file was on disk and visible in Android's Files
    // app, and nothing in the app listed it.
    //
    // A comment cannot stop that. The structure can: `_hiddenBecauseReachable`
    // is the ONLY thing that returns "hide", it takes `reachable` as a
    // parameter, and it has no early exit above the check. A future kind —
    // Audiobooks, Mixes, whatever — cannot be special-cased into invisibility
    // without first proving the user can reach it somewhere else.
    var grouped = 0;
    final explicitDownloads = cacheManager
        .getDownloadedTracks()
        .where((s) {
          final hide = _hiddenBecauseReachable(
            cacheManager.downloadCollectionOf(s.id),
            reachable,
          );
          if (hide) grouped++;
          return !hide;
        })
        .toList();
    if (grouped > 0) {
      print('Downloads: $grouped track(s) hidden because they belong to an '
          'album or playlist that is already in the library');
    }
    // Counted out loud, because these have been wrong in both directions.
    //
    // First they were excluded from Downloads and became invisible; then they
    // were included and turned into a pile of unrelated shows. They should now be
    // grouped under their show and therefore ABSENT from this list, so a
    // non-zero count here means the grouping above failed to make a show
    // reachable, and the episodes have fallen back to Downloads. That fallback is
    // deliberate (better here than nowhere) but it is not the intended state.
    final pods =
        explicitDownloads.where((s) => s.albumTitle == 'Podcast').length;
    if (pods > 0) {
      print('Downloads: $pods podcast episode(s) fell back to this list — '
          'their show did not become reachable, so check the grouping above');
    }

    // This claimed to preserve a custom order AND did NOT
    //
    // The old pair of `where` calls read plausibly and were wrong twice over.
    //
    // WRONG: both iterated `explicitDownloads`, so the result came out in the
    // CACHE INDEX's order and only used `currentOrder` as a membership test. A
    // user who dragged their downloads into an order lost it on the next
    // refresh, and this method runs on every cache update (debounced 300ms)
    // and on a 15-minute timer, so "the next refresh" is soon and unprompted.
    //
    // SLOW: `currentOrder.any(...)` inside a `where` over N downloads is O(N×M),
    // and the second line's `orderedSongs.any(...)` makes it O(N²) — on the main
    // isolate, immediately before a full library serialisation, at a few hundred
    // downloads.
    //
    // Walking `currentOrder` and taking from an id map is O(N+M) and actually
    // preserves the order, because the ORDER now comes from the thing that holds
    // it. Anything new is appended, which is where a newly downloaded track
    // belongs.
    final currentOrder = state.playlistSongs["Downloads"] ?? const <Song>[];
    final byId = <String, Song>{
      for (final s in explicitDownloads) s.id: s,
    };
    final finalList = <Song>[];
    for (final prev in currentOrder) {
      final s = byId.remove(prev.id);
      if (s != null) finalList.add(s);
    }
    // Whatever was not already in the list — newly downloaded, or imported by a
    // disk scan — goes on the end in the order the index reports it.
    finalList.addAll(byId.values);
    // The save is the expensive part, so earn it
    //
    // This is the call that persists the library, and it ran on every cache
    // event — 100 whole-blob encodes in 28 hours, most of them concluding the
    // bytes were identical. Downloads only change when a download finishes or a
    // file appears on disk, which is rare; a track being auto-cached is not a
    // change to this list at all.
    //
    // AND THE PODCAST BLOCK ABOVE MUST STILL BE PERSISTED. It creates library
    // rows for shows with saved episodes, with its own state write, so keying
    // the early exit purely on the Downloads list would have created a row and
    // then never written it, and the show would vanish on the next launch. That
    // is why the flag exists rather than a plain list comparison.
    final prevDownloads = state.playlistSongs["Downloads"] ?? const <Song>[];
    if (!podcastRowsChanged && _sameTracks(prevDownloads, finalList)) {
      _ensureCachedExcludesDownloads();
      return;
    }

    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap["Downloads"] = finalList;

    state = state.copyWith(playlistSongs: newMap);
    _updateSystemFolder("Downloads", "${finalList.length} songs", null);
    // Not user-initiated: this runs off a disk scan and a 15-minute timer, so it
    // must never be the thing that empties the library. See _saveToDisk.
    _saveToDisk(userInitiated: false);
    _ensureCachedExcludesDownloads();
  }

  /// User-triggered "scan device for music": requests All-files access (needed
  /// to read files other apps created on Android 11+), imports any audio the
  /// user dropped into the Auvy folder, then refreshes the Downloads list.
  /// Returns the number of newly-imported tracks.
  Future<int> importDeviceDownloads() async {
    final n = await AudioCacheManager().scanAndImportDownloads(requestAccess: true);
    refreshDownloadsFolder();
    return n;
  }

  /// Force a complete refresh of all system folders
  void forceRefreshAllFolders() {
    print("FORCE REFRESH: All system folders");
    
    // Re-initialize cache manager
    AudioCacheManager().initialize().then((_) {
      refreshCachedFolder();
      refreshDownloadsFolder();

      // Force save to disk
      _saveToDisk(userInitiated: false);

      print(" Force refresh complete");
    });
  }
  

  // Saves the current library state to local storage.
  /// Latched when the saved library could not be parsed. See the catch in _init:
  /// while this is true nothing may be written, because the in-memory state is
  /// empty and persisting it would destroy the copy on disk AND, via the backup,
  /// the copy in the cloud.
  bool _loadFailed = false;

  /// A load-time repair is waiting to be written back once saving is allowed.
  /// Set during _init, consumed the moment `_loaded` becomes true.
  bool _pendingRepairSave = false;

  /// False until [_init] has finished putting the stored library into `state`.
  ///
  /// The other half of the data-loss fix, AND the one that actually bit.
  ///
  /// `_loadFailed` covers a load that THREW. This covers a load that simply has
  /// not happened yet, which is the far more common case, because `_init` is
  /// async and `state` starts out as the empty seed. Anything that saves during
  /// that window persists an empty library over the real one and then schedules
  /// a cloud backup of the emptiness. `refreshDownloadsFolder` saves, and the
  /// cache-scan callback calls it, so this was reachable on any launch where the
  /// disk scan happened to finish first.
  bool _loaded = false;

  static const String _kLibraryKey = 'auvy_library_data';

  /// Mirror of the last save that contained real user content. See the fallback
  /// in [_init]. Listed in account_provider's `_userDataKeys` so an account
  /// switch clears it too — otherwise it would hand the next account the
  /// previous one's library.
  static const String _kLibraryBackupKey = 'auvy_library_data_last_good';

  /// Re-point playlists at their custom cover after the override files move.
  ///
  /// A CUSTOM COVER IS STORED TWICE, AND ONLY ONE COPY TRAVELS. Setting one
  /// writes the picture through ArtworkOverrideNotifier (which keeps the BYTES,
  /// so they survive a reinstall and sync to the cloud) and ALSO stamps that
  /// file's path into `LibraryItem.image` for rendering.
  ///
  /// The path is device-local and the bytes are rebuilt to a fresh file on a new
  /// install, so after a restore the stamped path points at nothing. `_healItem`
  /// then blanks it, and the library grid shows a coverless playlist while the
  /// home mosaic, which resolves covers by a different route — shows it
  /// correctly. That disagreement between two screens is the visible symptom.
  ///
  /// The override map is the source of truth for a deliberately-set cover, so
  /// the item follows it rather than the other way round.
  /// [persist] is false when the caller is about to save anyway — a rename
  /// already writes the library, and two disk writes for one user action is
  /// waste.
  void _reconcileCustomCovers({bool persist = true}) {
    try {
      final overrides = ref.read(artworkOverrideProvider);
      if (overrides.isEmpty) return;
      var changed = 0;
      final items = state.allItems.map((i) {
        final path = overrides['playlist:${i.title}'];
        if (path == null || path.isEmpty || i.image == path) return i;
        changed++;
        return LibraryItem(
          title: i.title,
          subtitle: i.subtitle,
          image: path,
          isPinned: i.isPinned,
          isCircle: i.isCircle,
          category: i.category,
          dateAdded: i.dateAdded,
          songCount: i.songCount,
          isSystemFolder: i.isSystemFolder,
        );
      }).toList();
      if (changed > 0) {
        print('re-pointed $changed playlist cover(s) at their restored files');
        state = state.copyWith(allItems: items);
        // Not user-initiated: this is repair, and it must not be able to empty
        // the library if something upstream went wrong.
        if (persist) _saveToDisk(userInitiated: false);
      }
    } catch (_) {
      // A cover that fails to reconcile is cosmetic; never block the load.
    }
  }

  /// See library_integrity.dart — pure and unit-tested, because every branch of
  /// it decides whether a write may replace someone's playlists.
  static bool _hasUserContent(Map<String, dynamic> data) =>
      libraryHasUserContent(data);

  /// [_hasUserContent] for a stored JSON string. Unparseable → treated as
  /// having no content, which only ever makes the guards more cautious.
  static bool _blobHasUserContent(String? blob) {
    if (blob == null || blob.isEmpty) return false;
    try {
      return _hasUserContent(jsonDecode(blob) as Map<String, dynamic>);
    } catch (_) {
      return false;
    }
  }

  /// [userInitiated] false marks a save that no one asked for — a folder
  /// refresh, a cover heal, the periodic rescan. Those may never be the reason
  /// a library becomes empty, so they are held to the extra check below. A real
  /// user action (deleting the last playlist, unliking the last song) is always
  /// honoured.
  /// True from the start of an account wipe until the reload that follows it.
  ///
  /// THE FOURTH WAY A SAVE CAN DESTROY DATA — AND THE ONE THAT LEAKED ACROSS
  /// ACCOUNTS. The other guards ask "have we loaded yet?"; this one asks "is the
  /// library we hold still ours to write?".
  ///
  /// `_wipeLocalUserData` removes the prefs and only reloads the providers
  /// AFTERWARDS, so in between this notifier still holds the OUTGOING account's
  /// library in memory. Wiping the audio cache — correct on an account change —
  /// fires `onCacheUpdated` → refreshDownloadsFolder → `_saveToDisk`, which wrote
  /// those rows straight back into the just-cleared prefs. The reload then read
  /// them, and the incoming account saw the previous account's playlists.
  /// Observed exactly that way:
  ///
  /// Account switch detected at sign-in — wiping…
  /// Local database wiped
  /// Filtered: 6 items                            ← briefly empty
  /// library loaded: 16 row(s), 11 playlist(s)    ← the old account, back
  bool _accountResetting = false;

  /// A fingerprint of the blob last written, so an identical save is skipped.
  ///
  /// CLEARED WHENEVER THE STORED COPY CHANGES BEHIND US (a cloud restore, an
  /// account reset). Otherwise the next save would compare against a stored
  /// blob that is no longer there and skip the write that has to happen.
  String? _lastSavedSig;

  /// The exact state OBJECT the last encode described.
  ///
  /// An identity test, AND it is only sound because nothing mutates state in
  /// PLACE. Every change in this notifier goes through `state = state.copyWith`,
  /// and no code anywhere takes a state collection and adds to, removes from or
  /// sorts it — verified by grep over every field name. So the same instance
  /// really does mean the same content.
  ///
  /// If that ever stops being true, this becomes a way to skip a save that was
  /// needed, which in this file means losing a playlist. The byte comparison
  /// below stays as the backstop, and any in-place mutation must be turned into
  /// a copyWith rather than worked around here.
  ///
  /// Cleared alongside [_lastSavedSig] for the same reason: a restore or an
  /// account reset changes the stored copy behind us.
  LibraryState? _lastEncodedState;

  /// Enter the wipe window: drop the in-memory library AND refuse every save
  /// until [endAccountReset].
  ///
  /// Both halves are needed. Clearing alone leaves the refresh paths free to
  /// rebuild rows from the cache and persist those; blocking alone leaves the old
  /// account's library on screen until the reload lands.
  void beginAccountReset() {
    _accountResetting = true;
    _lastSavedSig = null;
    _lastEncodedState = null;
    state = state.copyWith(
      allItems: const [],
      likedSongs: const [],
      likedSongIds: const {},
      likedAlbums: const [],
      likedPlaylists: const [],
      subscribedArtists: const [],
      playlistSongs: const {},
      downloadProgressMap: const {},
    );
    _applyFilterAndSort();
  }

  Future<void> _saveToDisk({bool userInitiated = true}) async {
    if (_accountResetting) {
      print("STOP: refusing to save the library: an account reset is in progress, "
          "so this write would restore the PREVIOUS account's data over the "
          "wipe (see _accountResetting)");
      return;
    }
    if (_loadFailed) {
      print("STOP: refusing to save the library: this session failed to LOAD it, "
          "so writing would overwrite the good copy with an empty one");
      return;
    }
    if (!_loaded) {
      print("STOP: refusing to save the library: it has not finished LOADING yet, "
          "so this write would persist the empty startup state over the real "
          "one (see _loaded)");
      return;
    }
    // The cheapest check runs first
    //
    // The byte comparison below already stops a redundant WRITE, but it can
    // only answer after a full jsonEncode of the whole library, and the
    // 2026-08-30 transcript shows that answer being computed 149 times in 28
    // hours, 47 of them to conclude that nothing had changed at all.
    //
    // The state object is replaced on every mutation and never edited in
    // place, so the same instance is proof that there is nothing to write, and
    // it costs one reference comparison instead of ~770KB of encoding.
    //
    // THE SNAPSHOT IS THEN USED THROUGHOUT. Reading `state` again after the
    // await below could describe a different object than the one just
    // compared, which would make the fast path lie in the worst direction.
    final snapshot = state;
    if (identical(snapshot, _lastEncodedState)) return;

    final prefs = await SharedPreferences.getInstance();
    // The cached folder is NOT persisted, AND that is the point
    //
    // THE COST THIS REMOVES, measured in the 2026-08-30 transcript: 102 whole
    // library writes in 28 hours — 833KB re-encoded and TWO full prefs rewrites
    // (live key + backup key) each time, and the trigger for nearly all of them
    // was a track being auto-cached or LRU-evicted. The count oscillated 159 ↔
    // 160 all day, and each flip changed the blob twice over: the song list under
    // `playlistSongs['Cached']`, and the row's own subtitle, which carries the
    // count. So the byte-identical guard below could not help — the bytes really
    // did differ, for state that was never worth storing.
    //
    // Not worth storing because the cache index is already the truth.
    // refreshCachedFolder rebuilds this list wholesale from AudioCacheManager,
    // it preserves no user-chosen order (unlike Downloads, which does and is
    // therefore kept), and it is called unconditionally right after the load on
    // BOTH branches. Persisting it duplicated a separately-persisted index and
    // then paid for the duplicate on every cached track.
    //
    // Only the WRITTEN copy is trimmed — in-memory state is untouched, so
    // nothing on screen changes. The empty-save guards are unaffected too:
    // libraryHasUserContent already skips every kSystemLibraryTitles row, so a
    // library made of nothing but system folders counted as empty before this
    // and still does.
    // THESE THREE ROWS ARE THROWN AWAY BY THE LOADER. See the removeWhere
    // above the load, which drops each of them and inserts a freshly-built one.
    // So every byte stored for them is written and never read, and their live
    // subtitle (which carries a COUNT) and dateAdded (set to now at each load)
    // made the blob differ for reasons no reader could ever observe.
    //
    // Zeroed rather than omitted, so the stored shape still matches what earlier
    // builds wrote and anything reading the blob by hand still finds the rows.
    const derivedFolder = 'Cached';
    const rebuiltRows = {'Cached', 'Downloads', 'Liked Playlists'};
    final persistedItems = snapshot.allItems.map((i) {
      final m = i.toMap();
      if (!rebuiltRows.contains(i.title)) return m;
      m['subtitle'] = 'Playlist • 0 songs';
      m['songCount'] = 0;
      m['dateAdded'] = DateTime.fromMillisecondsSinceEpoch(0).toIso8601String();
      return m;
    }).toList();
    final data = {
      'allItems': persistedItems,
      'likedSongs': snapshot.likedSongs.map((s) => s.toMap()).toList(),
      'likedAlbums': snapshot.likedAlbums.map((a) => a.toMap()).toList(),
      'likedPlaylists': snapshot.likedPlaylists.map((p) => p.toMap()).toList(),
      'subscribedArtists':
          snapshot.subscribedArtists.map((s) => s.toMap()).toList(),
      'playlistSongs': {
        for (final e in snapshot.playlistSongs.entries)
          if (e.key != derivedFolder)
            e.key: e.value.map((s) => s.toMap()).toList(),
      },
      'downloadProgressMap': snapshot.downloadProgressMap,
    };

    final nowHasContent = _hasUserContent(data);
    if (!userInitiated && !nowHasContent) {
      // A background refresh is about to empty a library that wasn't empty.
      // There is no sequence of events where that is correct, so refuse.
      if (_blobHasUserContent(prefs.getString(_kLibraryKey))) {
        print("STOP: BLOCKED an automatic save that would have emptied the "
            "library. Keeping the stored copy. (This is the guard for the "
            "overnight-wipe bug — if you see it, something refreshed folders "
            "before the library finished loading.)");
        return;
      }
    }

    // Instrumented because this is the heaviest synchronous thing the library
    // does, and it runs on the main isolate: `jsonEncode` walks every playlist,
    // liked song and cached track, and the result is then written to
    // SharedPreferences TWICE (live key + backup key), each of which rewrites the
    // whole prefs XML. Observed live, six saves landed inside a single second —
    // twelve whole-library writes, which is the leading suspect for the "UI
    // freezes for a second" report. StallWatchdog attributes a stall to whatever
    // it timed, so this now names itself instead of being guessed at.
    final encoded =
        StallWatchdog.time('library.jsonEncode', () => jsonEncode(data));
    StallWatchdog.note('library.blobKB', encoded.length ~/ 1024);

    // An identical save is still two full prefs rewrites
    //
    // The comment above counts six saves inside one second — twelve
    // whole-library writes, and it is written as a cost of the ENCODE. It is
    // not: the encode is one pass, the writes are two rewrites of the entire
    // prefs XML each, and in a burst like that every one of them stores exactly
    // the same bytes as the last.
    //
    // Comparing a fingerprint first turns a burst into one write. The encode
    // still has to run to produce it, so nothing is guessed at — the
    // comparison is against what was actually built, and the identity is
    // length plus hash rather than the string, so nothing is held twice.
    final sig = '${encoded.length}:${encoded.hashCode}';
    if (sig == _lastSavedSig) {
      // Remembered here too: a copyWith that happens to produce identical
      // content still yields a NEW object, and without this the cheap check
      // above would keep missing and every later call would re-encode to reach
      // this same conclusion.
      _lastEncodedState = snapshot;
      print('library save skipped — byte-identical to the last write '
          '(${encoded.length ~/ 1024}KB)');
      return;
    }

    await StallWatchdog.timeAsync('library.prefsWrite', () async {
      await prefs.setString(_kLibraryKey, encoded);
      if (nowHasContent) await prefs.setString(_kLibraryBackupKey, encoded);
    });
    _lastSavedSig = sig;
    _lastEncodedState = snapshot;
    // The size of the heaviest synchronous thing the library does, which was
    // measured but never reported: note() is inert without the debug define and
    // nothing ever printed it, so the blob's real size has never been known.
    print('library saved: ${encoded.length ~/ 1024}KB'
        '${nowHasContent ? ' (+backup)' : ''}');
    // Mirror the library to the cloud (debounced) so it survives a reinstall.
    CloudSyncService.instance.scheduleBackup();
  }

  /// Re-read the persisted library from SharedPreferences. Called after a cloud
  /// restore overwrites the local blob so in-memory state matches.
  /// Also ENDS an account-reset window — the reload is what makes the in-memory
  /// library ours to write again. Clearing the flag anywhere else would reopen
  /// the gap this guard exists to close.
  Future<void> reloadFromStorage() {
    _accountResetting = false;
    // The stored blob was just replaced by someone else (a cloud restore, a
    // wipe). Any fingerprint we hold describes a copy that is gone, so the next
    // save must write rather than compare.
    _lastSavedSig = null;
    _lastEncodedState = null;
    return _init();
  }

  // Adds or removes a song from the "Liked Songs" collection.
  // [restoreAt]: when re-adding via Undo, the song's original position — so
  // undo puts it back where it was instead of hoisting it to the top.
  void toggleSongLike(Song song, {int restoreAt = -1}) {
    final newSongs = List<Song>.from(state.likedSongs);
    final newIds = Set<String>.from(state.likedSongIds);
    if (newIds.contains(song.id)) {
      newIds.remove(song.id);
      newSongs.removeWhere((s) => s.id == song.id);
    } else {
      newIds.add(song.id);
      final at = (restoreAt < 0 || restoreAt > newSongs.length) ? 0 : restoreAt;
      newSongs.insert(at, song);
    }
    _updateSystemFolder("Liked Songs", "${newSongs.length} songs", null);
    state = state.copyWith(likedSongs: newSongs, likedSongIds: newIds);
    _saveToDisk();
  }

  /// Swap freshly-refetched metadata for a track into every place the library
  /// stores it — Liked Songs and every playlist.
  ///
  /// THE LIBRARY KEEPS ITS OWN COPY OF EVERY TRACK. `likedSongs` and
  /// `playlistSongs` hold whole Song objects, persisted to disk, so a refetch that
  /// only fixed the player's copy looked correct until the app was reopened — at
  /// which point the old cover and old title came straight back from storage. The
  /// same shape of bug as the Home mosaic's separate image copy.
  ///
  /// Saves only when something actually changed, so a refetch on a track that is
  /// not in the library costs no disk write.
  void replaceSongEverywhere(Song fresh) {
    final id = fresh.id;
    if (id.isEmpty) return;
    var changed = false;

    List<Song> swap(List<Song> list) {
      if (!list.any((s) => s.id == id)) return list;
      changed = true;
      return list.map((s) => s.id == id ? fresh : s).toList();
    }

    final liked = swap(state.likedSongs);
    final playlists = <String, List<Song>>{};
    state.playlistSongs.forEach((title, songs) {
      playlists[title] = swap(songs);
    });

    if (!changed) return;
    state = state.copyWith(likedSongs: liked, playlistSongs: playlists);
    _saveToDisk();
  }

  // Changes the order of songs within the "Liked Songs" playlist.
  void reorderLikedSongs(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final current = List<Song>.from(state.likedSongs);
    final moved = current.removeAt(oldIndex);
    current.insert(newIndex, moved);
    state = state.copyWith(likedSongs: current);
    _saveToDisk();
  }

  // Removes a specific track from a user-created playlist. Returns the index
  // the song sat at (so Undo can restore it in place), or -1 if absent.
  int removeSongFromPlaylist(String playlistTitle, String songId) {
  final currentSongs = state.playlistSongs[playlistTitle] ?? [];
  final removedIndex = currentSongs.indexWhere((s) => s.id == songId);
  final newSongs = currentSongs.where((s) => s.id != songId).toList();

  if (newSongs.length == currentSongs.length) return -1; // No change

  final newMap = Map<String, List<Song>>.from(state.playlistSongs);
  newMap[playlistTitle] = newSongs;
  
  final newAllItems = state.allItems.map((item) {
    if (item.title == playlistTitle) {
      return LibraryItem(
        title: item.title, 
        subtitle: "Playlist • ${newSongs.length} songs", 
        image: item.image, 
        isPinned: item.isPinned, 
        category: item.category, 
        dateAdded: item.dateAdded, 
        songCount: newSongs.length, 
        isSystemFolder: false
      );
    }
    return item;
  }).toList();
  
  state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
  _applyFilterAndSort();
  _saveToDisk();
  return removedIndex;
  }

  // Adds a song to an existing user-created playlist. [atIndex] (from
  // removeSongFromPlaylist) restores an undone delete to its original spot;
  // default appends.
  /// Adds [song] to a playlist. Returns TRUE when it was actually added, FALSE
  /// when the playlist already contained it.
  ///
  /// The return value matters. This used to be `void` and simply `return`ed on
  /// a duplicate — while every call site went on to show "Added to `<playlist>`".
  /// So adding a song twice reported success and did nothing, which is worse than
  /// an error: the user believes the library changed. Callers now say
  /// "Already in `<playlist>`" instead.
  ///
  /// Duplicate detection also matches on title+artist, not just id. The same
  /// recording resolved from a different source carries a different video id, so
  /// an id-only check let visible duplicates into playlists.
  bool addSongToPlaylist(String playlistTitle, Song song, {int atIndex = -1}) {
    final currentSongs = state.playlistSongs[playlistTitle] ?? [];
    final sig = '${song.title.toLowerCase().trim()}|${song.artist.toLowerCase().trim()}';
    if (currentSongs.any((s) =>
        s.id == song.id ||
        '${s.title.toLowerCase().trim()}|${s.artist.toLowerCase().trim()}' == sig)) {
      return false;
    }
    final newSongs = [...currentSongs];
    final at = (atIndex < 0 || atIndex > newSongs.length)
        ? newSongs.length
        : atIndex;
    newSongs.insert(at, song);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = newSongs;
    final newAllItems = state.allItems.map((item) {
      if (item.title == playlistTitle) return LibraryItem(title: item.title, subtitle: "Playlist • ${newSongs.length} songs", image: item.image, isPinned: item.isPinned, category: item.category, dateAdded: item.dateAdded, songCount: newSongs.length, isSystemFolder: false);
      return item;
    }).toList();
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort(); _saveToDisk();
    return true;
  }

  // Reorders tracks within a specific user playlist.
  void reorderPlaylistTracks(String playlistTitle, int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final currentSongs = List<Song>.from(state.playlistSongs[playlistTitle] ?? []);
    if (oldIndex >= currentSongs.length || newIndex >= currentSongs.length) return;
    final movedSong = currentSongs.removeAt(oldIndex);
    currentSongs.insert(newIndex, movedSong);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = currentSongs;
    state = state.copyWith(playlistSongs: newMap);
    _saveToDisk();
  }

  /// Rename a user playlist, moving everything that is keyed by its title.
  ///
  /// THE TITLE IS THE PRIMARY KEY. Songs live in `playlistSongs[title]` and
  /// the custom cover lives under `playlist:<title>` in the artwork override
  /// store, so changing only the LibraryItem's label would orphan both — the
  /// playlist would come back empty with its artwork gone. Everything moves
  /// together here or not at all.
  ///
  /// Returns false when the rename is refused: an empty name, an unchanged
  /// name, a name already in use, or a system folder (Liked Songs, Downloads,
  /// Cached, My Top 50 are structural, not user-named).
  Future<bool> renamePlaylist(String oldName, String newName) async {
    final next = newName.trim();
    if (next.isEmpty || next == oldName) return false;

    final item = state.allItems.cast<LibraryItem?>().firstWhere(
        (i) => i?.title == oldName,
        orElse: () => null);
    if (item == null || item.isSystemFolder) return false;
    // Case-insensitive collision check: two playlists differing only in case
    // would be indistinguishable in the UI and would fight over the same
    // artwork key.
    if (state.allItems.any((i) =>
        i.title.toLowerCase() == next.toLowerCase() && i.title != oldName)) {
      return false;
    }

    // 1. The songs, preserving order.
    final songs = Map<String, List<Song>>.from(state.playlistSongs);
    final tracks = songs.remove(oldName) ?? <Song>[];
    songs[next] = tracks;

    // 2. The library row.
    final items = state.allItems
        .map((i) => i.title == oldName
            ? LibraryItem(
                title: next,
                subtitle: i.subtitle,
                image: i.image,
                isPinned: i.isPinned,
                category: i.category,
                dateAdded: i.dateAdded,
                songCount: i.songCount,
                isSystemFolder: false,
                isCircle: i.isCircle,
              )
            : i)
        .toList();

    state = state.copyWith(allItems: items, playlistSongs: songs);

    // 3. The custom cover. setOverride re-encodes from the stored file, so the
    //    image survives the move; the old key is then dropped so it cannot be
    //    resurrected by a future playlist that happens to reuse the name.
    //
    // A MANUAL COVER IS STORED TWICE, AND ONLY ONE COPY USED TO MOVE.
    // _commitPendingCover writes the override AND copies that same file path
    // into LibraryItem.image. setOverride writes a fresh versioned filename
    // every time and clearOverride deletes the old file, so moving only the
    // override left item.image pointing at a file that had just been deleted:
    // a coverless playlist in the library grid, while the home mosaic (which
    // resolves through the override map) still looked right. The heal at the
    // next library load re-pointed it, so the cover came back after a restart
    // — which is exactly what made this look random rather than reproducible.
    try {
      final overrides = ref.read(artworkOverrideProvider);
      final oldKey = 'playlist:$oldName';
      final existing = overrides[oldKey];
      if (existing != null && existing.isNotEmpty) {
        final notifier = ref.read(artworkOverrideProvider.notifier);
        // THE RETURN VALUE MATTERS. It used to be discarded and clearOverride
        // ran regardless, so a re-encode that failed — unreadable source file,
        // no space, a decoder that rejected the bytes — deleted the only
        // remaining copy of a cover the user had chosen. Keep the old key when
        // the move did not land; a cover under the wrong name is recoverable,
        // a deleted one is not.
        final moved = await notifier.setOverride('playlist:$next', existing);
        if (moved) {
          await notifier.clearOverride(oldKey);
        } else {
          print('WARN: the cover did not survive renaming "$oldName" to '
              '"$next" — keeping it under the old key rather than deleting '
              'the last copy');
        }
      }
    } catch (_) {
      // The rename itself already succeeded; a cover that fails to move is a
      // cosmetic loss, not a reason to leave the library half-renamed.
    }

    // item.image still holds the path from before the rename. The override map
    // is the source of truth for a deliberate cover, so make the item follow
    // it. persist: false because the _saveToDisk below already covers this.
    _reconcileCustomCovers(persist: false);

    _applyFilterAndSort();
    _saveToDisk();
    return true;
  }

  // Creates a new empty playlist with the specified name.
  void addPlaylist(String name) {
    if (state.allItems.any((i) => i.title == name)) return;
    final newItem = LibraryItem(title: name, subtitle: "Playlist • 0 songs", image: "assets/images/playlist_cyan.webp", category: LibraryCategory.playlist, dateAdded: DateTime.now());
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[name] = [];
    state = state.copyWith(allItems: [newItem, ...state.allItems], playlistSongs: newMap);
    _applyFilterAndSort(); _saveToDisk();
  }

  // Allows user to update the cover art for a custom playlist
  void updatePlaylistImage(String playlistTitle, String newImagePath) {
    final newAllItems = state.allItems.map((item) {
      // Ensure we never accidentally modify a system folder like "Liked Songs"
      if (item.title == playlistTitle && !item.isSystemFolder) {
        return LibraryItem(
          title: item.title, 
          subtitle: item.subtitle, 
          image: newImagePath, 
          isPinned: item.isPinned, 
          category: item.category, 
          dateAdded: item.dateAdded, 
          songCount: item.songCount, 
          isSystemFolder: false,
          isCircle: item.isCircle,
        );
      }
      return item;
    }).toList();
    state = state.copyWith(allItems: newAllItems);
    // THE HOME MOSAIC STORES ITS OWN COPY OF THE IMAGE. Recents are persisted
    // as whole entries (recent_playlists_v1), so updating allItems alone left the
    // mosaic showing the previous cover until that playlist happened to be opened
    // again. Only reproduced on playlists the user CREATED — imported ones carry
    // a remote URL that is the same string in both stores.
    try {
      ref
          .read(recentPlaylistsProvider.notifier)
          .updateImageFor(playlistTitle, newImagePath);
    } catch (_) {
      // Cosmetic: a mosaic tile that lags is not worth failing the cover change.
    }
    _applyFilterAndSort();
    _saveToDisk();
  }

  // Saves a playlist found via search into the user's local library.
  /// Merge an imported library in, without losing this one
  ///
  /// Used by the restore screen for a backup written by ANOTHER music app (see
  /// [ForeignBackupReader]). Everything here is additive:
  ///
  ///  • Liked songs are a union. A track already liked keeps its existing entry
  ///    and position — the incoming copy does not overwrite metadata this app
  ///    resolved itself.
  ///  • A playlist whose name is already taken is imported ALONGSIDE, suffixed
  ///    with the source app, never merged into and never over. Two playlists
  ///    called "Chill" from two apps are not the same playlist, and guessing
  ///    wrong destroys one of them.
  ///  • Play counts take the HIGHER of the two. An import can only ever raise
  ///    the count for a track, so a foreign number cannot shrink real listening
  ///    history.
  ///
  /// ONE state write and ONE save for the whole import: an 800-track library
  /// applied through the per-song entry points would rebuild state 800 times and
  /// write the library blob to disk just as often.
  ///
  /// Returns a summary of what was actually added, so the UI can report it
  /// instead of claiming success in the abstract.
  ImportSummary mergeImportedLibrary({
    required String sourceApp,
    List<Song> likedSongs = const [],
    Map<String, List<Song>> playlists = const {},
    List<Album> albums = const [],
    List<Song> artists = const [],
  }) {
    // A load that has not finished yet must not be merged into: the incoming
    // data would be written and then overwritten by the load landing after it.
    if (!_loaded) return const ImportSummary(0, 0, 0, 0);

    var addedLikes = 0, addedPlaylists = 0, addedTracks = 0, addedAlbums = 0;

    // liked songs: union, existing entries win
    final newLiked = List<Song>.from(state.likedSongs);
    final newLikedIds = Set<String>.from(state.likedSongIds);
    // Title+artist as well as id, because the same recording carries different
    // ids in different apps — the same reason the now-playing indicator cannot
    // match on id alone (see isSameTrack).
    final likedSigs = <String>{
      for (final s in newLiked) _importSig(s),
    };
    for (final song in likedSongs) {
      if (newLikedIds.contains(song.id)) continue;
      if (!likedSigs.add(_importSig(song))) continue;
      newLikedIds.add(song.id);
      newLiked.add(song);
      addedLikes++;
    }

    // playlists: never write over an existing name
    final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);
    final newAllItems = List<LibraryItem>.from(state.allItems);
    playlists.forEach((rawName, tracks) {
      if (tracks.isEmpty) return;
      var name = rawName.trim();
      if (name.isEmpty) return;
      if (newPlaylistSongs.containsKey(name) ||
          newAllItems.any((i) => i.title == name)) {
        name = '$name ($sourceApp)';
        // Still taken (a second import of the same file) — number it rather
        // than silently replacing what the first import created.
        var n = 2;
        while (newPlaylistSongs.containsKey(name) ||
            newAllItems.any((i) => i.title == name)) {
          name = '${rawName.trim()} ($sourceApp $n)';
          n++;
          if (n > 50) return; // give up rather than loop
        }
      }
      final deduped = _dedupe(tracks);
      newPlaylistSongs[name] = deduped;
      newAllItems.insert(
          0,
          LibraryItem(
            title: name,
            subtitle: 'Playlist • ${deduped.length} songs',
            image: deduped.isNotEmpty && deduped.first.image.isNotEmpty
                ? deduped.first.image
                : 'assets/images/playlist_cyan.webp',
            category: LibraryCategory.playlist,
            dateAdded: DateTime.now(),
            songCount: deduped.length,
          ));
      addedPlaylists++;
      addedTracks += deduped.length;
    });

    // liked albums and followed artists: union by title/name
    final newAlbums = List<Album>.from(state.likedAlbums);
    for (final album in albums) {
      if (newAlbums.any((a) => a.title == album.title)) continue;
      newAlbums.add(album);
      newAllItems.insert(
          0,
          LibraryItem(
            title: album.title,
            subtitle: 'Album • ${album.artist}',
            image: album.image,
            category: LibraryCategory.album,
            dateAdded: DateTime.now(),
          ));
      addedAlbums++;
    }

    final newArtists = List<Song>.from(state.subscribedArtists);
    for (final artist in artists) {
      if (newArtists.any((a) => a.title == artist.title)) continue;
      newArtists.add(artist);
    }

    state = state.copyWith(
      likedSongs: newLiked,
      likedSongIds: newLikedIds,
      playlistSongs: newPlaylistSongs,
      allItems: newAllItems,
      likedAlbums: newAlbums,
      subscribedArtists: newArtists,
    );
    _recomputeCollectionCounts();
    _applyFilterAndSort();
    _saveToDisk();
    return ImportSummary(addedLikes, addedPlaylists, addedTracks, addedAlbums);
  }

  /// Identity for import dedup: the same rule the rest of the app uses for
  /// "is this the same recording", reduced to a key.
  static String _importSig(Song s) =>
      '${s.title.toLowerCase().trim()}|'
      '${s.artist.split(',').first.toLowerCase().trim()}';

  bool savePlaylistFromSearch(Song playlistItem, List<Song> initialTracks) {
    if (state.allItems.any((i) => i.title == playlistItem.title && i.category == LibraryCategory.playlist)) return false; 
    final newItem = LibraryItem(title: playlistItem.title, subtitle: "Playlist • ${initialTracks.length} songs", image: playlistItem.image, category: LibraryCategory.playlist, dateAdded: DateTime.now(), songCount: initialTracks.length);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistItem.title] = initialTracks;
    state = state.copyWith(allItems: [newItem, ...state.allItems], playlistSongs: newMap);
    _applyFilterAndSort(); _saveToDisk();
    return true;
  }

  bool toggleAlbumLike(Album album, String artistName) {
    final exists = state.likedAlbums.any((a) => a.title == album.title);
    List<Album> newList;
    List<LibraryItem> newAllItems = List.from(state.allItems);
    Map<String, List<Song>> newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);

    final isPodcast = album.recordType == 'podcast';

    if (exists) {
      newList = state.likedAlbums.where((a) => a.title != album.title).toList();
      newAllItems.removeWhere((i) => i.title == album.title);
      newPlaylistSongs.remove(album.title);
    } else {
      // Persist the ARTIST with the liked album — the library needs it to
      // resolve the album's tracks later (an artist-less album resolved with
      // "Unknown" and opened empty).
      final stamped = album.artist.isNotEmpty
          ? album
          : Album(
              id: album.id,
              title: album.title,
              image: album.image,
              releaseDate: album.releaseDate,
              recordType: album.recordType,
              subtitle: album.subtitle,
              artist: artistName,
            );
      newList = [...state.likedAlbums, stamped];
      if (!newAllItems.any((i) => i.title == album.title)) {
        newAllItems.insert(0, LibraryItem(
          title: album.title,
          subtitle: "${isPodcast ? 'Podcast' : 'Album'} • $artistName",
          image: album.image,
          //  THE MAGIC FIX: Save podcasts strictly as Playlists in the Library!
          category: isPodcast ? LibraryCategory.playlist : LibraryCategory.album, 
          dateAdded: DateTime.now(),
          songCount: 0,
          isSystemFolder: false,
        ));
      }
    }
    
    //  FIX: Exclude podcasts from the "Liked Albums" system folder counter
    final actualAlbumCount = newList.where((a) => a.recordType != 'podcast').length;

    // ORDER MATTERS — THIS IS WHY THE COUNT NEVER MOVED.
    //
    // _updateSystemFolder writes the new subtitle by doing
    // `state = state.copyWith(allItems: <state.allItems with the count changed>)`.
    // It used to run BEFORE the copyWith below, which then overwrote allItems with
    // `newAllItems` — a list captured at the top of this method, before the folder
    // was touched. So the count was computed correctly, written correctly, and
    // thrown away one line later. "Liked Albums" sat at whatever it said the first
    // time forever.
    //
    // Committing the like FIRST and updating the folder SECOND means the folder
    // update is applied on top of the finished list instead of under it.
    state = state.copyWith(likedAlbums: newList, allItems: newAllItems, playlistSongs: newPlaylistSongs);
    _updateSystemFolder("Liked Albums", "$actualAlbumCount Albums", null);
    // Followed Podcasts is the OTHER half of the same list, so its count is
    // derived here rather than anywhere else — the two can never disagree.
    _updateSystemFolder("Followed Podcasts",
        "${newList.length - actualAlbumCount} Podcasts", null);
    // _updateSystemFolder already re-filters, but this path can also change
    // allItems membership, so keep the explicit pass.
    _applyFilterAndSort();
    _saveToDisk();
    return !exists;
  }

  void updateAlbumTracks(String albumTitle, List<Song> tracks) {
      final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);
      newPlaylistSongs[albumTitle] = tracks;

      final newAllItems = state.allItems.map((item) {
          //  FIX: Match by title only (removed category check). 
          // This ensures background episodes successfully inject into the podcast playlist.
          if (item.title == albumTitle) {
              return LibraryItem(
                  title: item.title, subtitle: item.subtitle, image: item.image,
                  isPinned: item.isPinned, category: item.category,
                  dateAdded: item.dateAdded, songCount: tracks.length, isSystemFolder: item.isSystemFolder,
              );
          }
          return item;
      }).toList();

      state = state.copyWith(playlistSongs: newPlaylistSongs, allItems: newAllItems);
      _applyFilterAndSort();
      _saveToDisk();
  }

  // Background processor that updates all podcasts every 6 hours
  Future<void> _refreshAllPodcasts() async {
      final podcasts = state.likedAlbums.where((a) => a.recordType == 'podcast').toList();
      if (podcasts.isEmpty) return;

      print("Running background podcast refresh for ${podcasts.length} shows...");
      for (final p in podcasts) {
          try {
              final show = PodcastShow(collectionName: p.title, artistName: 'Podcast', artworkUrl: p.image, feedUrl: p.id);
              final episodes = await ref.read(podcastEpisodesProvider(show).future);
              if (episodes.isNotEmpty) {
                  updateAlbumTracks(p.title, episodes.map((e) => e.toSong()).toList());
              }
          } catch (e) {
              print("ERROR: Failed to refresh podcast ${p.title}: $e");
          }
      }
  }

  // Toggles the subscription status for a specific artist.
  bool toggleArtistSubscription(String artistName, String imageUrl, String artistId) {
    final exists = state.subscribedArtists.any((a) => a.title == artistName);
    List<Song> newList;
    if (exists) newList = state.subscribedArtists.where((a) => a.title != artistName).toList();
    else newList = [...state.subscribedArtists, Song(title: artistName, artist: "Artist", image: imageUrl, id: artistId)];
    _updateSystemFolder("Followed Artists", "${newList.length} Artists", null);
    state = state.copyWith(subscribedArtists: newList); _saveToDisk();
    return !exists;
  }

  //  FIX: Permanently deletes an item from ALL lists, allowing accurate "Unfollowing".
  //  Returns a snapshot for [restoreItem] so callers can offer Undo (null when
  //  nothing was deleted, i.e. system folders).
  DeletedLibraryItem? deleteItem(LibraryItem item) {
    if (item.isSystemFolder) return null;

    Album? likedAlbum;
    for (final a in state.likedAlbums) {
      if (a.title == item.title) { likedAlbum = a; break; }
    }
    LibraryItem? likedPlaylist;
    for (final p in state.likedPlaylists) {
      if (p.title == item.title) { likedPlaylist = p; break; }
    }
    final snapshot = DeletedLibraryItem(
      item: item,
      songs: state.playlistSongs[item.title],
      likedAlbum: likedAlbum,
      likedPlaylist: likedPlaylist,
      index: state.allItems.indexOf(item),
    );

    final newAllItems = state.allItems.where((i) => i != item).toList();
    final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs)..remove(item.title);
    final newLikedAlbums = state.likedAlbums.where((a) => a.title != item.title).toList();
    final newLikedPlaylists = state.likedPlaylists.where((p) => p.title != item.title).toList();

    state = state.copyWith(
        allItems: newAllItems,
        playlistSongs: newPlaylistSongs,
        likedAlbums: newLikedAlbums,
        likedPlaylists: newLikedPlaylists,
    );

    // Derived, not counted here — podcasts share likedAlbums. See
    // _recomputeCollectionCounts.
    _recomputeCollectionCounts();

    _applyFilterAndSort();
    _saveToDisk();
    return snapshot;
  }

  /// Puts back everything a [deleteItem] removed (the Undo path). Safe against
  /// double-restores: no-op if the item is already in the library again.
  void restoreItem(DeletedLibraryItem snapshot) {
    final item = snapshot.item;
    if (state.allItems.any((i) => i.title == item.title && i.category == item.category)) return;

    // Back into its ORIGINAL slot (clamped — the list may have shrunk/grown
    // while the undo toast was showing), not appended to the end.
    final newAllItems = [...state.allItems];
    final at = (snapshot.index < 0 || snapshot.index > newAllItems.length)
        ? newAllItems.length
        : snapshot.index;
    newAllItems.insert(at, item);
    final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);
    if (snapshot.songs != null) newPlaylistSongs[item.title] = snapshot.songs!;
    final newLikedAlbums = snapshot.likedAlbum != null
        ? [...state.likedAlbums, snapshot.likedAlbum!]
        : state.likedAlbums;
    final newLikedPlaylists = snapshot.likedPlaylist != null
        ? [...state.likedPlaylists, snapshot.likedPlaylist!]
        : state.likedPlaylists;

    state = state.copyWith(
        allItems: newAllItems,
        playlistSongs: newPlaylistSongs,
        likedAlbums: newLikedAlbums,
        likedPlaylists: newLikedPlaylists,
    );

    // Derived, not counted here — podcasts share likedAlbums. See
    // _recomputeCollectionCounts.
    _recomputeCollectionCounts();

    _applyFilterAndSort();
    _saveToDisk();
  }

  // Toggles the pinned status of a library item for priority listing.
  void togglePin(LibraryItem item) { final updated = LibraryItem(title: item.title, subtitle: item.subtitle, image: item.image, isPinned: !item.isPinned, isCircle: item.isCircle, category: item.category, dateAdded: item.dateAdded, songCount: item.songCount, isSystemFolder: item.isSystemFolder); state = state.copyWith(allItems: state.allItems.map((i) => i == item ? updated : i).toList()); _applyFilterAndSort(); _saveToDisk(); }
  
  // Changes the active category filter for the library view.
  void setCategory(LibraryCategory category) { state = state.copyWith(selectedCategory: category); _applyFilterAndSort(); }
  
  // Switches the library display between list and grid views.
  void toggleView() { state = state.copyWith(isGrid: !state.isGrid); _saveToDisk(); }
  
  // Updates the active search query for filtering library items.
  void setSearchQuery(String query) { state = state.copyWith(searchQuery: query); _applyFilterAndSort(); }

  // Check functions for UI state (likes and subscriptions).
  bool isSongLiked(String id) => state.likedSongIds.contains(id);
  bool isSubscribed(String artistName) => state.subscribedArtists.any((a) => a.title == artistName);
  bool isAlbumLiked(String albumTitle) => state.likedAlbums.any((a) => a.title == albumTitle);

  // Internal helper to update metadata for automatic system folders like "Liked Songs".
  /// System rows that hold SONGS, and so read as "Playlist • …".
  ///
  /// Everything else system-owned holds collections — followed artists, followed
  /// podcasts, liked albums, and reads as "Folder • …". Kept as an explicit list
  /// because neither `isSystemFolder` nor `category` distinguishes the two: see
  /// the note in [_updateSystemFolder].
  static const Set<String> _kPlaylistLikeFolders = {
    'Liked Songs',
    'My Top 50',
    'Cached',
    'Downloads',
    'Liked Playlists',
  };

  void _updateSystemFolder(String title, String newSubtitle, String? newImage) {
    final newAllItems = state.allItems.map((item) {
      if (item.title == title) {
        return LibraryItem(
          title: item.title,
          // THE KIND COMES FROM THE CATEGORY, NOT FROM isSystemFolder.
          //
          // This read `item.isSystemFolder ? "Playlist • …" : "Folder • …"`,
          // which is backwards for exactly the rows it was meant to describe:
          // every system entry was labelled "Playlist", so Followed Artists said
          // "Playlist • 5 Artists" and Liked Albums said "Playlist • 12 Albums".
          //
          // isSystemFolder answers "is this scaffolding?", which says nothing
          // about what the row CONTAINS.
          //
          // AND `category` DOES NOT ANSWER IT EITHER — I tried. "Liked Songs"
          // and "My Top 50" are both filed under LibraryCategory.folder despite
          // being playlists of songs, so keying off the category relabels them
          // "Folder • 128 songs". The categories are simply not consistent with
          // the semantics, and rather than re-file them (which is persisted state
          // other code switches on) the small fixed set is named here.
          subtitle: _kPlaylistLikeFolders.contains(item.title)
              ? "Playlist • $newSubtitle"
              : "Folder • $newSubtitle",
          image: newImage ?? item.image, 
          isPinned: item.isPinned, 
          category: item.category,
          dateAdded: item.dateAdded, 
          isSystemFolder: true, 
          isCircle: item.isCircle, 
          songCount: int.tryParse(newSubtitle.split(' ').first) ?? 0,
        );
      }
      return item;
    }).toList();
    state = state.copyWith(allItems: newAllItems);
    _applyFilterAndSort();
  }

  /// Recompute EVERY collection folder's count from the lists themselves.
  ///
  /// THE COUNT IS PERSISTED SEPARATELY FROM THE THING IT COUNTS, so the two
  /// drift and nothing was putting them back together. Three ways it went wrong,
  /// all reported at once:
  ///
  ///  • **Stale.** The subtitle is stored inside the `allItems` row, so a load
  ///    restores whatever number was written last. Nothing recomputed it, so
  ///    "Liked Albums" could say 2 next to one album for ever.
  ///  • **Reset to zero.** `_init` re-inserts the "Liked Playlists" row fresh
  ///    every load, hard-coded to 0, so it read 0 until the next like/unlike.
  ///  • **Wrong by construction.** Two of the three "Liked Albums" writers used
  ///    `likedAlbums.length` raw, but PODCASTS SHARE THAT LIST, and the album
  ///    grid filters them out. One followed podcast plus one liked album showed
  ///    "2 Albums" over a single row. Only the toggle path filtered correctly.
  ///
  /// Deriving all of them here, from state, in one pass means a count cannot be
  /// individually forgotten again, and the podcast split is defined once, so
  /// Albums and Podcasts can never disagree about the same list.
  ///
  /// Cached/Downloads are deliberately absent: those come from the cache manager,
  /// not from these lists, and have their own refresh paths.
  void _recomputeCollectionCounts() {
    final albums =
        state.likedAlbums.where((a) => a.recordType != 'podcast').length;
    final podcasts = state.likedAlbums.length - albums;
    final wanted = <String, String>{
      'Liked Songs': '${state.likedSongs.length} songs',
      'Liked Albums': '$albums Albums',
      'Followed Podcasts': '$podcasts Podcasts',
      'Liked Playlists': '${state.likedPlaylists.length} Playlists',
      'Followed Artists': '${state.subscribedArtists.length} Artists',
      // COUNTED THE WAY THE PAGE COUNTS IT — WHICH IS NOT FROM playlistSongs.
      //
      // My Top 50's label was written ONLY by refreshTop50, which runs when a
      // track finishes playing or after a cloud restore — never on a plain
      // launch. So the row said "0 songs" while the folder opened onto a full
      // playlist.
      //
      // The first fix counted `playlistSongs['My Top 50']` and STILL read 0,
      // because that map is not where the folder's content comes from either:
      // playlist_page DERIVES the list live from the taste profile
      // (`computeTop50(intel.playCounts, …)`, playlist_page.dart:1105). So the
      // only count that cannot disagree with what the user sees is the same
      // derivation. It is cheap — a bounded sort over capped metadata, taking 50.
      'My Top 50': '${_top50Length()} songs',
    };

    var changed = false;
    final newAllItems = state.allItems.map((item) {
      final sub = wanted[item.title];
      if (sub == null) return item;
      // Same prefix rule as _updateSystemFolder. See the note there for why the
      // set is named explicitly rather than derived from the category.
      final full = _kPlaylistLikeFolders.contains(item.title)
          ? 'Playlist • $sub'
          : 'Folder • $sub';
      if (item.subtitle == full) return item;
      changed = true;
      return LibraryItem(
        title: item.title,
        subtitle: full,
        image: item.image,
        isPinned: item.isPinned,
        category: item.category,
        dateAdded: item.dateAdded,
        isSystemFolder: true,
        isCircle: item.isCircle,
        songCount: int.tryParse(sub.split(' ').first) ?? 0,
      );
    }).toList();

    // One state write for all five, and none at all when nothing moved — this
    // runs on load and after every collection change.
    if (!changed) return;
    state = state.copyWith(allItems: newAllItems);
    _applyFilterAndSort();
  }

  /// How many tracks My Top 50 actually has, derived exactly as the folder
  /// derives its content. Zero when the taste profile has not hydrated yet, and
  /// the next recompute (which every collection change triggers) corrects it.
  int _top50Length() {
    try {
      final intel = ref.read(intelligenceProvider);
      return computeTop50(
              intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps)
          .length;
    } catch (_) {
      // Reading another provider must never be what breaks a library update.
      return (state.playlistSongs['My Top 50'] ?? const <Song>[]).length;
    }
  }

  bool isSongInPlaylist(String playlistTitle, String songId) {
    final songs = state.playlistSongs[playlistTitle] ?? [];
    return songs.any((s) => s.id == songId);
  }

  /// How many duplicate tracks a playlist is carrying, without changing anything.
  ///
  /// Lets a menu offer the action only when there is something to do, and say how
  /// much — "Remove 14 duplicates" is a decision, "Remove duplicates" is a leap.
  int countDuplicatesInPlaylist(String playlistTitle) {
    final songs = state.playlistSongs[playlistTitle];
    if (songs == null || songs.length < 2) return 0;
    return songs.length - _dedupe(songs).length;
  }

  /// Drop repeated tracks from a playlist, keeping the FIRST of each.
  ///
  /// Matched on more than the ID, because the ID is NOT reliably the song.
  /// An import matches each title to a stream, and the same track can resolve to
  /// two different video ids across two attempts, which is exactly what the
  /// retry pass added when a first-round miss succeeded second time around. Those
  /// are duplicates to a person and distinct rows to an id comparison, so the
  /// visible signature (title + primary artist, normalised) is compared too.
  ///
  /// Keeping the FIRST occurrence preserves the order the user built, and the
  /// earliest copy is the one their queue history and play counts already refer
  /// to. Returns the number removed; 0 means nothing was touched and nothing was
  /// saved.
  int removeDuplicatesFromPlaylist(String playlistTitle) {
    final songs = state.playlistSongs[playlistTitle];
    if (songs == null || songs.length < 2) return 0;

    final deduped = _dedupe(songs);
    final removed = songs.length - deduped.length;
    if (removed == 0) return 0;

    final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);
    newPlaylistSongs[playlistTitle] = deduped;
    state = state.copyWith(playlistSongs: newPlaylistSongs);

    // NOT _updateSystemFolder — IT MARKS THE ROW AS A SYSTEM FOLDER.
    //
    // That function exists for the BUILT-IN folders and hardcodes
    // `isSystemFolder: true`. Calling it on a user playlist converted the
    // playlist into a system folder, and `deletePlaylist` refuses those
    // (`if (item.isSystemFolder) return false`), so cleaning up duplicates
    // silently took away delete, rename and every other customisation on that
    // playlist, and saved the damage to disk. Reported exactly that way.
    //
    // The row is updated directly instead, preserving what it actually is.
    final newAllItems = state.allItems.map((item) {
      if (item.title != playlistTitle) return item;
      return LibraryItem(
        title: item.title,
        subtitle: 'Playlist • ${deduped.length} songs',
        image: item.image,
        isPinned: item.isPinned,
        isCircle: item.isCircle,
        category: item.category,
        dateAdded: item.dateAdded,
        songCount: deduped.length,
        isSystemFolder: item.isSystemFolder,
      );
    }).toList();
    state = state.copyWith(allItems: newAllItems);
    _applyFilterAndSort();
    // userInitiated: this is an explicit action, so it must not be mistaken for
    // a background write and refused by the empty-save guard.
    _saveToDisk(userInitiated: true);
    print('playlist "$playlistTitle": removed $removed duplicate(s), '
        '${deduped.length} left');
    return removed;
  }

  /// First-wins dedupe on id OR visible signature. Pure, so both the count and
  /// the removal agree by construction rather than by two similar loops.
  static List<Song> _dedupe(List<Song> songs) {
    final seenIds = <String>{};
    final seenSigs = <String>{};
    final out = <Song>[];
    for (final s in songs) {
      final sig = '${s.title.toLowerCase().trim()}|'
          '${s.artist.split(',').first.toLowerCase().trim()}';
      final dupById = s.id.isNotEmpty && !seenIds.add(s.id);
      final dupBySig = !seenSigs.add(sig);
      if (dupById || dupBySig) continue;
      out.add(s);
    }
    return out;
  }

  /// Rebuilds the "My Top 50" system folder from intelligence data.
  /// Call this whenever play data changes (after recordPlay / trackInteraction).
  void refreshTop50(
    Map<String, int> playCounts,
    Map<String, Song> trackMetadata, [
    Map<String, int> firstPlayTimestamps = const {},
  ]) {
    // Ranked by real listen count via the SHARED computeTop50 — the exact same
    // function playlist_page.dart uses to render the list, so this folder's
    // song-count subtitle can never diverge from the tracks it opens to.
    final top50 = computeTop50(playCounts, trackMetadata, firstPlayTimestamps);

    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap['My Top 50'] = top50;

    final newAllItems = state.allItems.map((item) {
      if (item.title == 'My Top 50') {
        return LibraryItem(
          title: item.title,
          subtitle: 'Playlist • ${top50.length} songs',
          image: item.image,
          isPinned: item.isPinned,
          category: item.category,
          dateAdded: item.dateAdded,
          songCount: top50.length,
          isSystemFolder: true,
        );
      }
      return item;
    }).toList();

    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort();
  }

  // Filters and sorts the library items based on the active search query and category.
  /// Reused rather than allocated per call — this runs dozens of times a minute.
  final Stopwatch _filterSw = Stopwatch();

  /// Request a re-filter. COALESCED — a burst of calls does ONE pass.
  ///
  /// 19 CALL SITES, AND ONE USER ACTION HITS SEVERAL OF THEM.
  ///
  /// _updateSystemFolder ends with a filter pass of its own, so a single
  /// operation like liking an album ran the whole pipeline three or four times:
  /// once per folder count it touched, then again for the caller's own call.
  /// Measured on device as `Filtered items` six times inside one second and 38
  /// times across six IDLE minutes.
  ///
  /// Each pass is not free: it rebuilds the liked-title Set, filters allItems
  /// twice, allocates an orderIndex Map over every item, sorts, and publishes new
  /// state, which wakes every widget watching the library.
  ///
  /// Coalescing rather than deleting call sites, deliberately. Each of those 19
  /// exists because something genuinely changed and the list had to follow; the
  /// bug was never that they ask, it was that each ask did the work immediately.
  /// No caller reads `filteredItems` synchronously after asking (checked), and
  /// the only external readers are in build(), which Riverpod rebuilds on the
  /// state change regardless.
  ///
  /// A microtask was NOT enough, AND the log said so
  ///
  /// The first version of this coalesced with `scheduleMicrotask`, which collapses
  /// calls made in ONE event-loop turn. Measured again in the launch window:
  ///
  /// Filtered: 24 items, 8 folders …   ×7, identical every time
  ///      Cached folder synced: 162 …          ×4
  ///
  /// The startup burst is not that shape. The library load, the cached-folder
  /// sync, the downloads refresh and the system-folder updates are separated by
  /// `await`s, so each got its own microtask and its own full sort.
  ///
  /// One frame of debounce spans those gaps. 16ms is below what anyone can
  /// perceive, and the pass recomputes from state rather than accumulating, so
  /// collapsing N requests into one loses nothing. The count is reported, so the
  /// next reader can see how many collapsed instead of taking this on trust.
  void _applyFilterAndSort() {
    _filterDebounce?.cancel();
    _filterCoalesced++;
    _filterDebounce = Timer(const Duration(milliseconds: 16), () {
      _filterDebounce = null;
      // The notifier can be disposed inside the window (an account reset, a
      // provider rebuild), and assigning state after that throws.
      if (!mounted) return;
      final collapsed = _filterCoalesced;
      _filterCoalesced = 0;
      _applyFilterAndSortNow(collapsed: collapsed);
    });
  }

  Timer? _filterDebounce;
  int _filterCoalesced = 0;


  void _applyFilterAndSortNow({int collapsed = 1}) {
    _filterSw
      ..reset()
      ..start();
    // Liked things live in their folder, NOT also at the top level
    //
    // Liking an album puts it in `likedAlbums` AND inserts a LibraryItem into
    // `allItems` (see toggleAlbumLike), so it showed up twice: once loose in the
    // Library grid and once inside "Liked Albums". Same visible result for liked
    // playlists.
    //
    // Filtered HERE rather than by removing the insert, for two reasons:
    //  • it fixes libraries that already contain the duplicates, with no
    //    migration pass over the user's saved data — nothing is deleted, the
    //    entry simply stops being listed twice;
    //  • it holds no matter WHICH code path inserted the entry, so a future
    //    "add to library" route cannot quietly reintroduce the duplicate.
    //
    // System folders are never excluded — "Liked Albums" itself is one of them,
    // and hiding it would hide the very place these items now live.
    final likedTitles = <String>{
      ...state.likedAlbums.map((a) => a.title),
      ...state.likedPlaylists.map((p) => p.title),
    };
    bool isDuplicateOfLiked(LibraryItem i) =>
        !i.isSystemFolder && likedTitles.contains(i.title);

    List<LibraryItem> items;
    if (state.selectedCategory == LibraryCategory.all) {
      items = state.allItems.where((i) =>
        (i.category == LibraryCategory.folder ||
        i.category == LibraryCategory.playlist ||
        i.category == LibraryCategory.album ||
        i.isSystemFolder == true) && !isDuplicateOfLiked(i)
      ).toList();
    } else {
    // Other categories (playlist, album, etc.) use the standard filter
    items = state.allItems.where((i) =>
        i.category == state.selectedCategory && !isDuplicateOfLiked(i)).toList();
  }
    
    if (state.searchQuery.isNotEmpty) {
      items = items.where((i) => 
        i.title.toLowerCase().contains(state.searchQuery.toLowerCase()) || 
        i.subtitle.toLowerCase().contains(state.searchQuery.toLowerCase())
      ).toList();
    }
    
    // Pre-index allItems once (O(n)) so the comparator is O(1) instead of
    // calling indexOf() per comparison — that was O(n²·log n) and froze the UI
    // for ~500ms on large libraries during every search/filter.
    final orderIndex = <LibraryItem, int>{};
    for (var i = 0; i < state.allItems.length; i++) {
      orderIndex[state.allItems[i]] = i;
    }
    items.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return (orderIndex[a] ?? 0).compareTo(orderIndex[b] ?? 0);
    });
    
    state = state.copyWith(filteredItems: items);
    StallWatchdog.note('library.filterSort', _filterSw.elapsedMilliseconds);
    // One line, not three. Each print() is a synchronous platform-log write, and
    // this ran on every pass, so the old three-line report cost 3 writes per
    // pass and made the churn look even worse in the log than it was. The two
    // booleans were only ever read together with the counts anyway.
    final folderCount = items
        .where((i) => i.category == LibraryCategory.folder || i.isSystemFolder)
        .length;
    print("Filtered: ${items.length} items, $folderCount folders"
        "${collapsed > 1 ? ' — $collapsed requests collapsed into this one' : ''}"
        " (cached=${items.any((i) => i.title == 'Cached')},"
        " downloads=${items.any((i) => i.title == 'Downloads')})");
  }
}

// Provider for accessing the library state and logic.
final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>((ref) {
  return LibraryNotifier(ref);
});
/// #18/#21 — counters for the one-shot dead-cover heal at library load.
///
/// One summary line per load rather than one per row: the heal walks the whole
/// library, and a per-row log buries the count that actually matters. Visible on
/// a release build only with `--dart-define=AUVY_DEBUG_LOG=true`, like every
/// other `print` — main.dart's zone swallows them all otherwise.
class _ImageHealStats {
  int dead = 0;    // stored images that were device paths with no file behind them
  int healed = 0;  // re-pointed at a live local cover or the network URL
  int blanked = 0; // nothing recoverable → cleared so the UI shows a placeholder

  void report() {
    if (dead == 0) {
      print('cover-heal: nothing dead — all stored images are URLs, assets, '
          'or live files (#18/#21 not reproducing on this install)');
      return;
    }
    print('cover-heal: $dead dead local image path(s) in the restored '
        'library → $healed re-pointed, $blanked blanked. '
        '(#18 root cause CONFIRMED: local cover paths were persisted + uploaded.)');
  }
}

/// Reports foreground/background to [LibraryNotifier].
///
/// A tiny dedicated observer rather than making the notifier itself one: a
/// StateNotifier is not a widget, and giving it a mixin whose lifetime it does
/// not control is how an observer outlives its owner.
///
/// Public only so a test can drive it: the pause-collapsing below is the kind
/// of rule that regresses silently, because a second flush looks like nothing
/// at all from the outside.
@visibleForTesting
class LibraryLifecycleHook extends WidgetsBindingObserver {
  final VoidCallback onResume;
  final VoidCallback onPause;

  LibraryLifecycleHook({required this.onResume, required this.onPause});

  /// LEAVING IS SEVERAL EVENTS, NOT ONE — AND EACH ONE COST A CLOUD PUSH.
  ///
  /// THE BUG THIS FIXES, from the 2026-08-30 transcript. Android delivers
  /// `hidden` and then `paused` when the app goes to the background (and can
  /// add `detached` on the way out). All three mapped to onPause, so every
  /// backgrounding ran the flush twice — visible as pairs of identical lines a
  /// millisecond apart:
  ///
  ///   12:21:41.684  flushing unpushed changes (app backgrounded)
  ///   12:21:41.684  flushing unpushed changes (app backgrounded)
  ///
  /// Each one is a Firestore round trip, and the second could only ever find
  /// nothing left to send: 22 of the day's 97 pushes uploaded no blobs at all.
  ///
  /// The transition is what matters, not the individual event, so the group is
  /// collapsed into the first of its kind and re-armed on the way back in.
  bool _backgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      onResume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      if (_backgrounded) return;
      _backgrounded = true;
      onPause();
    }
  }
}

/// What an import actually added — reported to the user instead of a bare
/// "restored". A restore that says nothing about what it did is the reason the
/// cloud restore could return an empty library unnoticed.
class ImportSummary {
  final int likedSongs;
  final int playlists;
  final int playlistTracks;
  final int albums;
  const ImportSummary(
      this.likedSongs, this.playlists, this.playlistTracks, this.albums);

  bool get isEmpty =>
      likedSongs == 0 && playlists == 0 && playlistTracks == 0 && albums == 0;
}
