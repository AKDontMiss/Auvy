import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/swipe_action_tile.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/explicit_badge.dart';
import 'package:auvy/providers/artist_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/services/artist_info_service.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/track_download_overlay.dart'; 
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/presentation/widgets/fullscreen_artwork.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';
import 'package:auvy/presentation/widgets/page_skeletons.dart';
import 'package:auvy/providers/density_provider.dart';

class ArtistPage extends ConsumerWidget {
  final Song artist;
  const ArtistPage({super.key, required this.artist});

  void _shareArtist(BuildContext context, WidgetRef ref) {
    final themeColor = ref.read(themeProvider);
    // The `artist` Song we were opened with often carries an EMPTY or stale
    // image (e.g. an artist row tapped from search). The page header shows the
    // RESOLVED profile picture from the artist provider (`data.image`) — the
    // postcard must use that same resolved art/name, or it renders the empty
    // placeholder. Fall back to the passed-in values when the fetch hasn't
    // landed yet.
    final data = ref.read(artistProvider(artist.artistPageKey)).valueOrNull;
    final resolvedImage =
        (data?.image.isNotEmpty ?? false) ? data!.image : artist.image;
    final resolvedName =
        (data?.name.isNotEmpty ?? false) ? data!.name : artist.title;
    final shareArtist =
        artist.copyWith(image: resolvedImage, title: resolvedName);
    showSharePostcardDialog(context, shareArtist, themeColor,
        kind: PostcardKind.artist);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The portrait, resolved ONCE
    //
    // In order of trustworthiness: the YouTube Music channel header (the
    // picture on the artist's own page), then Deezer's artist portrait — a
    // MUSIC-ONLY catalogue, so unlike a Wikipedia search it cannot hand back
    // a film — then nothing, and AuvyImage draws a placeholder.
    //
    // NOT `resolvedImage`, WHICH FALLS BACK TO THE TRACK ARTWORK. That is
    // correct for the share postcard and wrong here: using a track's cover as
    // an artist portrait is what put a film poster on Jennifer Lopez's page.
    //
    // Shared by the header tile and the hold-to-view-full-screen action, so
    // the picture someone enlarges is always the one they were looking at.
    // The fallback waits for the primary to actually fail
    //
    // This used to read the Deezer portrait in the else-branch of a ternary on
    // `headerData?.image`, which meant it was watched WHILE THE YOUTUBE FETCH
    // WAS STILL IN FLIGHT — headerData is null on the first frame, so the
    // fallback request went out on every artist page open and was thrown away
    // the moment YouTube answered with a picture.
    //
    // Worse, the family key was `headerData?.name ?? artist.title`, and that
    // CHANGES when the resolved name arrives. A second Deezer request, for the
    // same artist, under a different key.
    //
    // Now: ask YouTube, and only if it has SETTLED with nothing does the
    // fallback run — by which point the name is resolved, so the key is stable
    // and one request is the most that can ever be made.
    final headerAsync = ref.watch(artistProvider(artist.artistPageKey));
    final headerData = headerAsync.valueOrNull;
    final ytPortrait = headerData?.image ?? '';

    var portrait = ytPortrait;
    // True while nothing can be drawn yet. Drives a shimmer circle rather than
    // AuvyImage's static placeholder, so the header does not show a grey
    // silhouette and then swap.
    var portraitPending = false;
    if (ytPortrait.isEmpty) {
      if (headerAsync.isLoading) {
        portraitPending = true;
      } else {
        final fallback = ref.watch(
            artistPortraitProvider(headerData?.name ?? artist.title));
        portrait = fallback.valueOrNull ?? '';
        portraitPending = fallback.isLoading;
      }
    }
    // 1. Optimized Provider Usage
    final artistDataAsync = ref.watch(artistProvider(artist.artistPageKey));
    final themeColor = ref.watch(themeProvider);
    final isSubscribed = ref.watch(libraryProvider.select((s) => s.subscribedArtists.any((a) => a.title == artist.title)));
    
    final data = artistDataAsync.valueOrNull;

    return DynamicBackground(child: Scaffold(
      backgroundColor: Colors.transparent, 
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // ── Auvy identity header: a circular artist "medallion" with a
              // themed glow over the ambient backdrop, instead of the
              // Spotify-style full-bleed banner. The name collapses into the
              // pinned bar as you scroll.
              SliverAppBar(
                backgroundColor: Colors.transparent,
                pinned: true,
                expandedHeight: 330,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                actions: [
                  IconButton(
                      icon: const Icon(Icons.ios_share_rounded, color: Colors.white, size: 21),
                      onPressed: () => _shareArtist(context, ref)),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  centerTitle: true,
                  titlePadding: const EdgeInsets.only(left: 54, right: 54, bottom: 14),
                  title: Text(
                    data?.name ?? artist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0, -0.55),
                            radius: 1.1,
                            colors: [themeColor.withOpacity(0.20), Colors.transparent],
                          ),
                        ),
                      ),
                      SafeArea(
                        child: Column(
                          children: [
                            const SizedBox(height: 26),
                            Container(
                              width: 164,
                              height: 164,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.5),
                                boxShadow: [
                                  BoxShadow(color: themeColor.withOpacity(0.30), blurRadius: 54, spreadRadius: 4),
                                  BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 24, offset: const Offset(0, 10)),
                                ],
                              ),
                              child: ClipOval(
                                // Portrait, in order of trustworthiness:
                                //  1. the YouTube Music channel header — the
                                //     picture on the artist's own page
                                //  2. Deezer's artist portrait — a MUSIC-ONLY
                                //     catalogue, so unlike a Wikipedia search it
                                //     cannot hand back a film
                                //  3. nothing, and AuvyImage draws a placeholder
                                //
                                // The TRACK's artwork is deliberately absent
                                // from that list — using it is what put a film
                                // poster on Jennifer Lopez's page.
                                // Hold the portrait to see it full screen and
                                // sharp. The tile only ever requests a 164px
                                // rung off the CDN ladder, so there is nothing
                                // here to enlarge — the viewer asks for a
                                // bigger url. See showFullScreenArtwork.
                                child: HoldToOpen(
                                  // Circular, or the charge ring cuts across
                                  // the portrait's corners.
                                  borderRadius:
                                      BorderRadius.circular(164),
                                  onHold: () => showFullScreenArtwork(
                                    context,
                                    path: portrait,
                                    caption: headerData?.name ?? artist.title,
                                  ),
                                  // A shimmer disc while the portrait is still
                                  // being resolved, rather than AuvyImage's
                                  // static silhouette — that read as "this
                                  // artist has no picture" and then swapped.
                                  child: portraitPending
                                      ? const Shimmer(
                                          child: ShimmerBox(
                                            width: 164,
                                            height: 164,
                                            shape: BoxShape.circle,
                                          ),
                                        )
                                      : AuvyImage(
                                          path: portrait,
                                          width: 164,
                                          height: 164,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text('ARTIST',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.66),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 2.6)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ACTION BAR (Instant)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Row(
                  children: [
                    // Primary action: start an endless ARTIST MIX (Spotify-style).
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (data != null && data.topTracks.isNotEmpty) {
                            HapticService.medium();
                            // Seed with ALL the artist's top songs shuffled (not
                            // just the ~5 shown) and set the ARTIST context so
                            // autoplay top-up keeps weaving in more of this artist
                            // + similar tracks — a live, growing radio instead of
                            // a fixed handful.
                            final pool = data.topTracks.toList()..shuffle();
                            ref.read(playerProvider.notifier).playSong(
                              pool.first,
                              newQueue: pool,
                              source: 'Artist Mix',
                              contextType: 'artist',
                              contextTitle: data.name,
                              contextId: artist.id,
                              locationName: '${data.name} Mix',
                            );
                          }
                        },
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: themeColor,
                            borderRadius: BorderRadius.circular(23),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.shuffle_rounded, color: Colors.black, size: 18),
                              SizedBox(width: 8),
                              Text('Shuffle play',
                                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13.5)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () {
                        HapticService.selection();
                        ref.read(libraryProvider.notifier).toggleArtistSubscription(
                            data?.name ?? artist.title, data?.image ?? artist.image, artist.id);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSubscribed ? Colors.white.withOpacity(0.10) : Colors.transparent,
                          borderRadius: BorderRadius.circular(23),
                          border: Border.all(color: Colors.white.withOpacity(isSubscribed ? 0.10 : 0.30), width: 1.2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(isSubscribed ? Icons.check_rounded : Icons.person_add_alt_1_rounded,
                                color: Colors.white, size: 16),
                            const SizedBox(width: 7),
                            Text(isSubscribed ? "Following" : "Follow",
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // DYNAMIC CONTENT (Appears when ready)
            //
            // Shaped like the body that is coming — a shelf of releases over the
            // top tracks — rather than a spinner. Opening an artist from the
            // player is a cold fetch every time, so this is the state a first
            // visit actually spends its first second in.
            if (artistDataAsync.isLoading && data == null)
              const ArtistBodySkeleton(),

            // Error state with retry — previously an errored fetch left a
            // silently empty page.
            if (artistDataAsync.hasError && data == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 60, 40, 20),
                  child: Column(
                    children: [
                      const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 42),
                      const SizedBox(height: 14),
                      const Text("Couldn't load this artist",
                          style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () => ref.invalidate(artistProvider(artist.artistPageKey)),
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

            if (data != null) ...[
              // Who this is, before what they made.
              //
              // This card used to sit at the very BOTTOM of the page, below
              // every release shelf, where a first-time visitor never reached
              // it. Its own comment claimed the placement was "prominent and
              // noticeable", which it had not been for some time.
              //
              // Here it answers what the page opens with: who is this, and how
              // big are they. Kept deliberately SHORT in this position — two
              // lines, tap to expand, so it introduces the artist without
              // pushing their music below the fold.
              //
              // Rendered unconditionally: when YouTube has no blurb the card
              // falls back to a Wikipedia summary, and hides itself only when
              // neither source has anything.
              SliverToBoxAdapter(
                child: _ArtistBioCard(
                  artistName: data.name,
                  description: data.description,
                  subscriberCount: data.subscriberCount,
                  themeColor: themeColor,
                ),
              ),

              // 1. TOP SONGS
              _buildSectionHeader(context, "Top songs", null),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = data.topTracks[index];
                    
                    // NO per-tile "slide + fade" entry animation (removed
                    // 2026-08-03). See the matching note in album_page.dart. It
                    // rose 20px per row, staggered 100ms, so the list kept moving
                    // VERTICALLY long after the route had finished sliding in
                    // HORIZONTALLY; and because these tiles live in a lazy
                    // `SliverChildBuilderDelegate`, the animation restarted every
                    // time a row scrolled back into view.
                    return _SwipeableArtistSongTile(
                        song: song,
                        rank: index + 1,
                        onTap: () => ref.read(playerProvider.notifier).playSong(
                          song,
                          // Spotify behavior: the artist's remaining top tracks
                          // queue up after the tapped one instead of the queue
                          // refilling from recommendations right away.
                          newQueue: data.topTracks,
                          source: "Artist",
                          locationName: data.name,
                          contextType: "artist",
                          contextTitle: data.name,
                        ),
                        onQueue: (pos) {
                          bool added = ref.read(playerProvider.notifier).toggleQueue(song);
                          AnimatedToast.show(context, text: added ? "Added to Queue" : "Removed from Queue", icon: added ? Icons.queue_music : Icons.remove_circle_outline, color: themeColor, startOffset: pos);
                        },
                        onPlaylist: (pos) => _handleAddToPlaylist(context, ref, song, pos),
                    );
                  },
                  childCount: data.topTracks.length > 5 ? 5 : data.topTracks.length,
                ),
              ),

              // 2. ALBUMS
              if (data.albums.isNotEmpty) ...[
                _buildSectionHeader(context, "Albums", () => _navigateToViewAll(context, "Albums", data.albums, data.name)),
                _buildHorizontalList(context, data.albums, data.name),
              ],

              // 3. SINGLES & EPs
              if (data.singles.isNotEmpty) ...[
                _buildSectionHeader(context, "Singles & EPs", () => _navigateToViewAll(context, "Singles & EPs", data.singles, data.name)),
                _buildHorizontalList(context, data.singles, data.name),
              ],

              // 4. LIVE PERFORMANCES
              if (data.liveAlbums.isNotEmpty) ...[
                _buildSectionHeader(context, "Live performances", () => _navigateToViewAll(context, "Live performances", data.liveAlbums, data.name)),
                _buildHorizontalList(context, data.liveAlbums, data.name),
              ],

              // 4b. FEATURED ON — albums / compilations the artist appears on
              if (data.featuredAlbums.isNotEmpty) ...[
                _buildSectionHeader(context, "Featured on", () => _navigateToViewAll(context, "Featured on", data.featuredAlbums, data.name)),
                _buildHorizontalList(context, data.featuredAlbums, data.name),
              ],

              // 5. ARTIST PLAYLISTS (Restored Section)
              if (data.playlists.isNotEmpty) ...[
                _buildSectionHeader(context, "Artist Playlists", null),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 210,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: data.playlists.length,
                      itemBuilder: (context, index) {
                        final p = data.playlists[index];
                        return GestureDetector(
                          onTap: () => AppNavigation.push(
                            context,
                            PlaylistPage(
                              externalId: p.id,
                              externalTitle: p.title,
                              externalImage: p.image,
                              externalSubtitle: p.artist,
                              isAlbumView: false,
                            ),
                            name: AppNavigation.playlistTag(p.id),
                          ),
                          child: Container(width: 140, margin: const EdgeInsets.only(right: 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ClipRRect(borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)), child: AuvyImage(path: p.image, width: 140, height: 140, fit: BoxFit.cover)), const SizedBox(height: 8), Text(p.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis), Text(p.artist, style: const TextStyle(color: Colors.white54, fontSize: 12))])),
                        );
                      },
                    ),
                  ),
                ),
              ],

              // 6. RELATED ARTISTS (Restored Section)
              if (data.relatedArtists.any((a) => a.image.isNotEmpty && a.image != 'null')) ...[
                _buildSectionHeader(context, "Fans might also like", null),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 220, 
                    child: Builder(
                      builder: (context) {
                        //  FIX 3: Strictly filter out any related artists that do not have an image
                        final validRelated = data.relatedArtists.where((a) => a.image.isNotEmpty && a.image != 'null').toList();
                        
                        return ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: validRelated.length,
                          itemBuilder: (context, index) {
                            final relArtist = validRelated[index];
                            return GestureDetector(
                              onTap: () => AppNavigation.push(
                                context,
                                ArtistPage(artist: relArtist),
                                name: AppNavigation.artistTag(relArtist),
                              ),
                              child: Container(
                                width: 140, 
                                margin: const EdgeInsets.only(right: 16),
                                child: Column(
                                  children: [
                                    ClipOval( 
                                      child: AuvyImage(
                                        path: relArtist.image, 
                                        width: 140, 
                                        height: 140, 
                                        fit: BoxFit.cover
                                      )
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      relArtist.title, 
                                      style: const TextStyle(
                                        color: Colors.white, 
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ), 
                                      maxLines: 2, 
                                      overflow: TextOverflow.ellipsis, 
                                      textAlign: TextAlign.center
                                    )
                                  ]
                                ),
                              ),
                            );
                          },
                        );
                      }
                    ),
                  ),
                ),
              ],
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
        ],
      ),
    ),
    );
  }

  // Auvy's section voice: quiet small-caps overlines (the app's menu/details
  // language) instead of the big bold headers every other player uses.
  Widget _buildSectionHeader(BuildContext context, String title, VoidCallback? onViewAll) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 30, 20, 12),
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
            if (onViewAll != null)
              GestureDetector(
                onTap: () {
                  HapticService.selection();
                  onViewAll();
                },
                child: Row(
                  children: [
                    Text('SEE ALL',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2)),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 17),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalList(BuildContext context, List<Album> items, String artistName) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 210,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // NO CAP. A CAP HERE READS AS A MISSING RELEASE.
          //
          // This was 10, then 25, and both hid real records. Verified against
          // YouTube Music's own grids for The Weeknd: 13 albums and 63
          // singles/EPs. Sections are sorted newest-first, so a 25-item cap
          // silently cuts everything older than roughly the last few years —
          // "My Dear Melancholy," (2018) sat around position 40 and was
          // unreachable, which looks exactly like the app failing to fetch it,
          // especially when search finds it immediately.
          //
          // The cap bought nothing: this is a ListView.builder, so it only ever
          // builds the handful of tiles actually on screen. Capping the itemCount
          // of a lazy list does not save work, it just truncates the data.
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return GestureDetector(
              onTap: () => _openAlbumOrPlaylist(context, item, artistName),
              child: Container(
                width: 140, margin: const EdgeInsets.only(right: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ClipRRect(borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(14)), child: AuvyImage(path: item.image, width: 140, height: 140, fit: BoxFit.cover)), const SizedBox(height: 8), Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis), Text(item.displaySubtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12))]),
              ),
            );
          },
        ),
      ),
    );
  }

  void _navigateToViewAll(BuildContext context, String title, List<Album> items, String artistName) {
    AppNavigation.push(context, _SectionViewAllPage(title: title, items: items, artistName: artistName));
  }
}

// Widget representing the full-list view for a specific discography section.
class _SectionViewAllPage extends StatelessWidget {
  final String title;
  final List<Album> items;
  final String artistName;

  const _SectionViewAllPage({required this.title, required this.items, required this.artistName});

  @override
  Widget build(BuildContext context) {
    return DynamicBackground(child: Scaffold(
      backgroundColor: Colors.transparent, 
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            // Was a flat 16 at the bottom, which is a large fixed gap and the
            // single biggest reason this list ignored the density setting.
            contentPadding:
                EdgeInsets.only(bottom: 4 + densityNow.rowVerticalPadding),
            leading: ClipRRect(
                borderRadius: BorderRadius.circular(
                    ListeningPolicy.roundArtwork(4)),
                child: AuvyImage(
                    path: item.image,
                    width: densityNow.artwork(56),
                    height: densityNow.artwork(56),
                    fit: BoxFit.cover)),
            title: Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
            subtitle: Text(item.displaySubtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
            onTap: () => _openAlbumOrPlaylist(context, item, artistName),
          );
        },
      ),
    )
    );
  }
}

/// Open a discography item to the CORRECT destination. Playlists (incl. those
/// in "Featured on") must go to the PlaylistPage — the album browse endpoint
/// returns nothing for a playlist id, which is why those tiles opened empty.
/// Everything else is an album/single/EP and opens the AlbumPage.
void _openAlbumOrPlaylist(BuildContext context, Album item, String artistName) {
  if (item.recordType == 'playlist') {
    AppNavigation.push(
      context,
      PlaylistPage(
        externalId: item.id,
        externalTitle: item.title,
        externalImage: item.image,
        externalSubtitle: item.displaySubtitle,
        isAlbumView: false,
      ),
      name: AppNavigation.playlistTag(item.id),
    );
  } else {
    AppNavigation.push(context, AlbumPage(album: item, artistName: artistName),
        name: AppNavigation.albumTag(item));
  }
}
/// Delegates to the shared sheet. See [showAddToPlaylistSheet].
void _handleAddToPlaylist(BuildContext context, WidgetRef ref, Song song, Offset tapPos) {
  showAddToPlaylistSheet(context, ref, song, ref.read(themeProvider),
      toastOrigin: tapPos);
}


class _SwipeableArtistSongTile extends ConsumerWidget {
  final Song song;
  final VoidCallback onTap;
  final Function(Offset) onQueue;
  final Function(Offset) onPlaylist;
  /// Chart position within "Top songs" (1-based). Rendered as a quiet numeral
  /// before the artwork — part of Auvy's ranked-list identity.
  final int? rank;

  const _SwipeableArtistSongTile({
    required this.song,
    required this.onTap,
    required this.onQueue,
    required this.onPlaylist,
    this.rank,
  });

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
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (rank != null) ...[
                SizedBox(
                  width: 20,
                  child: Text(
                    '$rank',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Stack(
                children: [
                  AuvyImage(
                      path: display.image,
                      width: densityNow.artwork(50),
                      height: densityNow.artwork(50),
                      borderRadius: 8),
                  // Under the cache badge, so a downloaded track still shows its
                  // tick while playing.
                  NowPlayingArtOverlay(
                      rowId: song.id,
                      altId: display.id,
                      title: display.title,
                      artist: song.displayArtist,
                      size: 50),
                  // Cache badge updates live as tracks stream into the cache
                  // (cacheEpoch) instead of only on a full page rebuild.
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: ValueListenableBuilder<int>(
                      valueListenable: AudioCacheManager.cacheEpoch,
                      builder: (_, __, ___) => cacheManager.isCached(song.id)
                          ? Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.grey[800],
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.grey[900]!, width: 1),
                              ),
                              child: const Icon(Icons.check, color: Colors.grey, size: 10),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ],
          ),
          title: Row(
            children: [
              if (cacheManager.isExplicitlyDownloaded(song.id)) ...[
                const Icon(Icons.download_done, color: Colors.grey, size: 16),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: NowPlayingTitle(
                  title: display.title,
                  rowId: song.id,
                  altId: display.id,
                  artist: song.displayArtist,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          subtitle: TrackDownloadBar(
            songId: song.id,
            fallback: ExplicitArtistLine(
              isExplicit: song.isExplicit == true,
              text: song.displayArtist,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
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

/// Sleek, prominent "About" card for the artist page. Features subscriber counts,
/// a smooth expanding bio, and source attribution to look legitimate.
class _ArtistBioCard extends ConsumerStatefulWidget {
  final String artistName;
  final String description;
  final String subscriberCount;
  final Color themeColor;

  const _ArtistBioCard({
    required this.artistName,
    required this.description,
    required this.subscriberCount,
    required this.themeColor,
  });

  @override
  ConsumerState<_ArtistBioCard> createState() => _ArtistBioCardState();
}

class _ArtistBioCardState extends ConsumerState<_ArtistBioCard> {
  bool _expanded = false;

  // YouTube blurbs under this length are usually a single marketing line —
  // worth upgrading with the Wikipedia summary.
  static const int _thinBioLength = 120;

  @override
  Widget build(BuildContext context) {
    final ytBio = widget.description.trim();
    final needsWiki = ytBio.length < _thinBioLength;
    // Only reaches for Wikipedia when YouTube's blurb is missing/thin.
    final wiki = needsWiki
        ? ref.watch(artistWikiBioProvider(widget.artistName)).asData?.value
        : null;

    final String bioText;
    final String source;
    if (wiki != null && wiki.extract.length > ytBio.length) {
      bioText = wiki.extract;
      source = "Source: ${wiki.source}";
    } else {
      bioText = ytBio;
      source = "Source: YouTube Music";
    }
    // Neither source has anything worth a card.
    if (bioText.isEmpty && widget.subscriberCount.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    // Split into the FIGURE and its unit so they can be typeset separately —
    // "1.2M" large, "subscribers" small underneath. YouTube hands this over
    // already worded ("1.2M subscribers") or as a bare count, so both shapes
    // have to be understood rather than assumed.
    final subs = widget.subscriberCount.trim();
    final subsCount = subs.isEmpty
        ? ''
        : subs.split(RegExp(r'\s+')).first;
    final subsUnit = subs.isEmpty
        ? ''
        : (subs.toLowerCase().contains('subscriber') ? 'SUBSCRIBERS' : 'LISTENERS');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selection();
        setState(() => _expanded = !_expanded);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          // QUIETER THAN IT WAS, because it now sits directly under the header
          // rather than alone at the bottom of the page. A 10% accent wash was
          // fine as a closing panel and competes with the artwork up here, so
          // this is a plain surface with a hairline, and the accent appears only
          // on the label and the chevron.
          color: Colors.white.withOpacity(_expanded ? 0.055 : 0.035),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Colors.white.withOpacity(_expanded ? 0.10 : 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // THE AUDIENCE SIZE IS THE HEADLINE, not a chip in the corner.
            //
            // It is the one fact on this card someone actually scans for, and as
            // a 9.5px all-caps pill it was the smallest text in the panel. Here
            // it reads as a figure with a label under it, the way a stat should,
            // and "ABOUT" steps back to a quiet eyebrow beside it.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (subsCount.isNotEmpty) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        subsCount,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        subsUnit,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.50),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Container(
                      width: 1,
                      height: 26,
                      color: Colors.white.withOpacity(0.08)),
                  const SizedBox(width: 14),
                ],
                Icon(Icons.info_outline_rounded,
                    color: widget.themeColor.withOpacity(0.9), size: 14),
                const SizedBox(width: 6),
                Text(
                  "ABOUT",
                  style: TextStyle(
                    color: widget.themeColor.withOpacity(0.9),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const Spacer(),
                // One affordance instead of two. The old card had a "Read more"
                // text button AND was tappable anywhere; a rotating chevron says
                // the same thing without a second control to reason about.
                if (bioText.isNotEmpty)
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.keyboard_arrow_down_rounded,
                        color: Colors.white.withOpacity(0.55), size: 22),
                  ),
              ],
            ),
            if (bioText.isNotEmpty) ...[
              const SizedBox(height: 12),

              // Expandable Text
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Text(
                  bioText,
                  // Two lines collapsed, not three: this now sits above the
                  // music rather than below it, and every line here is a line
                  // the artist's own tracks move down the screen.
                  maxLines: _expanded ? null : 2,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.74),
                    fontSize: 13.5,
                    height: 1.55,
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Attribution only. The READ MORE / SHOW LESS button that used to
              // sit here is gone: the chevron in the header already says the
              // card expands, the whole card has always been tappable, and two
              // controls for one action is one too many. It also let the footer
              // shrink to a single quiet line.
              //
              // The source stays. A biography that silently switches between
              // YouTube Music and Wikipedia without saying which is worse than
              // no attribution — the two read very differently.
              Text(
                source,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}