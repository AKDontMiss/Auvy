import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/providers/density_provider.dart';

// HIDDEN CONTENT — makeover in the Stats-page design language.
//
// Shows the UNION of both dislike layers (player blacklist + intelligence
// blacklist) so nothing stays invisibly blocked, and Restore goes through
// PlayerNotifier.unhideSong which clears BOTH layers + any live failure block.
// (The old page listed only the intelligence layer and restored only there, so
// a "restored" track often remained blocked by the player layer.)

class HiddenContentPage extends ConsumerWidget {
  const HiddenContentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final intel = ref.watch(intelligenceProvider);
    final playerBlacklist = ref.watch(playerProvider.select((p) => p.blacklistedIds));

    // Union of both persisted dislike layers.
    final allIds = <String>{...intel.blacklistedIds, ...playerBlacklist};
    final hidden = allIds.map((id) {
      return intel.trackMetadata[id] ??
          Song(id: id, title: 'Unknown track', artist: 'Not in your library', image: '');
    }).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      const Text('Hidden Content',
                          style: TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
                      const Spacer(),
                      if (hidden.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text('${hidden.length}',
                              style: TextStyle(
                                  color: theme, fontSize: 13, fontWeight: FontWeight.w800)),
                        ),
                    ],
                  ),
                ),
              ),

              // How hiding works
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.withOpacity(0.16), theme.withOpacity(0.03)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.withOpacity(0.22)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.block_rounded, color: theme, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Tracks you mark "Don\'t play this" never play, never appear '
                          'in your queue and are never recommended — until you restore them.',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.75), fontSize: 12.5, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (hidden.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.visibility_off_rounded,
                            size: 56, color: Colors.white.withOpacity(0.2)),
                        const SizedBox(height: 16),
                        Text('Nothing hidden',
                            style:
                                TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 16)),
                        const SizedBox(height: 6),
                        Text('Your dislikes will show up here',
                            style:
                                TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13)),
                      ],
                    ),
                  ),
                )
              else ...[
                // Restore all
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          HapticService.medium();
                          ref.read(playerProvider.notifier).unhideAll(hidden);
                          AnimatedToast.show(context,
                              text: 'All tracks restored',
                              icon: Icons.restore_rounded,
                              color: theme);
                        },
                        icon: Icon(Icons.restore_rounded, color: theme, size: 18),
                        label: Text('Restore all',
                            style: TextStyle(
                                color: theme, fontWeight: FontWeight.w700, fontSize: 13)),
                      ),
                    ),
                  ),
                ),

                // Hidden tracks
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final song = hidden[index];
                        return _HiddenTile(
                          song: song,
                          theme: theme,
                          onRestore: () {
                            HapticService.selection();
                            ref.read(playerProvider.notifier).unhideSong(song);
                            AnimatedToast.show(context,
                                text: '${song.title} restored',
                                icon: Icons.check_circle_rounded,
                                color: theme);
                          },
                        );
                      },
                      childCount: hidden.length,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HiddenTile extends StatelessWidget {
  final Song song;
  final Color theme;
  final VoidCallback onRestore;

  const _HiddenTile({required this.song, required this.theme, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(9)),
            child: song.image.isNotEmpty
                ? Opacity(
                    opacity: 0.55, // dimmed — it's blocked
                    child:
                        AuvyImage(
                            path: song.image,
                            width: densityNow.artwork(48),
                            height: densityNow.artwork(48),
                            fit: BoxFit.cover),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: Colors.white.withOpacity(0.07),
                    child: const Icon(Icons.music_off_rounded, color: Colors.white30, size: 22),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(song.displayArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onRestore,
            style: TextButton.styleFrom(
              foregroundColor: theme,
              backgroundColor: theme.withOpacity(0.13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Restore',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
