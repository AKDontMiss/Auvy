import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/core/app_colors.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/info_hint.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// Imports playlists, albums and tracks from a pasted link. A sheet like the app's
/// other modals, following the sleep timer's layout: a header that carries the
/// state, choices as rows, no paragraphs of prose.
///
/// Matching a long playlist takes minutes and continues after the sheet closes, so
/// progress lives in library state (see [LinkImportProgress]): this sheet and the
/// library page's banner show the same numbers, and the completion notice appears
/// whether or not anyone is watching.
void showLinkImportSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const LinkImportSheet(),
  );
}

class LinkImportSheet extends ConsumerStatefulWidget {
  const LinkImportSheet({super.key});

  @override
  ConsumerState<LinkImportSheet> createState() => _LinkImportSheetState();
}

class _LinkImportSheetState extends ConsumerState<LinkImportSheet> {
  /// One controller per link field, disposed in [dispose] (the state object is torn
  /// down after its route has left the tree).
  final List<TextEditingController> _fields = [TextEditingController()];

  bool _busy = false;
  int _imported = 0;
  int _kept = 0;
  int _failed = 0;
  int _linkIndex = 0;
  int _linkCount = 0;
  bool _finished = false;

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  /// A link worth trying.
  ///
  /// Deliberately loose — a bare id pasted without the URL around it is a thing
  /// people do, and refusing it teaches nothing. The resolver says what went
  /// wrong far better than a regex here can.
  bool _looksLikeLink(String s) =>
      s.contains('spotify') || s.contains('open.spotify') || s.length > 20;

  Future<void> _import() async {
    final urls = _fields
        .map((c) => c.text.trim())
        .where((u) => u.isNotEmpty && _looksLikeLink(u))
        .toList();

    if (urls.isEmpty) {
      AnimatedToast.message('Paste a public Spotify link first.');
      return;
    }

    HapticService.medium();
    setState(() {
      _busy = true;
      _finished = false;
      _imported = 0;
      _kept = 0;
      _failed = 0;
      _linkCount = urls.length;
      _linkIndex = 0;
    });

    final searchService = ref.read(searchServiceProvider);
    var written = 0;
    var kept = 0;
    var failed = 0;

    for (var i = 0; i < urls.length; i++) {
      if (mounted) setState(() => _linkIndex = i);
      try {
        final r = await ref
            .read(libraryProvider.notifier)
            .importPlaylistFromUrl(urls[i], searchService);
        // Counted by outcome, not by the returned number (a refused import reports the
        // existing playlist's size, which isn't something imported).
        switch (r.outcome) {
          case LinkImportOutcome.created:
          case LinkImportOutcome.replaced:
            written += r.tracks;
          case LinkImportOutcome.keptExisting:
            kept++;
          case LinkImportOutcome.nothingMatched:
          case LinkImportOutcome.failed:
            failed++;
        }
      } catch (_) {
        failed++;
      }
    }

    // Announced whether or not anyone is still watching; the toast needs no
    // BuildContext.
    final parts = <String>[
      if (written > 0) '$written track(s) imported',
      // Named explicitly. "Nothing happened" is the outcome people most need
      // told, and it is the one a count alone cannot express.
      if (kept > 0)
        '$kept playlist(s) left unchanged — delete first to re-import',
      if (failed > 0) '$failed link(s) failed — each must be PUBLIC',
    ];
    AnimatedToast.message(
        parts.isEmpty ? 'Nothing was imported' : parts.join(' · '));

    if (!mounted) return;
    setState(() {
      _busy = false;
      _finished = true;
      _imported = written;
      _kept = kept;
      _failed = failed;
    });
    // Closed only when there is genuinely nothing left to read. A kept playlist
    // is a result the user has to see, so it keeps the sheet open.
    if (failed == 0 && kept == 0) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final progress = ref.watch(libraryProvider.select((s) => s.linkImport));

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 24,
          // Keeps the link fields above the keyboard.
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
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
              Center(child: _grabber()),
              const SizedBox(height: 18),
              _header(accent, progress),
              const SizedBox(height: 16),
              if (_busy)
                _progress(accent, progress)
              else
                ..._form(accent),
            ],
          ),
        ),
      ),
    );
  }

  // Header.

  /// Icon tile, name, and a subtitle that states what's true right now (while
  /// importing: how far along it is).
  Widget _header(Color accent, LinkImportProgress? p) {
    final String subtitle;
    if (_busy && p != null && !p.isCounting) {
      subtitle = 'Matching ${p.done} of ${p.total}';
    } else if (_busy) {
      subtitle = 'Reading the playlist…';
    } else if (_finished) {
      // Say what happened, including "nothing was written", which a bare count can't
      // express.
      final bits = <String>[
        if (_imported > 0) '$_imported imported',
        if (_kept > 0) '$_kept left unchanged',
        if (_failed > 0) '$_failed failed',
      ];
      subtitle = bits.isEmpty ? 'Nothing was imported' : bits.join(' · ');
    } else {
      subtitle = 'Playlists, albums or single tracks';
    }

    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: _busy ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(13),
            border:
                Border.all(color: accent.withValues(alpha: _busy ? 0.34 : 0.18)),
          ),
          // Same glyph as the control that opened it, so the sheet is
          // recognisably the thing that was tapped.
          child: Icon(Icons.add_link_rounded, color: accent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Import from a link',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _busy || _finished
                      ? accent
                      : Colors.white.withValues(alpha: 0.60),
                  fontSize: 12.5,
                  fontWeight:
                      _busy || _finished ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        // The guidance lives behind an info hint.
        InfoHint(
          title: 'Importing from Spotify',
          message:
              'Paste one or more Spotify links — playlists, albums or single '
              'tracks. Each one becomes its own Auvy playlist.\n\n'
              'The playlist must be PUBLIC for Auvy to read it. In Spotify: '
              'open it → ⋯ → Share → Copy link. A link that fails is almost '
              'always still private.\n\n'
              'Auvy matches each track to the closest result on YouTube Music, '
              'so occasional mismatches on rare or live recordings are normal.\n\n'
              'Importing the same link again replaces the playlist if the new '
              'copy has more tracks, so a short import can be completed by '
              'pasting it a second time.',
          tint: accent,
        ),
      ],
    );
  }

  // While importing.

  Widget _progress(Color accent, LinkImportProgress? p) {
    // A null fraction keeps the bar indeterminate while the track list is still being
    // fetched from Spotify, so it doesn't look stuck at 0%.
    final fraction = p?.fraction;
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
        Text(
          p == null || p.isCounting
              ? 'Reading the playlist from Spotify…'
              : '${p.done} of ${p.total} matched'
                  '${p.name.isEmpty ? '' : ' · ${p.name}'}',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        if (_linkCount > 1) ...[
          const SizedBox(height: 3),
          Text('Link ${_linkIndex + 1} of $_linkCount',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45), fontSize: 11.5)),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 14, color: Colors.white.withValues(alpha: 0.40)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'This keeps running if you close the sheet. Progress stays on '
                'your Library.',
                style: TextStyle(
                    // Held at reading contrast: this is the line that answers
                    // "can I close this", which is the whole reason it is here.
                    color: Colors.white.withValues(alpha: 0.60),
                    fontSize: 11.5,
                    height: 1.3),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // The form.

  List<Widget> _form(Color accent) {
    return [
      for (var i = 0; i < _fields.length; i++) ...[
        if (i > 0) const SizedBox(height: 10),
        _linkField(accent, i),
      ],
      const SizedBox(height: 6),
      // A row, not a TextButton with an icon — the same shape every other
      // secondary choice in the app takes.
      _row(
        icon: Icons.add_rounded,
        label: 'Add another link',
        subtitle: 'Each one becomes its own playlist',
        accent: accent,
        onTap: () {
          HapticService.light();
          setState(() => _fields.add(TextEditingController()));
        },
      ),
      const SizedBox(height: 10),
      _primaryButton(accent),
    ];
  }

  Widget _linkField(Color accent, int i) {
    return TextField(
      controller: _fields[i],
      autofocus: i == 0,
      keyboardType: TextInputType.url,
      textInputAction:
          i == _fields.length - 1 ? TextInputAction.go : TextInputAction.next,
      onSubmitted: (_) {
        if (i == _fields.length - 1) _import();
      },
      style: const TextStyle(color: Colors.white, fontSize: 14),
      cursorColor: accent,
      decoration: InputDecoration(
        hintText: 'https://open.spotify.com/playlist/…',
        // A specimen URL is the only thing saying WHAT to paste, so it is
        // informative text and clears the contrast bar like any other.
        hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.55), fontSize: 13.5),
        prefixIcon: Icon(Icons.link_rounded, color: accent, size: 18),
        // Only past the first: removing the only field would leave nothing to
        // paste into and no way back.
        suffixIcon: _fields.length > 1
            ? IconButton(
                icon: Icon(Icons.close_rounded,
                    size: 17, color: Colors.white.withValues(alpha: 0.45)),
                tooltip: 'Remove this link',
                onPressed: () {
                  HapticService.light();
                  setState(() => _fields.removeAt(i).dispose());
                },
              )
            : null,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.09)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
      ),
    );
  }

  Widget _primaryButton(Color accent) {
    return Semantics(
      button: true,
      label: 'Import',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _import,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 48,
            width: double.infinity,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.55)),
            ),
            child: Center(
              child: Text('Import',
                  style: TextStyle(
                      color: accent,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }

  // Small pieces.

  /// The app's standard choice row. Same metrics as the sleep timer's.
  Widget _row({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color accent,
    required VoidCallback onTap,
  }) {
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
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.50),
                            fontSize: 11.5,
                            height: 1.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grabber() => Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2)),
      );
}
