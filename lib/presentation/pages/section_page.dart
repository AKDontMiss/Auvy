import 'package:flutter/material.dart';
import 'package:auvy/providers/view_count_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/providers/density_provider.dart';

/// Detail view for a home-feed section ("Take it easy", "All hits", …):
/// the section's full track list with Play / Shuffle. This is where tapping a
/// section title lands — those titles are moods/mixes, not artists, so the old
/// route into an artist search made no sense.
class SectionPage extends ConsumerWidget {
  final String title;
  final List<Song> songs;

  const SectionPage({super.key, required this.title, required this.songs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              backgroundColor: Colors.transparent,
              pinned: true,
              expandedHeight: 210,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: Colors.white, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [themeColor.withOpacity(0.26), Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            'MIX',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.4),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                height: 1.1,
                                letterSpacing: -0.6),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "${songs.length} ${songs.length == 1 ? 'song' : 'songs'}",
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Play / Shuffle actions
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (songs.isEmpty) return;
                          HapticService.medium();
                          // `source` is the KIND of place and `locationName` its
                          // NAME — the player header renders them as two lines.
                          // A section is always opened from Home (see
                          // home_page's SectionPage push), so the kind is Home
                          // and the section title is the name. Passing `title`
                          // as `source` put the name on the kind line and left
                          // the name line falling back to the track's album.
                          ref.read(playerProvider.notifier).playSong(
                              songs.first,
                              newQueue: songs,
                              source: 'Home',
                              locationName: title);
                        },
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: themeColor,
                              borderRadius: BorderRadius.circular(23)),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow_rounded,
                                  color: AppColors.matteBlack, size: 22),
                              SizedBox(width: 6),
                              Text('Play',
                                  style: TextStyle(
                                      color: AppColors.matteBlack,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () {
                        if (songs.isEmpty) return;
                        HapticService.medium();
                        final shuffled = songs.toList()..shuffle();
                        ref.read(playerProvider.notifier).playSong(
                            shuffled.first,
                            newQueue: shuffled,
                            source: 'Home',
                            locationName: title);
                      },
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.07),
                          border: Border.all(color: Colors.white.withOpacity(0.08)),
                        ),
                        child: Icon(Icons.shuffle_rounded,
                            color: Colors.white.withOpacity(0.85), size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  // Conform a few rows ahead. See [warmAhead].
                  warmAhead(ref, songs, index);
                  final song = songs[index];
                  return _SectionTrackTile(
                    index: index,
                    song: song,
                    onTap: () {
                      HapticService.light();
                      ref.read(playerProvider.notifier).playSong(song,
                          newQueue: songs,
                          index: index,
                          source: 'Home',
                          locationName: title);
                    },
                  );
                },
                childCount: songs.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}

class _SectionTrackTile extends ConsumerWidget {
  final int index;
  final Song song;
  final VoidCallback onTap;

  const _SectionTrackTile(
      {required this.index, required this.song, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = conformedForDisplay(ref, song);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
      onTap: onTap,
      leading: Stack(
        children: [
          AuvyImage(
              path: display.image,
              width: densityNow.artwork(48),
              height: densityNow.artwork(48),
              borderRadius: 8),
          NowPlayingArtOverlay(
              rowId: song.id,
              altId: display.id,
              title: display.title,
              artist: song.displayArtist),
        ],
      ),
      title: NowPlayingTitle(
        title: display.title,
        rowId: song.id,
        altId: display.id,
        artist: song.displayArtist,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w500, fontSize: 14.5),
      ),
      subtitle: Text(
        song.displayArtist,
        style: const TextStyle(color: Colors.grey, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // Play count, the same field on every page. See [trackRowViews].
      trailing: () {
        final v = watchTrackViews(ref, song.id, song.viewCount);
        return v == null
            ? null
            : Text(v,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66), fontSize: 11.5));
      }(),
    );
  }
}
