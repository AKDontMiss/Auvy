import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:flutter/material.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart'; 
import 'package:auvy/core/app_navigation.dart';
// For smoothRoute — the app's standard page transition, used by every other
// page-to-page navigation (see AppNavigation.push).
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/providers/theme_provider.dart'; 
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/services/page_cache_service.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/track_download_overlay.dart'; 
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';
import 'package:auvy/providers/recent_playlists_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/providers/download_provider.dart';
import 'package:auvy/presentation/widgets/fullscreen_artwork.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';
import 'package:auvy/presentation/widgets/page_skeletons.dart';
import 'package:auvy/providers/density_provider.dart';

/// Identifies which album to load. Carries the title + artist so the album can
/// be resolved by NAME when the id isn't a real browse id (the wrong/invalid
/// album bug), and an isSingle flag so genuine singles just show their track.
class AlbumQuery {
  final String id;
  final String title;
  final String artist;
  final bool isSingle;
  // The track this album was opened FROM (when navigated via a song). Lets the
  // resolver verify the opened album actually contains that track and re-resolve
  // if it doesn't — fixes a collab track (e.g. "Real Nigga", Metro Boomin & 21
  // Savage) opening a DIFFERENT album the same two artists appear on.
  final String expectTrackTitle;
  const AlbumQuery(this.id, this.title, this.artist, this.isSingle,
      {this.expectTrackTitle = ''});

  // Cache key: a real browse id, else keyed by name so resolved albums cache.
  // 'nm2' (not 'nm'): name-resolution used to be able to pick a wrong album
  // and CACHE it — the old entries are poisoned, so orphan them. When opened
  // from a track, the expected title is folded in so a corrected (re-resolved)
  // tracklist can't poison the cache entry another track shares.
  String get cacheKey {
    return expectTrackTitle.isEmpty
        ? sharedCacheKey
        : '$sharedCacheKey|t:${expectTrackTitle.toLowerCase().trim()}';
  }

  /// The album-wide key, WITHOUT the entry track folded in.
  ///
  /// The per-track key meant one network fetch per track of the same album.
  /// Every song you could open an album from produced its own cache entry, so a
  /// 12-track album cost up to 12 identical fetches and a cached album still
  /// showed a loading state when entered from a different song. Observed:
  ///
  /// Fetching fresh album tracks for NAKAMURA (id=MPREb_7dy7BhyT7p4)
  ///   Album tracks cached for MPREb_7dy7BhyT7p4|t:djadja
  ///
  /// The suffix cannot simply be dropped: even with a real browse id the resolver
  /// RE-RESOLVES when the album turns out not to contain the expected track (the
  /// collab-track fix above), so the result genuinely can differ per entry track.
  /// Instead the tracklist is ALSO stored under this album-wide key, and a reader
  /// may only use that copy once it has proved it contains the track it came in
  /// on. See [containsExpectedTrack]. A re-resolved album can therefore never be
  /// served for a track it does not hold.
  String get sharedCacheKey => (id.length > 11 && id != 'null')
      ? id
      : 'nm2:${title.toLowerCase()}:${artist.toLowerCase()}';

  /// Does [tracks] actually contain the track this album was opened from?
  ///
  /// The proof that lets an album-wide cache entry be reused. Compared on the
  /// normalised title, because that is all the caller has at this point — the id
  /// of a row is not yet known to be the same edition.
  bool containsExpectedTrack(List<Song> tracks) {
    final want = expectTrackTitle.toLowerCase().trim();
    if (want.isEmpty) return true;
    return tracks.any((t) => t.title.toLowerCase().trim() == want);
  }

  @override
  bool operator ==(Object o) =>
      o is AlbumQuery && o.id == id && o.title == title && o.artist == artist &&
      o.isSingle == isSingle && o.expectTrackTitle == expectTrackTitle;
  @override
  int get hashCode => Object.hash(id, title, artist, isSingle, expectTrackTitle);
}

final albumTracksProvider = FutureProvider.family<List<Song>, AlbumQuery>((ref, q) async {
  final service = ref.read(searchServiceProvider);
  final cacheService = PageCacheService();
  final offline = ref.read(connectivityProvider).isOffline;

  //  CACHE: Try loading from cache first (keyed so resolved-by-name albums stick).
  //  Offline, a stale entry beats the guaranteed network failure.
  final cachedTracks = await cacheService.getCachedAlbumTracks(q.cacheKey, allowStale: offline);
  if (cachedTracks != null && cachedTracks.isNotEmpty) {
    return cachedTracks;
  }

  // Nothing under this track's own key → try the ALBUM-WIDE copy another track
  // already fetched, and use it only if it proves it holds this track. That is
  // what stops the same album being downloaded once per song you enter it from,
  // without ever serving a re-resolved album to a track it does not contain.
  // See AlbumQuery.sharedCacheKey.
  if (q.sharedCacheKey != q.cacheKey) {
    final shared = await cacheService.getCachedAlbumTracks(q.sharedCacheKey,
        allowStale: offline);
    if (shared != null && shared.isNotEmpty && q.containsExpectedTrack(shared)) {
      return shared;
    }
  }

  print("Fetching fresh album tracks for ${q.title} (id=${q.id}, single=${q.isSingle})");
  final List<Song> tracks;
  try {
    tracks = await service.getAlbumTracksSmart(q.id, q.title, q.artist,
        isSingle: q.isSingle, expectTrackTitle: q.expectTrackTitle);
  } catch (e) {
    // Failed fetch (offline / flaky network): any cached copy, however old,
    // beats the error page.
    final stale = await cacheService.getCachedAlbumTracks(q.cacheKey, allowStale: true);
    if (stale != null && stale.isNotEmpty) {
      print("Album fetch failed, serving stale cache for ${q.title}");
      return stale;
    }
    rethrow;
  }

  if (tracks.isNotEmpty) {
    await cacheService.cacheAlbumTracks(q.cacheKey, tracks);
    // Also store it album-wide so the NEXT track of this album finds it instead
    // of refetching the identical list. Written second and read with a
    // containment check, so a re-resolved album cannot be handed to a track it
    // does not contain. See AlbumQuery.sharedCacheKey.
    if (q.sharedCacheKey != q.cacheKey) {
      await cacheService.cacheAlbumTracks(q.sharedCacheKey, tracks);
    }
  }
  return tracks;
});

/// Other editions of the album being viewed — the deluxe beside the standard.
///
/// Free: [SearchService.getAlbumOtherVersions] re-reads the SAME cached browse
/// response the tracklist came from, so this adds no network request.
/// PERSISTED, LIKE THE TRACKLIST BESIDE IT. This used to read only
/// CatalogApiClient's in-memory browse cache, which is gone after 30 minutes or
/// any restart, so the tracklist came straight off disk while this section
/// spun, and the page looked half loaded. It now shares the tracklist's cache
/// and TTL, so both halves of the page arrive together.
final albumOtherVersionsProvider =
    FutureProvider.family<List<Album>, String>((ref, albumId) async {
  if (albumId.isEmpty) return const [];
  final cacheService = PageCacheService();
  final offline = ref.read(connectivityProvider).isOffline;
  final key = 'album_versions:$albumId';

  final cached = await cacheService.getCachedSection(key, allowStale: offline);
  if (cached is List) {
    return cached
        .whereType<Map>()
        .map((m) => Album.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  try {
    final versions =
        await ref.read(searchServiceProvider).getAlbumOtherVersions(albumId);
    // Cached even when EMPTY — "this album has no other editions" is a real
    // answer, and not storing it meant re-asking on every single open.
    await cacheService.cacheSection(
        key, versions.map((a) => a.toMap()).toList());
    return versions;
  } catch (_) {
    final stale = await cacheService.getCachedSection(key, allowStale: true);
    if (stale is List) {
      return stale
          .whereType<Map>()
          .map((m) => Album.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    }
    // A missing extras section must never break the page it sits on.
    return const [];
  }
});

class AlbumPage extends ConsumerStatefulWidget {
  final Album album;
  final String artistName;
  // When this "album" is actually a single (no real album browse id, so the
  // track list comes back empty), fall back to showing this originating track
  // instead of a broken "0 songs" page.
  final Song? fallbackTrack;

  /// Start this track as soon as the album resolves.
  ///
  /// Set when arriving from a "song found" notification: the user tapped an
  /// answer, so landing on the album and waiting for a second tap is a step too
  /// many — they already told us what they wanted to hear.
  ///
  /// Waits for the album rather than playing the loose track immediately.
  /// Playing the single Song on arrival would start audio a beat sooner and
  /// leave the queue with one item in it, so the track would end into the
  /// autoplay radio instead of into the rest of the record. Resolving first
  /// costs a moment and produces exactly what tapping the row produces.
  final Song? autoplayTrack;

  const AlbumPage(
      {super.key,
      required this.album,
      required this.artistName,
      this.fallbackTrack,
      this.autoplayTrack});

  @override
  ConsumerState<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends ConsumerState<AlbumPage> {
  /// Guards the one-shot autoplay. build() runs on every provider tick, and the
  /// resolved-tracks future settles into a value that stays settled — without
  /// this the track would be restarted from zero on every rebuild, which is a
  /// particularly nasty bug because it only shows up once something else on the
  /// page changes.
  bool _autoplayDone = false;

  @override
  void initState() {
    super.initState();
    // NOTE: opening an album does NOT flag it "recently played" — only PLAYING a
    // track from it does (see _recordPlayFromAlbum, called from track/Play/Shuffle
    // taps). This keeps merely-browsed albums out of the Home mosaic.
  }

  /// Start [AlbumPage.autoplayTrack] once, as soon as the album has tracks.
  ///
  /// Matched by id first and by title second: the notification path looks the
  /// song up by a "title artist" string, so the Song it lands with can be a
  /// different upload of the same recording than the one the album lists. An
  /// id-only match would silently fall through to the loose-track fallback and
  /// lose the album queue, which is the thing this is here to preserve.
  ///
  /// Deferred to after the frame: this is called FROM build, and starting
  /// playback synchronously would mutate a provider mid-build.
  void _maybeAutoplay(List<Song>? tracks) {
    if (_autoplayDone) return;
    final want = widget.autoplayTrack;
    if (want == null) {
      _autoplayDone = true;
      return;
    }
    if (tracks == null || tracks.isEmpty) return; // still resolving
    _autoplayDone = true;

    final wantTitle = want.title.trim().toLowerCase();
    var index = tracks.indexWhere((t) => t.id == want.id);
    if (index < 0) {
      index = tracks.indexWhere((t) => t.title.trim().toLowerCase() == wantTitle);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final title = (tracks.first.albumTitle.trim().isNotEmpty)
          ? tracks.first.albumTitle.trim()
          : widget.album.title;
      if (index >= 0) {
        // The row-tap path, exactly: the rest of the album queues behind it.
        _recordPlayFromAlbum(tracks[index]);
        ref.read(playerProvider.notifier).playSong(
              tracks[index],
              newQueue: tracks,
              index: index,
              source: "Album",
              locationName: title,
              contextId: widget.album.id.isNotEmpty ? widget.album.id : title,
              contextType: 'album',
              contextTitle: title,
            );
      } else {
        // The album resolved but does not contain the match — a compilation, a
        // live version, a single that resolved to the wrong record. Play what
        // the user actually asked for rather than nothing.
        ref.read(playerProvider.notifier).playSong(want, source: "Recognised");
      }
    });
  }

  /// A track was PLAYED from this album → record the album in the recents store
  /// (so the Home mosaic can reopen it) AND remember that [playedSong] came from
  /// it, so the mosaic shows only the album tile, not the album AND the song.
  /// Only albums with a REAL browse id are recorded — name-resolved ones have no
  /// stable identity to dedupe/reopen by.
  void _recordPlayFromAlbum(Song playedSong) {
    if (!mounted) return;
    final a = widget.album;
    if (a.title.trim().isEmpty || a.image.isEmpty) return;
    if (a.id.length <= 11 || a.id == 'null') return;
    if (a.recordType == 'podcast') return;
    final sig =
        '${playedSong.title.toLowerCase()}|${playedSong.artist.toLowerCase()}';
    ref.read(recentPlaylistsProvider.notifier).recordPlayedFrom(
          RecentPlaylist(
            kind: 'album',
            externalId: a.id,
            title: a.title,
            image: a.image,
            subtitle: widget.artistName,
            playedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          songId: playedSong.id,
          songSig: sig,
        );
  }

  /// The tracks to actually display: the browsed album tracks, or — when the
  /// album browse yields nothing and this was opened from a single — the single
  /// track itself, so the page never shows an empty "0 songs".
  List<Song> _effective(List<Song> tracks) {
    if (tracks.isEmpty && widget.fallbackTrack != null) {
      return [widget.fallbackTrack!];
    }
    return tracks;
  }

  /// "1 hr 12 min" / "43 min" summed from the tracks' duration strings
  /// ("m:ss", "h:mm:ss" or raw seconds). Empty when nothing parses.
  String _totalDurationLabel(List<Song> tracks) {
    int total = 0;
    for (final t in tracks) {
      final d = t.duration.trim();
      if (d.isEmpty) continue;
      if (d.contains(':')) {
        final parts = d.split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
        if (parts.length == 3) {
          total += parts[0] * 3600 + parts[1] * 60 + parts[2];
        } else if (parts.length == 2) {
          total += parts[0] * 60 + parts[1];
        }
      } else {
        total += int.tryParse(d) ?? 0;
      }
    }
    if (total <= 0) return '';
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    if (h > 0) return '$h hr $m min';
    return '$m min';
  }

  /// Quiet circular secondary action — the page's counterpart to the Play pill.
  /// When [disabled] the tap is suppressed and the chip dims, so an already-
  /// completed action (e.g. an album that's fully downloaded) reads as inert.
  Widget _circleAction({
    required IconData icon,
    Color? color,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.07),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Icon(icon, color: color ?? Colors.white.withOpacity(0.85), size: 20),
        ),
      ),
    );
  }

  void _shareAlbum(BuildContext context, String albumTitle) {
    final themeColor = ref.read(themeProvider);
    // Convert Album info into a Song object for the postcard
    final albumSong = Song(
      id: widget.album.id,
      title: albumTitle,
      artist: widget.artistName,
      image: widget.album.image,
    );
    showSharePostcardDialog(context, albumSong, themeColor,
        kind: PostcardKind.album);
  }


  /// Open the artist this album is credited to.
  ///
  /// Why this delegates instead of searching
  ///
  /// It used to search `artistName` as ONE name and refuse when nothing matched
  /// exactly. On a collaboration that name is a joined credit — "Central Cee,
  /// Lil Baby", "Metro Boomin & 21 Savage", which is nobody, so the exact-match
  /// rule correctly rejected every result and the page dead-ended on
  /// "Couldn't find that artist".
  ///
  /// [ContentMenus] already solves this for the song menu: it offers a picker
  /// when a track credits several artists, resolves the specific channel, and —
  /// the part that matters here — falls back to the NAME when no channel id can
  /// be found, so the artist page still opens and resolves it itself. Refusing
  /// to navigate was this copy's own invention.
  Future<void> _goToArtistPage(BuildContext context) async {
    final track = widget.fallbackTrack;
    if (track != null) {
      final chosen = await ContentMenus.pickArtist(context, track);
      if (chosen == null || !context.mounted) return;
      final targetId = await ContentMenus.resolveArtistTarget(ref, track, chosen);
      if (!context.mounted) return;
      final target = Song(
        id: targetId,
        title: chosen,
        artist: chosen,
        image: '',
        duration: '',
      );
      AppNavigation.push(context, ArtistPage(artist: target),
          name: AppNavigation.artistTag(target));
      return;
    }

    // No entry track (opened from the library): resolve by name. Still never a
    // dead end — an unresolved name opens the page, which searches for itself.
    final service = ref.read(searchServiceProvider);
    final results = await service.search(widget.artistName, 'artist');
    // Not results.first. Search ranks by popularity, not identity, so the top
    // hit for a name can be a tribute act or a bigger artist with a similar one.
    final match =
        SearchService.pickArtistMatch(results, widget.artistName, (s) => s.title);
    if (!context.mounted) return;
    if (match == null) {
      print('WARN: album artist "${widget.artistName}" matched none of '
          '${results.length} result(s) — opening the page by name: '
          '${results.take(4).map((s) => s.title).join(" | ")}');
    }
    final target = match ??
        Song(
          id: widget.artistName,
          title: widget.artistName,
          artist: widget.artistName,
          image: '',
          duration: '',
        );
    AppNavigation.push(context, ArtistPage(artist: target),
        name: AppNavigation.artistTag(target));
  }

  @override
  Widget build(BuildContext context) {
    // Treat as a single (don't try to resolve an album) when recordType says so,
    // OR when the "album" title is really just the track title (the nav fell back
    // to the song title because no album name was known).
    final isSingle = widget.album.recordType == 'single' ||
        (widget.fallbackTrack != null &&
            widget.album.title.trim().toLowerCase() ==
                widget.fallbackTrack!.title.trim().toLowerCase());
    // When opened from a track (not a genuine single), tell the resolver which
    // track we came from so it can reject a wrong same-artists album.
    final expectTitle = (!isSingle && widget.fallbackTrack != null)
        ? widget.fallbackTrack!.title
        : '';
    final query = AlbumQuery(widget.album.id, widget.album.title,
        widget.artistName, isSingle, expectTrackTitle: expectTitle);
    final tracksAsync = ref.watch(albumTracksProvider(query));
    // Keep the library's stored copy of a LIKED album's tracks in sync — this
    // is what makes a liked album opened from the Library actually show its
    // content (and lets the library compute downloaded/cached badges).
    ref.listen(albumTracksProvider(query), (prev, next) {
      final tracks = next.value;
      if (tracks == null || tracks.isEmpty) return;
      final lib = ref.read(libraryProvider);
      if (!lib.likedAlbums.any((a) => a.title == widget.album.title)) return;
      if ((lib.playlistSongs[widget.album.title]?.length ?? -1) == tracks.length) return;
      ref.read(libraryProvider.notifier).updateAlbumTracks(widget.album.title, tracks);
    });
    final isLiked = ref.watch(libraryProvider.select((s) => s.likedAlbums.any((a) => a.title == widget.album.title)));
    final themeColor = ref.watch(themeProvider);

    // The album name to DISPLAY. widget.album.title is often just the track name
    // the page was navigated with (used only to resolve the album by name), so
    // prefer the real album name carried by the resolved tracks. Falls back to
    // the passed-in title while loading / for genuine singles.
    final resolvedTracks = tracksAsync.value;
    _maybeAutoplay(resolvedTracks);
    final resolvedTitle = (resolvedTracks != null &&
            resolvedTracks.isNotEmpty &&
            resolvedTracks.first.albumTitle.trim().isNotEmpty)
        ? resolvedTracks.first.albumTitle.trim()
        : widget.album.title;

    // The title is unconfirmed until the tracklist lands
    //
    // [resolvedTitle] above says it outright: it PREFERS the album name carried
    // by the resolved tracks and only falls back to what the caller passed. So
    // until those tracks arrive the header is displaying an unverified value —
    // often the TRACK name, when the page was opened from the player.
    //
    // An earlier version tried to be clever and only skeletoned when it could
    // prove the title was wrong (passed title == entry track title). That missed
    // every other way of being unconfirmed, and the wrong text still flashed.
    // Loading means unconfirmed; unconfirmed means skeleton. The cost is a brief
    // shimmer on an album whose tracks were cached, which is what a skeleton is
    // for.
    final titleIsGuess = resolvedTracks == null;

    // Tracks used to decide whether the album is fully downloaded (which
    // disables the Download action). The actual check runs inside a
    // ValueListenableBuilder on AudioCacheManager.cacheEpoch below, so the
    // button flips to "downloaded" the instant the last track finishes.
    final _dlTracks = _effective(resolvedTracks ?? []);

    return DynamicBackground(child: Scaffold(
      backgroundColor: Colors.transparent, 
      body: Stack(
        children: [
            CustomScrollView(
              slivers: [
                // ── Auvy identity header: a LEFT-aligned "record sleeve" — art
                // beside the metadata column — instead of the centered floating
                // cover every other player uses. The type overline (ALBUM /
                // SINGLE / PODCAST) is the app's small-caps voice.
                SliverAppBar(
                  backgroundColor: Colors.transparent,
                  pinned: true,
                  expandedHeight: 316,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  actions: [
                    // (Removed the album "details" info button — it duplicated
                    // what the page already shows and wasn't useful.)
                    IconButton(
                      icon: const Icon(Icons.ios_share_rounded, color: Colors.white, size: 21),
                      onPressed: () => _shareAlbum(context, resolvedTitle),
                    ),
                  ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [themeColor.withOpacity(0.28), Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 56, 20, 18),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  width: 148,
                                  height: 148,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black.withOpacity(0.5),
                                          blurRadius: 24,
                                          offset: const Offset(0, 10)),
                                    ],
                                  ),
                                  // Hold the cover to see it full screen and
                                  // sharp. The tile requests a 148px rung off
                                  // the CDN ladder, so there is nothing here to
                                  // enlarge — the viewer asks for a bigger url.
                                  // See showFullScreenArtwork.
                                  child: HoldToOpen(
                                    // Matches the ClipRRect below, or the charge
                                    // ring cuts across the artwork's corners.
                                    borderRadius: BorderRadius.circular(
                                        ListeningPolicy.roundArtwork(20)),
                                    onHold: () => showFullScreenArtwork(
                                      context,
                                      path: widget.album.image,
                                      caption: widget.album.title,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                          ListeningPolicy.roundArtwork(20)),
                                      child: AuvyImage(
                                          path: widget.album.image,
                                          width: 148,
                                          height: 148,
                                          fit: BoxFit.cover),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 18),
                                Expanded(
                                  child: MaybeShimmer(
                                    active: titleIsGuess || tracksAsync.isLoading,
                                    child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Don't show a guess as if it were the answer
                                      //
                                      // Opened from the player, `album.title` is
                                      // the TRACK name and `recordType` defaults
                                      // to "album". See [resolvedTitle]. Both
                                      // are replaced when the tracklist lands, so
                                      // the header used to display the song's
                                      // name in album type for a second and then
                                      // swap. A shimmer bar says "this is coming"
                                      // instead of asserting something wrong.
                                      if (titleIsGuess) ...const [
                                        ShimmerBox(width: 58, height: 9, radius: 4),
                                        SizedBox(height: 9),
                                        ShimmerBox(width: 210, height: 19, radius: 6),
                                        SizedBox(height: 7),
                                        ShimmerBox(width: 130, height: 19, radius: 6),
                                      ] else ...[
                                      Text(
                                        widget.album.recordType.toUpperCase(),
                                        style: TextStyle(
                                            color: Colors.white.withOpacity(0.66),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2.4),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        resolvedTitle,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 21,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      ],
                                      const SizedBox(height: 8),
                                      GestureDetector(
                                        onTap: () => _goToArtistPage(context),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                widget.artistName,
                                                style: TextStyle(color: themeColor, fontSize: 13.5, fontWeight: FontWeight.w700),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Icon(Icons.chevron_right_rounded, size: 16, color: themeColor),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      tracksAsync.when(
                                        data: (tracks) {
                                          final eff = _effective(tracks);
                                          // Date: prefer a real passed-in value; else the album
                                          // year the browse header stamped onto the fetched
                                          // tracks (fixes "Unknown" when opened from the player
                                          // title tap, which has no year to hand). _AlbumMetaLine
                                          // then upgrades whatever we have to the EXACT release
                                          // day via the first track's player microformat.
                                          final passed = widget.album.releaseDate;
                                          final valid = passed.isNotEmpty && passed != 'Unknown Date' && passed != 'Unknown';
                                          final raw = valid ? passed : (eff.isNotEmpty ? eff.first.releaseDate : '');
                                          return _AlbumMetaLine(
                                            key: ValueKey('meta_${widget.album.id}_${eff.length}'),
                                            rawDate: raw,
                                            trackCount: eff.length,
                                            totalDuration: _totalDurationLabel(eff),
                                            firstTrackId: eff.isNotEmpty ? eff.first.id : null,
                                          );
                                        },
                                        error: (err, stack) => Text("Couldn't load tracks",
                                            style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                                        loading: () => const ShimmerBox(
                                            width: 132, height: 11, radius: 4),
                                      ),
                                    ],
                                  ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── Action row: Play leads, everything else is a quiet circle.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            final tracks = _effective(tracksAsync.value ?? []);
                            if (tracks.isNotEmpty) {
                              HapticService.medium();
                              _recordPlayFromAlbum(tracks.first);
                              // Play the WHOLE album as the queue, with the album
                              // as the playback CONTEXT (matches tapping a track)
                              // so it plays straight through and only tops up with
                              // radio after the album genuinely ends.
                              ref.read(playerProvider.notifier).playSong(
                                tracks.first,
                                newQueue: tracks,
                                source: "Album",
                                locationName: resolvedTitle,
                                contextId: widget.album.id.isNotEmpty
                                    ? widget.album.id
                                    : resolvedTitle,
                                contextType: 'album',
                                contextTitle: resolvedTitle,
                              );
                            }
                          },
                          child: Container(
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: themeColor, borderRadius: BorderRadius.circular(23)),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow_rounded, color: AppColors.matteBlack, size: 22),
                                SizedBox(width: 6),
                                Text("Play",
                                    style: TextStyle(
                                        color: AppColors.matteBlack, fontWeight: FontWeight.w800, fontSize: 14)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _circleAction(
                        icon: Icons.shuffle_rounded,
                        onTap: () {
                          final tracks = _effective(tracksAsync.value ?? []);
                          if (tracks.isNotEmpty) {
                            HapticService.medium();
                            final shuffled = tracks.toList()..shuffle();
                            _recordPlayFromAlbum(shuffled.first);
                            // Same source/context as the Play button — shuffling
                            // an album is still playing FROM that album. Omitting
                            // these fell back to source's "Library" default and a
                            // location of the track's own albumTitle, so the
                            // header read "PLAYING FROM LIBRARY".
                            ref.read(playerProvider.notifier).playSong(
                              shuffled.first,
                              newQueue: shuffled,
                              source: "Album",
                              locationName: resolvedTitle,
                              contextId: widget.album.id.isNotEmpty
                                  ? widget.album.id
                                  : resolvedTitle,
                              contextType: 'album',
                              contextTitle: resolvedTitle,
                            );
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      _circleAction(
                        icon: Icons.queue_music_rounded,
                        onTap: () {
                          // One-shot "queue the album". (The old toggle's
                          // remove path passed parsed SONG IDS into
                          // removeFromQueue(index) — it never removed anything.)
                          final tracks = _effective(tracksAsync.value ?? []);
                          if (tracks.isNotEmpty) {
                            HapticService.medium();
                            ref.read(playerProvider.notifier).addListToQueue(tracks);
                            // Fly the album art into the mini-player (toast
                            // only when there's nothing to fly to).
                            if (!QueueFlyOverlay.flyFrom(context, imageUrl: widget.album.image)) {
                              AnimatedToast.show(context,
                                  text: "Album queued", icon: Icons.queue_music_rounded, color: themeColor);
                            }
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      _circleAction(
                        icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: isLiked ? themeColor : null,
                        onTap: () {
                          HapticService.selection();
                          final lib = ref.read(libraryProvider.notifier);
                          // Store WITH the artist so the library can
                          // resolve/open this album later.
                          final stamped = Album(
                            id: widget.album.id,
                            title: widget.album.title,
                            image: widget.album.image,
                            releaseDate: widget.album.releaseDate,
                            recordType: widget.album.recordType,
                            subtitle: widget.album.subtitle,
                            artist: widget.artistName,
                          );
                          final nowLiked = lib.toggleAlbumLike(stamped, widget.artistName);
                          final tracks = _effective(tracksAsync.value ?? []);
                          if (nowLiked && tracks.isNotEmpty) {
                            lib.updateAlbumTracks(widget.album.title, tracks);
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      ValueListenableBuilder<int>(
                        valueListenable: AudioCacheManager.cacheEpoch,
                        builder: (context, _, __) {
                        final albumFullyDownloaded = _dlTracks.isNotEmpty &&
                            _dlTracks.every((s) =>
                                AudioCacheManager().isExplicitlyDownloaded(s.id));
                        return _circleAction(
                        // Fully downloaded → inert "downloaded" checkmark.
                        icon: albumFullyDownloaded
                            ? Icons.download_done_rounded
                            : Icons.download_rounded,
                        color: albumFullyDownloaded ? themeColor : null,
                        disabled: albumFullyDownloaded,
                        onTap: () async {
                          // Download must NOT start playback (this stray
                          // playSong of the first track was a copy-paste from
                          // the Play button).
                          final tracks = _effective(tracksAsync.value ?? []);
                          final widgetRef = ref;
                          if (!mounted) return;

                          // One bulk download at a time.
                          //
                          // Nothing stopped a second tap. Two runs then drove
                          // the same progress banner, each resetting the other's
                          // counts, and whichever finished first dismissed it
                          // while the other was still going.
                          final running = widgetRef.read(downloadProvider);
                          if (running.isDownloading) {
                            AnimatedToast.show(context,
                                text: 'Already downloading '
                                    '${running.currentItemName}',
                                icon: Icons.downloading_rounded,
                                color: themeColor);
                            return;
                          }

                          // No captured context across the await.
                          //
                          // This held a `scaffoldContext = context` from the
                          // enclosing builder and reused it AFTER the download,
                          // guarded by `mounted`, which is the State's flag, not
                          // that element's. Downloading a whole album takes long
                          // enough for the user to move around: the builder's
                          // element can be gone while this State is still mounted,
                          // and the toast then went to a dead context.
                          //
                          // Using the State's own `context` makes the guard and
                          // the context the same object, which is the only version
                          // of this that is actually safe.
                          AnimatedToast.show(context,
                              text: "Downloading album…", icon: Icons.downloading_rounded, color: themeColor);

                          // File the download under the REAL album name, not the
                          // track-name fallback the page may have been opened with.
                          final album = Album(
                            id: widget.album.id,
                            title: resolvedTitle,
                            image: widget.album.image,
                            releaseDate: widget.album.releaseDate,
                            recordType: widget.album.recordType,
                          );
                          await widgetRef.read(libraryProvider.notifier).downloadAlbumAsPlaylist(
                            album,
                            widget.artistName,
                            tracks,
                          );

                          if (!mounted) return;
                          // message(), not show(): this follows an await, and the
                          // context show() takes is discarded anyway. See the
                          // note on AnimatedToast.show.
                          // THIS SAID "Downloaded to Library" UNCONDITIONALLY.
                          //
                          // Including when tracks failed. A run that saved 15 of
                          // 20 announced itself as a clean success, which is the
                          // exact failure this codebase's own notes say it keeps
                          // having to fix — a partial result reporting as
                          // complete. The count comes from the download state,
                          // set as the run finished.
                          final failed =
                              widgetRef.read(downloadProvider).failedTracks;
                          AnimatedToast.message(failed == 0
                              ? 'Downloaded to Library'
                              : '${tracks.length - failed} of ${tracks.length} '
                                  'saved — retrying the rest');
                        },
                        );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              tracksAsync.when(
                data: (rawTracks) {
                  final tracks = _effective(rawTracks);
                  // One shared mapping for display AND the playback queue.
                  // A track's image can be the ambient-background placeholder
                  // (getHighResImage substitutes it for missing art), so treat
                  // that like "no art" and fall back to the album cover.
                  final fullTracks = tracks.map((song) {
                    final bool songHasArt = song.image.isNotEmpty &&
                        !song.image.contains('avatar_ambient_background');
                    return Song(
                      id: song.id,
                      title: song.title,
                      artist: song.artist,
                      image: songHasArt ? song.image : (widget.album.image.isNotEmpty ? widget.album.image : ''),
                      audioUrl: song.audioUrl,
                      // Use the real album name (not the track-name fallback the
                      // page was navigated with) so played tracks carry it onward.
                      albumTitle: song.albumTitle.trim().isNotEmpty ? song.albumTitle : resolvedTitle,
                      // Prefer the RESOLVED id the browse stamped on the track —
                      // widget.album.id is empty for name-resolved albums, and
                      // carrying the exact id is what lets "View album" later
                      // reopen THIS edition (deluxe vs standard) precisely.
                      albumId: song.albumId.isNotEmpty ? song.albumId : widget.album.id,
                      isExplicit: song.isExplicit,
                      viewCount: song.viewCount,
                    );
                  }).toList();
                  return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      // Conform a few rows ahead. See [warmAhead].
                      warmAhead(ref, fullTracks, index);
                      final fullSong = fullTracks[index];

                      // NO per-tile entry animation here (removed 2026-08-03).
                      //
                      // Each tile used to fade in and rise 15px, staggered 80ms per
                      // index, so the list kept moving VERTICALLY for up to a
                      // second after the route had finished sliding in
                      // HORIZONTALLY. Two motions, different directions, different
                      // durations: reported as "something else is also happening to
                      // the page when it comes". HYDRV's whole premise is that a
                      // navigation is ONE continuous movement, and the route
                      // transition already provides it.
                      //
                      // It was also a bug independent of taste: inside a
                      // `SliverChildBuilderDelegate` a tile is rebuilt every time it
                      // scrolls back into view, and `TweenAnimationBuilder` restarts
                      // from `begin` on a fresh build, so the fade-and-rise
                      // REPLAYED on recycled rows while merely scrolling.
                      return _SwipeableAlbumTrackTile(
                          index: index,
                          song: fullSong,
                          // Spotify behavior: tapping a track queues the REST of
                          // the album after it (playSong slices newQueue at
                          // index), instead of dropping context and letting the
                          // radio top-up refill with recommendations.
                          onTap: () {
                            _recordPlayFromAlbum(fullSong);
                            ref.read(playerProvider.notifier).playSong(
                              fullSong,
                              newQueue: fullTracks,
                              index: index,
                              source: "Album",
                              locationName: resolvedTitle,
                              contextId: widget.album.id.isNotEmpty ? widget.album.id : resolvedTitle,
                              contextType: 'album',
                              contextTitle: resolvedTitle,
                            );
                          },
                            onQueue: (pos) {
                            bool added = ref.read(playerProvider.notifier).toggleQueue(fullSong);
                            AnimatedToast.show(context, text: added ? "Added to Queue" : "Removed from Queue", icon: added ? Icons.queue_music : Icons.remove_circle_outline, color: themeColor, startOffset: pos);
                          },
                          onPlaylist: (pos) => _handleAddToPlaylist(context, ref, fullSong, pos),
                      );
                    },
                    childCount: tracks.length,
                  ),
                );
                },
                // A skeleton shaped like the track list, not a spinner: this page
                // opens instantly from the player with only a title, so the wait
                // is visible and the layout used to jump when the tracks landed.
                loading: () => const AlbumTracksSkeleton(),
                error: (e, s) => SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 50, 40, 20),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 42),
                        const SizedBox(height: 14),
                        const Text("Couldn't load this album",
                            style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: () => ref.invalidate(albumTracksProvider(query)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withOpacity(0.25)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          child: const Text("Retry", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
             // Other editions of THIS album (deluxe ↔ standard). Absent for most
             // albums, so it renders nothing rather than an empty heading.
             _buildOtherVersions(context, themeColor),
             const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ],
    ),
    ),
    );
  }
  /// "Other versions" — the deluxe next to the standard, and back again.
  ///
  /// WHY THIS ROW EXISTS. An artist page lists ONE edition of a release, and
  /// an album search does not dependably surface the other, so a deluxe edition
  /// could be effectively unreachable even though its tracks were searchable.
  /// The album's own browse response names its other editions explicitly — this
  /// is the source's own link between them, and it was already being fetched and
  /// discarded (see [SearchService.getAlbumOtherVersions]).
  ///
  /// Renders NOTHING unless there is something to show: most albums have no other
  /// edition, and a permanent empty heading would be worse than no heading.
  Widget _buildOtherVersions(BuildContext context, Color themeColor) {
    final versions =
        ref.watch(albumOtherVersionsProvider(widget.album.id)).valueOrNull;
    if (versions == null || versions.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OTHER VERSIONS',
              style: TextStyle(
                color: Colors.white.withOpacity(0.66),
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.8,
              ),
            ),
            const SizedBox(height: 12),
            for (final v in versions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      HapticService.light();
                      // MainLayout.smoothRoute, NOT MaterialPageRoute.
                      //
                      // Every page-to-page move in this app goes through
                      // smoothRoute (see AppNavigation.push) — a non-opaque
                      // horizontal transition that composites over the shared
                      // DynamicBackground so the backdrop stays continuous. A
                      // MaterialPageRoute is opaque and animates bottom-up, so it
                      // looked like it came from a different app.
                      //
                      // pushReplacement rather than push: hopping standard →
                      // deluxe → standard would otherwise build a back-stack of
                      // album pages to unwind one tap at a time. The route still
                      // carries its album tag, matching every other album push.
                      Navigator.of(context).pushReplacement(
                        MainLayout.smoothRoute(
                          AlbumPage(album: v, artistName: widget.artistName),
                          name: AppNavigation.albumTag(v),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          AuvyImage(
                            path: v.image,
                            width: 46,
                            height: 46,
                            borderRadius: 9,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  v.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (v.releaseDate.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    v.releaseDate,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.66),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded,
                              color: themeColor.withOpacity(0.7), size: 14),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Delegates to the shared sheet. See [showAddToPlaylistSheet].
  void _handleAddToPlaylist(BuildContext context, WidgetRef ref, Song song, Offset tapPos) {
    showAddToPlaylistSheet(context, ref, song, ref.read(themeProvider),
        toastOrigin: tapPos);
  }

}

class _SwipeableAlbumTrackTile extends ConsumerWidget {
  final int index;
  final Song song;
  final VoidCallback onTap;
  final Function(Offset) onQueue;
  final Function(Offset) onPlaylist;

  const _SwipeableAlbumTrackTile({required this.index, required this.song, required this.onTap, required this.onQueue, required this.onPlaylist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    final cacheManager = AudioCacheManager();
    // Show the audio track's square cover + clean title once resolved; playback
    // still targets the original row (onTap) so queue logic is unchanged.
    final display = conformedForDisplay(ref, song);

    return SwipeActionTile(
      swipeId: song.id,
      onTap: onTap,
      // Press-and-hold opens the song options menu (same ContentMenu as search
      // and home). Passes the ORIGINAL row song, not `display` — every action in
      // the menu (queue, download, playlist) must target the same track playback
      // does, and `display` is a conformed stand-in for artwork/title only.
      // No haptic here: HoldToOpen fires one when the charge completes, and two
      // buzzes for one gesture reads as a stutter.
      onLongPress: () => ContentMenus.showSongMenu(context, song, ref),
      enableTapShrink: true,
      flyImageUrl: song.image,
      // QUEUE IS THE LEFT PILL EVERYWHERE, so adding to the queue is always the
      // same left-to-right swipe whichever page you are on. One direction for
      // the one action you repeat constantly is worth more than pairing each
      // page's actions by how destructive they are.
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  "${index + 1}",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Stack(
                children: [
                  Hero(
                    tag: 'list_artwork_${song.id}',
                    child: AuvyImage(
                        path: display.image,
                        width: densityNow.artwork(48),
                        height: densityNow.artwork(48),
                        borderRadius: 8),
                  ),
                  // Both ids, because an album row is a video entry until its
                  // conform lands while playback swaps to audio at once — see
                  // [NowPlayingArtOverlay].
                  NowPlayingArtOverlay(
                      rowId: song.id,
                      altId: display.id,
                      title: display.title,
                      artist: song.displayArtist),
                ],
              ),
            ],
          ),
          title: Row(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: AudioCacheManager.cacheEpoch,
                builder: (_, __, ___) => cacheManager.isExplicitlyDownloaded(song.id)
                    ? const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.download_done, color: Colors.grey, size: 16))
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: NowPlayingTitle(
                  title: display.title,
                  rowId: song.id,
                  altId: display.id,
                  artist: song.displayArtist,
                ),
              ),
            ],
          ),
          // While THIS track is downloading, the artist line becomes a slim
          // horizontal progress bar (to the right of the cover art); it reverts
          // to the artist the moment the download completes.
          subtitle: TrackDownloadBar(
            songId: song.id,
            fallback: ExplicitArtistLine(
              isExplicit: song.isExplicit == true,
              text: song.displayArtist,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
              badgeSize: 12,
            ),
          ),
          // Play count, the same field on every page. See [trackRowViews].
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

const List<String> _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The album header's `<date> • N songs • duration` line.
///
/// YouTube Music's browse header only publishes a YEAR, which is why this line
/// used to read a bare "2019". The exact release day DOES exist — in the player
/// response's microformat for the album's tracks, so this widget upgrades
/// itself to the full date once the tracklist is in, keeping the year as the
/// immediate (never-blank) value. All tracks of a release share a release day,
/// so the first track is authoritative for the album.
class _AlbumMetaLine extends ConsumerStatefulWidget {
  final String rawDate;
  final int trackCount;
  final String totalDuration;
  final String? firstTrackId;

  const _AlbumMetaLine({
    super.key,
    required this.rawDate,
    required this.trackCount,
    required this.totalDuration,
    required this.firstTrackId,
  });

  @override
  ConsumerState<_AlbumMetaLine> createState() => _AlbumMetaLineState();
}

class _AlbumMetaLineState extends ConsumerState<_AlbumMetaLine> {
  /// "2019-05-17" → "17 May 2019"; a bare year stays a year; junk → ''.
  static String _label(String raw) {
    final r = raw.trim();
    if (r.isEmpty || r.toLowerCase() == 'unknown' || r.toLowerCase() == 'unknown date') {
      return '';
    }
    final parsed = DateTime.tryParse(r);
    if (parsed != null) {
      return '${parsed.day} ${_monthNames[parsed.month - 1]} ${parsed.year}';
    }
    // Not a full date — keep whatever leading year it carries.
    final year = r.split('-').first.trim();
    return year.length == 4 && int.tryParse(year) != null ? year : '';
  }

  String _date = '';

  @override
  void initState() {
    super.initState();
    _date = _label(widget.rawDate);
    _resolveExactDate();
  }

  @override
  void didUpdateWidget(_AlbumMetaLine old) {
    super.didUpdateWidget(old);
    if (old.rawDate != widget.rawDate && _date.length <= 4) {
      _date = _label(widget.rawDate);
    }
    if (old.firstTrackId != widget.firstTrackId) _resolveExactDate();
  }

  /// Best-effort upgrade year → exact day. Silent on failure: the year (or an
  /// empty date) simply stays. Free for anything already played — stream
  /// resolution seeds the same week-long cache.
  Future<void> _resolveExactDate() async {
    final id = widget.firstTrackId;
    // Already showing a full date, or nothing resolvable to work with.
    if (_date.length > 4 || id == null || id.length != 11) return;
    try {
      final exact = await ref
          .read(searchServiceProvider)
          .getTrackReleaseDate(id)
          .timeout(const Duration(seconds: 8));
      if (exact == null || !mounted) return;
      final label = _label(exact);
      if (label.isNotEmpty) setState(() => _date = label);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.trackCount;
    final parts = [
      if (_date.isNotEmpty) _date,
      "$count ${count == 1 ? 'song' : 'songs'}",
      if (widget.totalDuration.isNotEmpty) widget.totalDuration,
    ].join(' • ');
    // WRAPS instead of truncating. A full release date ("17 September 2019") plus
    // song count plus total duration does not fit the header column on one line,
    // and eliding it hid the very information this line exists to show. Two
    // lines is the natural ceiling — the separators give it a clean break point.
    return Text(
      parts,
      maxLines: 2,
      softWrap: true,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
          color: Colors.white.withOpacity(0.66), fontSize: 11.5, height: 1.35),
    );
  }
}
