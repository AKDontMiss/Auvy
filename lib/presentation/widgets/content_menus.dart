import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/spoken_word_nav.dart';
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
import 'package:auvy/services/search_service.dart';
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

  /// Builds the [Album] a track's "View Album" should open, shared by every menu
  /// (track sheet, player menu, queue swipe):
  ///  • a real browse id → open the album directly;
  ///  • no id but a real album name (different from the track title) → let AlbumPage
  ///    resolve the album by name (recordType 'album');
  ///  • neither → a genuine single: AlbumPage shows the track itself.
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
  /// Delegates to the shared sheet (see [showAddToPlaylistSheet]).
  static void _showAddToPlaylistSheet(BuildContext context, WidgetRef ref, Song song, Color themeColor) {
    showAddToPlaylistSheet(context, ref, song, themeColor);
  }

  // Helper: Navigate to Album Page
  static Future<void> _navigateToAlbum(
      BuildContext context, BuildContext parentCtx, WidgetRef ref, Song song) async {
    // An episode's "album" is its show, a chapter's is its book.
    if (await openSpokenWordSource(ref, song)) return;
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

  static Future<void> _startSongRadio(
      BuildContext context, WidgetRef ref, Color themeColor, Song song) async {
    HapticService.medium();
    Navigator.pop(context);
    AnimatedToast.show(context,
        text: 'Building song radio…',
        icon: Icons.radio_rounded,
        color: themeColor);
    final radio = await SearchService().getSongRadio(song.id);
    if (radio.isEmpty) {
      AnimatedToast.message('No radio available for this track');
      return;
    }
    final queue = <Song>[
      song,
      ...radio.where((s) => s.id != song.id),
    ];
    ref.read(playerProvider.notifier).playSong(
          song,
          newQueue: queue,
          source: 'Song radio',
          locationName: song.title,
          contextType: 'radio',
          contextTitle: '${song.title} radio',
        );
    AnimatedToast.message('Song radio started · ${queue.length - 1} tracks');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return _GlassSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          // Header: artwork, title and artist.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 10, 8),
            child: Row(
              children: [
                Hero(
                  tag: 'menu_art_${song.id}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(8)),
                    child: AuvyImage(
                      path: song.image,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        song.displayArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                _HeaderLikeButton(song: song, themeColor: themeColor),
              ],
            ),
          ),

          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),

          // Quick actions strip
          _QuickActionStrip(
            song: song,
            parentContext: parentContext,
            themeColor: themeColor,
          ),

          const SizedBox(height: 4),

          // Two-column grid of actions.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    _SleekActionTile(
                      icon: Icons.playlist_add_rounded,
                      label: 'Add to Playlist',
                      onTap: () {
                        Navigator.pop(context);
                        _showAddToPlaylistSheet(context, ref, song, themeColor);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SleekActionTile(
                      icon: Icons.album_rounded,
                      label: 'View Album',
                      onTap: () {
                        Navigator.pop(context);
                        _navigateToAlbum(context, parentContext, ref, song);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    _SleekActionTile(
                      icon: Icons.person_rounded,
                      label: 'View Artist',
                      onTap: () {
                        Navigator.pop(context);
                        _navigateToArtist(context, parentContext, ref, song);
                      },
                    ),
                    const SizedBox(width: 8),
                    _SleekActionTile(
                      icon: Icons.info_outline_rounded,
                      label: 'Song Details',
                      onTap: () {
                        Navigator.pop(context);
                        showSongDetailsSheet(parentContext, ref, song);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Consumer(builder: (context, ref, _) {
                      final hasOverride = ref.watch(
                          artworkOverrideProvider.select((m) => m.containsKey(song.id)));
                      return _SleekActionTile(
                        icon: hasOverride
                            ? Icons.image_not_supported_outlined
                            : Icons.image_rounded,
                        label: hasOverride ? 'Reset Artwork' : 'Change Artwork',
                        tint: hasOverride ? Colors.orangeAccent : null,
                        onTap: () async {
                          Navigator.pop(context);
                          final notifier = ref.read(artworkOverrideProvider.notifier);
                          if (hasOverride) {
                            await notifier.clearOverride(song.id);
                            AnimatedToast.message('Artwork reset');
                            return;
                          }
                          final picked = await ImagePicker()
                              .pickImage(source: ImageSource.gallery);
                          if (picked == null) return;
                          final ok = await notifier.setOverride(song.id, picked.path);
                          AnimatedToast.message(
                              ok ? 'Artwork updated' : "Couldn't use that image");
                        },
                      );
                    }),
                    const SizedBox(width: 8),
                    _SleekActionTile(
                      icon: Icons.radio_rounded,
                      label: 'Song Radio',
                      tint: themeColor,
                      onTap: () => _startSongRadio(context, ref, themeColor, song),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Subtle Hide Action
                GestureDetector(
                  onTap: () {
                    HapticService.heavy();
                    Navigator.pop(context);
                    ref.read(playerProvider.notifier).dontRecommend(song);
                    AnimatedToast.show(
                      context,
                      text: '${song.title} hidden',
                      icon: Icons.block_rounded,
                      color: Colors.redAccent,
                    );
                  },
                  child: Container(
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.18),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.block_rounded, size: 14, color: Colors.redAccent),
                        const SizedBox(width: 6),
                        Text(
                          "Don't play this track again",
                          style: TextStyle(
                            color: Colors.redAccent.withValues(alpha: 0.9),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
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
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
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
                  // Read before the add, so the message says whether it was already queued.
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
                  // Report the outcome of the download.
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
    return Semantics(
      label: isLiked ? 'Unlike' : 'Like',
      button: true,
      child: GestureDetector(
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
      splashColor: Colors.white.withOpacity(0.04),
      highlightColor: Colors.white.withOpacity(0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9.5),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _SleekActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  const _SleekActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticService.selection();
            onTap();
          },
          borderRadius: BorderRadius.circular(10),
          splashColor: (tint ?? Colors.white).withValues(alpha: 0.08),
          highlightColor: (tint ?? Colors.white).withValues(alpha: 0.04),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.05),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16.5, color: tint ?? Colors.white70),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.038),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.065), width: 0.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < artists.length; i++) ...[
                    _MenuTile(
                      icon: Icons.person_rounded,
                      iconColor: Colors.white70,
                      label: artists[i],
                      trailing:
                          const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 18),
                      onTap: () => Navigator.pop(context, artists[i]),
                    ),
                    if (i < artists.length - 1)
                      Divider(color: Colors.white.withOpacity(0.04), height: 0.5, indent: 54),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// Shared micro-widgets

class _GlassSheet extends StatelessWidget {
  final Widget child;
  const _GlassSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xF0151518),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: child,
          ),
        ),
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
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
}
