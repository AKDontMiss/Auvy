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
import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:auvy/presentation/widgets/queue_fly_overlay.dart';

/// Compact now-playing bar: artwork, title/artist, like and play/pause, with a
/// thin progress line along the bottom edge. Swipe sideways to skip, swipe up
/// (or tap) to open the player, swipe down to dismiss.
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
    // Appearance → Mini-player. Watched, so a new style restyles the bar on screen.
    final m = MiniPlayerMetrics.of(ref.watch(miniPlayerStyleProvider));
    // Only the cover style needs the artwork colour; watching it in the others
    // would rebuild the bar on every song for nothing.
    final Color? cover = m.surface == MiniSurface.cover
        ? _coverSurface(ref.watch(playerColorProvider))
        : null;

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

    // The spinner is delayed: `isLoading && !isPlaying` becomes true the instant you
    // pause if anything has isLoading set (a gapless prefetch, a retry), which would
    // flash a dimmed cover. A real stall lasts, so the overlay only appears once the
    // condition has held for [_spinnerDelay].
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
          // Gesture feedback layer, behind the main player.
          _buildGestureFeedbackLayer(
              isHorizontalTriggerActive, isVerticalTriggerActive, themeColor, m),

          // Main mini-player card.
          Opacity(
            opacity: dismissOpacity,
            child: Transform.translate(
              offset: Offset(_dragX, _dragY),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: m.horizontalMargin),
                // Animated so the cover style eases from one song's colour to
                // the next instead of jumping.
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  // The tour anchor is on the container that draws the bar (inside the horizontal
                  // margin), so the spotlight matches the visible bar. `localToGlobal` accounts for
                  // the transforms above, so it stays correct during a bounce or drag.
                  key: CoachAnchor.keyFor('miniplayer'),
                  height: m.height,
                  decoration: _surfaceDecoration(m, themeColor, cover),
                  child: ClipRRect(
                    borderRadius: _surfaceRadius(m),
                    child: Stack(
                      children: [
                        if (m.progress == MiniProgress.fill) _buildProgressFill(themeColor),
                        Row(
                          children: [
                            // The same inset on three sides, so the cover sits
                            // optically centred in the bar.
                            SizedBox(width: (m.height - m.artwork) / 2),
                            _buildArtwork(song, showSpinner, themeColor, m),
                            const SizedBox(width: 12),
                            _buildMetadata(song),
                            _buildActions(song, isLiked, isPlaying, showSpinner, themeColor, m),
                          ],
                        ),
                        // Live progress hairline along the bottom edge, white on
                        // a cover colour the accent might clash with.
                        if (m.progress == MiniProgress.bottomLine)
                          _buildBottomProgressBar(
                              cover != null ? Colors.white : themeColor,
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

  Widget _buildGestureFeedbackLayer(
      bool hActive, bool vActive, Color themeColor, MiniPlayerMetrics m) {
    return Container(
      height: m.height,
      margin: EdgeInsets.symmetric(horizontal: m.horizontalMargin),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.15),
        // Sits directly behind the bar, so it takes the bar's own corners.
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

  /// One definition of the surface shape, used by the decoration, the clip and
  /// the gesture layer behind it, so they can't disagree.
  BorderRadius _surfaceRadius(MiniPlayerMetrics m) =>
      BorderRadius.circular(m.pill ? m.height / 2 : m.radius);

  /// The cover colour darkened until white text reads on it, keeping its hue, so
  /// a pale cover gives a deep tint rather than a grey.
  static Color _coverSurface(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness(hsl.lightness.clamp(0.10, 0.24)).toColor();
  }

  BoxDecoration _surfaceDecoration(
      MiniPlayerMetrics m, Color themeColor, Color? cover) {
    final radius = _surfaceRadius(m);
    // A plain shadow: it gives height without colouring anything.
    final grounded = BoxShadow(
      color: Colors.black.withOpacity(0.55),
      blurRadius: 18,
      offset: const Offset(0, 8),
    );
    return switch (m.surface) {
      MiniSurface.lit => BoxDecoration(
          color: AppColors.matteBlack,
          borderRadius: radius,
          // A faintly tinted edge, so the border belongs to the glow beneath it.
          border: Border.all(color: themeColor.withOpacity(0.22), width: 1.0),
          boxShadow: [
            // An accent-tinted shadow reads as LIGHT coming off the panel; a
            // black one only reads as height.
            BoxShadow(
              color: themeColor.withOpacity(0.34),
              blurRadius: 26,
              spreadRadius: -4,
              offset: const Offset(0, 8),
            ),
            // Kept underneath the glow so the panel still has weight against
            // bright artwork — a tinted shadow on its own floats without
            // grounding anything.
            BoxShadow(
              color: Colors.black.withOpacity(0.45),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
      MiniSurface.cover => BoxDecoration(
          color: cover ?? AppColors.matteBlack,
          borderRadius: radius,
          border: Border.all(color: Colors.white.withOpacity(0.10), width: 1.0),
          boxShadow: [grounded],
        ),
      MiniSurface.plain => BoxDecoration(
          color: AppColors.matteBlack,
          borderRadius: radius,
          border: Border.all(color: AppColors.whiteFaded08, width: 1.0),
          boxShadow: [grounded],
        ),
    };
  }

  Widget _buildArtwork(
      dynamic song, bool showSpinner, Color themeColor, MiniPlayerMetrics m) {
    final size = m.artwork;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            // Scaled by the user's cover corners setting, like every other cover
            // in the app. Clamped to half the size so the slider can never push
            // a cover past a circle.
            borderRadius: BorderRadius.circular(
                ListeningPolicy.roundArtwork(m.artworkRadius).clamp(0.0, size / 2)),
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

  Widget _buildMetadata(dynamic song) {
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
      ),
    );
  }

  Widget _buildActions(dynamic song, bool isLiked, bool isPlaying,
      bool showSpinner, Color themeColor, MiniPlayerMetrics m) {
    final isLiveRadio = song.id.startsWith('http');
    // Tap targets run the full bar height, so there is no dead strip above or
    // below a button.
    final barHeight = m.height;
    // On the cover colour a liked heart is white: the accent can clash with it.
    final likedColor = m.surface == MiniSurface.cover ? Colors.white : themeColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.showLike)
          Semantics(
              label: isLiked ? 'Unlike' : 'Like',
              button: true,
              child: GestureDetector(
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
                    color: isLiked ? likedColor : Colors.white38,
                    size: 22,
                  ),
                ),
              ),
            ),
        // A dedicated play/pause button; tapping the bar opens the player.
        Semantics(
          label: isPlaying ? 'Pause' : 'Play',
          button: true,
          child: GestureDetector(
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
                  ? _PlayRing(isPlaying: isPlaying, themeColor: themeColor, ref: ref)
                  : Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
            ),
          ),
        ),
        // Live radio has nowhere to skip to.
        if (m.showNext && !isLiveRadio)
          Semantics(
            label: 'Next track',
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticService.light();
                ref.read(playerProvider.notifier).playNext();
              },
              child: Container(
                width: 38,
                height: barHeight,
                alignment: Alignment.center,
                child: const Icon(Icons.skip_next_rounded,
                    color: Colors.white70, size: 26),
              ),
            ),
          ),
        SizedBox(width: m.pill ? 10 : 6),
      ],
    );
  }

  /// [sideInset] keeps the hairline off each end, inside the rounded corners.
  Widget _buildBottomProgressBar(Color color, double sideInset) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    // Duration is watched live: it resolves about a second into each track.
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    final crossfadeEnabled = ref.watch(playerProvider.select((s) => s.crossfadeEnabled));
    final isLiveRadio = song?.id.startsWith('http') ?? false;

    if (isLiveRadio) return const SizedBox.shrink();

    return Positioned(
      bottom: 0,
      left: sideInset,
      right: sideInset,
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
                      color: isCrossfading ? Colors.orangeAccent : color,
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

  /// Fill style: the accent sweeps across the whole bar, behind the text, as the
  /// song plays. In its own RepaintBoundary, so a position tick repaints this
  /// layer only, not the cover and text drawn over it.
  Widget _buildProgressFill(Color themeColor) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    if (song?.id.startsWith('http') ?? false) return const SizedBox.shrink();
    return Positioned.fill(
      child: RepaintBoundary(
        child: ValueListenableBuilder<Duration>(
          valueListenable: currentPositionProvider,
          builder: (context, pos, _) {
            final double p = duration.inMilliseconds > 0
                ? (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: p,
              // Brighter at the leading edge, so the front of the fill reads as
              // where the song is.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    themeColor.withOpacity(0.14),
                    themeColor.withOpacity(0.30),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Play/pause with playback progress as a ring around it (the Capsule style),
/// so progress sits where the thumb already is and the round ends stay clean.
/// Listens to `currentPositionProvider` itself, since only the ring needs
/// per-tick updates.
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
              // Inside the 38px box, so the ring can't clip against the
              // neighbouring buttons.
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
