import 'dart:convert';
import 'package:auvy/services/event_log.dart';
import 'dart:async';
import 'dart:io' show File;
import 'package:auvy/services/http_pool.dart';
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
import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/providers/keep_fresh_provider.dart';
import 'package:auvy/providers/whats_new_provider.dart';
import 'package:auvy/providers/audiobook_provider.dart';
import 'package:auvy/logic/stall_watchdog.dart';
import 'package:auvy/providers/recent_playlists_provider.dart'
    show recentPlaylistsProvider;
import 'package:auvy/providers/intelligence_provider.dart'
    show computeTop50, intelligenceProvider;
import 'package:auvy/services/audio_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/set_log.dart';
import 'package:auvy/providers/download_provider.dart';
import 'package:auvy/core/utils/container_path_resolver.dart';

// Defines sorting options for library items.
/// How the library list is sorted.

enum SortOption { dateAdded, name, songCount }

// State container for all library-related data and UI preferences.
/// What an import actually did, so the UI never reports a count for an import
/// that wrote nothing (e.g. one refused because the name was taken).
enum LinkImportOutcome {
  /// A new playlist was created.
  created,

  /// A playlist of that name already existed and its tracks were replaced.
  replaced,

  /// A playlist of that name already existed and was left alone, because the
  /// incoming list was materially smaller. Nothing was written.
  keptExisting,

  /// The link resolved but nothing could be matched to a stream.
  nothingMatched,

  /// The link could not be read at all — private, malformed, or a dead network.
  failed,
}

/// The result of one link import: what happened, and the numbers behind it.
typedef LinkImportResult = ({
  LinkImportOutcome outcome,
  /// Tracks in the playlist afterwards.
  int tracks,
  /// What the existing playlist held, for the outcomes where that matters.
  int existing,
});

/// A link import that is currently running. Kept in library state, not the
/// dialog, because matching hundreds of tracks takes minutes and continues after
/// the sheet is dismissed; reopening it shows the progress.
///
/// [total] is 0 while the track list is still being fetched from Spotify (a real
/// phase of several seconds for long playlists), so treat 0 as "working, count
/// unknown", not "nothing to do".
class LinkImportProgress {
  /// The playlist being built, once its name is known. Empty while resolving.
  final String name;

  /// Tracks matched so far, and how many there are in total.
  final int done;
  final int total;

  const LinkImportProgress({
    this.name = '',
    this.done = 0,
    this.total = 0,
  });

  /// True while the track list is still being fetched and there is no
  /// denominator yet — the point at which a progress bar must stay
  /// indeterminate rather than claim 0%.
  bool get isCounting => total <= 0;

  /// 0.0-1.0, or null when there is nothing meaningful to show yet.
  double? get fraction =>
      total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  @override
  String toString() => 'LinkImportProgress($name $done/$total)';
}

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

  /// The link import in flight, or null when none is. See [LinkImportProgress].
  final LinkImportProgress? linkImport;

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
    this.linkImport,
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
    LinkImportProgress? linkImport,
    /// Explicit, because a null [linkImport] is a REAL value here — "the
    /// import finished" — and copyWith cannot tell that apart from "leave it
    /// alone" without being told.
    bool clearLinkImport = false,
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
      downloadProgressMap: downloadProgressMap ?? this.downloadProgressMap,
      linkImport: clearLinkImport ? null : (linkImport ?? this.linkImport),
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

/// The user's library: liked songs, playlists, albums, artists and downloads.
///
/// Saving is the dangerous part. This is the one thing in the app that can't be
/// re-fetched, and a save that raced the load once wrote an empty library to
/// disk and then to the cloud. The save path therefore snapshots before
/// writing, refuses to write before the library has loaded (or after a failed
/// load, or during an account reset), excludes derived folders, and skips
/// identical saves. Read the notes on the save path before changing it.
///
/// Lifecycle goes through [LibraryLifecycleHook] rather than raw
/// AppLifecycleState, so the several events Android sends when backgrounding
/// count as one.
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

    // Safety-net polling only, every 15 minutes: `cacheManager.onCacheUpdated`
    // already fires on every cache/download change, so this only catches files a
    // file manager copied into Music/Auvy. Each tick is two recursive directory
    // scans, so it only runs while the app is in front (the resume hook covers
    // changes made while away). The podcast refresh below has its own 12-hour check.
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
          _checkFreshPlaylists();
        }
      },
      onPause: () {
        _appInForeground = false;
        // The last moment this device is sure to get. Issuing the cloud push here is
        // enough even if the process dies right after: Firestore persists pending writes
        // and replays them on the next launch or reconnect. Order matters: the library's
        // own deferred save first (see flushPendingLibrarySave), then the taste/history
        // save to disk, then the push, so the upload includes the last few seconds.
        flushPendingLibrarySave()
            .then((_) =>
                ref.read(intelligenceProvider.notifier).flushPendingSave())
            .whenComplete(() => CloudSyncService.instance
                .flushPendingNow(reason: 'app backgrounded'));
      },
    );
    WidgetsBinding.instance.addObserver(_lifecycleHook!);

    // A cross-device merge has to reach live state, not just disk: these sets live
    // in memory here and _saveToDisk writes memory back over the file, so writing
    // prefs directly would be undone by the next like.
    CloudSyncService.onLibrarySetsMerged = applyMergedSets;

    ref.listen<Map<String, String>>(artworkOverrideProvider, (prev, next) {
      if (next.isNotEmpty) {
        _reconcileCustomCovers(persist: true);
      }
    });

    // Cancel the timers when the provider is destroyed.
    ref.onDispose(() {
      _refreshTimer?.cancel();
      _cacheEventDebounce?.cancel();
      _filterDebounce?.cancel();
      // A deferred order change must not die with the notifier. Not awaited —
      // dispose cannot be async — but issuing the write here is the last
      // chance it gets, and prefs persists a write in flight.
      flushPendingLibrarySave();
      if (_lifecycleHook != null) {
        WidgetsBinding.instance.removeObserver(_lifecycleHook!);
        _lifecycleHook = null;
      }
      // Leaving a closure over a disposed notifier here would have the next
      // merge call into dead state.
      if (CloudSyncService.onLibrarySetsMerged == applyMergedSets) {
        CloudSyncService.onLibrarySetsMerged = null;
      }
    });
  }

  // Loads saved library data from local storage on startup.
  Future<void> _init() async {
    final cacheManager = AudioCacheManager();
    await cacheManager.initialize();
    await ContainerPathResolver.ensureInitialized();
    try {
      await ref
          .read(artworkOverrideProvider.notifier)
          .initialized
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    
    // Refresh when the cache changes (the main trigger for folder updates),
    // debounced by 300 ms: the cache fires one event per track, so a queue top-up or
    // scan produces a burst, and each event would otherwise recount every folder,
    // re-sort the library and save it.
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

    // The saved library is read first; don't move the scan back above it. The scan
    // isn't awaited, and finding anything triggers a library save; started earlier,
    // that save could write the empty startup state over the stored library (and
    // then back it up). Now the worst a cache callback can do is save what was just
    // loaded; `_loaded` below is a second safeguard.
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

        // Migration: "Your Artists" → "Followed Artists". The folder title is saved and
        // is the row's identity (used by `_updateSystemFolder`, `_getThemedIcon` and the
        // tap handler), so it's renamed in place, keeping the row's pin state and date
        // added, instead of adding a second row.
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
        
        // One bad row must not cost the whole library: each entry is parsed separately,
        // so an unreadable one (from an older build, or truncated) is skipped and the
        // rest load.
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
        
        // DIAGNOSE + HEAL dead cover paths (see _healSong / _healItem).
        final stats = _ImageHealStats();
        final healedLikedSongs = likedSongs.map((s) => _healSong(s, stats)).toList();
        final healedItems = allItems.map((i) => _healItem(i, stats)).toList();
        final healedPlaylistSongs = <String, List<Song>>{};
        playlistSongs.forEach((k, v) {
          healedPlaylistSongs[k] = v.map((s) => _healSong(s, stats)).toList();
        });
        stats.report();

        // Repair: a user playlist wrongly marked as a system folder. `isSystemFolder`
        // gates delete and edit and is saved, so a mistaken flag removes those
        // permanently. The built-in folders are a known, closed set, so any other row
        // claiming to be one is fixed on load.
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
          // Written back, not just patched in memory, so the repair reaches disk and the
          // cloud backup. Scheduled after this load completes, because _saveToDisk refuses
          // to write until `_loaded` is set below.
          _pendingRepairSave = true;
        }

        // Orphaned playlists: a playlist is stored in two places (tracks in
        // `playlistSongs[name]`, the visible row in `allItems`), which are also separate
        // cloud blobs, so a restore can bring one without the other. A row is rebuilt
        // for any playlist with tracks but no row; the name and track list are all a row
        // needs. Matched on title, which is how `playlistSongs` is keyed.
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
        _drainPendingMergedSets();
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
        try {
          final liveTitles = state.allItems.map((i) => i.title).toSet();
          ref.read(recentPlaylistsProvider.notifier).pruneMissing(liveTitles);
        } catch (_) {}
      } catch (e) {
        // A failed load must not lead to a save. If parsing throws partway, `state` is
        // empty or partial, and any later save would overwrite the good data on disk and
        // back up the empty copy. Latching this makes the failure inert: nothing
        // overwrites what's on disk, so the next launch (or a fix) can still read it.
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
      _drainPendingMergedSets();
    }

    _reconcileCustomCovers();
    // Delayed so the first refresh doesn't compete with start-up work.
    Future.delayed(const Duration(seconds: 20), _checkFreshPlaylists);
    refreshCachedFolder();
    refreshDownloadsFolder();
    _applyFilterAndSort();
    _refreshAllPodcasts();

    // Recognise audio the user dropped into the Auvy folder by hand. Started
    // only now: it fires onCacheUpdated, which saves. See the note above the
    // prefs read for why that must not race the load.
    cacheManager.scanAndImportDownloads();
  }

  // Dead cover paths after a cloud restore. A disk-imported track without a network
  // cover can have a device-local path in `Song.image`, which gets saved and backed
  // up; after a reinstall that file is gone. The `.auvyid` sidecar prevents this for
  // newer downloads; this heals older data once, on load: point at a live local
  // cover if the disk scan made one, else the network URL the cache index knows,
  // else blank it so the UI shows a placeholder.

  /// True for a value that is a device path (not a network URL, not a bundled
  /// asset) which no longer exists on disk (even after container rebasing).
  bool _isDeadLocalImage(String image) {
    if (image.isEmpty) return false;
    if (image.startsWith('http')) return false;
    if (image.startsWith('assets/')) return false;
    try {
      if (File(image).existsSync()) return false;
      final rebased = ContainerPathResolver.rebaseIfNeeded(image);
      return !File(rebased).existsSync();
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
    final rebased = ContainerPathResolver.rebaseIfNeeded(s.image);
    if (rebased != s.image && File(rebased).existsSync()) {
      stats.healed++;
      return s.copyWith(image: rebased);
    }
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
    final rebased = ContainerPathResolver.rebaseIfNeeded(i.image);
    if (rebased != i.image && File(rebased).existsSync()) {
      stats.healed++;
      return LibraryItem(
        title: i.title,
        subtitle: i.subtitle,
        image: rebased,
        isPinned: i.isPinned,
        isCircle: i.isCircle,
        category: i.category,
        dateAdded: i.dateAdded,
        songCount: i.songCount,
        isSystemFolder: i.isSystemFolder,
      );
    }
    if (!_isDeadLocalImage(i.image)) return i;
    stats.dead++;
    // A playlist's dead cover can be recovered: manually set playlist covers are
    // stored under `playlist:<title>` in ArtworkOverrideNotifier as bytes (which are
    // backed up), so re-point at the rebuilt file instead of blanking it.
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
    
    // Keyed by title because that is what likedPlaylists is keyed by;
    // using a different key here would make the log and the set disagree.
    SetLog.instance.record(SetLog.playlists, item.title, member: !isLiked);
    state = state.copyWith(likedPlaylists: newLiked);
    _updateSystemFolder("Liked Playlists", "${newLiked.length} Playlists", null);
    _saveToDisk();
  }


  /// Resolves stream URLs for [tracks] with progress, returning what can be fetched
  /// and what couldn't be resolved. Resolved six at a time (through the shared
  /// RateLimiter) so region-blocked tracks don't stall a bulk download for minutes
  /// before anything is written. Order is preserved; callers pair failures back to
  /// tracks by index.
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
          // preferMp4, so album downloads can carry tags and cover art (WebM can't, and
          // Android's media scanner won't index it), as single downloads already do.
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
    int failedCount = 0;
    try {
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
      failedCount = totalFailed.length;
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
    } catch (e, st) {
      print("Error in downloadFullPlaylist for '${playlistItem.title}': $e\n$st");
      failedCount = tracks.length;
    } finally {
      // The banner is dismissed here and nowhere else, reporting the failure count, so
      // a run that ends early never leaves it on screen.
      dl.finishDownload(failed: failedCount);

      // Cleanup progress after this attempt
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          final finalMap = Map<String, double>.from(state.downloadProgressMap);
          finalMap.remove(playlistItem.title);
          state = state.copyWith(downloadProgressMap: finalMap);
        }
      });
    }
  }

  /// Matches "Title Artist" queries to real streams. Shared by pasted Spotify links
  /// and Spotify data exports, so both use the same matcher (its overlap scoring is
  /// what keeps karaoke, live and tribute versions out). Returns the matched songs
  /// and how many queries matched nothing, so a partial import is reported as such.
  Future<({List<Song> songs, int missing})> resolveQueriesToSongs(
      List<String> searchQueries, dynamic searchService,
      {void Function(int done, int total)? onProgress}) async {
    // Chunks of 10 with no artificial delay (the InnerTube RateLimiter already paces
    // requests). Each search has a timeout that allows for rate-limiter queueing.
    // Failed lookups are retried once at the end.
    List<Song> matchedSongs = [];

    Future<Song?> matchQuery(String query,
        {Duration timeout = const Duration(seconds: 8)}) async {
      try {
        final results = await searchService.search(query, 'track').timeout(timeout);
        if (results.isNotEmpty) {
          // Best overlap, not the first hit: the query is "<title> <artist>", so pick the
          // result whose title+artist covers most of those words (search order is
          // popularity, which often puts a remix or live version first). If the top hit is
          // the best overlap it still wins; nothing is dropped for failing to match.
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
    // Retry every miss, in chunks like the first pass, so large imports don't
    // silently drop tracks.
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

  /// How much smaller an incoming list may be before a re-import refuses to
  /// overwrite the playlist it shares a name with. A guard, not a correctness test:
  /// a count can't tell "same playlist re-imported" from "different playlist with
  /// the same name", so it only blocks the destructive case (a large curated list
  /// replaced by a much smaller one).
  static const double _kReimportKeepRatio = 0.9;

  Future<LinkImportResult> importPlaylistFromUrl(
      String inputUrl, dynamic searchService) async {
    // Published from the start, including the phase with no total yet (fetching a
    // long Spotify list), so a slow import can be told from a stuck one, even after
    // the sheet is closed. See [LinkImportProgress].
    state = state.copyWith(linkImport: const LinkImportProgress());
    try {
      // 1. YouTube playlists.
      if (inputUrl.contains('youtube.com') || inputUrl.contains('youtu.be')) {
        final uri = Uri.parse(inputUrl);
        final playlistId = uri.queryParameters['list'];
        if (playlistId == null) throw 'Invalid YouTube Link. Must contain a playlist ID.';
        
        final ytTracks = await searchService.getPlaylistTracks(playlistId);
        if (ytTracks.isEmpty) throw 'No tracks found in this YouTube playlist. Is it private?';
        
        const ytName = 'YouTube Import';
        final playlistSong = Song(id: 'yt_$playlistId', title: ytName, artist: 'YouTube', image: ytTracks.first.image);
        // Refused on the name means nothing was written, and the caller has to
        // be able to say so rather than report the fetched count as imported.
        final made = savePlaylistFromSearch(playlistSong, ytTracks);
        // Explicit ints: searchService is `dynamic`, so `ytTracks.length` is
        // too, and a dynamic field quietly makes the whole record's type wrong.
        final int fetched = ytTracks.length as int;
        final int held = state.playlistSongs[ytName]?.length ?? 0;
        return (
          outcome:
              made ? LinkImportOutcome.created : LinkImportOutcome.keptExisting,
          tracks: made ? fetched : held,
          existing: made ? 0 : held,
        );
      }

      // 2. Spotify links, keyless: the user pastes a public link and the track list is
      // read without an API key or client secret. The credentialed API is only a
      // fallback if keys happen to be configured.
      final regex = RegExp(r'(playlist|album|track)\/([a-zA-Z0-9]+)');
      final match = regex.firstMatch(inputUrl);
      if (match == null) throw 'Invalid Link. Please paste a valid Spotify or YouTube Playlist URL.';

      final type = match.group(1)!;
      final id = match.group(2)!;

      List<String> searchQueries = [];
      String collectionName = 'Spotify Import';
      String coverImage = '';

      // Primary: Spotify's Web API with the anonymous access token the web player uses
      // (no client secret). It's the only keyless path that pages through the full
      // playlist/album; the embed page below returns a truncated preview (~30–100
      // tracks).
      final api = await _spotifyApiTracks(type, id);
      if (api.name.isNotEmpty) collectionName = api.name;
      if (api.cover.isNotEmpty) coverImage = api.cover;
      searchQueries = api.queries;

      // Fallback 1: scrape the embed page (preview only) if the API path returned
      // nothing.
      if (searchQueries.isEmpty) {
        final embed = await _spotifyEmbedTracks(type, id);
        if (embed.name.isNotEmpty) collectionName = embed.name;
        if (embed.cover.isNotEmpty) coverImage = embed.cover;
        searchQueries = embed.queries;
        // Log which source won and how many tracks it found; the two differ by an order
        // of magnitude in completeness.
        print('Spotify: API path returned nothing — embed fallback gave '
            '${searchQueries.length} track(s) (a preview, NOT the full list)');
      }

      // Fallback 2: the credentialed Spotify API, only if keys are present (normally
      // they aren't).
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

      // Matching lives in [resolveQueriesToSongs] so pasted links and data exports use
      // the same matcher.
      final resolved = await resolveQueriesToSongs(
        searchQueries,
        searchService,
        // The denominator finally exists, so the bar can stop guessing. The
        // name comes along because by the time this is the only thing on
        // screen, "142 of 888" without saying WHICH playlist is half an answer.
        onProgress: (done, total) => state = state.copyWith(
          linkImport: LinkImportProgress(
            name: collectionName,
            done: done,
            total: total,
          ),
        ),
      );
      final matchedSongs = resolved.songs;
      if (resolved.missing > 0) {
        // Said out loud: a partial import must never look like a complete one.
        print('WARN: Spotify import: ${resolved.missing} of ${searchQueries.length} '
            'track(s) could not be matched to a stream');
      }

      if (matchedSongs.isNotEmpty) {
        final playlistSong = Song(id: 'spotify_$id', title: collectionName, artist: 'Spotify Import', image: coverImage);
        // A re-import must be able to complete a short one. savePlaylistFromSearch
        // refuses an existing title, so pasting the link again (the way to fix a
        // truncated import) would do nothing. Replace the existing playlist unless the new
        // list is materially smaller ([_kReimportKeepRatio]); a strict "only if longer"
        // rule would block refreshing a playlist that gained a track.
        if (!savePlaylistFromSearch(playlistSong, matchedSongs)) {
          final existing = state.playlistSongs[collectionName] ?? const <Song>[];
          final materiallySmaller =
              matchedSongs.length < existing.length * _kReimportKeepRatio;
          if (materiallySmaller) {
            print('WARN: Spotify import: "$collectionName" already holds '
                '${existing.length} track(s) and this import matched only '
                '${matchedSongs.length} — kept the existing one, wrote nothing');
            return (
              outcome: LinkImportOutcome.keptExisting,
              tracks: existing.length,
              existing: existing.length,
            );
          }
          replacePlaylistSongs(collectionName, matchedSongs);
          print('Spotify import: "$collectionName" already existed with '
              '${existing.length} track(s) — replaced with ${matchedSongs.length}');
          return (
            outcome: LinkImportOutcome.replaced,
            tracks: matchedSongs.length,
            existing: existing.length,
          );
        }
        return (
          outcome: LinkImportOutcome.created,
          tracks: matchedSongs.length,
          existing: 0,
        );
      }

      // Queries resolved but nothing matched a stream. Not a success with zero
      // tracks — a failure, and the caller must be able to tell them apart.
      return (
        outcome: LinkImportOutcome.nothingMatched,
        tracks: 0,
        existing: 0,
      );
    } catch (e, st) {
      // Never re-throw: a bad or private link, a changed page format, a network error
      // or a type cast must not become an uncaught exception. Report a 0-track result
      // and let the caller show a friendly message.
      print('ERROR: Link Import Error: $e\n$st');
      return (outcome: LinkImportOutcome.failed, tracks: 0, existing: 0);
    } finally {
      // FINALLY, so no exit can leave a progress bar running forever. There are
      // five ways out of the try above — three returns, a throw and the error
      // path — and clearing it at each of them is how one gets missed. A
      // spinner that never stops is worse than no spinner: it says the app is
      // working when it has given up.
      state = state.copyWith(clearLinkImport: true);
    }
  }

  /// Pulls a session access token out of the embed page's `__NEXT_DATA__`: a fallback
  /// token source for [_spotifyApiTracks]. Returns '' when there isn't one; the caller
  /// then falls back to the truncated embed track list.
  Future<String> _spotifyTokenFromEmbed(String type, String id) async {
    try {
      final resp = await HttpPool().getClient().get(
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

  /// How many times a throttled tracks page is waited out before giving up. A 429
  /// means wait, not stop: the paginating path is the only one that returns the whole
  /// playlist, and the anonymous endpoint throttles readily but briefly. Giving up on
  /// the first 429 would fall back to the truncated preview. Bounded (with
  /// [_kSpotifyMaxThrottleSeconds]) so a hard throttle can't hang the import.
  static const int _kSpotifyMaxThrottleWaits = 3;

  /// The longest single wait this import will hold for. It decides whether to wait,
  /// not how long: retrying before Retry-After has passed just fails again, so
  /// Spotify's value is honoured up to this ceiling, and anything longer ends
  /// pagination and falls back.
  static const int _kSpotifyMaxThrottleSeconds = 20;

  /// Keyless full-list Spotify import: gets the anonymous access token the web
  /// player uses (no client secret) and pages the public Web API through the
  /// whole playlist/album. Returns the name, cover URL and "Title Artist"
  /// queries, or empty on failure so the caller falls back to the embed preview.
  /// Public content only.
  Future<({String name, String cover, List<String> queries})> _spotifyApiTracks(
      String type, String id) async {
    const ua =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    try {
      // 1. Anonymous access token (same endpoint the web player/embeds call).
      final tokenResp = await HttpPool().getClient().get(
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

      // A second token source: if the dedicated token endpoint moves or is blocked,
      // every large import would silently become a preview. The embed page must be
      // reachable for the fallback anyway, and it carries a session token of its own.
      // Searched recursively, since the JSON shape moves but the key name doesn't.
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
        final r = await HttpPool().getClient().get(Uri.parse('https://api.spotify.com/v1/tracks/$id'), headers: auth)
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
        final meta = await HttpPool().getClient().get(Uri.parse(metaUrl), headers: auth)
            .timeout(const Duration(seconds: 10));
        // How many tracks there are supposed to be, from metadata already fetched for
        // the name and cover, so a short import can be recognised.
        int expectedTotal = 0;
        if (meta.statusCode == 200) {
          final mj = jsonDecode(meta.body);
          name = (mj['name'] ?? '').toString();
          cover = coverFrom(mj['images']);
          final t = type == 'album' ? mj['total_tracks'] : mj['tracks']?['total'];
          expectedTotal = int.tryParse('${t ?? 0}') ?? 0;
        }
        // Album tracks cap at 50/page, playlist at 100/page. Follow `next`.
        final pageLimit = type == 'album' ? 50 : 100;
        String? next = 'https://api.spotify.com/v1/${type}s/$id/tracks?limit=$pageLimit&offset=0';
        int guard = 0;
        int throttleWaits = 0;
        while (next != null && guard < 50) {
          guard++;
          final tr = await HttpPool().getClient().get(Uri.parse(next), headers: auth)
              .timeout(const Duration(seconds: 12));

          // Throttled isn't failed (see [_kSpotifyMaxThrottleWaits]). Spotify's Retry-After
          // is preferred; doubling covers responses without it. Both are bounded.
          if (tr.statusCode == 429 && throttleWaits < _kSpotifyMaxThrottleWaits) {
            final headerSecs = int.tryParse(
                (tr.headers['retry-after'] ?? '').trim());
            // Retrying earlier than Retry-After asks can't succeed, so the ceiling decides
            // whether to wait at all: inside it, honour Spotify's value; beyond it, stop and
            // fall back.
            if (headerSecs != null && headerSecs > _kSpotifyMaxThrottleSeconds) {
              print('WARN: Spotify API: throttled on page $guard and asked to '
                  'wait ${headerSecs}s — longer than the '
                  '${_kSpotifyMaxThrottleSeconds}s this import will hold for, '
                  'so falling back rather than retrying early');
              break;
            }
            throttleWaits++;
            // No header: back off by doubling. Seen in the wild, and the reason
            // the fallback is not a flat delay.
            final waitSecs =
                (headerSecs ?? (1 << (throttleWaits - 1))).clamp(1, _kSpotifyMaxThrottleSeconds);
            // Log the Retry-After value too, so "asked for 2 s" can be told from "asked for
            // 60 s".
            print('Spotify API: throttled on page $guard — Retry-After '
                '${headerSecs ?? "absent"}, waiting ${waitSecs}s '
                '($throttleWaits/$_kSpotifyMaxThrottleWaits)');
            await Future.delayed(Duration(seconds: waitSecs));
            // This attempt fetched nothing, so it must not consume one of the
            // fifty pages. The retry budget is what bounds the loop here, and
            // it only ever counts up.
            guard--;
            continue;
          }
          // Log the status code before giving up: 401/403 means the token isn't accepted,
          // 404 means the playlist id didn't resolve, 429 means throttled. Otherwise a
          // failure falls through to the truncated preview silently.
          if (tr.statusCode != 200) {
            print('WARN: Spotify API: tracks page returned ${tr.statusCode} '
                'after $guard page(s)'
                '${throttleWaits > 0 ? " and $throttleWaits throttle wait(s)" : ""}'
                ' — falling back to the truncated embed list, so this import '
                'may be short');
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
        // Report the count against the real total, so a short import is obvious.
        if (expectedTotal > 0 && queries.length < expectedTotal) {
          print('WARN: Spotify import came up SHORT — ${queries.length} of '
              '$expectedTotal track(s) for $type/$id. The missing ones are a '
              'failed fetch, not a limit Auvy imposes.');
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

  /// Keyless Spotify import from the open.spotify.com embed page's `__NEXT_DATA__`
  /// JSON for a public playlist/album/track. Returns the collection name, a cover URL
  /// and "Title Artist" search queries (matched to YouTube streams by the caller).
  /// Locates the track list recursively in case the JSON shape moves.
  Future<({String name, String cover, List<String> queries})> _spotifyEmbedTracks(
      String type, String id) async {
    try {
      final resp = await HttpPool().getClient().get(
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

  /// Recursively finds the first List stored under [key] anywhere in a decoded JSON
  /// tree (used to locate Spotify's track list).
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
    int failedCount = 0;
    try {
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
      failedCount = totalFailed.length;
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

      // tracks minus what is still outstanding — already-cached tracks are on
      // disk too, so counting up from `batch` would under-report them.
      print('album attempt complete: "${album.title}" — '
          '${tracks.length - totalFailed.length}/${tracks.length} on disk, '
          '${totalFailed.length} outstanding');
    } catch (e, st) {
      print("Error in downloadAlbumAsPlaylist for '${album.title}': $e\n$st");
      failedCount = tracks.length;
    } finally {
      // The banner is dismissed here and nowhere else (see downloadFullPlaylist).
      dl.finishDownload(failed: failedCount);

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          final finalMap = Map<String, double>.from(state.downloadProgressMap);
          finalMap.remove(album.title);
          state = state.copyWith(downloadProgressMap: finalMap);
        }
      });
    }
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
    // Not the debounced pass: the list renders `filteredItems`, and a debounced
    // update would show the old order for a frame after the drop. A drag is a single
    // change whose result must appear in the same frame.
    _applyFilterAndSortNowCancellingDebounce();
    // Deferred save: a reorder only changes order, but a save re-encodes the whole
    // library on the main isolate, which would stutter the drop, and drags come in
    // bursts. Coalesced into one write after the gesture settles; every exit flushes
    // it (see [flushPendingLibrarySave], called by the lifecycle hook and dispose).
    _saveToDiskSoon();
  }

  Timer? _deferredSave;

  /// Coalesce a burst of order changes into one write.
  void _saveToDiskSoon() {
    _deferredSave?.cancel();
    _deferredSave = Timer(const Duration(milliseconds: 700), () {
      _deferredSave = null;
      _saveToDisk();
    });
  }

  /// Write a deferred save NOW, if one is waiting.
  ///
  /// Called from the lifecycle hook when the app is backgrounded and from
  /// dispose. Without both, the coalescing window becomes a window in which a
  /// reorder can be lost — which is the whole reason the save was immediate
  /// before.
  Future<void> flushPendingLibrarySave() async {
    if (_deferredSave == null) return;
    _deferredSave!.cancel();
    _deferredSave = null;
    await _saveToDisk();
  }

  void reorderDownloadedTracks(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final current = List<Song>.from(state.playlistSongs["Downloads"] ?? []);
    if (current.isEmpty) {
        // Fallback: If no custom order exists, get from CacheManager first
        current.addAll(AudioCacheManager().getDownloadedTracks());
    }
    if (oldIndex < 0 || oldIndex >= current.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= current.length) return;
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
    
    // Exclude songs that are marked as downloads.
    final downloadIds = cacheManager.getDownloadedTracks().map((s) => s.id).toSet();
    final filteredSongs = songs.where((s) => !downloadIds.contains(s.id)).toList();
    
    // Nothing changed means touch nothing: this runs once per auto-cached track, and
    // replacing state unconditionally rebuilds every library consumer and triggers a
    // full re-encode. A cache event isn't necessarily a change (re-touches, or an
    // eviction plus an add), so compare the rebuilt list first.
    final prev = state.playlistSongs["Cached"] ?? const <Song>[];
    if (_sameTracks(prev, filteredSongs)) return;

    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap["Cached"] = filteredSongs;
    state = state.copyWith(playlistSongs: newMap);
    
    _updateSystemFolder("Cached", "${filteredSongs.length} songs", null);
    
    print("Cached folder synced: ${filteredSongs.length} auto-cached items (excluding ${songs.length - filteredSongs.length} downloads)");
  }

  /// Whether a downloaded track may be left out of the Downloads folder. Every path
  /// keeps it except one: the track belongs to a collection whose name is present in
  /// the library, so it's reachable another way. New download kinds therefore default
  /// to visible, which is the safe direction (a duplicate listing is untidy; an
  /// unreachable file is lost).
  static bool _hiddenBecauseReachable(
    ({String kind, String name})? collection,
    Set<String> reachable,
  ) {
    if (collection == null) return false; // a loose single: Downloads is home
    return reachable.contains(collection.name.trim().toLowerCase());
  }

  /// Rebuilds the Downloads folder from what is actually downloaded on disk.
  /// Every explicit download is listed, except tracks whose album, playlist or
  /// show is reachable in the library (see [_hiddenBecauseReachable]).
  void refreshDownloadsFolder() {
    final cacheManager = AudioCacheManager();
    // A downloaded album belongs under its album, not as loose singles in Downloads.
    // The download type isn't in the cache index; the folder is the record
    // (Albums/<name>, Playlists/<name>, Podcasts/<show>, Singles; see
    // downloadCollectionOf). Tracks are only excluded when their collection is
    // actually reachable in the library; otherwise Downloads remains their home.
    //
    // Downloaded podcast episodes are grouped under their show: a show is a library
    // row whose subtitle starts 'Podcast • ' (see library_page), grouped by the
    // episode's `artist` (the show name, see PodcastEpisode.toSong) rather than the
    // sanitised folder name. The reachability rule then removes them from Downloads.
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

    // Both spellings of every title: a download's collection comes from its sanitised
    // folder name, while library titles aren't sanitised.
    final reachable = <String>{
      for (final i in state.allItems) i.title.trim().toLowerCase(),
      for (final i in state.allItems)
        AudioCacheManager.folderNameFor(i.title).trim().toLowerCase(),
      ...state.playlistSongs.keys.map((k) => k.trim().toLowerCase()),
      ...state.playlistSongs.keys
          .map((k) => AudioCacheManager.folderNameFor(k).trim().toLowerCase()),
    };
    // Only [_hiddenBecauseReachable] can hide a track, and it requires `reachable`:
    // no kind can be special-cased into invisibility without proving the user can
    // reach it elsewhere. (Hard-coding podcasts as hidden once made saved episodes
    // disappear, since the podcast page has no downloads view.)
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
    // Log podcast episodes that fell back to Downloads: they should be grouped under
    // their show, so a non-zero count means that grouping failed.
    final pods =
        explicitDownloads.where((s) => s.albumTitle == 'Podcast').length;
    if (pods > 0) {
      print('Downloads: $pods podcast episode(s) fell back to this list — '
          'their show did not become reachable, so check the grouping above');
    }

    // Preserve the user's custom order: walk `currentOrder` and take tracks from an
    // id map (O(N+M)), then append anything new at the end.
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
    // Only save when something actually changed. Downloads change rarely (a finished
    // download or a new file), and auto-caching isn't a change here. The podcast block
    // above can create rows, so the flag covers that too.
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
    final n = await AudioCacheManager().scanAndImportDownloads();
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

      print("Force refresh complete");
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

  /// A cross-device set merge that arrived before the library was in memory.
  /// Same shape as [_pendingRepairSave], for the same reason. See
  /// [applyMergedSets].
  Map<String, Map<String, ({bool member, int atMs})>>? _pendingMergedSets;

  /// Apply a set merge that had to wait for the load. Called from both
  /// `_loaded = true` sites — a merge held on a load that then FAILED would
  /// otherwise sit there forever.
  void _drainPendingMergedSets() {
    final held = _pendingMergedSets;
    if (held == null) return;
    _pendingMergedSets = null;
    applyMergedSets(held);
  }

  /// False until [_init] has loaded the stored library into `state`. `_init` is async
  /// and `state` starts empty, so a save in that window would write an empty library
  /// over the real one and back it up. `_loadFailed` covers a load that threw; this
  /// covers one that hasn't happened yet.
  bool _loaded = false;

  static const String _kLibraryKey = 'auvy_library_data';

  /// Mirror of the last save that contained real user content. See the fallback
  /// in [_init]. Listed in account_provider's `_userDataKeys` so an account
  /// switch clears it too — otherwise it would hand the next account the
  /// previous one's library.
  static const String _kLibraryBackupKey = 'auvy_library_data_last_good';

  /// Re-points playlists at their custom cover after the override files move. A
  /// custom cover is stored twice: the bytes in ArtworkOverrideNotifier (which survive
  /// reinstalls and sync) and the file path in `LibraryItem.image` for rendering.
  /// After a restore the path is dead, so the item follows the override map, the
  /// source of truth for a deliberately set cover.
  /// [persist] is false when the caller is about to save anyway.
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

  /// True from the start of an account wipe until the reload that follows it.
  /// `_wipeLocalUserData` clears prefs and reloads providers afterwards, so meanwhile
  /// this notifier still holds the outgoing account's library, and a save (e.g.
  /// triggered by wiping the audio cache) would write it back into the cleared prefs
  /// for the incoming account to inherit. While set, saves are refused.
  bool _accountResetting = false;

  /// A fingerprint of the last written blob, so an identical save is skipped.
  /// Cleared whenever the stored copy changes behind us (a cloud restore, an account
  /// reset), or the next needed save would be skipped.
  String? _lastSavedSig;

  /// The exact state object the last encode described. An identity test, sound only
  /// because nothing mutates state in place (every change goes through
  /// `state = state.copyWith`; a test enforces it). The byte comparison below stays
  /// as a backstop. Cleared alongside [_lastSavedSig].
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

  /// Saves the library to prefs (and schedules a backup). [userInitiated] false
  /// marks a save nobody asked for (a folder refresh, a cover heal, the periodic
  /// rescan); those may never be the reason a library becomes empty, so they get
  /// the extra check below. A real user action is always honoured.
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
    // The cheapest check first: state is replaced on every change and never edited in
    // place, so the same instance proves there's nothing to write, without encoding
    // the whole library. The snapshot is used throughout, since reading `state` again
    // after the await could describe a different object.
    final snapshot = state;
    if (identical(snapshot, _lastEncodedState)) return;

    final prefs = await SharedPreferences.getInstance();
    // The Cached folder's songs aren't saved: refreshCachedFolder rebuilds the list
    // from AudioCacheManager (the real source) right after every load, and it has no
    // user-chosen order. Saving it made the blob change every time a track was cached
    // or evicted. Only the written copy is trimmed; in-memory state is unchanged, and
    // libraryHasUserContent already ignores system rows.
    //
    // The three system rows are rebuilt by the loader (see the removeWhere above the
    // load), so their count subtitle and dateAdded are zeroed in the saved copy
    // rather than omitted, keeping the stored shape the same as earlier builds.
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

    // Timed with StallWatchdog: this is the heaviest synchronous work the library
    // does (jsonEncode of everything, then two whole-prefs rewrites), on the main
    // isolate.
    final encoded =
        StallWatchdog.time('library.jsonEncode', () => jsonEncode(data));
    StallWatchdog.note('library.blobKB', encoded.length ~/ 1024);

    // Compare a fingerprint (length + hash) of the encoded blob first, so a burst of
    // identical saves costs one write instead of two full prefs rewrites each.
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
    // Log the saved size.
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
    // Keep fresh's state is restored or wiped with the library, so it reloads
    // with it (a wipe must not leave the previous account's settings in memory).
    try {
      unawaited(ref.read(keepFreshProvider.notifier).reload());
    } catch (_) {}
    final loaded = _init();
    // What's New too, once the library is in: its background list names the
    // artists and podcasts this library follows.
    unawaited(loaded.then((_) {
      if (mounted) return ref.read(whatsNewProvider.notifier).reload();
    }).catchError((_) {}));
    // Saved audiobooks too (restored or wiped with the account).
    try {
      unawaited(ref.read(audiobookLibraryProvider.notifier).reload());
    } catch (_) {}
    return loaded;
  }

  // Adds or removes a song from the "Liked Songs" collection.
  // [restoreAt]: when re-adding via Undo, the song's original position — so
  // undo puts it back where it was instead of hoisting it to the top.
  void toggleSongLike(Song song, {int restoreAt = -1}) {
    final newSongs = List<Song>.from(state.likedSongs);
    final newIds = Set<String>.from(state.likedSongIds);
    final nowLiked = !newIds.contains(song.id);
    if (newIds.contains(song.id)) {
      newIds.remove(song.id);
      newSongs.removeWhere((s) => s.id == song.id);
    } else {
      newIds.add(song.id);
      final at = (restoreAt < 0 || restoreAt > newSongs.length) ? 0 : restoreAt;
      newSongs.insert(at, song);
    }
    // Record when, not just whether, so two devices can be reconciled: the newest
    // decision per track wins (see SetLog). An Undo is recorded too; it's the latest
    // decision.
    SetLog.instance.record(SetLog.songs, song.id, member: nowLiked);
    _updateSystemFolder("Liked Songs", "${newSongs.length} songs", null);
    state = state.copyWith(likedSongs: newSongs, likedSongIds: newIds);
    _saveToDisk();
  }

  /// Swaps refetched metadata for a track into every place the library stores it
  /// (Liked Songs and every playlist). The library keeps its own saved copy of each
  /// track, so fixing only the player's copy would revert on the next launch. Saves
  /// only when something changed.
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
    if (oldIndex == newIndex) return;
    final current = List<Song>.from(state.likedSongs);
    if (oldIndex < 0 || oldIndex >= current.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= current.length) return;
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

  // Removed from THIS playlist only, with the moment — so it is not put back
  // by an older add on another phone, and so removing it here does not touch
  // the same track in any other playlist. See SetLog.playlistItems.
  SetLog.instance
      .record(SetLog.playlistItems(playlistTitle), songId, member: false);

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
  /// Replaces an existing playlist's tracks wholesale, for a re-import (pasting the
  /// same link again to complete a short playlist, where appending would duplicate
  /// tracks). Separate from [savePlaylistFromSearch], which refuses existing titles
  /// so one import can't silently replace another's playlist. Returns false when
  /// there is no such playlist.
  bool replacePlaylistSongs(String playlistTitle, List<Song> songs) {
    if (!state.playlistSongs.containsKey(playlistTitle) &&
        !state.allItems.any((i) =>
            i.title == playlistTitle &&
            i.category == LibraryCategory.playlist)) {
      return false;
    }
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = songs;
    // The subtitle carries the count, and a stale one is how a playlist ends up
    // claiming a size it does not have — the same shape as the liked-albums
    // counter that sat frozen. Rewritten here rather than left to a later pass.
    final newAllItems = state.allItems.map((item) {
      if (item.title != playlistTitle) return item;
      return LibraryItem(
        title: item.title,
        subtitle: 'Playlist • ${songs.length} songs',
        image: item.image,
        isPinned: item.isPinned,
        category: item.category,
        dateAdded: item.dateAdded,
        songCount: songs.length,
        isSystemFolder: false,
      );
    }).toList();
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort();
    _saveToDisk();
    return true;
  }

  /// Adds [song] to a playlist. Returns true when it was added, false when the
  /// playlist already contained it (callers then say "Already in <playlist>").
  /// Duplicates are matched on title + artist as well as id, since the same
  /// recording can have different video ids.
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
    // Recorded AFTER the duplicate check, so re-adding a track already present
    // does not write a fresh timestamp for a change that did not happen.
    SetLog.instance
        .record(SetLog.playlistItems(playlistTitle), song.id, member: true);
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

  /// Sets a Keep fresh playlist's songs and its hidden reserve (see
  /// [freshReserveKey]) in one state update and one save, recording every
  /// membership change in the set log as a manual edit does, so another phone
  /// applies the same swap rather than undoing it. An empty reserve is removed.
  void applyFreshRotation(
      String playlistTitle, List<Song> playlist, List<Song> reserve) {
    if (!mounted || !state.playlistSongs.containsKey(playlistTitle)) return;
    final reserveKey = freshReserveKey(playlistTitle);
    void logDiff(String key, List<Song> before, List<Song> after) {
      final log = SetLog.playlistItems(key);
      final b = before.map((s) => s.id).toSet();
      final a = after.map((s) => s.id).toSet();
      for (final id in b.difference(a)) {
        SetLog.instance.record(log, id, member: false);
      }
      for (final id in a.difference(b)) {
        SetLog.instance.record(log, id, member: true);
      }
    }

    logDiff(playlistTitle, state.playlistSongs[playlistTitle] ?? const [], playlist);
    logDiff(reserveKey, state.playlistSongs[reserveKey] ?? const [], reserve);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = playlist;
    if (reserve.isEmpty) {
      newMap.remove(reserveKey);
    } else {
      newMap[reserveKey] = reserve;
    }
    final newAllItems = state.allItems.map((item) {
      if (item.title != playlistTitle) return item;
      return LibraryItem(
        title: item.title,
        subtitle: 'Playlist • ${playlist.length} songs',
        image: item.image,
        isPinned: item.isPinned,
        category: item.category,
        dateAdded: item.dateAdded,
        songCount: playlist.length,
        isSystemFolder: false,
      );
    }).toList();
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort();
    _saveToDisk();
  }

  /// Drops a reserve whose playlist no longer exists (deleted with it).
  void dropFreshReserve(String playlistTitle) {
    final key = freshReserveKey(playlistTitle);
    final reserve = state.playlistSongs[key];
    if (!mounted || reserve == null) return;
    final log = SetLog.playlistItems(key);
    for (final s in reserve) {
      SetLog.instance.record(log, s.id, member: false);
    }
    state = state.copyWith(
        playlistSongs: Map<String, List<Song>>.from(state.playlistSongs)..remove(key));
    _saveToDisk();
  }

  /// Replaces Weekly Discovery's songs, adding its row the first time. A derived
  /// system playlist like My Top 50: written directly, with no set-log decisions
  /// (system folders are skipped by the cross-device merge).
  void setWeeklyDiscovery(List<Song> songs) {
    if (!mounted || !_loaded) return;
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[kWeeklyDiscoveryTitle] = songs;
    final row = LibraryItem(
      title: kWeeklyDiscoveryTitle,
      subtitle: 'Playlist • ${songs.length} songs',
      image: 'assets/images/weekly_discovery_cyan.webp',
      isPinned: true,
      category: LibraryCategory.playlist,
      dateAdded: DateTime.now(),
      songCount: songs.length,
      isSystemFolder: true,
    );
    final i = state.allItems.indexWhere((it) => it.title == kWeeklyDiscoveryTitle);
    final newAllItems = [...state.allItems];
    if (i < 0) {
      newAllItems.add(row);
    } else {
      final old = newAllItems[i];
      newAllItems[i] = LibraryItem(
        title: old.title,
        subtitle: row.subtitle,
        image: old.image,
        isPinned: old.isPinned,
        category: old.category,
        dateAdded: old.dateAdded,
        songCount: songs.length,
        isSystemFolder: true,
      );
    }
    state = state.copyWith(playlistSongs: newMap, allItems: newAllItems);
    _applyFilterAndSort();
    _saveToDisk();
  }

  DateTime? _lastFreshCheck;

  /// Runs the Keep fresh and Weekly Discovery checks, which do nothing when
  /// nothing is due. Only in the app's own engine: a headless one (widget, quick
  /// settings tile) has no screen and must not spend the network.
  void _checkFreshPlaylists() {
    if (!mounted || !_loaded || !NativeAudioEngine.platformAvailable) return;
    // Every app switch is a resume, but a check only has work when a day or a
    // week rolls over, so they're spaced out (seen on device: one every few
    // seconds while switching apps).
    final now = DateTime.now();
    final last = _lastFreshCheck;
    if (last != null && now.difference(last) < const Duration(minutes: 15)) return;
    _lastFreshCheck = now;
    try {
      unawaited(ref.read(keepFreshProvider.notifier).refreshDue());
    } catch (_) {}
  }

  // Reorders tracks within a specific user playlist.
  void reorderPlaylistTracks(String playlistTitle, int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final currentSongs = List<Song>.from(state.playlistSongs[playlistTitle] ?? []);
    if (oldIndex < 0 || oldIndex >= currentSongs.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= currentSongs.length) return;
    final movedSong = currentSongs.removeAt(oldIndex);
    currentSongs.insert(newIndex, movedSong);
    final newMap = Map<String, List<Song>>.from(state.playlistSongs);
    newMap[playlistTitle] = currentSongs;
    state = state.copyWith(playlistSongs: newMap);
    _saveToDisk();
  }

  /// Renames a user playlist, moving everything keyed by its title (tracks in
  /// `playlistSongs[title]` and the custom cover under `playlist:<title>`), all
  /// together or not at all.
  ///
  /// Returns false when the rename is refused: an empty or unchanged name, a name
  /// already in use, or a system folder (Liked Songs, Downloads, Cached, My Top 50).
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
    // A Keep fresh playlist's resting songs move with it.
    final resting = songs.remove(freshReserveKey(oldName));
    if (resting != null) songs[freshReserveKey(next)] = resting;

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

    // 3. The custom cover. setOverride re-encodes from the stored file under the new
    // key, and the old key is then dropped. The library item's image path is updated
    // too, since setOverride writes a fresh file and clearOverride deletes the old one.
    try {
      final overrides = ref.read(artworkOverrideProvider);
      final oldKey = 'playlist:$oldName';
      final existing = overrides[oldKey];
      if (existing != null && existing.isNotEmpty) {
        final notifier = ref.read(artworkOverrideProvider.notifier);
        // Only clear the old key if the move succeeded: a cover under the wrong name can
        // be recovered, a deleted one can't.
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
    try {
      ref.read(recentPlaylistsProvider.notifier).rename(oldName, next);
    } catch (_) {}
    try {
      ref.read(keepFreshProvider.notifier).rename(oldName, next);
    } catch (_) {}

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
    // The home mosaic stores its own copy of the image (recent_playlists_v1), so
    // update it too.
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
  /// Merges an imported library without losing this one. Used by the restore
  /// screen for backups from other music apps (see [ForeignBackupReader]).
  /// Everything is additive:
  ///
  ///  • Liked songs are a union; an already liked track keeps its entry and
  ///    position.
  ///  • A playlist whose name is taken is imported alongside, suffixed with the
  ///    source app, never merged into or over it.
  ///  • Play counts take the higher of the two, so imports can't shrink real
  ///    history.
  ///
  /// One state write and one save for the whole import. Returns a summary of what
  /// was actually added.
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
    // BY TITLE, because that is what likedAlbums is keyed by two lines above.
    // Logging the album id instead would record a decision about an item the
    // merge could never match, so an un-like would never cross devices.
    SetLog.instance.record(SetLog.albums, album.title, member: !exists);
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
          // Podcasts are saved as playlists in the library.
          category: isPodcast ? LibraryCategory.playlist : LibraryCategory.album, 
          dateAdded: DateTime.now(),
          songCount: 0,
          isSystemFolder: false,
        ));
      }
    }
    
    // Followed podcasts share this list; don't count them as liked albums.
    final actualAlbumCount = newList.where((a) => a.recordType != 'podcast').length;

    // Commit the like first, then update the folder count: _updateSystemFolder writes
    // into allItems, and running it before this copyWith (which uses a list captured
    // earlier) threw the new count away.
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
          // Match by title only (not category), so episodes fetched in the background
          // land in the podcast's playlist.
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

  /// Followed shows' newest episodes, kept in the library for Android Auto and
  /// for offline. Only the newest [podcastSnapshot]: the whole feed (hundreds of
  /// episodes) made the library and every backup grow by hundreds of KB per show.
  static const int podcastSnapshot = 20;
  static const String _kPodcastRefreshAt = 'auvy_podcast_refresh_at';

  /// Refreshes those snapshots at most every 12 hours (it ran at every launch,
  /// one feed request per followed show), and only saves a show whose newest
  /// episodes changed.
  Future<void> _refreshAllPodcasts() async {
      final podcasts = state.likedAlbums.where((a) => a.recordType == 'podcast').toList();
      if (podcasts.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt(_kPodcastRefreshAt) ?? 0;
      // A show followed but never snapshotted (or an old full copy to trim) is
      // worth a refresh before the 12 hours are up.
      final needsWork = podcasts.any((p) {
        final n = state.playlistSongs[p.title]?.length ?? 0;
        return n == 0 || n > podcastSnapshot;
      });
      if (!needsWork && now - last < const Duration(hours: 12).inMilliseconds) return;
      await prefs.setInt(_kPodcastRefreshAt, now);

      var changed = 0;
      for (final p in podcasts) {
          try {
              final show = PodcastShow(collectionName: p.title, artistName: 'Podcast', artworkUrl: p.image, feedUrl: p.id);
              final episodes = await ref.read(podcastEpisodesProvider(show).future);
              if (episodes.isEmpty || !mounted) continue;
              final snapshot = [for (final e in episodes.take(podcastSnapshot)) e.toSong()];
              final old = state.playlistSongs[p.title] ?? const <Song>[];
              final same = old.length == snapshot.length &&
                  [for (var i = 0; i < old.length; i++) old[i].id == snapshot[i].id].every((b) => b);
              if (same) continue;
              updateAlbumTracks(p.title, snapshot);
              changed++;
          } catch (e) {
              print("ERROR: Failed to refresh podcast ${p.title}: $e");
          }
      }
      print('podcast snapshots: ${podcasts.length} followed show(s), $changed updated');
  }

  // Toggles the subscription status for a specific artist.
  bool toggleArtistSubscription(String artistName, String imageUrl, String artistId) {
    final exists = state.subscribedArtists.any((a) => a.title == artistName);
    List<Song> newList;
    if (exists) newList = state.subscribedArtists.where((a) => a.title != artistName).toList();
    else newList = [...state.subscribedArtists, Song(title: artistName, artist: "Artist", image: imageUrl, id: artistId)];
    _updateSystemFolder("Followed Artists", "${newList.length} Artists", null);
    // Followed/unfollowed, with the moment — so an unfollow on one device
    // is not undone by an older follow on another. See SetLog.
    SetLog.instance.record(SetLog.artists, artistId, member: !exists);
    state = state.copyWith(subscribedArtists: newList); _saveToDisk();
    return !exists;
  }

  /// Applies a merged cross-device set log to the live library. Removals are the
  /// point: a union would bring back every un-like, while the log records when each
  /// decision was made and the newest wins (see SetLog). Ids added on another device
  /// that aren't present here are counted, not invented; the snapshot restore brings
  /// the real items. Keys match what each list already uses: songs by id, albums and
  /// playlists by title, artists by artist id.
  Future<void> applyMergedSets(
      Map<String, Map<String, ({bool member, int atMs})>> mergedLog) async {
    // An empty library usually means "not loaded yet": hold the log and apply it once
    // the real library is in memory, or the other device's un-likes would be lost.
    if (!_loaded) {
      _pendingMergedSets = mergedLog;
      logEvent('library: sets merged before the library finished loading — '
          'held until it has');
      return;
    }
    var missing = 0;
    // Which collections they are in, so a count that never goes down can be
    // traced to its items rather than guessed at.
    final missingIn = <String>[];

    /// Prune one list against the merged log. Null when nothing moved, so an
    /// unchanged set does not trigger a save.
    List<T>? prune<T>(
        String collection, List<T> local, String Function(T) idOf) {
      final r = SetLog.resolve(
        mergedLog: mergedLog,
        collection: collection,
        localIds: local.map(idOf).toList(),
      );
      missing += r.missingIds.length;
      if (r.missingIds.isNotEmpty) {
        missingIn.add('$collection: ${r.missingIds.take(3).join(", ")}'
            '${r.missingIds.length > 3 ? " (+${r.missingIds.length - 3})" : ""}');
      }
      final keep = r.keepIds.toSet();
      final next = local.where((e) => keep.contains(idOf(e))).toList();
      return next.length == local.length ? null : next;
    }

    final songs = prune(SetLog.songs, state.likedSongs, (Song s) => s.id);
    final albums = prune(SetLog.albums, state.likedAlbums, (Album a) => a.title);
    final playlists = prune(
        SetLog.playlists, state.likedPlaylists, (LibraryItem p) => p.title);
    final artists =
        prune(SetLog.artists, state.subscribedArtists, (Song a) => a.id);

    // Per-playlist membership. System folders are skipped: Downloads, Cached and My
    // Top 50 are derived from other state and have no add/remove decisions.
    final systemTitles = {
      for (final i in state.allItems)
        if (i.isSystemFolder) i.title,
    };
    Map<String, List<Song>>? playlistSongs;
    for (final entry in state.playlistSongs.entries) {
      if (systemTitles.contains(entry.key)) continue;
      final next = prune(SetLog.playlistItems(entry.key), entry.value,
          (Song s) => s.id);
      if (next == null) continue;
      playlistSongs ??= Map<String, List<Song>>.from(state.playlistSongs);
      playlistSongs[entry.key] = next;
    }

    if (songs == null &&
        albums == null &&
        playlists == null &&
        artists == null &&
        playlistSongs == null) {
      if (missing > 0) {
        print('library: $missing item(s) another device added are not here '
            'yet — the snapshot restore carries them (${missingIn.join("; ")})');
      }
      return;
    }

    // A dropped album or playlist also has a row in allItems and a track list keyed
    // by its title (as in toggleAlbumLike); clear those too. Copied, not aliased
    // (day3_fixes_test forbids aliasing state lists).
    var allItems = List<LibraryItem>.from(state.allItems);
    var songsByTitle =
        Map<String, List<Song>>.from(playlistSongs ?? state.playlistSongs);
    final dropped = <String>{
      if (albums != null)
        ...state.likedAlbums
            .map((a) => a.title)
            .where((t) => !albums.any((a) => a.title == t)),
      if (playlists != null)
        ...state.likedPlaylists
            .map((p) => p.title)
            .where((t) => !playlists.any((p) => p.title == t)),
    };
    if (dropped.isNotEmpty) {
      allItems = allItems.where((i) => !dropped.contains(i.title)).toList();
      songsByTitle = Map<String, List<Song>>.from(songsByTitle)
        ..removeWhere((title, _) => dropped.contains(title));
    }

    state = state.copyWith(
      likedSongs: songs,
      // Kept in step by hand: likedSongIds is the fast membership check every
      // heart icon reads, and a stale one shows a filled heart for a song that
      // is no longer in the list.
      likedSongIds:
          songs == null ? null : Set<String>.from(songs.map((s) => s.id)),
      likedAlbums: albums,
      likedPlaylists: playlists,
      subscribedArtists: artists,
      allItems: allItems,
      playlistSongs: songsByTitle,
    );

    logEvent('library: merged sets — '
        '${songs != null ? '${songs.length} liked songs, ' : ''}'
        '${albums != null ? '${albums.length} albums, ' : ''}'
        '${playlists != null ? '${playlists.length} playlists, ' : ''}'
        '${artists != null ? '${artists.length} artists, ' : ''}'
        '${playlistSongs != null ? '${playlistSongs.length} playlist(s) changed, ' : ''}'
        '$missing not here yet');

    if (artists != null) {
      _updateSystemFolder('Followed Artists', '${artists.length} Artists', null);
    }
    _recomputeCollectionCounts();
    _applyFilterAndSort();
    _saveToDisk();
  }

  // Deletes an item from every list (so unfollowing is complete). Returns a
  // snapshot for [restoreItem] so callers can offer Undo (null when nothing was
  // deleted, i.e. system folders).
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

    // Deleting from the library is a REMOVAL like any other, and it was the
    // one path that did not say so. Without these two lines, unfollowing here
    // was undone the moment another device's older "liked" decision merged in.
    if (newLikedAlbums.length != state.likedAlbums.length) {
      SetLog.instance.record(SetLog.albums, item.title, member: false);
    }
    if (newLikedPlaylists.length != state.likedPlaylists.length) {
      SetLog.instance.record(SetLog.playlists, item.title, member: false);
    }

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
    try {
      final liveTitles = newAllItems.map((i) => i.title).toSet();
      ref.read(recentPlaylistsProvider.notifier).pruneMissing(liveTitles);
    } catch (_) {}
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

    // An undo is a NEWER decision than the delete it undoes, and it has to be
    // logged as one. Otherwise the delete's timestamp is the last word in the
    // log, and the next cross-device merge deletes the item again — the undo
    // holding only until the next sync.
    if (snapshot.likedAlbum != null) {
      SetLog.instance.record(SetLog.albums, item.title, member: true);
    }
    if (snapshot.likedPlaylist != null) {
      SetLog.instance.record(SetLog.playlists, item.title, member: true);
    }

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
    kWeeklyDiscoveryTitle,
    'Cached',
    'Downloads',
    'Liked Playlists',
  };

  void _updateSystemFolder(String title, String newSubtitle, String? newImage) {
    final newAllItems = state.allItems.map((item) {
      if (item.title == title) {
        return LibraryItem(
          title: item.title,
          // The row's type comes from a fixed set of names, not from isSystemFolder (which
          // means "scaffolding") or category (not consistent with content: Liked Songs and
          // My Top 50 are filed as folders).
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

  /// Recomputes every collection folder's count from the lists themselves, in one
  /// pass. The count is saved inside the `allItems` row, separately from what it
  /// counts, so it could go stale, be reset by a freshly inserted row, or include
  /// podcasts (which share `likedAlbums` but aren't shown in the album grid).
  /// Deriving them all here defines the podcast split once. Cached and Downloads come
  /// from the cache manager and have their own refresh paths.
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
      // Counted the way the page counts it: playlist_page derives My Top 50 live from
      // the taste profile (`computeTop50(intel.playCounts, …)`), so the row uses the same
      // derivation (a bounded sort over capped metadata).
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

  /// How many duplicate tracks a playlist is carrying, without changing anything.
  ///
  /// Lets a menu offer the action only when there is something to do, and say how
  /// much — "Remove 14 duplicates" is a decision, "Remove duplicates" is a leap.
  int countDuplicatesInPlaylist(String playlistTitle) {
    final songs = state.playlistSongs[playlistTitle];
    if (songs == null || songs.length < 2) return 0;
    return songs.length - _dedupe(songs).length;
  }

  /// Removes repeated tracks from a playlist, keeping the first of each. Matched on
  /// title + primary artist as well as id, because the same track can resolve to
  /// different video ids across import attempts. Keeping the first occurrence keeps
  /// the user's order. Returns the number removed; 0 means nothing changed and
  /// nothing was saved.
  int removeDuplicatesFromPlaylist(String playlistTitle) {
    final songs = state.playlistSongs[playlistTitle];
    if (songs == null || songs.length < 2) return 0;

    final deduped = _dedupe(songs);
    final removed = songs.length - deduped.length;
    if (removed == 0) return 0;

    final newPlaylistSongs = Map<String, List<Song>>.from(state.playlistSongs);
    newPlaylistSongs[playlistTitle] = deduped;
    state = state.copyWith(playlistSongs: newPlaylistSongs);

    // Not _updateSystemFolder, which hardcodes `isSystemFolder: true` and would turn
    // this user playlist into a system folder (losing delete and rename). The row is
    // updated directly.
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

    // Nothing changed means touch nothing: this runs after every finished track, and
    // once fifty tracks exist an ordinary play usually reproduces the same list.
    // Compared by id order and title, since a reshuffle (same length) is real content
    // and a corrected title must still refresh.
    final prev = state.playlistSongs['My Top 50'];
    if (prev != null && prev.length == top50.length) {
      var unchanged = true;
      for (var i = 0; i < top50.length; i++) {
        if (prev[i].id != top50[i].id || prev[i].title != top50[i].title) {
          unchanged = false;
          break;
        }
      }
      // At most fifty comparisons against a rebuild, a state write and a sort.
      if (unchanged) return;
    }

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

  /// Requests a re-filter; a burst of requests does one pass. There are many call
  /// sites, and one user action can hit several (each _updateSystemFolder call ends
  /// with a pass). Each pass rebuilds sets, filters, sorts and publishes new state.
  /// Coalesced over one frame (16 ms) rather than a microtask, because the startup
  /// steps are separated by awaits. No caller reads `filteredItems` synchronously
  /// afterwards. The collapsed count is logged.
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

  /// Publish the sorted list in THIS frame, and drop any pending debounce.
  ///
  /// For the callers whose change the user is watching happen — a drag being
  /// dropped. Cancelling the pending timer matters: without it the same pass
  /// runs again a frame later for no reason, and the count it reports would
  /// claim requests were collapsed when they were already served.
  void _applyFilterAndSortNowCancellingDebounce() {
    _filterDebounce?.cancel();
    _filterDebounce = null;
    _filterCoalesced = 0;
    _applyFilterAndSortNow();
  }


  void _applyFilterAndSortNow({int collapsed = 1}) {
    _filterSw
      ..reset()
      ..start();
    // Liked albums and playlists appear inside their folder, not also at the top
    // level. Filtered here rather than by removing the insert, so libraries that
    // already contain the duplicates are fixed without a migration, whichever code
    // path inserted the entry. System folders are never excluded.
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
    // One log line per pass.
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
/// counters for the one-shot dead-cover heal at library load.
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
    // Silent when there's nothing to heal.
    if (dead == 0) return;
    print('cover-heal: $dead dead local image path(s) in the restored '
        'library → $healed re-pointed, $blanked blanked. Local cover paths '
        'were persisted and uploaded, so a restore can carry paths that mean '
        'nothing on this device.');
  }
}

/// Reports foreground/background to [LibraryNotifier]: a small dedicated observer
/// rather than making the notifier one. Public so a test can drive it.
@visibleForTesting
class LibraryLifecycleHook extends WidgetsBindingObserver {
  final VoidCallback onResume;
  final VoidCallback onPause;

  LibraryLifecycleHook({required this.onResume, required this.onPause});

  /// Leaving the app delivers several lifecycle events (Android sends `hidden` then
  /// `paused`, sometimes `detached`), and each triggered a flush and a cloud push. The
  /// group is collapsed into the first event and re-armed when the app returns.
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

/// What an import actually added, reported to the user instead of a bare
/// "restored".
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
