import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/core/app_colors.dart';
import 'package:auvy/logic/music_link.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/music_link_resolver.dart';
import 'package:auvy/services/search_service.dart';

/// Opens a Spotify, Apple Music or YouTube link: shows what it is, then plays
/// it, queues it or saves it. Reached from a share into Auvy, a pasted link in
/// Search, or an `auvy://open` link. Laid out like the app's other sheets.
void showOpenLinkSheet(BuildContext context, MusicLink link) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => OpenLinkSheet(link: link),
  );
}

class OpenLinkSheet extends ConsumerStatefulWidget {
  const OpenLinkSheet({super.key, required this.link});
  final MusicLink link;

  @override
  ConsumerState<OpenLinkSheet> createState() => _OpenLinkSheetState();
}

class _OpenLinkSheetState extends ConsumerState<OpenLinkSheet> {
  ResolvedMusicLink? _resolved;
  String? _error;
  bool _working = false;
  int _done = 0;
  int _total = 0;

  late final MusicLinkResolver _resolver =
      MusicLinkResolver(ref.read(libraryProvider.notifier));

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final r = await _resolver.resolve(widget.link);
      if (mounted) setState(() => _resolved = r);
    } on MusicLinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      print('ERROR: open link failed: $e');
      if (mounted) setState(() => _error = "Couldn't open that link. Check your connection and try again.");
    }
  }

  Future<void> _play({bool shuffle = false}) async {
    final r = _resolved;
    if (r == null || _working) return;
    HapticService.medium();
    setState(() => _working = true);
    final player = MusicLinkPlayer(_resolver, ref.read(playerProvider.notifier), ref.read(libraryProvider.notifier));
    var closed = false;
    final played = await player.play(r, shuffle: shuffle, onProgress: (done, total) {
      if (mounted && !closed) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    if (!mounted) return;
    if (!played) {
      setState(() {
        _working = false;
        _error = "Couldn't find those songs on YouTube Music.";
      });
      return;
    }
    // Playing has started; the rest of a long list keeps matching after the
    // sheet closes.
    closed = true;
    AnimatedToast.message(shuffle ? 'Shuffling ${r.title}' : 'Playing ${r.title}');
    Navigator.of(context).maybePop();
  }

  void _playNext() {
    final song = _resolved?.songs.firstOrNull;
    if (song == null) return;
    HapticService.selection();
    final player = ref.read(playerProvider.notifier);
    if (ref.read(playerProvider).currentSong == null) {
      player.playSong(song, source: 'Shared link');
    } else {
      player.addToQueueNext(song);
    }
    AnimatedToast.message('${song.title} plays next');
    Navigator.of(context).maybePop();
  }

  void _like() {
    final song = _resolved?.songs.firstOrNull;
    if (song == null) return;
    HapticService.selection();
    final library = ref.read(libraryProvider.notifier);
    final already = ref.read(libraryProvider).likedSongIds.contains(song.id);
    if (!already) library.toggleSongLike(song);
    AnimatedToast.message(already ? 'Already in Liked Songs' : 'Added to Liked Songs');
    Navigator.of(context).maybePop();
  }

  /// Spotify and YouTube lists go through the existing import (it reads the
  /// whole Spotify list and shows its progress on the Library). Apple Music
  /// lists are matched here and saved the same way.
  Future<void> _save() async {
    final r = _resolved;
    if (r == null || _working) return;
    HapticService.medium();
    final library = ref.read(libraryProvider.notifier);
    if (r.link.source != MusicLinkSource.appleMusic) {
      AnimatedToast.message('Saving ${r.title} to your Library…');
      Navigator.of(context).maybePop();
      final result = await library.importPlaylistFromUrl(r.link.uri.toString(), SearchService());
      AnimatedToast.message(switch (result.outcome) {
        LinkImportOutcome.created => 'Saved ${r.title} (${result.tracks} songs)',
        LinkImportOutcome.replaced => 'Updated ${r.title} (${result.tracks} songs)',
        LinkImportOutcome.keptExisting => 'A playlist with that name already exists',
        _ => "Couldn't save ${r.title}",
      });
      return;
    }
    setState(() => _working = true);
    final matched = await library.resolveQueriesToSongs(r.queries, SearchService(),
        onProgress: (done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    if (!mounted) return;
    final saved = matched.songs.isNotEmpty &&
        library.savePlaylistFromSearch(
            matched.songs.first.copyWith(id: 'apple_${r.link.id}', title: r.title, artist: 'Apple Music', image: r.image),
            matched.songs);
    AnimatedToast.message(saved
        ? 'Saved ${r.title} (${matched.songs.length} songs)'
        : matched.songs.isEmpty
            ? "Couldn't find those songs on YouTube Music"
            : 'A playlist with that name already exists');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.modalPanel,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 18),
              _header(accent),
              const SizedBox(height: 18),
              if (_error != null)
                _message(_error!, accent)
              else if (_resolved == null)
                _loading(accent, 'Reading the link from ${widget.link.sourceName}…')
              else if (_working)
                _loading(
                    accent,
                    _total > 0 ? 'Finding songs · $_done of $_total' : 'Finding songs…',
                    fraction: _total > 0 ? _done / _total : null)
              else
                ..._actions(accent, _resolved!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Color accent) {
    final r = _resolved;
    final kindLabel = switch (widget.link.kind) {
      MusicLinkKind.track => 'Song',
      MusicLinkKind.album => 'Album',
      MusicLinkKind.playlist => 'Playlist',
      MusicLinkKind.artist => 'Artist',
      MusicLinkKind.short => 'Link',
    };
    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(widget.link.kind == MusicLinkKind.artist ? 32 : 14),
            border: Border.all(color: accent.withValues(alpha: 0.18)),
          ),
          clipBehavior: Clip.antiAlias,
          child: r != null && r.image.isNotEmpty
              ? AuvyImage(path: r.image, width: 64, height: 64)
              : Icon(Icons.link_rounded, color: accent, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$kindLabel from ${widget.link.sourceName}'.toUpperCase(),
                style: TextStyle(
                    color: accent, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.8),
              ),
              const SizedBox(height: 3),
              Text(
                r?.title ?? 'Opening link',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, height: 1.2),
              ),
              if (r != null && r.subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(r.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.60), fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _loading(Color accent, String text, {double? fraction}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            color: accent,
          ),
        ),
        const SizedBox(height: 12),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }

  Widget _message(String text, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: Colors.white.withValues(alpha: 0.6)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _button('Close', accent, () => Navigator.of(context).maybePop(), filled: false),
      ],
    );
  }

  List<Widget> _actions(Color accent, ResolvedMusicLink r) {
    final isTrack = widget.link.kind == MusicLinkKind.track;
    final canSave = widget.link.kind == MusicLinkKind.album || widget.link.kind == MusicLinkKind.playlist;
    return [
      Row(children: [
        Expanded(child: _button('Play', accent, () => _play(), icon: Icons.play_arrow_rounded)),
        if (!isTrack) ...[
          const SizedBox(width: 10),
          Expanded(
              child: _button('Shuffle', accent, () => _play(shuffle: true),
                  icon: Icons.shuffle_rounded, filled: false)),
        ],
      ]),
      const SizedBox(height: 8),
      if (isTrack) ...[
        _row(Icons.queue_music_rounded, 'Play next', 'After the song that is playing now', _playNext),
        _row(Icons.favorite_border_rounded, 'Add to Liked Songs', 'Keep it in your Library', _like),
      ],
      if (canSave)
        _row(Icons.library_add_rounded, 'Save to Library', '${r.trackCount} songs as an Auvy playlist', _save),
    ];
  }

  Widget _button(String label, Color accent, VoidCallback onTap, {IconData? icon, bool filled = true}) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: filled ? accent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: filled ? accent.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: filled ? accent : Colors.white, size: 20),
                  const SizedBox(width: 6),
                ],
                Text(label,
                    style: TextStyle(
                        color: filled ? accent : Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The app's standard choice row, as in the import and sleep-timer sheets.
  Widget _row(IconData icon, String label, String subtitle, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
          child: Row(
            children: [
              Icon(icon, size: 19, color: Colors.white.withValues(alpha: 0.75)),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.50), fontSize: 11.5, height: 1.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
