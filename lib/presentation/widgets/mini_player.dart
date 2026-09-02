import 'dart:async';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/mini_player_style_provider.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';

/// Compact now-playing bar. Sleek matte card: rounded artwork, title/artist,
/// like + play/pause, and a live progress hairline along the BOTTOM edge.
/// All gestures preserved: swipe sideways to skip, swipe up (or tap) to open
/// the player, swipe down to dismiss.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer>
    with TickerProviderStateMixin {
  // Drag variables
  double _dragX = 0.0;
  double _dragY = 0.0;

  late AnimationController _recenterController;
  late Animation<Offset> _recenterAnimation;

  // Dock-style landing pop when a queue ghost lands on the bar.
  late AnimationController _bounceController;
  late Animation<double> _bounceScale;

  final double _triggerThreshold = 70.0;
  String? _currentSongId;
  bool _isTransitioningToNewSong = false;
  Timer? _transitionTimeoutTimer;

  /// How long a loading state must HOLD before the dim overlay + spinner appear.
  /// Long enough that a pause-induced blip never shows, short enough that a real
  /// stall still reports itself promptly.
  static const Duration _spinnerDelay = Duration(milliseconds: 400);
  bool _spinnerVisible = false;
  Timer? _spinnerTimer;

  /// Arm or disarm the delayed spinner. Called from build with the raw
  /// condition; only flips [_spinnerVisible] after the delay, and hides it
  /// immediately when the condition clears.
  void _syncSpinner(bool want) {
    if (want) {
      if (_spinnerVisible || _spinnerTimer != null) return;
      _spinnerTimer = Timer(_spinnerDelay, () {
        _spinnerTimer = null;
        if (mounted) setState(() => _spinnerVisible = true);
      });
    } else {
      _spinnerTimer?.cancel();
      _spinnerTimer = null;
      if (_spinnerVisible) {
        // Post-frame: this runs from build, and setState during build throws.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _spinnerVisible = false);
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Elastic snap-back controller
    _recenterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _recenterController.addListener(() {
      setState(() {
        _dragX = _recenterAnimation.value.dx;
        _dragY = _recenterAnimation.value.dy;
      });
    });

    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _bounceScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.07), weight: 35),
      TweenSequenceItem(tween: Tween(begin: 1.07, end: 0.97), weight: 35),
      TweenSequenceItem(tween: Tween(begin: 0.97, end: 1.0), weight: 30),
    ]).animate(
        CurvedAnimation(parent: _bounceController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _recenterController.dispose();
    _bounceController.dispose();
    _transitionTimeoutTimer?.cancel();
    _spinnerTimer?.cancel();
    super.dispose();
  }

  void _handleDragEnd(Velocity velocity) {
    final isLiveRadio = _currentSongId?.startsWith('http') ?? false;

    // 1. SWIPE UP -> Open Player
    if (_dragY < -(MediaQuery.of(context).size.height * 0.15) ||
        velocity.pixelsPerSecond.dy < -600) {
      ref.read(playerProvider.notifier).updateSwipeProgress(0.0);
      _openPlayer(context);

      // Reset drag state once the PlayerPage covers the mini-player. Tracks
      // HydrvMotion.sheetEnterDuration rather than hardcoding a guess — resetting
      // early leaves the mini-player visibly snapping back underneath a
      // still-transparent player.
      Future.delayed(HydrvMotion.sheetEnterDuration, () {
        if (mounted) setState(() { _dragX = 0.0; _dragY = 0.0; });
      });

      return;
    }

    // 2. SWIPE DOWN -> Completely Remove
    if (_dragY > _triggerThreshold || velocity.pixelsPerSecond.dy > 600) {
      HapticService.medium();
      ref.read(playerProvider.notifier).dismissMiniPlayer();
      return;
    }

    ref.read(playerProvider.notifier).updateSwipeProgress(0.0);

    // 3. HORIZONTAL SWIPE -> Skip Tracks
    if (!isLiveRadio && _dragX.abs() > _triggerThreshold) {
      HapticService.light();
      if (_dragX > 0) {
        ref.read(playerProvider.notifier).playPrevious();
      } else {
        ref.read(playerProvider.notifier).playNext();
      }
    }

    // 4. Snap Back
    _recenterAnimation =
        Tween<Offset>(begin: Offset(_dragX, _dragY), end: Offset.zero).animate(
            CurvedAnimation(parent: _recenterController, curve: Curves.elasticOut));
    _recenterController.reset();
    _recenterController.forward();
  }

  void _openPlayer(BuildContext context) {
    // Never stack a second PlayerPage on top of one that's already showing.
    if (AppNavigation.isPlayerOpen) return;
    HapticService.light();
    // Shared HYDRV sheet route — same one the media-notification path uses.
    Navigator.of(context).push(AppNavigation.playerRoute());
  }

  @override
  Widget build(BuildContext context) {
    // Queue ghost landed → macOS-dock pop.
    ref.listen<int>(miniPlayerBounceProvider, (prev, next) {
      if (prev != next) _bounceController.forward(from: 0);
    });

    // Clean up drag state on song change
    ref.listen<String?>(playerProvider.select((s) => s.currentSong?.id), (prev, next) {
      if (next != null && prev != next) {
        if (_dragX != 0.0 || _dragY != 0.0) {
          setState(() { _dragX = 0.0; _dragY = 0.0; });
        }
      }
    });

    final song        = ref.watch(playerProvider.select((s) => s.currentSong));
    final isPlaying   = ref.watch(playerProvider.select((s) => s.isPlaying));
    final isLoading   = ref.watch(playerProvider.select((s) => s.isLoading));
    final swipeProgress = ref.watch(playerProvider.select((s) => s.swipeProgress));
    final isLiked     = ref.watch(libraryProvider.select((s) => s.likedSongIds.contains(song?.id ?? '')));
    final themeColor  = ref.watch(themeProvider);
    // Shape/proportions of the mini-player (Appearance -> Mini-player). Watched,
    // so switching style restyles the bar that is on screen right now.
    final m = MiniPlayerMetrics.of(ref.watch(miniPlayerStyleProvider));

    if (song == null) return const SizedBox.shrink();

    final String? newSongId = song.id;

    // Detect new song
    if (_currentSongId != newSongId) {
      _currentSongId = newSongId;
      _isTransitioningToNewSong = true;

      // SAFETY: Force clear transition flag after 3 seconds (fallback)
      _transitionTimeoutTimer?.cancel();
      _transitionTimeoutTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _isTransitioningToNewSong) {
          setState(() {
            _isTransitioningToNewSong = false;
          });
        }
      });
    }

    // Clear the transition flag as soon as playback actually starts (or the
    // load settles without playing).
    if (_isTransitioningToNewSong) {
      if (isPlaying || (!isLoading && !isPlaying)) {
        _isTransitioningToNewSong = false;
        _transitionTimeoutTimer?.cancel();
      }
    }

    // The spinner is DELAYED, and that is the whole point
    //
    // `isLoading && !isPlaying` fires the instant you PAUSE, because pausing is
    // what makes `!isPlaying` true. If anything had `isLoading` set at that
    // moment — a gapless prefetch of the next track, a recovery retry — the
    // cover darkened 50% and a spinner appeared, then cleared again on the next
    // position tick ~500ms later. That is the flicker seen when pausing a track
    // that has just started: not the artwork changing, the dim overlay flashing
    // over it.
    //
    // A real stall lasts; a transient flag does not. So the overlay only appears
    // once the condition has HELD for [_spinnerDelay]. Genuine buffering still
    // shows it (it lasts far longer), a pause never does.
    final bool wantSpinner =
        _isTransitioningToNewSong || (isLoading && !isPlaying);
    _syncSpinner(wantSpinner);
    final bool showSpinner = _spinnerVisible;

    // Opacity calculation for dismiss gesture
    final double downProgress = (_dragY > 0) ? (_dragY / (_triggerThreshold * 2)) : 0.0;
    final double dismissOpacity = (1.0 - downProgress - swipeProgress).clamp(0.0, 1.0);
    final bool isHorizontalTriggerActive = _dragX.abs() > _triggerThreshold;
    final bool isVerticalTriggerActive = _dragY < -_triggerThreshold;

    return AnimatedBuilder(
      animation: _bounceScale,
      builder: (context, child) =>
          Transform.scale(scale: _bounceScale.value, child: child),
      child: GestureDetector(
      onHorizontalDragUpdate: (details) => setState(() => _dragX += details.delta.dx),
      onHorizontalDragEnd: (details) => _handleDragEnd(details.velocity),
      onVerticalDragUpdate: (details) {
        setState(() {
          _dragY += details.delta.dy;
        });
      },
      onVerticalDragEnd: (details) => _handleDragEnd(details.velocity),
      onTap: () => _openPlayer(context),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // GESTURE FEEDBACK LAYER: Hidden behind the main player
          _buildGestureFeedbackLayer(
              isHorizontalTriggerActive, isVerticalTriggerActive, themeColor, m),

          // MAIN MINI-PLAYER: solid matte card
          Opacity(
            opacity: dismissOpacity,
            child: Transform.translate(
              offset: Offset(_dragX, _dragY),
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: m.horizontalMargin),
                child: Container(
                  height: m.height,
                  decoration: BoxDecoration(
                    // A flat fill for the quiet styles; a faint accent wash for
                    // the one whose job is presence. The wash stays under 20% and
                    // runs corner to corner, so it lifts the surface without ever
                    // competing with the title sitting on it.
                    color: m.accentWash ? null : AppColors.matteBlack,
                    gradient: m.accentWash
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(themeColor.withOpacity(0.16),
                                  AppColors.matteBlack),
                              Color.alphaBlend(themeColor.withOpacity(0.04),
                                  AppColors.matteBlack),
                            ],
                          )
                        : null,
                    // Docked (Bar) keeps its corners only on TOP: rounding the
                    // bottom of something flush with the screen edge just shows
                    // the page through two notches. A pill takes its radius from
                    // its own height. See _surfaceRadius.
                    borderRadius: _surfaceRadius(m),
                    // A floating card needs an edge to separate it from the page.
                    // A docked bar is part of the chrome and reads cleaner without
                    // one — a hairline across the full width looks like a seam.
                    // The lit styles take a faintly tinted edge instead of a grey
                    // one, so the border belongs to the glow beneath it.
                    border: m.docked
                        ? null
                        : Border.all(
                            color: m.accentGlow
                                ? themeColor.withOpacity(0.22)
                                : AppColors.whiteFaded08,
                            width: 1.0),
                    boxShadow: m.docked
                        ? null
                        : [
                            // An accent-tinted shadow reads as LIGHT coming off
                            // the panel; a black one only reads as height. The lit
                            // styles swap the colour rather than adding a layer.
                            BoxShadow(
                              color: m.accentGlow
                                  ? themeColor.withOpacity(0.34)
                                  : Colors.black.withOpacity(0.55),
                              blurRadius: m.accentGlow ? 26 : 18,
                              spreadRadius: m.accentGlow ? -4 : 0,
                              offset: const Offset(0, 8),
                            ),
                            // Kept underneath the glow so the panel still has
                            // weight against bright artwork — a tinted shadow on
                            // its own floats without grounding anything.
                            if (m.accentGlow)
                              BoxShadow(
                                color: Colors.black.withOpacity(0.45),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: _surfaceRadius(m),
                    child: Stack(
                      children: [
                        Row(
                          children: [
                            // Inset scales with the artwork so the cover stays
                            // optically centred in the card at every size.
                            SizedBox(width: m.docked ? 12 : (m.height - m.artwork) / 2),
                            _buildArtwork(song, showSpinner, themeColor,
                                m.artwork, m.artworkRadius),
                            const SizedBox(width: 12),
                            _buildMetadata(song, m.showArtist),
                            _buildActions(song, isLiked, isPlaying, showSpinner, themeColor, m),
                          ],
                        ),
                        // Live progress hairline along the BOTTOM edge.
                        if (m.progress != MiniProgress.ring)
                          _buildBottomProgressBar(themeColor, m.progress,
                              m.pill ? m.height / 2 : 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildGestureFeedbackLayer(bool hActive, bool vActive, Color themeColor, MiniPlayerMetrics m) {
    return Container(
      height: m.height,
      margin: EdgeInsets.symmetric(horizontal: m.horizontalMargin),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.15),
        // Was hardcoded to 18, which was the Card radius. It sits DIRECTLY
        // BEHIND the player, so on any other shape its corners showed past
        // them — most visibly on the pill, whose ends are fully round.
        borderRadius: _surfaceRadius(m),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildFeedbackIcon(Icons.skip_previous_rounded, _dragX > 0, hActive, themeColor),
              _buildFeedbackIcon(Icons.skip_next_rounded, _dragX < 0, hActive, themeColor),
            ],
          ),
          _buildFeedbackIcon(Icons.expand_less_rounded, _dragY < 0, vActive, themeColor),
        ],
      ),
    );
  }

  Widget _buildFeedbackIcon(IconData icon, bool visible, bool active, Color themeColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: AnimatedScale(
        scale: (visible && active) ? 1.4 : 0.8,
        duration: const Duration(milliseconds: 200),
        child: Icon(
          icon,
          color: visible ? (active ? themeColor : Colors.white24) : Colors.transparent,
          size: 30,
        ),
      ),
    );
  }

  /// ONE definition of the surface shape, used by both the decoration and the
  /// clip. They were computed separately before; any future style that changed
  /// one and not the other would clip its own contents square inside a rounded
  /// panel, which is exactly the sort of bug that only shows up on one setting.
  BorderRadius _surfaceRadius(MiniPlayerMetrics m) {
    if (m.docked) {
      return BorderRadius.vertical(top: Radius.circular(m.radius));
    }
    return BorderRadius.circular(m.pill ? m.height / 2 : m.radius);
  }

  /// [radius] is the style's own cover radius, NOT a fraction of [size].
  ///
  /// It used to be `size * 0.24` for everyone, which meant the cover shape was a
  /// function of how tall the bar was, so all four styles landed on the same
  /// mild rounding and the cover never helped tell them apart. Compact now gets
  /// a circle and Bar gets near-square corners because those are design
  /// decisions, not consequences of a height.
  Widget _buildArtwork(dynamic song, bool showSpinner, Color themeColor,
      double size, double radius) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            // Still scaled by the user's cover-art roundness, like every other
            // cover in the app — the style picks the base shape, the user scales
            // it. Clamped to half the size so the roundness slider can never push
            // a cover past a circle.
            borderRadius: BorderRadius.circular(
                ListeningPolicy.roundArtwork(radius).clamp(0.0, size / 2)),
            child: ColorFiltered(
              colorFilter: showSpinner
                  ? ColorFilter.mode(Colors.black.withOpacity(0.5), BlendMode.darken)
                  : const ColorFilter.mode(Colors.transparent, BlendMode.multiply),
              child: AuvyImage(
                // Honour a user-chosen cover. The mini-player reads the playing
                // song from `playerProvider`, so it never passes through
                // `conformedForDisplay` the way list tiles do — without this it
                // kept showing the ORIGINAL art while the full player showed the
                // override, for the same track.
                path: overriddenArtwork(ref, song),
                width: size,
                height: size,
                fit: BoxFit.cover,
              ),
            ),
          ),
          if (showSpinner)
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(themeColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetadata(dynamic song, bool showArtist) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            song.title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                letterSpacing: -0.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Compact drops the artist entirely — that is what makes it a genuinely
          // different row rather than the same row squeezed, and it is what lets
          // the bar be 52px without the text feeling crushed.
          if (showArtist) ...[
            const SizedBox(height: 2),
            Text(
              song.displayArtist,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.72),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(
      // Matches the card height so a Compact bar cannot be overflowed by a
      // taller tap target, and a Spotlight bar has no dead strip beside it.
      dynamic song, bool isLiked, bool isPlaying, bool showSpinner, Color themeColor, MiniPlayerMetrics m) {
    final isLiveRadio = song.id.startsWith('http');
    final barHeight = m.height;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.showLike)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticService.selection();
              ref.read(libraryProvider.notifier).toggleSongLike(song);
            },
            child: Container(
              width: 40,
              height: barHeight,
              alignment: Alignment.center,
              child: Icon(
                isLiked ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                color: isLiked ? themeColor : Colors.white38,
                size: 22,
              ),
            ),
          ),
        // PREV, only where the style is a transport bar. Live radio has nowhere
        // to go back to, so it never gets one.
        if (m.showSkip && !isLiveRadio)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticService.light();
              ref.read(playerProvider.notifier).playPrevious();
            },
            child: Container(
              width: 34,
              height: barHeight,
              alignment: Alignment.center,
              child: const Icon(Icons.skip_previous_rounded,
                  color: Colors.white70, size: 24),
            ),
          ),
        // Dedicated play/pause — clearer than the old tap-the-artwork toggle
        // (tapping the bar opens the player, matching the tutorial).
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (showSpinner) return;
            HapticService.light();
            if (isLiveRadio && !isPlaying) {
              ref.read(playerProvider.notifier).playSong(song, isManual: true, source: "Live Radio");
            } else {
              if (!ref
                  .read(listenTogetherProvider.notifier)
                  .scheduleToggle()) {
                ref.read(playerProvider.notifier).togglePlay();
              }
            }
          },
          child: Container(
            width: 46,
            height: barHeight,
            alignment: Alignment.center,
            child: m.progress == MiniProgress.ring
                // RING: progress drawn around the glyph instead of along an edge,
                // so Spotlight's artwork has no line running under it.
                ? _PlayRing(
                    isPlaying: isPlaying, themeColor: themeColor, ref: ref)
                : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
          ),
        ),
        if (m.showSkip && !isLiveRadio)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticService.light();
              ref.read(playerProvider.notifier).playNext();
            },
            child: Container(
              width: 34,
              height: barHeight,
              alignment: Alignment.center,
              child: const Icon(Icons.skip_next_rounded,
                  color: Colors.white70, size: 24),
            ),
          ),
        const SizedBox(width: 6),
      ],
    );
  }

  /// [sideInset] is how far the hairline is held off each end.
  ///
  /// It was a flat 14, which is right for a rounded rectangle and wrong for a
  /// PILL: at the very bottom of a lozenge the shape only exists between its
  /// two end caps, so a line starting at 14 was clipped to the cap radius and
  /// appeared to begin partway along. The caller passes the radius for pill
  /// styles so the line sits inside the shape it is drawn on.
  Widget _buildBottomProgressBar(
      Color themeColor, MiniProgress placement, double sideInset) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    // Duration is WATCHED live: it resolves ~a second into each track (native
    // onPosition). The old code passed a one-shot ref.read snapshot down from
    // build, so progress was computed against a stale (often the previous
    // track's) duration — the "mini-player bar doesn't track" bug.
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    final crossfadeEnabled = ref.watch(playerProvider.select((s) => s.crossfadeEnabled));
    final isLiveRadio = song?.id.startsWith('http') ?? false;

    if (isLiveRadio) return const SizedBox.shrink();

    final bool onTop = placement == MiniProgress.topLine;
    return Positioned(
      // Bar draws progress along its TOP edge: its bottom edge IS the screen
      // edge, where a 3px line sits half-inside the gesture inset and reads as a
      // rendering artefact rather than a progress bar.
      top: onTop ? 0 : null,
      bottom: onTop ? null : 0,
      // Full width when docked — an inset line on an edge-to-edge bar looks like
      // it stopped short of something.
      left: onTop ? 0 : sideInset,
      right: onTop ? 0 : sideInset,
      child: ValueListenableBuilder<Duration>(
        valueListenable: currentPositionProvider,
        builder: (context, pos, _) {
          final double progress = duration.inMilliseconds > 0
              ? (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
              : 0.0;

          // Crossfade transition indicator (last 5 seconds)
          final bool isCrossfading = crossfadeEnabled &&
              duration.inSeconds > 0 &&
              (duration - pos).inSeconds <= 5 &&
              (duration - pos).inSeconds > 0;

          return Container(
            height: 3,
            decoration: BoxDecoration(
              color: AppColors.whiteFaded04,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
            ),
            child: Stack(
              children: [
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      color: isCrossfading ? Colors.orangeAccent : themeColor,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: isCrossfading
                          ? [const BoxShadow(color: Colors.orangeAccent, blurRadius: 6, spreadRadius: 1)]
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Play/pause glyph with playback progress drawn as a RING around it.
///
/// Spotlight's whole idea is that the artwork carries the bar, so a progress line
/// running along an edge under a 60px cover fights it. Putting progress around
/// the play button keeps the information but moves it to where the thumb already
/// is, and leaves the card's edges clean.
///
/// Listens to `currentPositionProvider` itself rather than taking a value: it is
/// the only part of the mini-player that needs per-tick updates, and rebuilding
/// the whole bar four times a second to move a ring would be wasteful.
class _PlayRing extends StatelessWidget {
  final bool isPlaying;
  final Color themeColor;
  final WidgetRef ref;
  const _PlayRing(
      {required this.isPlaying, required this.themeColor, required this.ref});

  @override
  Widget build(BuildContext context) {
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    return ValueListenableBuilder<Duration>(
      valueListenable: currentPositionProvider,
      builder: (context, pos, _) {
        final double p = duration.inMilliseconds > 0
            ? (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        return SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // strokeAlign inside so the ring cannot overflow the 38px box and
              // clip against the neighbouring buttons.
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  value: p,
                  strokeWidth: 2.2,
                  backgroundColor: Colors.white.withOpacity(0.16),
                  valueColor: AlwaysStoppedAnimation<Color>(themeColor),
                ),
              ),
              Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 22,
              ),
            ],
          ),
        );
      },
    );
  }
}
