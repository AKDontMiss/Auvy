import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/presentation/widgets/sleep_timer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:auvy/services/artwork_export_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/presentation/widgets/song_details_sheet.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/player_provider.dart';

import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/quick_action_cell.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/track_refetch_service.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/listen_together_sheet.dart';
import 'package:auvy/providers/listen_together_provider.dart';

class PlayerMenuSheet extends ConsumerWidget {
  final Song song;

  const PlayerMenuSheet({super.key, required this.song});

  Future<void> _shareSong(BuildContext context, WidgetRef ref) async {
    Navigator.pop(context);
    final themeColor = ref.read(themeProvider);
    showSharePostcardDialog(context, song, themeColor);
  }

  /// Replace what's coming up with YouTube Music's own radio for this track —
  /// Spotify's "Go to song radio".
  ///
  /// The CURRENT track keeps playing and stays first in the new queue: this is
  /// "everything after this song becomes a mix built from it", not "restart".
  /// Restarting the audio for a queue change the user asked for would lose their
  /// position for no reason.
  Future<void> _startSongRadio(
      BuildContext context, WidgetRef ref, Color themeColor) async {
    HapticService.medium();
    Navigator.pop(context);
    AnimatedToast.show(context,
        text: 'Building song radio…',
        icon: Icons.radio_rounded,
        color: themeColor);
    // getSongRadio rejects non-11-character ids itself (live streams, podcasts,
    // local imports), returning [] rather than throwing, so a radio that can't
    // exist reports plainly instead of failing.
    final radio = await SearchService().getSongRadio(song.id);
    if (radio.isEmpty) {
      AnimatedToast.message('No radio available for this track');
      return;
    }
    // Dedupe: the radio response usually leads with the seed track itself, and
    // queueing it twice would replay it the moment it ends.
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
    // message(), not show(): this follows an await and the context is discarded
    // anyway. See the note on AnimatedToast.show.
    AnimatedToast.message('Song radio started · ${queue.length - 1} tracks');
  }

  /// Re-resolve everything about this track: cover art, metadata, lyrics.
  ///
  /// Closes the menu first and reports through toasts, because the work is several
  /// network round-trips (a conform or catalogue search, then a four-source lyrics
  /// scan) and holding a sheet open on a spinner for that long is worse than
  /// letting the user watch the player correct itself.
  ///
  /// The result toast is deliberately specific — "Updated cover art and album" or
  /// "Nothing new found for this track", because the honest failure case here is
  /// common, and a button that always says "Done" teaches people to distrust it.
  Future<void> _refetch(
      BuildContext context, WidgetRef ref, Color themeColor) async {
    HapticService.medium();
    Navigator.pop(context);
    AnimatedToast.show(context,
        text: 'Refetching track details…',
        icon: Icons.refresh_rounded,
        color: themeColor);
    final outcome = await TrackRefetchService.refetch(ref, song);
    AnimatedToast.message(outcome.message);
  }

  // This menu opens from the PlayerPage AND from plain list pages (History).
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(playerProvider.select((s) => s.volume));
    final activeDuration = ref.watch(playerProvider.select((s) => s.duration));
    final isDownloaded = AudioCacheManager().isExplicitlyDownloaded(song.id);
    final themeColor = ref.watch(themeProvider);

    return SafeArea(
      child: Padding(
        // vertical 24 → 12: with the Cancel button gone the sheet no longer needs
        // to reserve room beneath itself.
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Floating main menu. Solid panel instead of BackdropFilter: the
            // player keeps animating beneath this sheet, so the old blur was
            // recomputed every frame it was open — for a look this close to
            // an opaque dark card.
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1E).withOpacity(0.97),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header with Artwork
                      Padding(
                        // Identifies the track; doesn't re-display it. The artwork
                        // is already filling the player behind this sheet.
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(11)),
                              child: AuvyImage(path: song.image, width: 52, height: 52, fit: BoxFit.cover),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(song.title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 3),
                                  Text(song.displayArtist, style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),
                      
                      // Seamless Volume Slider
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: Row(
                          children: [
                            Icon(volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white54, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  overlayShape: SliderComponentShape.noOverlay,
                                  activeTrackColor: themeColor,
                                  inactiveTrackColor: Colors.white24,
                                  trackHeight: 4,
                                ),
                                child: Slider(
                                  value: volume,
                                  onChanged: (val) => ref.read(playerProvider.notifier).setVolume(val),
                                ),
                              ),
                            ),
                          ]
                        )
                      ),
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),

                      // Quick actions
                      // Share, Download, Sleep timer and Listen Together laid
                      // out ACROSS instead of down — the same rework as the track
                      // menu, for the same reason: eight stacked rows plus a
                      // header, a slider and a Cancel button filled the screen.
                      //
                      // Sleep timer and Listen Together belong here even though
                      // they open a picker: both carry STATE the user opens this
                      // menu to check, and a tinted disc reads that state at a
                      // glance better than a text row ever did.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                        child: Row(
                          children: [
                            QuickActionCell(
                              icon: Icons.ios_share_rounded,
                              label: 'Share',
                              color: Colors.white70,
                              onTap: () => _shareSong(context, ref),
                            ),
                            QuickActionCell(
                              icon: isDownloaded
                                  ? Icons.download_done_rounded
                                  : Icons.download_rounded,
                              label: isDownloaded ? 'Saved' : 'Download',
                              color: isDownloaded ? themeColor : Colors.blueAccent,
                              onTap: () {
                                if (isDownloaded) return;
                                Navigator.pop(context);
                                ref.read(playerProvider.notifier).downloadSong(song);
                              },
                            ),
                            Builder(builder: (context) {
                              final sleep = ref.watch(playerProvider.select(
                                  (s) => (s.sleepTimerMinutes, s.sleepAtEndOfTrack)));
                              final mins = sleep.$1;
                              final endOfTrack = sleep.$2;
                              final active = mins != null || endOfTrack;
                              return QuickActionCell(
                                icon: active
                                    ? Icons.bedtime_rounded
                                    : Icons.bedtime_outlined,
                                // The armed value IS the label when set — "30m"
                                // answers the question the user opened this for.
                                label: endOfTrack
                                    ? 'End of track'
                                    : (mins != null ? '${mins}m' : 'Sleep'),
                                color: active ? themeColor : Colors.white70,
                                onTap: () {
                                  // Close THIS menu first, then open the picker on
                                  // the root navigator, so it replaces the menu
                                  // instead of stacking on top of it.
                                  Navigator.pop(context);
                                  showSleepTimerSheet(context, ref, themeColor);
                                },
                              );
                            }),
                            Builder(builder: (context) {
                              final ltLive = ref.watch(
                                  listenTogetherProvider.select((s) => s.active));
                              return QuickActionCell(
                                icon: Icons.groups_rounded,
                                label: ltLive ? 'LIVE' : 'Together',
                                color: ltLive ? themeColor : Colors.white70,
                                onTap: () {
                                  Navigator.pop(context);
                                  showListenTogetherSheet(context);
                                },
                              );
                            }),
                          ],
                        ),
                      ),

                      Divider(color: Colors.white.withOpacity(0.08), height: 12, indent: 20, endIndent: 20),

                      //"View Album" and "View Artist" are NOT here.
                      //
                      // The player page already navigates to both by tapping the
                      // track title and the artist name — the labels themselves are
                      // the affordance. Repeating them in a menu one tap further
                      // away made the sheet taller to offer a slower version of
                      // something already on screen. (The TRACK menu keeps them,
                      // because a list row has no tappable artist name.)
                      //
                      // Their space went to actions the player page genuinely has
                      // no other route to.
                      _buildListTile(Icons.radio_rounded, "Start song radio",
                          () => _startSongRadio(context, ref, themeColor)),
                      _buildListTile(Icons.playlist_add_rounded, "Add to Playlist", () => _showPlaylistSelector(context, ref, themeColor)),
                      _buildListTile(Icons.image_outlined, "Save cover art", () async {
                        HapticService.selection();
                        Navigator.pop(context);
                        AnimatedToast.message("Saving cover art…");
                        final r = await ArtworkExportService.saveCover(song);
                        if (r.error != null) {
                          AnimatedToast.message(r.error!);
                        } else {
                          // Name the folder, not the full path — /Pictures/Auvy
                          // is something you can go and look in.
                          AnimatedToast.message("Saved to Pictures/Auvy");
                        }
                      }),
                      // Refetch
                      //
                      // The escape hatch for a track that is confidently WRONG:
                      // the cover from a different release, a YouTube video title
                      // with "(Official Video)" in it, lyrics for another song
                      // entirely. All three come from the same place — an ambiguous
                      // catalogue matched automatically, so they are fixed
                      // together rather than as three separate buttons the user has
                      // to know to press in order.
                      _buildListTile(Icons.refresh_rounded, "Refetch track details",
                          () => _refetch(context, ref, themeColor)),
                      _buildListTile(Icons.info_outline_rounded, "Song Details", () {
                        Navigator.pop(context);
                        showSongDetailsSheet(context, ref, song, activeDuration: activeDuration);
                      }),
                      _buildListTile(Icons.block_rounded, "Don't play this", () {
                        HapticService.heavy();
                        Navigator.pop(context);
                        // Same single entry point the track menu uses: blacklists in
                        // the intelligence layer AND the player layer, drops the
                        // track from every active queue, and skips it if it is the
                        // one playing (which, here, it always is).
                        ref.read(playerProvider.notifier).dontRecommend(song);
                        AnimatedToast.show(context,
                            text: '${song.title} hidden',
                            icon: Icons.block_rounded,
                            color: Colors.redAccent);
                      }, iconColor: Colors.redAccent, textColor: Colors.redAccent),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
            ),
            // NO Cancel button. It was a 60px row plus a 16px gap — the tallest
            // single element in the sheet — restating what tapping outside and
            // the system back gesture already do. Both still work.
          ],
        ),
      ),
    );
  }

  Widget _buildListTile(IconData icon, String title, VoidCallback onTap, {Color? iconColor, Color? textColor}) { 
    return InkWell(
      onTap: onTap,
      splashColor: Colors.white.withOpacity(0.05),
      highlightColor: Colors.white.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? Colors.white70, size: 24),
            const SizedBox(width: 16),
            Text(title, style: TextStyle(color: textColor ?? Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  /// Delegates to the shared sheet. See [showAddToPlaylistSheet].
  ///
  /// This used to be a 100-line copy with its own fixed 60%-of-screen height, its
  /// own "New Playlist" dialog reachable only via an add icon in the title row,
  /// and a double `Navigator.pop` that closed the create dialog and the sheet by
  /// position rather than by intent.
  void _showPlaylistSelector(BuildContext context, WidgetRef ref, Color themeColor) {
    Navigator.pop(context); // close the player menu first
    showAddToPlaylistSheet(context, ref, song, themeColor);
  }
}
