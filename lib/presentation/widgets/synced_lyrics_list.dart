import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/providers/lyrics_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/romanization_service.dart';

class SyncedLyricsList extends ConsumerStatefulWidget {
  final List<LyricLine> linesToDisplay;
  final Function(Duration) onLineTapped;
  /// The line playing RIGHT NOW, recomputed by the parent on every position tick.
  ///
  /// **−1 means the song has not reached its first line yet** (an intro). That
  /// case needs its own value rather than collapsing to 0: with 0, line one was
  /// styled as though it were being sung during the whole intro, and — worse —
  /// the list anchored to it.
  ///
  /// THIS IS THE AUTHORITY, not `activeLyricIndexProvider`. The provider is
  /// global and only updated from a post-frame callback, while this subtree is
  /// destroyed and rebuilt on every flip back to the lyrics face. So on a fresh
  /// mount the provider could still hold the PREVIOUS mount's index: the list
  /// would be born at that stale line, animate to it, then animate back once the
  /// callback corrected the provider. That double movement is the "tweaking" seen
  /// when flipping back and forth before the first line. Reading the value the
  /// parent computed synchronously removes the race entirely.
  final int activeIndex;

  const SyncedLyricsList({
    Key? key,
    required this.linesToDisplay,
    required this.onLineTapped,
    this.activeIndex = -1,
  }) : super(key: key);

  @override
  ConsumerState<SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends ConsumerState<SyncedLyricsList> {
  /// Where the active line sits in the card, as a fraction from the top.
  ///
  /// Sits ABOVE the true middle on purpose. The anchor positions a line's
  /// LEADING edge, so a two-line lyric hangs below the mark — park it at 0.5 and
  /// long lines read low. It also keeps more of the song ahead of you than
  /// behind, which is the direction you are actually reading.
  ///
  /// All four anchor sites read this. A resting anchor that disagrees with the
  /// auto-scroll anchor makes the pane lurch the instant line one is sung.
  static const double _anchor = 0.3;

  final ItemScrollController _isc = ItemScrollController();
  bool _isUserScrolling = false;

  static const bool _kDebugLog =
      bool.fromEnvironment('AUVY_DEBUG_LOG', defaultValue: false);

  /// Last lyric set reported, so the summary below prints once per song rather
  /// than on every position tick.
  String _lastRomanReport = "";

  /// The scripts to romanise THIS lyric with, decided once for the whole song.
  ///
  /// Recomputed only when the lyric identity changes, not per line and not per
  /// position tick: the ideograph scan walks the entire text, and itemBuilder
  /// runs for every visible row several times a second.
  Set<RomanizableScript>? _lyricScripts;
  String _lyricScriptsFor = "";

  Set<RomanizableScript> _scriptsForCurrentLyric() {
    // Same identity the ScrollablePositionedList is keyed on — cheap, and it
    // changes exactly when the words do.
    final id = widget.linesToDisplay.isEmpty
        ? "empty"
        : '${widget.linesToDisplay.length}:${widget.linesToDisplay.first.words}'
          ":${ListeningPolicy.romanizeScripts.length}";
    final cached = _lyricScripts;
    if (cached != null && _lyricScriptsFor == id) return cached;
    final whole = widget.linesToDisplay.map((l) => l.words).join(" ");
    final scripts = ListeningPolicy.scriptsForLyric(whole);
    _lyricScripts = scripts;
    _lyricScriptsFor = id;
    return scripts;
  }

  /// Romanisation, one line per song.
  ///
  /// "Romanisation does nothing" has four distinct causes and they are
  /// indistinguishable from the outside:
  ///   1. the lyric contains no convertible script at all (a Latin song, or a
  ///      Chinese/kanji-only one, which this deliberately does not attempt);
  ///   2. it does, but that script is not switched on;
  ///   3. it is switched on, and the conversion genuinely changed nothing;
  ///   4. the toggle never persisted (see the load/set logs in ListeningPolicy).
  ///
  /// Printing DETECTED against ENABLED separates all four, which a per-line log
  /// would bury under a hundred lines of noise.
  void _reportRomanization() {
    if (!_kDebugLog || widget.linesToDisplay.isEmpty) return;
    // Separator is irrelevant: detection is per character.
    final joined = widget.linesToDisplay.map((l) => l.words).join(" ");
    final detected = RomanizationService.scriptsIn(joined);
    final enabled = ListeningPolicy.romanizeScripts;
    // What will ACTUALLY be used, after the song-wide kana decision.
    final effective = ListeningPolicy.scriptsForLyric(joined);
    final applied = detected.intersection(effective);
    var changed = 0;
    if (applied.isNotEmpty) {
      for (final l in widget.linesToDisplay) {
        if (ListeningPolicy.romanizeLine(l.words, scripts: effective) !=
            l.words) changed++;
      }
    }
    // Named separately so the log distinguishes "you did not enable it" from
    // "it was enabled and the song ruled it out".
    final suppressed = enabled.difference(effective);
    final report =
        "${widget.linesToDisplay.length}|${detected.map((s) => s.key).join(",")}"
        "|${enabled.map((s) => s.key).join(",")}|$changed";
    if (report == _lastRomanReport) return;
    _lastRomanReport = report;
    print("LT romanize: lines=${widget.linesToDisplay.length} "
        "${suppressed.isEmpty ? '' : 'suppressed=${suppressed.map((s) => s.key).join('+')}(kanji) '}"
        "detected=${detected.isEmpty ? "none" : detected.map((s) => s.key).join("+")} "
        "enabled=${enabled.isEmpty ? "none" : enabled.map((s) => s.key).join("+")} "
        "applied=${applied.isEmpty ? "none" : applied.map((s) => s.key).join("+")} "
        "changedLines=$changed/${widget.linesToDisplay.length} "
        "asMain=${ListeningPolicy.romanizeAsMain}");
  }

  /// Auto-scroll follows the PROP, not a provider listener.
  ///
  /// It used to `ref.listen(activeLyricIndexProvider)`, which fires on a global
  /// value updated from a post-frame callback — one frame late, and stale on a
  /// fresh mount. `didUpdateWidget` fires exactly when the parent hands down a
  /// new line, in the same frame, and only for THIS instance.
  @override
  void didUpdateWidget(SyncedLyricsList old) {
    super.didUpdateWidget(old);
    // Before the early returns below — the interesting case is lyrics arriving
    // or the toggle changing, and both can leave activeIndex untouched.
    _reportRomanization();
    final next = widget.activeIndex;

    // The lines arriving is also a reason to re-anchor.
    //
    // Lyrics load asynchronously, so this list is routinely built EMPTY and
    // populated a moment later. `initialScrollIndex` only applies to the first
    // build, so it anchored an empty list, and when the lines landed the
    // activeIndex had not changed (−1 both times), the early return below fired,
    // and the list stayed at pixel 0. Pixel 0 is the top of the 250px leading
    // pad, NOT line one at the anchor, which is exactly the "it never actually
    // centres" the owner reported.
    final bool linesArrived =
        widget.linesToDisplay.length != old.linesToDisplay.length;
    if (next == old.activeIndex && !linesArrived) return;
    if (_isUserScrolling) return;
    if (widget.linesToDisplay.isEmpty) return;
    //"NOT ATTACHED YET" IS NOT "NOTHING TO DO" — RETRY, DON'T DROP IT.
    //
    // This used to bail out whenever `!_isc.isAttached`, and that is exactly the
    // state on the frame the lyrics arrive: the list is being rebuilt (its key is
    // the text identity, which just changed from 'empty'), so the controller is
    // between attachments. The one re-anchor that mattered — the first population,
    // mid-song — was therefore the one most likely to be thrown away, leaving the
    // pane at the top of the 250px leading pad until the NEXT line change moved
    // it. That is the "brief unsynced moment when the lyrics open".
    //
    // One post-frame retry is enough: by the next frame the rebuilt list has
    // attached. Guarded on mounted + still-attached + the index not having moved
    // on, so a retry can never fight a newer scroll.
    if (!_isc.isAttached) {
      final pending = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isUserScrolling) return;
        if (!_isc.isAttached || widget.linesToDisplay.isEmpty) return;
        if (widget.activeIndex != pending) return; // superseded
        _isc.jumpTo(
          index: pending < 0
              ? 0
              : pending.clamp(0, widget.linesToDisplay.length - 1),
          alignment: _anchor,
        );
      });
      return;
    }
    // −1 PARKS ON LINE ONE, it does not mean "do nothing"
    //
    // TWO BEHAVIOURS, ONE NUMBER — keep them apart. −1 says "nothing has been
    // sung yet", which is a HIGHLIGHT state, not a SCROLL state:
    //
    //   • highlight — the isActive test below compares index == activeIndex, and
    //     −1 can never match, so during an intro nothing is lit up.
    //   • scroll    — the list still has to sit somewhere, and that somewhere is
    //     line one, waiting (the target below turns −1 into 0).
    //
    // Collapsing the two by sending 0 from the caller was tried and is WRONG: it
    // highlights line one through the whole intro, as if it were being sung.
    //
    // This used to `return` on −1. That is fine on a fresh mount, where
    // initialScrollIndex already clamps to 0, but not when the TRACK CHANGES
    // with the lyrics card open: the index drops from wherever it was straight
    // to −1, the early return left the list parked in the middle of the
    // previous song, and the new song's first line was off-screen above. The
    // card looked like it was floating somewhere in the lyrics instead of
    // waiting at the top for the first line to be sung.
    final int target = next < 0 ? 0 : next.clamp(0, widget.linesToDisplay.length - 1);
    if (linesArrived && old.linesToDisplay.isEmpty) {
      // First population: be THERE, do not slide there. Animating from an empty
      // list reads as the pane drifting on open.
      _isc.jumpTo(index: target, alignment: _anchor);
      return;
    }
    _isc.scrollTo(
      index: target,
      alignment: _anchor,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
    );
  }

  // Lyric sharing
  //
  // Selection lives in THIS widget rather than the player page because the page
  // rebuilds this subtree from scratch on every flip back to the lyrics card;
  // state held above would have to be threaded down and reset anyway.
  //
  // Deliberately NOT on long-press. Long-press already means "the song is
  // here right now" (the sync nudge), which is a gesture worth protecting — it
  // is used mid-listen, one-handed, on the line you can hear. Overloading it
  // with a second meaning would make both feel unreliable. Selection is entered
  // explicitly from the button instead, and while it is active a tap SELECTS
  // rather than seeks, so the two modes never interpret the same gesture
  // differently at the same time.
  bool _selecting = false;
  final Set<int> _selected = {};

  /// User-configurable in Settings → Playback. Default 6 — a chorus or a couplet;
  /// the card is a fixed 9:16, so every extra line shrinks the type.
  int get _maxLines => ListeningPolicy.lyricShareMaxLines;

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleLine(int index) {
    HapticService.light();
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        if (_selected.length >= _maxLines) {
          AnimatedToast.message('Up to $_maxLines lines');
          return;
        }
        _selected.add(index);
      }
    });
  }

  void _shareSelection() {
    final song = ref.read(playerProvider).currentSong;
    if (song == null || _selected.isEmpty) return;
    // Document order, whatever order they were tapped in — a quote that runs
    // backwards is never what was meant.
    final ordered = _selected.toList()..sort();
    final lines = ordered
        .where((i) => i >= 0 && i < widget.linesToDisplay.length)
        .map((i) => widget.linesToDisplay[i].words.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (lines.isEmpty) return;
    HapticService.medium();
    showSharePostcardDialog(
      context,
      song,
      ref.read(themeProvider),
      kind: PostcardKind.lyrics,
      lyricLines: lines,
      // The rendition actually on screen. Auvy can show machine translations, and
      // a translated line shared as the songwriter's words misattributes them —
      // the recipient can't tell, so the card states it.
      lyricLanguage: ref.read(currentLyricsLanguageProvider),
    );
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    // The parent's synchronously-computed line, not the global provider — see
    // [SyncedLyricsList.activeIndex] for why the provider is unsafe on remount.
    // −1 while the song is still before its first line, so nothing is highlighted
    // and nothing is scrolled to during an intro.
    final activeIndex = widget.activeIndex;

    return Stack(
      children: [
        // Fading Gradient Mask
        ShaderMask(
          shaderCallback: (Rect rect) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent, 
                Colors.black,       
                Colors.black,       
                Colors.transparent, 
              ],
              stops: [0.0, 0.15, 0.85, 1.0], 
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: NotificationListener<ScrollNotification>(
            onNotification: (scrollInfo) {
              if (scrollInfo is UserScrollNotification) {
                if (scrollInfo.direction != ScrollDirection.idle) {
                  if (!_isUserScrolling) {
                    setState(() {
                      _isUserScrolling = true;
                    });
                  }
                }
              }
              return false;
            },
            child: ScrollablePositionedList.builder(
              // Keyed on the TEXT identity, not the list instance. Transcript
              // offset nudges emit a new list with identical words — the old
              // instance key recreated the whole scroll view and snapped it to
              // the top on every nudge. A different song/translation (different
              // words) still resets the view as before.
              key: ValueKey(widget.linesToDisplay.isEmpty
                  ? 'empty'
                  : '${widget.linesToDisplay.length}:${widget.linesToDisplay.first.words}:${widget.linesToDisplay.last.words}'),
              itemScrollController: _isc,
              // Born on the line that's playing right now (see initialIndex) —
              // same anchor the auto-scroll uses.
              // −1 (pre-first-line) anchors at the TOP, which is where an intro
              // should sit. clamp handles it: max(0, …).
              initialScrollIndex: widget.activeIndex
                  .clamp(0, widget.linesToDisplay.isEmpty ? 0 : widget.linesToDisplay.length - 1),
              initialAlignment: _anchor,
              padding: const EdgeInsets.symmetric(vertical: 250, horizontal: 24),
              itemCount: widget.linesToDisplay.length,
              itemBuilder: (context, index) {
                final isActive = index == activeIndex;
                final line = widget.linesToDisplay[index];

                // Romanisation (Settings → Lyrics)
                // Computed per VISIBLE line, which is cheap and also correct:
                // the toggles can change while the player is open, and a value
                // cached at load time would go stale. Lines are only rebuilt when
                // on screen (`ScrollablePositionedList` is lazy).
                final String original = line.words;
                // ONE DECISION FOR THE WHOLE SONG, not one per line. A lyric
                // sheet with six romaji lines among twenty-seven Japanese ones
                // is a jumble. See ListeningPolicy.scriptsForLyric.
                final lyricScripts = _scriptsForCurrentLyric();
                final String romanized = lyricScripts.isEmpty
                    ? ''
                    // Via the policy helper, NOT the service directly: the
                    // service defaults its three system parameters, so a
                    // direct call here would quietly render Hepburn while the
                    // settings screen previewed Kunrei.
                    : ListeningPolicy.romanizeLine(original,
                        scripts: lyricScripts);
                // Only treat it as a romanisation if it actually CHANGED the line
                // — an all-Latin lyric would otherwise get a duplicate copy of
                // itself printed underneath.
                final bool hasRomanization =
                    romanized.isNotEmpty && romanized != original;
                final String displayText = (hasRomanization &&
                        ListeningPolicy.romanizeAsMain)
                    ? romanized
                    : original;
                // Shown under the line unless it IS the line.
                final String? subLine =
                    (hasRomanization && !ListeningPolicy.romanizeAsMain)
                        ? romanized
                        : null;

                final double targetBlur = isActive || _isUserScrolling ? 0.0 : 1.5;
                final bool isNearActive = (index - activeIndex).abs() <= 2; 

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      // In selection mode a tap picks the line instead of
                      // seeking to it — sharing a quote shouldn't mean jumping
                      // the playhead around the song while you choose.
                      if (_selecting) {
                        _toggleLine(index);
                        return;
                      }
                      widget.onLineTapped(line.startTime);
                      setState(() {
                        _isUserScrolling = false;
                      });
                    },
                    // Long-press a line to declare "this is what's playing
                    // right now" — the sync offset is computed from it in one
                    // gesture. Originally podcast-only (ad-insertion shift);
                    // now also on music lyrics, whose LRC timing is
                    // occasionally offset against the resolved stream.
                    onLongPress: () {
                      // Sync-to-this-line is meaningless while choosing a quote,
                      // and would move the playhead under the user mid-selection.
                      if (_selecting) return;
                      final song = ref.read(playerProvider).currentSong;
                      if (song == null) return;
                      final isPodcast = song.albumTitle == 'Podcast';
                      HapticService.medium();
                      final pos = currentPositionProvider.value;
                      final oldOffset = ref.read(podcastLyricsOffsetProvider);
                      // Rendered time = original + oldOffset − 200ms advance;
                      // recover the original, then pin it to the playhead.
                      final original = line.startTime -
                          oldOffset +
                          const Duration(milliseconds: 200);
                      final newOffset = pos - original;
                      ref.read(podcastLyricsOffsetProvider.notifier).state =
                          newOffset;
                      // Remember the nudge for THIS song so the next listen
                      // starts in sync instead of resetting to zero.
                      saveLyricOffsetForSong(song.id, newOffset);
                      setState(() => _isUserScrolling = false);
                      AnimatedToast.show(context,
                          text: isPodcast
                              ? 'Transcript synced to this line'
                              : 'Lyrics synced to this line',
                          icon: Icons.my_location,
                          color: ref.read(themeProvider));
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      // Selected lines get a tinted plate. Only drawn while
                      // selecting, so normal reading is unchanged.
                      decoration: _selecting && _selected.contains(index)
                          ? BoxDecoration(
                              color: ref
                                  .read(themeProvider)
                                  .withOpacity(0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: ref
                                      .read(themeProvider)
                                      .withOpacity(0.55)),
                            )
                          : null,
                      child: TweenAnimationBuilder<double>(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                        tween: Tween<double>(end: targetBlur),
                        builder: (context, blur, child) {
                          final text = AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : Colors.white.withOpacity(isNearActive ? 0.65 : 0.35),
                              // Scaled by the Settings → Lyrics size control, but
                              // still ONE size for active and inactive lines: the
                              // original note holds — animating the font size per
                              // line makes the whole column re-lay-out on every
                              // beat, which is the morphing jump. Emphasis comes
                              // from weight, colour and blur instead.
                              fontSize: 24 * ListeningPolicy.lyricTextScale,
                              fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                              height: 1.4, // Keeping height constant is vital for stability
                              shadows: isActive
                                  ? [Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 12, offset: const Offset(0, 2))]
                                  : [],
                            ),
                            child: subLine == null
                                ? (isActive && line.hasWordTiming &&
                                        displayText == original
                                    //`displayText == original` is a
                                    // CORRECTNESS guard, not an optimisation.
                                    // Word timings index the ORIGINAL words; if
                                    // the line on screen is a romanisation (or
                                    // any other transform) the token boundaries
                                    // no longer correspond, and highlighting
                                    // would light up the wrong syllables. Those
                                    // lines keep the line-level highlight.
                                    ? _KaraokeLine(
                                        line: line,
                                        centered:
                                            ListeningPolicy.lyricsCentered)
                                    : Text(displayText,
                                        textAlign: ListeningPolicy.lyricsCentered
                                            ? TextAlign.center
                                            : TextAlign.left))
                                : Column(
                                    crossAxisAlignment:
                                        ListeningPolicy.lyricsCentered
                                            ? CrossAxisAlignment.center
                                            : CrossAxisAlignment.start,
                                    children: [
                                      Text(displayText,
                                          textAlign:
                                              ListeningPolicy.lyricsCentered
                                                  ? TextAlign.center
                                                  : TextAlign.left),
                                      const SizedBox(height: 2),
                                      // Quieter and smaller — a pronunciation aid
                                      // under the line, not a second lyric
                                      // competing with it. Inherits nothing from
                                      // the AnimatedDefaultTextStyle above, so it
                                      // stays put while the active line animates.
                                      Text(
                                        subLine,
                                        textAlign:
                                            ListeningPolicy.lyricsCentered
                                                ? TextAlign.center
                                                : TextAlign.left,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(
                                              isActive ? 0.62 : 0.28),
                                          fontSize:
                                              15 * ListeningPolicy.lyricTextScale,
                                          fontWeight: FontWeight.w500,
                                          height: 1.3,
                                        ),
                                      ),
                                    ],
                                  ),
                          );
                          // Skip the filter entirely at (near-)zero blur — a
                          // 0-sigma ImageFiltered still forces a saveLayer per
                          // line, i.e. dozens per frame while lyrics scroll.
                          if (blur < 0.05) return text;
                          return ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                            child: text,
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // "Back to the playhead"
        //
        // Was a bottom-right extended FAB: a filled pill, 56pt tall, parked
        // directly over the lyrics it was meant to help you read, and in the
        // middle of the text at that. Now a small ghost chip in the top-right
        // corner, matching the quote button's weight and using the accent as an
        // outline rather than a fill, so it reads as available instead of urgent.
        //
        // Hidden while selecting: jumping to the playhead is meaningless when
        // taps are picking lines.
        if (_isUserScrolling && !_selecting)
          Positioned(
            top: 8,
            right: 8,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (context, val, child) => Opacity(
                opacity: val.clamp(0.0, 1.0),
                child: Transform.translate(
                    offset: Offset(0, -6 * (1 - val)), child: child),
              ),
              child: _GhostChip(
                icon: Icons.my_location_rounded,
                label: 'Sync',
                accent: ref.read(themeProvider),
                onTap: () {
                  HapticService.light();
                  setState(() {
                    _isUserScrolling = false;
                  });
                  // clamp: activeIndex is −1 before the first line, and
                  // scrollTo(-1) throws. Recentring during an intro means line
                  // one.
                  if (_isc.isAttached && widget.linesToDisplay.isNotEmpty) {
                    _isc.scrollTo(
                      index: activeIndex.clamp(
                          0, widget.linesToDisplay.length - 1),
                      alignment: _anchor,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeInOut,
                    );
                  }
                },
              ),
            ),
          ),

        // Enter selection
        //
        // Top-LEFT, so it never trades places with the Sync chip that appears
        // opposite it. NOT hidden while scrolling: an earlier version gated it
        // on `!_isUserScrolling` and the button vanished exactly when it was
        // needed most — scrolling the lyrics to find the line you want to quote
        // is the normal way into this feature.
        if (!_selecting)
          Positioned(
            top: 8,
            left: 8,
            child: _GlassIconButton(
              icon: Icons.format_quote_rounded,
              tooltip: 'Share lyrics',
              onTap: () {
                HapticService.light();
                setState(() {
                  _selecting = true;
                  _selected.clear();
                });
              },
            ),
          ),

        // Selection action bar
        if (_selecting)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _SelectionBar(
              count: _selected.length,
              max: _maxLines,
              accent: ref.read(themeProvider),
              onCancel: _exitSelection,
              onShare: _selected.isEmpty ? null : _shareSelection,
            ),
          ),
      ],
    );
  }
}

/// Compact outlined chip: accent as a border and glyph, not a fill.
///
/// Sized to sit level with [_GlassIconButton] on the opposite corner so the two
/// read as a matched pair rather than one button and one interruption.
class _GhostChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const _GhostChip({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: accent.withOpacity(0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: accent),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// Small translucent circular button. Plain container fill rather than a
/// BackdropFilter: this sits over scrolling lyrics, and a real blur here would
/// force a saveLayer on every frame of that scroll.
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.35),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.14)),
          ),
          child: Icon(icon, color: Colors.white.withOpacity(0.85), size: 19),
        ),
      ),
    );
  }
}

/// The bar shown while picking lines: how many are chosen, cancel, share.
///
/// States the LIMIT up front rather than only complaining when it's hit — being
/// told "up to 6" after tapping a seventh line is a worse experience than
/// knowing the budget while choosing.
class _SelectionBar extends StatelessWidget {
  final int count;
  final int max;
  final Color accent;
  final VoidCallback onCancel;
  final VoidCallback? onShare;

  const _SelectionBar({
    required this.count,
    required this.max,
    required this.accent,
    required this.onCancel,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF15151A).withOpacity(0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 0
                  ? 'Tap lines to share · up to $max'
                  : '$count of $max selected',
              style: TextStyle(
                color: count == 0 ? Colors.white.withOpacity(0.78) : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.78),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          Opacity(
            opacity: onShare == null ? 0.35 : 1,
            child: GestureDetector(
              onTap: onShare,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.ios_share_rounded,
                        size: 15, color: Colors.black),
                    SizedBox(width: 7),
                    Text('Share',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
/// The ACTIVE line, highlighted word by word.
///
/// Only ever built for a line that carries real `<mm:ss.xx>` word timings from
/// the provider (see [LyricLine.timedWords]) and whose displayed text is the
/// original, untransformed words — the call site guards both.
///
/// WHY ITS OWN WIDGET. Word highlighting needs the live playback position, which
/// ticks several times a second. `SyncedLyricsList` deliberately does NOT take
/// the position as a prop: doing so would rebuild the whole lyric column — and
/// re-run romanisation for every visible line — on every tick. Listening to
/// `currentPositionProvider` down here confines those rebuilds to the single line
/// being sung. (The provider is a plain `ValueNotifier<Duration>`, which is
/// exactly what makes that scoping possible.)
class _KaraokeLine extends StatelessWidget {
  final LyricLine line;
  final bool centered;
  const _KaraokeLine({required this.line, required this.centered});

  @override
  Widget build(BuildContext context) {
    final words = line.timedWords!;
    // Inherits size/weight/shadow from the AnimatedDefaultTextStyle above, so the
    // karaoke line and a plain active line are typographically identical — only
    // the per-word colour differs. Anything else would make the highlight look
    // like a different font appearing mid-song.
    final base = DefaultTextStyle.of(context).style;

    return ValueListenableBuilder<Duration>(
      valueListenable: currentPositionProvider,
      builder: (context, pos, _) {
        return Text.rich(
          TextSpan(
            children: [
              for (int i = 0; i < words.length; i++)
                TextSpan(
                  text: words[i].text,
                  style: base.copyWith(
                    // A word is "sung" once its own timestamp has passed. The
                    // NEXT word's timestamp is what ends it, so the last word
                    // stays lit until the line changes, which is correct: it is
                    // still being held.
                    color: pos >= words[i].start
                        ? Colors.white
                        // Not fully hidden: an unsung word has to stay readable
                        // so you can see what is coming. Karaoke that blanks the
                        // rest of the line is useless for reading ahead.
                        : Colors.white.withOpacity(0.42),
                  ),
                ),
            ],
          ),
          textAlign: centered ? TextAlign.center : TextAlign.left,
        );
      },
    );
  }
}
