import 'package:auvy/presentation/widgets/sleep_timer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:auvy/services/artwork_export_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/presentation/widgets/song_details_sheet.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/player_provider.dart';

import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/services/track_refetch_service.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/listen_together_sheet.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/presentation/widgets/ab_looper_sheet.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/presentation/widgets/audio_output_sheet.dart';
import 'package:auvy/core/app_colors.dart';

class PlayerMenuSheet extends ConsumerWidget {
  final Song song;

  const PlayerMenuSheet({super.key, required this.song});

  Future<void> _shareSong(BuildContext context, WidgetRef ref) async {
    Navigator.pop(context);
    final themeColor = ref.read(themeProvider);
    showSharePostcardDialog(context, song, themeColor);
  }

  /// Replaces what's coming up with YouTube Music's radio for this track. The
  /// current track keeps playing and stays first: everything after it becomes a mix
  /// built from it.
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

  /// Re-resolves everything about this track (cover art, metadata, lyrics). Closes
  /// the menu first and reports through toasts, since the work takes several network
  /// round trips. The result toast is specific ("Updated cover art and album" or
  /// "Nothing new found for this track"), because finding nothing is common.
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
    final activeDuration = ref.watch(playerProvider.select((s) => s.duration));
    final isDownloaded = AudioCacheManager().isExplicitlyDownloaded(song.id);
    final themeColor = ref.watch(themeProvider);
    final isLoopActive = ref.watch(playerProvider.select((s) => s.isLoopActive));
    final isLiked = ref.watch(libraryProvider.select((l) => l.likedSongIds.contains(song.id)));
    final isLiveRadio = song.mediaKind == MediaKind.liveStream;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xF0151518),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.9),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top drag handle
                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 4),
                  child: _SheetHandle(),
                ),

                // One-line preview of the current track.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 10, 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: AuvyImage(path: song.image, width: 34, height: 34, fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 1),
                            Text(
                              song.displayArtist,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 11.5, fontWeight: FontWeight.w500),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Semantics(
                        label: isLiked ? 'Unlike' : 'Like',
                        button: true,
                        child: GestureDetector(
                          onTap: () {
                            HapticService.selection();
                            ref.read(libraryProvider.notifier).toggleSongLike(song);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              color: isLiked ? themeColor : Colors.white54,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),

                // Two-column grid of actions.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    children: [
                      // Radio: one 3×2 grid of the actions that exist only here (Pin Station and Resync
                      // Live are already on the player page). Paired by what they touch: the stream,
                      // the session, then getting something out of it.
                      if (isLiveRadio) ...[
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: Icons.tune_rounded,
                              label: 'Stream Info',
                              onTap: () {
                                Navigator.pop(context);
                                showSongDetailsSheet(context, ref, song, activeDuration: activeDuration);
                              },
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: Icons.graphic_eq_rounded,
                              label: 'Audio Output',
                              onTap: () async {
                                Navigator.pop(context);
                                await showAudioOutputSheet(context);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            // Both carry live state, so both keep the Builder
                            // the pills used — a tile with no tint would lose
                            // the only cue that a timer is already running.
                            Builder(builder: (context) {
                              final sleep = ref.watch(playerProvider.select(
                                  (s) => (s.sleepTimerMinutes, s.sleepAtEndOfTrack)));
                              final mins = sleep.$1;
                              final endOfTrack = sleep.$2;
                              final active = mins != null || endOfTrack;
                              return _SleekActionTile(
                                icon: active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
                                label: endOfTrack
                                    ? 'Sleep · End'
                                    : (mins != null ? 'Sleep · ${mins}m' : 'Sleep Timer'),
                                tint: active ? themeColor : null,
                                onTap: () {
                                  Navigator.pop(context);
                                  showSleepTimerSheet(context, ref, themeColor);
                                },
                              );
                            }),
                            const SizedBox(width: 8),
                            Builder(builder: (context) {
                              final ltLive = ref.watch(
                                  listenTogetherProvider.select((s) => s.active));
                              return _SleekActionTile(
                                icon: Icons.groups_rounded,
                                label: ltLive ? 'Together LIVE' : 'Listen Together',
                                tint: ltLive ? themeColor : null,
                                onTap: () {
                                  Navigator.pop(context);
                                  showListenTogetherSheet(context);
                                },
                              );
                            }),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: Icons.image_outlined,
                              label: 'Save Logo',
                              onTap: () async {
                                HapticService.selection();
                                Navigator.pop(context);
                                AnimatedToast.message('Saving station logo…');
                                final r = await ArtworkExportService.saveCover(song);
                                if (r.error != null) {
                                  AnimatedToast.message(r.error!);
                                } else {
                                  AnimatedToast.message('Saved to Pictures/Auvy');
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: Icons.ios_share_rounded,
                              label: 'Share',
                              onTap: () => _shareSong(context, ref),
                            ),
                          ],
                        ),
                      ] else ...[
                        // Music is a grid too, so no action is hidden off the edge of a scrolling strip.
                        // Ordered by what they touch: what plays next, how it plays, getting it out, what
                        // it is, the session.
                        //
                        // Share is a full-width bar at the top, mirroring the hide action at the bottom
                        // (same 34 px bar, in the accent instead of red): both are whole-track actions,
                        // and the ten tiles in between divide evenly into a 5×2 block.
                        GestureDetector(
                          onTap: () => _shareSong(context, ref),
                          child: Container(
                            height: 34,
                            decoration: BoxDecoration(
                              color: themeColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: themeColor.withValues(alpha: 0.28),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.ios_share_rounded,
                                    size: 14, color: themeColor),
                                const SizedBox(width: 6),
                                Text(
                                  'Share this track',
                                  style: TextStyle(
                                    color: themeColor.withValues(alpha: 0.95),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: Icons.radio_rounded,
                              label: 'Song Radio',
                              tint: themeColor,
                              onTap: () => _startSongRadio(context, ref, themeColor),
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: Icons.playlist_add_rounded,
                              label: 'Add to Playlist',
                              onTap: () => _showPlaylistSelector(context, ref, themeColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: Icons.tune_rounded,
                              label: 'Speed / Key',
                              onTap: () {
                                Navigator.pop(context);
                                _showPlaybackSpeedSheet(context, ref, themeColor);
                              },
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: isLoopActive ? Icons.repeat_on_rounded : Icons.repeat_rounded,
                              label: isLoopActive ? 'Loop ON' : 'A-B Looper',
                              tint: isLoopActive ? themeColor : null,
                              onTap: () {
                                Navigator.pop(context);
                                showABLooperSheet(context, ref, themeColor);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
                              label: isDownloaded ? 'Downloaded' : 'Download',
                              tint: isDownloaded ? themeColor : Colors.blueAccent,
                              onTap: () {
                                if (isDownloaded) return;
                                Navigator.pop(context);
                                ref.read(playerProvider.notifier).downloadSong(song);
                              },
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: Icons.info_outline_rounded,
                              label: 'Song Details',
                              onTap: () {
                                Navigator.pop(context);
                                showSongDetailsSheet(context, ref, song, activeDuration: activeDuration);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            _SleekActionTile(
                              icon: Icons.image_outlined,
                              label: 'Save Cover',
                              onTap: () async {
                                HapticService.selection();
                                Navigator.pop(context);
                                AnimatedToast.message('Saving cover art…');
                                final r = await ArtworkExportService.saveCover(song);
                                if (r.error != null) {
                                  AnimatedToast.message(r.error!);
                                } else {
                                  AnimatedToast.message('Saved to Pictures/Auvy');
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            _SleekActionTile(
                              icon: Icons.refresh_rounded,
                              label: 'Refetch Details',
                              onTap: () => _refetch(context, ref, themeColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            // Both keep the Builder the pills used: a tile with
                            // no tint would lose the only cue that a timer is
                            // already counting or a session is live.
                            Builder(builder: (context) {
                              final sleep = ref.watch(playerProvider.select(
                                  (s) => (s.sleepTimerMinutes, s.sleepAtEndOfTrack)));
                              final mins = sleep.$1;
                              final endOfTrack = sleep.$2;
                              final active = mins != null || endOfTrack;
                              return _SleekActionTile(
                                icon: active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
                                label: endOfTrack
                                    ? 'Sleep · End'
                                    : (mins != null ? 'Sleep · ${mins}m' : 'Sleep Timer'),
                                tint: active ? themeColor : null,
                                onTap: () {
                                  Navigator.pop(context);
                                  showSleepTimerSheet(context, ref, themeColor);
                                },
                              );
                            }),
                            const SizedBox(width: 8),
                            Builder(builder: (context) {
                              final ltLive = ref.watch(
                                  listenTogetherProvider.select((s) => s.active));
                              return _SleekActionTile(
                                icon: Icons.groups_rounded,
                                label: ltLive ? 'Together LIVE' : 'Listen Together',
                                tint: ltLive ? themeColor : null,
                                onTap: () {
                                  Navigator.pop(context);
                                  showListenTogetherSheet(context);
                                },
                              );
                            }),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Subtle Hide Action
                        GestureDetector(
                          onTap: () {
                            HapticService.heavy();
                            Navigator.pop(context);
                            ref.read(playerProvider.notifier).dontRecommend(song);
                            AnimatedToast.show(context,
                                text: '${song.title} hidden',
                                icon: Icons.block_rounded,
                                color: Colors.redAccent);
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
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Delegates to the shared sheet (see [showAddToPlaylistSheet]).
  void _showPlaylistSelector(BuildContext context, WidgetRef ref, Color themeColor) {
    Navigator.pop(context); // close the player menu first
    showAddToPlaylistSheet(context, ref, song, themeColor);
  }

  void _showPlaybackSpeedSheet(BuildContext context, WidgetRef ref, Color themeColor) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final speed = ref.watch(playerProvider.select((s) => s.speed));
            final semitones = ref.watch(playerProvider.select((s) => s.pitchSemitones));
            final notifier = ref.read(playerProvider.notifier);
            final presets = [0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 2.0];
            final pitchPresets = [-2, -1, 0, 1, 2];

            String labelFor(double s) {
              if (s == 1.0) return '1.0x (Normal)';
              if (s == 0.85) return '0.85x (Slowed)';
              if (s == 1.25) return '1.25x (Nightcore)';
              return '${s.toStringAsFixed(s.truncateToDouble() == s ? 0 : 2)}x';
            }

            String pitchLabel(int semi) {
              if (semi == 0) return 'Original (0)';
              return semi > 0 ? '+$semi st' : '$semi st';
            }

            return Container(
              decoration: const BoxDecoration(
                color: AppColors.modalPanel,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // SPEED SECTION
                  Row(
                    children: [
                      const Icon(Icons.speed_rounded, color: Colors.white70, size: 20),
                      const SizedBox(width: 10),
                      const Text(
                        'Playback Speed',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: themeColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: themeColor.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          labelFor(speed),
                          style: TextStyle(
                            color: themeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: presets.map((p) {
                      final selected = (speed - p).abs() < 0.02;
                      return AuvyPill(
                label: p == 1.0 ? '1.0x' : (p == 0.85 ? '0.85x Slow' : (p == 1.25 ? '1.25x Night' : '${p}x')),
                selected: selected,
                accent: themeColor,
                onTap: () => notifier.setSpeed(p),
              );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: themeColor,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: speed.clamp(0.5, 2.0),
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      label: '${speed.toStringAsFixed(2)}x',
                      onChanged: (v) => notifier.setSpeed((v * 20).round() / 20),
                    ),
                  ),

                  Divider(color: Colors.white.withValues(alpha: 0.08), height: 24),

                  // Pitch / key transpose.
                  Row(
                    children: [
                      const Icon(Icons.music_note_rounded, color: Colors.white70, size: 20),
                      const SizedBox(width: 10),
                      const Text(
                        'Key Transpose',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: themeColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: themeColor.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          pitchLabel(semitones),
                          style: TextStyle(
                            color: themeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: pitchPresets.map((semi) {
                      final selected = semitones == semi;
                      return AuvyPill(
                label: semi == 0 ? 'Original' : (semi > 0 ? '+$semi' : '$semi'),
                selected: selected,
                accent: themeColor,
                onTap: () => notifier.setPitchSemitones(semi),
              );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: themeColor,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: semitones.toDouble().clamp(-6.0, 6.0),
                      min: -6.0,
                      max: 6.0,
                      divisions: 12,
                      label: pitchLabel(semitones),
                      onChanged: (v) => notifier.setPitchSemitones(v.round()),
                    ),
                  ),

                  if ((speed - 1.0).abs() > 0.02 || semitones != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextButton.icon(
                        onPressed: () {
                          HapticService.light();
                          notifier.setSpeed(1.0);
                          notifier.setPitchSemitones(0);
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 16, color: Colors.white60),
                        label: const Text('Reset speed & key to original',
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
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
