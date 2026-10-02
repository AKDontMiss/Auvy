import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/presentation/widgets/hold_to_open.dart';

/// Everything Auvy has identified, newest first.
///
/// Recognition without a log is a feature you can only use in the moment — the
/// song you identified in a shop is gone as soon as the sheet closes. This is the
/// other half of it.
class RecognitionHistoryPage extends ConsumerStatefulWidget {
  const RecognitionHistoryPage({super.key});

  @override
  ConsumerState<RecognitionHistoryPage> createState() =>
      _RecognitionHistoryPageState();
}

class _RecognitionHistoryPageState
    extends ConsumerState<RecognitionHistoryPage> {
  List<RecognitionEntry>? _entries;
  String? _resolving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await RecognitionHistory.load();
    if (mounted) setState(() => _entries = e);
  }

  /// Recognition results only carry a title and artist, so playback resolves the
  /// track on YouTube Music first — the same path the recognition sheet uses.

  Future<void> _play(RecognitionEntry e) async {
    if (_resolving != null) return;
    HapticService.selection();
    final theme = ref.read(themeProvider);


    setState(() => _resolving = e.title);
    try {
      final songs = await ref
          .read(searchServiceProvider)
          .search('${e.title} ${e.artist}'.trim(), 'track');
      if (!mounted) return;
      if (songs.isNotEmpty) {
        ref
            .read(playerProvider.notifier)
            .playSong(songs.first, source: 'Recognition history');
        Navigator.of(context).maybePop();
        return;
      }
      AnimatedToast.show(context,
          text: "Couldn't find this track on Auvy.",
          icon: Icons.search_off_rounded,
          color: theme);
    } catch (_) {
      if (!mounted) return;
      AnimatedToast.show(context,
          text: 'Something went wrong. Try again.',
          icon: Icons.error_outline_rounded,
          color: Colors.orange);
    } finally {
      if (mounted) setState(() => _resolving = null);
    }
  }

  Future<void> _clear() async {
    final theme = ref.read(themeProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: const Text('Clear recognition history?',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text('This removes every song Auvy has identified.',
            style: TextStyle(
                color: Colors.white.withOpacity(0.78), fontSize: 13.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear',
                style:
                    TextStyle(color: theme, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await RecognitionHistory.clear();
    await _load();
  }

  static String _when(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[at.month - 1]} ${at.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final entries = _entries;

    // Transparent over DynamicBackground, with the collapsing large title the rest of
    // the app uses, rather than an opaque Scaffold that would hide the shared
    // background.
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: entries == null
            ? Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child:
                      CircularProgressIndicator(strokeWidth: 2.2, color: theme),
                ),
              )
            : CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    pinned: true,
                    expandedHeight: 128,
                    iconTheme: const IconThemeData(color: Colors.white),
                    flexibleSpace: FlexibleSpaceBar(
                      titlePadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                      expandedTitleScale: 1.6,
                      title: const Text('Identified songs',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 18)),
                    ),
                    actions: [
                      if (entries.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: _clear,
                        ),
                    ],
                  ),
                  if (entries.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                  else ...[
                    // A count, in the app's small-caps section voice. Cheap, and
                    // it makes the page feel like a collection rather than a log.
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Row(children: [
                          Container(
                            width: 3,
                            height: 13,
                            decoration: BoxDecoration(
                                color: theme,
                                borderRadius: BorderRadius.circular(2)),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            entries.length == 1
                                ? '1 SONG'
                                : '${entries.length} SONGS',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 9.5,
                                letterSpacing: 1.8,
                                fontWeight: FontWeight.w800),
                          ),
                        ]),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 130),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          // No per-item gap: rows are ListTiles on the shared
                          // background now, not floating cards, so spacing comes
                          // from the tile's own padding (and therefore from the
                          // density setting) rather than from a gap between cards.
                          (ctx, i) => _row(entries[i], theme),
                          childCount: entries.length,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  /// Long-press opens the app's standard track menu. A recognition entry has only a
  /// title and artist (Shazam returns no YouTube id), so the track is resolved on
  /// long-press rather than for every row up front. Uses the same resolve path and
  /// spinner as tapping to play.
  Future<void> _openMenu(RecognitionEntry e) async {
    if (_resolving != null) return;
    HapticService.medium();
    setState(() => _resolving = e.title);
    try {
      final songs = await ref
          .read(searchServiceProvider)
          .search('${e.title} ${e.artist}'.trim(), 'track');
      if (!mounted) return;
      if (songs.isEmpty) {
        AnimatedToast.message('Could not find that track');
        return;
      }
      ContentMenus.showSongMenu(context, songs.first, ref);
    } catch (_) {
      if (mounted) AnimatedToast.message('Could not find that track');
    } finally {
      if (mounted) setState(() => _resolving = null);
    }
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.graphic_eq_rounded,
                  size: 42, color: Colors.white.withOpacity(0.22)),
              const SizedBox(height: 14),
              Text(
                'Nothing identified yet.\nTap the Shazam icon in Search to '
                'recognise what\'s playing.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66),
                    fontSize: 13.5,
                    height: 1.5),
              ),
            ],
          ),
        ),
      );


  /// One identified song as a flat ListTile, like other song lists: 42 px artwork,
  /// artist and time on one subtitle line ("Daft Punk · 2h ago"). Being a ListTile
  /// also means it follows Appearance → List spacing.
  Widget _row(RecognitionEntry e, Color theme) {
    final busy = _resolving == e.title;
    // Long-press = the same track menu every other list in the app has, and it
    // charges visibly like the rest of them now. See HoldToOpen.
    return HoldToOpen(
      borderRadius: BorderRadius.circular(10),
      onHold: busy ? null : () => _openMenu(e),
      child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      onTap: busy ? null : () => _play(e),
      leading: ClipRRect(
        borderRadius:
            BorderRadius.circular(ListeningPolicy.roundArtwork(42 * 0.24)),
        child: SizedBox(
          width: 42,
          height: 42,
          // A local hit has no artwork by design (it came from the device, not
          // Shazam), so it gets a glyph rather than a broken image.
          child: e.coverArtUrl != null
              ? AuvyImage(path: e.coverArtUrl!)
              : ColoredBox(
                  color: Colors.white.withOpacity(0.06),
                  child: Icon(Icons.music_note_rounded,
                      color: Colors.white.withOpacity(0.35), size: 20),
                ),
        ),
      ),
      title: Text(e.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
      // Artist AND time on one line. The timestamp is the quieter half — it is
      // context, not identity, so it takes a dimmer colour after a separator
      // rather than a line of its own.
      subtitle: Row(
        children: [
          Flexible(
            child: Text(e.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.72), fontSize: 11.5)),
          ),
          Text('  ·  ',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.55), fontSize: 11.5)),
          Text(_when(e.at),
              style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
      trailing: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: theme),
            )
          : Icon(Icons.play_arrow_rounded,
              color: Colors.white.withOpacity(0.35), size: 20),
    ));
  }
}
