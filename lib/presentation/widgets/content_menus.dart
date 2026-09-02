import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/presentation/widgets/song_details_sheet.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/logic/download_helper.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';
import 'package:auvy/presentation/widgets/quick_action_cell.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:image_picker/image_picker.dart';

// Public API — same signatures as before, no call-sites need changing

class ContentMenus {
  static void showSongMenu(BuildContext context, Song song, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      isScrollControlled: true,
      builder: (_) => _SongMenuSheet(song: song, parentContext: context), 
    );
  }

  static Future<void> showSongMenuAsync(
          BuildContext context, Song song, WidgetRef ref) async =>
      showSongMenu(context, song, ref);

  /// Build the [Album] a track's "View Album" should open. Shared by every
  /// menu (3-dot sheet, player menu, queue swipe) so they all behave the same:
  ///  • real browse id → open the album directly;
  ///  • no id but a REAL album NAME (differs from the track title) → let the
  ///    AlbumPage resolve the album by name (recordType 'album'). The old code
  ///    marked these 'single', which skipped name resolution entirely — that
  ///    was the "View Album doesn't work" bug;
  ///  • neither → a genuine single: the AlbumPage shows the track itself.
  static Album buildAlbumForSong(Song song) {
    final bool hasRealAlbum =
        song.albumId.isNotEmpty && song.albumId != 'null' && song.albumId != song.id;
    final t = song.albumTitle.trim();
    final bool hasAlbumName = t.isNotEmpty &&
        t != 'null' &&
        t.toLowerCase() != 'single' &&
        t.toLowerCase() != song.title.trim().toLowerCase();
    // diagnose "wrong album from a track" (#11): shows whether we open the
    // track's own albumId directly (source data) vs resolve by name/track.
    print('buildAlbumForSong "${song.title}" by ${song.artist}: '
        'songAlbumId="${song.albumId}" albumTitle="${song.albumTitle}" '
        '→ hasRealAlbum=$hasRealAlbum hasAlbumName=$hasAlbumName');
    return Album(
      id: hasRealAlbum ? song.albumId : song.id,
      title: hasAlbumName ? t : song.title,
      image: song.image,
      releaseDate: song.releaseDate.isNotEmpty ? song.releaseDate : 'Unknown',
      recordType: (hasRealAlbum || hasAlbumName) ? 'album' : 'single',
    );
  }

  /// Split a combined artist credit ("A, B & C", "A feat. B", "A x B") into
  /// the individual artist names, deduped, order preserved.
  static List<String> splitArtists(String raw) {
    final parts = raw
        .split(RegExp(
          r'\s*(?:,|;|&|\+|/)\s*|\s+(?:feat\.?|ft\.?|featuring|x|×)\s+',
          caseSensitive: false,
        ))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final seen = <String>{};
    final out = <String>[];
    for (final p in parts) {
      if (seen.add(p.toLowerCase())) out.add(p);
    }
    return out.isEmpty ? [raw.trim()] : out;
  }

  /// Which artist does the user mean? Single-artist tracks resolve instantly;
  /// multi-artist tracks show a picker sheet listing every credited artist.
  /// Returns the chosen artist name, or null if dismissed.
  static Future<String?> pickArtist(BuildContext context, Song song) async {
    final source = song.artist.isNotEmpty ? song.artist : song.displayArtist;
    final artists = splitArtists(source);
    if (artists.length <= 1) return artists.isEmpty ? null : artists.first;
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => _ArtistPickerSheet(song: song, artists: artists),
    );
  }

  /// Best artist-page target id for [name] as credited on [song]: prefer the
  /// song's OWN linked channel id, else resolve the SPECIFIC artist behind the
  /// track (so two same-named artists — e.g. two "Xenia"s — don't collide),
  /// else fall back to the plain name (ArtistPage then name-searches). The
  /// return value is exactly what `ArtistPage`'s `artist.id` expects.
  static Future<String> resolveArtistTarget(
      WidgetRef ref, Song song, String name) async {
    bool sameName(String a, String b) {
      final x = a.toLowerCase().trim(), y = b.toLowerCase().trim();
      return x == y || x.contains(y) || y.contains(x);
    }

    for (final a in song.artists) {
      if (a.id.startsWith('UC') && sameName(a.name, name)) return a.id;
    }
    final resolved = await ref
        .read(searchServiceProvider)
        .resolveArtistIdForTrack(song.title, name);
    return (resolved != null && resolved.startsWith('UC')) ? resolved : name;
  }

}

// Song menu sheet

class _SongMenuSheet extends ConsumerWidget {
  final Song song;
  final BuildContext parentContext; 
  const _SongMenuSheet({required this.song, required this.parentContext});

  // Helper: Shows the user's custom playlists to add the song to
  /// Delegates to the shared sheet. See [showAddToPlaylistSheet]. This used to
  /// be one of FIVE hand-rolled copies; among other things this one dropped the
  /// duplicate result on the floor and reported "Added" either way, and offered
  /// no way to create a playlist.
  static void _showAddToPlaylistSheet(BuildContext context, WidgetRef ref, Song song, Color themeColor) {
    showAddToPlaylistSheet(context, ref, song, themeColor);
  }

  // Helper: Navigate to Album Page
  static void _navigateToAlbum(BuildContext context, BuildContext parentCtx, WidgetRef ref, Song song) {
    final album = ContentMenus.buildAlbumForSong(song);
    // Shared standard: land in the active tab's stack (nav bar + mini-player
    // stay visible), never stacking a duplicate of the album already on top.
    AppNavigation.pushOnActiveTab(
      AlbumPage(album: album, artistName: song.artist, fallbackTrack: song),
      name: AppNavigation.albumTag(album),
    );
  }

  // Helper: Navigate to Artist Page
  // Multi-artist tracks first show a picker so the user chooses WHICH artist
  // they meant; single-artist tracks navigate straight away.
  static Future<void> _navigateToArtist(
      BuildContext context, BuildContext parentCtx, WidgetRef ref, Song song) async {
    final chosen = await ContentMenus.pickArtist(parentCtx, song);
    if (chosen == null) return;
    // Resolve the SPECIFIC artist channel (disambiguates same-named artists).
    final targetId = await ContentMenus.resolveArtistTarget(ref, song, chosen);
    final artistPseudoSong = Song(
      id: targetId,
      title: chosen,
      artist: chosen,
      image: song.image,
    );
    AppNavigation.pushOnActiveTab(
      ArtistPage(artist: artistPseudoSong),
      name: AppNavigation.artistTag(artistPseudoSong),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return _GlassSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          // Hero Header
          // Sized to identify the track, not to re-display it — the artwork is
          // already on screen behind the sheet. 56px keeps two lines of title
          // legible; the old 64 with 20px of bottom padding was a poster.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 16, 14),
            child: Row(
              children: [
                Hero(
                  tag: 'menu_art_${song.id}',
                  child: Container(
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))
                      ]
                    ),
                    child: _Artwork(path: song.image, size: 56),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              height: 1.2)),
                      const SizedBox(height: 3),
                      Text(song.displayArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.78),
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                _HeaderLikeButton(song: song, themeColor: themeColor),
              ],
            ),
          ),
          
          Divider(color: Colors.white.withOpacity(0.07), height: 1, indent: 24, endIndent: 24),

          // Quick actions
          // The one-tap, no-navigation actions, laid out ACROSS instead of down.
          // Nine stacked rows is what made this sheet fill the screen, and four of
          // them (Play next, Queue, Download, Share) were single verbs with no
          // submenu and no state to read — exactly the shape a strip of icon+label
          // cells serves better than a list. (Other music apps reach for the same
          // GridMenu here.) The list below keeps only the actions that lead
          // somewhere.
          _QuickActionStrip(
              song: song, parentContext: parentContext, themeColor: themeColor),

          Divider(color: Colors.white.withOpacity(0.06), height: 14, indent: 24, endIndent: 24),

          _MenuTile(
            icon: Icons.library_add_rounded,
            iconColor: Colors.white70,
            label: 'Add to Playlist',
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
            onTap: () { 
              HapticService.selection(); 
              Navigator.pop(context); 
              _showAddToPlaylistSheet(context, ref, song, themeColor); 
            },
          ),
          _MenuTile(
            icon: Icons.album_rounded,
            iconColor: Colors.white70,
            label: 'View Album',
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
            onTap: () { 
              HapticService.light(); 
              Navigator.pop(context); // Close the sheet
              _navigateToAlbum(context, parentContext, ref, song); // Navigate beneath the MiniPlayer
            },
          ),
          _MenuTile(
            icon: Icons.person_rounded,
            iconColor: Colors.white70,
            label: 'View Artist',
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
            onTap: () { 
              HapticService.light(); 
              Navigator.pop(context); // Close the sheet
              _navigateToArtist(context, parentContext, ref, song); // Navigate beneath the MiniPlayer
            },
          ),
          
          // Manual cover-art fix. Present on every track, not only ones that look
          // wrong — the app has no way to know a cover is wrong, which is exactly
          // why the override exists (see [ArtworkOverrideNotifier]).
          Consumer(builder: (context, ref, _) {
            final hasOverride = ref.watch(
                artworkOverrideProvider.select((m) => m.containsKey(song.id)));
            return _MenuTile(
              icon: hasOverride
                  ? Icons.image_not_supported_outlined
                  : Icons.image_rounded,
              iconColor: hasOverride ? Colors.orangeAccent : Colors.white70,
              label: hasOverride ? 'Reset artwork' : 'Change artwork',
              onTap: () async {
                HapticService.selection();
                Navigator.pop(context);
                final notifier = ref.read(artworkOverrideProvider.notifier);
                if (hasOverride) {
                  await notifier.clearOverride(song.id);
                  AnimatedToast.message('Artwork reset');
                  return;
                }
                final picked = await ImagePicker()
                    .pickImage(source: ImageSource.gallery);
                if (picked == null) return; // cancelled — say nothing
                final ok = await notifier.setOverride(song.id, picked.path);
                // Report the OUTCOME: a failed copy used to be indistinguishable
                // from a cover that just hadn't refreshed yet.
                AnimatedToast.message(
                    ok ? 'Artwork updated' : "Couldn't use that image");
              },
            );
          }),
          _MenuTile(
            icon: Icons.info_outline_rounded,
            iconColor: Colors.white70,
            label: 'Song details',
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
            onTap: () {
              HapticService.selection();
              Navigator.pop(context);
              showSongDetailsSheet(parentContext, ref, song);
            },
          ),
          _MenuTile(
            icon: Icons.block_rounded,
            iconColor: Colors.redAccent,
            label: 'Don\'t play this',
            onTap: () {
              HapticService.heavy();
              Navigator.pop(context);
              // Route through the player's dontRecommend: it blacklists in BOTH
              // the intelligence layer (recommendations) AND the player layer
              // (queue), removes the track from every active queue, and skips it
              // if it's currently playing. markAsNotInterested alone only updated
              // recommendations, so a disliked song kept playing from the queue.
              ref.read(playerProvider.notifier).dontRecommend(song);
              AnimatedToast.show(context, text: '${song.title} hidden', icon: Icons.block_rounded, color: Colors.redAccent);
            },
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }
}
/// The one-tap actions, laid out ACROSS the sheet as icon+label cells.
///
/// Every action here is a single verb that finishes immediately and opens
/// nothing, which is what makes a strip the right shape for them. Moving them
/// out of the vertical list is what let the list rows keep comfortable spacing
/// while the sheet still stops well short of covering the page.
class _QuickActionStrip extends ConsumerWidget {
  final Song song;
  final BuildContext parentContext;
  final Color themeColor;

  const _QuickActionStrip({
    required this.song,
    required this.parentContext,
    required this.themeColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<int>(
      valueListenable: AudioCacheManager.cacheEpoch,
      builder: (context, _, __) {
        final downloaded = AudioCacheManager().isExplicitlyDownloaded(song.id);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
          child: Row(
            children: [
              QuickActionCell(
                icon: Icons.queue_play_next_rounded,
                label: 'Play next',
                color: themeColor,
                onTap: () {
                  HapticService.selection();
                  Navigator.pop(context);
                  if (!ref
                      .read(listenTogetherProvider.notifier)
                      .requestQueueAdd(song, playNext: true)) {
                    ref.read(playerProvider.notifier).addToQueueNext(song);
                  }
                  if (!QueueFlyOverlay.flyFrom(parentContext, imageUrl: song.image)) {
                    AnimatedToast.show(context,
                        text: 'Playing next',
                        icon: Icons.queue_play_next_rounded,
                        color: themeColor);
                  }
                },
              ),
              QuickActionCell(
                icon: Icons.playlist_add_rounded,
                label: 'Queue',
                color: themeColor,
                onTap: () {
                  HapticService.selection();
                  // Read BEFORE the add, or the answer is always "already there".
                  // Without this the menu reported success unconditionally, so a
                  // song the queue already held looked like it had been added.
                  final already =
                      ref.read(playerProvider.notifier).isPendingInQueue(song);
                  Navigator.pop(context);
                  if (!ref
                      .read(listenTogetherProvider.notifier)
                      .requestQueueAdd(song)) {
                    ref.read(playerProvider.notifier).addToQueue(song);
                  }
                  // Same fly-to-mini-player ghost as swipe-to-queue; toast only
                  // when there's no mini-player to fly to. A no-op always gets
                  // the toast — the ghost would read as "done".
                  if (already) {
                    AnimatedToast.show(context,
                        text: 'Already in queue',
                        icon: Icons.playlist_add_check,
                        color: themeColor);
                  } else if (!QueueFlyOverlay.flyFrom(parentContext,
                      imageUrl: song.image)) {
                    AnimatedToast.show(context,
                        text: 'Added to queue',
                        icon: Icons.check_circle,
                        color: themeColor);
                  }
                },
              ),
              // One cell, two states — a downloaded track offers to un-download
              // rather than showing a dead "Download" it would silently ignore.
              QuickActionCell(
                icon: downloaded
                    ? Icons.delete_outline_rounded
                    : Icons.download_rounded,
                label: downloaded ? 'Remove' : 'Download',
                color: downloaded ? Colors.orangeAccent : Colors.blueAccent,
                onTap: () async {
                  HapticService.medium();
                  Navigator.pop(context);
                  if (downloaded) {
                    // Deletes the on-disk file too (removeFromCache unlinks it).
                    AudioCacheManager().removeFromCache(song.id);
                    ref.read(libraryProvider.notifier).refreshDownloadsFolder();
                    AnimatedToast.show(context,
                        text: 'Download removed',
                        icon: Icons.delete_outline_rounded,
                        color: Colors.orangeAccent);
                    return;
                  }
                  AnimatedToast.show(context,
                      text: 'Downloading...',
                      icon: Icons.downloading_rounded,
                      color: Colors.blueAccent);
                  // Report the OUTCOME. This used to fire and forget, so a failed
                  // download's only trace was a "Downloading..." toast and a track
                  // that never appeared.
                  final r = await DownloadHelper.downloadCollection([song]);
                  AnimatedToast.message(r.summary);
                },
              ),
              QuickActionCell(
                icon: Icons.ios_share_rounded,
                label: 'Share',
                color: Colors.white70,
                onTap: () {
                  HapticService.selection();
                  Navigator.pop(context);
                  showSharePostcardDialog(context, song, themeColor);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeaderLikeButton extends ConsumerWidget {
  final Song song;
  final Color themeColor;
  const _HeaderLikeButton({required this.song, required this.themeColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLiked = ref.watch(libraryProvider.select((l) => l.likedSongIds.contains(song.id)));
    return GestureDetector(
      onTap: () {
        HapticService.selection();
        ref.read(libraryProvider.notifier).toggleSongLike(song);
      },
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
          child: Icon(
            isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: ValueKey(isLiked),
            color: isLiked ? themeColor : Colors.white.withOpacity(0.4),
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      splashColor: Colors.white.withOpacity(0.04),
      highlightColor: Colors.white.withOpacity(0.03),
      child: Padding(
        // Comfortable, NOT compressed. Shrinking these rows was the wrong way to
        // make the sheet smaller — it bought height at the cost of every row
        // feeling cramped. The height now comes off the ITEM COUNT instead: five
        // of the nine actions moved up into [_QuickActionStrip], so these rows get
        // to keep their breathing room.
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500)),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// Artist picker sheet — shown when a track credits multiple artists and the
// user taps "View Artist": lists every artist so they choose the one they mean.

class _ArtistPickerSheet extends StatelessWidget {
  final Song song;
  final List<String> artists;
  const _ArtistPickerSheet({required this.song, required this.artists});

  @override
  Widget build(BuildContext context) {
    return _GlassSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 4),
            child: Row(
              children: [
                const Icon(Icons.person_search_rounded, color: Colors.white70, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Which artist?',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 12),
              ),
            ),
          ),
          Divider(color: Colors.white.withOpacity(0.07), height: 1, indent: 24, endIndent: 24),
          const SizedBox(height: 6),
          for (final name in artists)
            _MenuTile(
              icon: Icons.person_rounded,
              iconColor: Colors.white70,
              label: name,
              trailing:
                  const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
              onTap: () => Navigator.pop(context, name),
            ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }
}

// Shared micro-widgets

class _GlassSheet extends StatelessWidget {
  final Widget child;
  const _GlassSheet({required this.child});
  // Solid panel: at 0.93 opacity the old sigma-24 BackdropFilter was visually
  // indistinguishable, yet re-blurred every frame anything animated beneath.
  @override
  Widget build(BuildContext context) {
    // NO ConstrainedBox + SingleChildScrollView HERE, DELIBERATELY.
    //
    // Capping the height with a scroll view was the first attempt at "stop
    // covering the whole page", and it cost drag-to-dismiss: a `Scrollable` sits
    // deeper in the tree than `showModalBottomSheet`'s own vertical-drag
    // recognizer, so it wins the gesture arena and swallows the downward swipe —
    // even when the content fits and there is nothing to scroll. The sheet became
    // tap-outside-only.
    //
    // The height problem is solved where it actually came from instead: the
    // ITEM COUNT (see [_QuickActionStrip]). Nine stacked rows are now four plus a
    // strip, so the sheet is short enough on its own, the rows keep comfortable
    // spacing, and the swipe works because nothing intercepts it.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF161616).withOpacity(0.97),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          border: Border(
              top: BorderSide(
                  color: Colors.white.withOpacity(0.09), width: 0.5)),
        ),
        child: child,
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
}

class _Artwork extends StatelessWidget {
  final String path;
  final double size;
  const _Artwork({required this.path, required this.size});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(10)),
          child: AuvyImage(
              path: path, width: size, height: size, fit: BoxFit.cover),
        ),
      );
}
