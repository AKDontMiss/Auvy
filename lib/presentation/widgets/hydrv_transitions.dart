import 'package:flutter/material.dart';

/// Navigation motion, ported from the fragment transitions of HYDRV (an earlier
/// Android app several of Auvy's patterns come from). Two asymmetries make it
/// feel clean rather than like a plain cross-fade:
///
///  1. **Everything travels upward.** The incoming page rises from +8% of its own
///     height while the outgoing one drifts up to −4%, so a navigation reads as one
///     continuous movement.
///  2. **Out is faster than in** and accelerates, while the entrance decelerates,
///     so the old page gets out of the way early and the new one settles.
///
/// Source (HYDRV/app/src/main/res/anim/):
///   fragment_fade_in  — alpha 0→1, translate Y  8%→0%, 180ms, fast_out_slow_in
///   fragment_fade_out — alpha 1→0, translate Y  0%→−4%, 160ms, fast_out_linear_in
///
/// Percentages are fractions of the widget's own height, as in Flutter's
/// [SlideTransition], so the port is exact.
class HydrvMotion {
  const HydrvMotion._();

  /// Settings → Appearance → "Reduce motion".
  ///
  /// A plain static rather than a provider because transitions are built inside
  /// `PageRouteBuilder` callbacks that have no reliable `ref`, and route
  /// construction must never wait on an async read. [ListeningPolicy] loads it
  /// once at startup and writes it here.
  ///
  /// Reduced motion keeps the CROSS-FADE and drops the travel. Removing the fade
  /// too would make pages replace each other with a hard cut, which reads as a
  /// glitch rather than as calm; it's the sliding that causes discomfort for
  /// motion-sensitive users, not the opacity.
  static bool reduceMotion = false;

  // Slightly longer than HYDRV's 180/160 ms (+11%) so the motion is easier to
  // follow, keeping the exit/enter ratio. Change the two together.
  static Duration get enterDuration =>
      reduceMotion ? const Duration(milliseconds: 130) : const Duration(milliseconds: 200);
  static Duration get exitDuration =>
      reduceMotion ? const Duration(milliseconds: 112) : const Duration(milliseconds: 178);

  /// `@android:interpolator/fast_out_slow_in` — decelerate into place.
  static const Curve enterCurve = Curves.fastOutSlowIn;

  /// `@android:interpolator/fast_out_linear_in` = cubic(0.4, 0.0, 1.0, 1.0).
  /// Accelerates and never eases out, so the outgoing page leaves decisively.
  static const Curve exitCurve = Cubic(0.4, 0.0, 1.0, 1.0);

  /// Enter travels from 8% below its resting position — or not at all under
  /// reduced motion, leaving a pure cross-fade.
  static Offset get enterOffset =>
      reduceMotion ? Offset.zero : const Offset(0, 0.08);

  /// Exit continues to 4% above — half the distance, so it reads as "carried
  /// away" rather than as a second, competing movement.
  static Offset get exitOffset =>
      reduceMotion ? Offset.zero : const Offset(0, -0.04);

  // Sheet variant (the now-playing screen): the same motion scaled up, since the
  // player replaces the whole screen and at page timings it read as a hard cut.
  // Durations ~1.7x and travel ~1.75x, keeping HYDRV's ratios (exit shorter than
  // enter, exit travel ~40% of enter travel, same curves, upward).
  static Duration get sheetEnterDuration =>
      reduceMotion ? const Duration(milliseconds: 175) : const Duration(milliseconds: 345);
  static Duration get sheetExitDuration =>
      reduceMotion ? const Duration(milliseconds: 142) : const Duration(milliseconds: 280);

  static Offset get sheetEnterOffset =>
      reduceMotion ? Offset.zero : const Offset(0, 0.14);
  static Offset get sheetExitOffset =>
      reduceMotion ? Offset.zero : const Offset(0, -0.06);

  // Face variant: two faces of one surface (the player's artwork ⇄ lyrics swap,
  // driven by a horizontal swipe, so the axis follows the finger). See
  // [HydrvFaceSwap]. Duration sits between the page and sheet variants, since the
  // artwork card is between a fragment and a whole screen in size.
  static Duration get faceDuration =>
      reduceMotion ? const Duration(milliseconds: 162) : const Duration(milliseconds: 262);

  /// Fraction of [faceDuration] the outgoing face gets — HYDRV's own 160/180.
  ///
  /// Both of their animations start together and the exit simply ENDS earlier;
  /// running the exit over an [Interval] of the single controller reproduces
  /// that exactly, so "out is faster than in" survives the port instead of
  /// becoming two controllers that can drift apart.
  static const double faceExitFraction = 160 / 180;

  /// Fractions of the surface's OWN width, mirroring the page variant's 8% / 4%.
  static double get faceEnterTravel => reduceMotion ? 0.0 : 0.08;
  static double get faceExitTravel => reduceMotion ? 0.0 : 0.04;
}

/// Horizontal counterpart of [HydrvTransition]: swaps the two faces of one surface
/// (the player's artwork ⇄ lyrics) instead of two routes. The same asymmetries,
/// rotated 90°:
///
///  1. **Both faces travel the finger's way.** [direction] is +1 for a rightward
///     swipe, −1 for leftward; the arriving face enters from the opposite edge and
///     the leaving face keeps going.
///  2. **Out ends before in**, on HYDRV's 160/180 ratio.
///
/// A slide-and-fade keeps all values in the animation, with no angle held in
/// mutable state (a 3D flip it replaced could render already flipped on unrelated
/// rebuilds, and overshot).
class HydrvFaceSwap extends StatelessWidget {
  /// 0 → 1 progress of a single swap.
  final Animation<double> animation;

  /// Direction the CONTENT travels: +1 right, −1 left. Match it to the swipe.
  final int direction;

  final Widget incoming;
  final Widget outgoing;

  const HydrvFaceSwap({
    super.key,
    required this.animation,
    required this.direction,
    required this.incoming,
    required this.outgoing,
  });

  @override
  Widget build(BuildContext context) {
    final enter =
        CurvedAnimation(parent: animation, curve: HydrvMotion.enterCurve);
    final exit = CurvedAnimation(
      parent: animation,
      curve: Interval(0.0, HydrvMotion.faceExitFraction,
          curve: HydrvMotion.exitCurve),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        // Outgoing first, so the arriving face composites over it.
        SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: Offset(direction * HydrvMotion.faceExitTravel, 0),
          ).animate(exit),
          child: FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.0).animate(exit),
            // Mid-swap the old face is decoration: ignore taps on it so they can't hit
            // controls the user can no longer see.
            child: IgnorePointer(child: outgoing),
          ),
        ),
        SlideTransition(
          position: Tween<Offset>(
            begin: Offset(-direction * HydrvMotion.faceEnterTravel, 0),
            end: Offset.zero,
          ).animate(enter),
          child: FadeTransition(opacity: enter, child: incoming),
        ),
      ],
    );
  }
}

/// Wraps [child] in HYDRV's enter motion driven by [animation], and its exit
/// motion driven by [secondaryAnimation] (the route being covered).
///
/// Pass a null [secondaryAnimation] for cases with nothing underneath to move.
class HydrvTransition extends StatelessWidget {
  final Animation<double> animation;
  final Animation<double>? secondaryAnimation;
  final Widget child;

  /// Use the larger sheet-sized gesture (the now-playing screen) instead of the
  /// page-sized one. See [HydrvMotion.sheetEnterOffset].
  final bool sheet;

  /// Which way the motion travels.
  ///
  /// [Axis.horizontal]: for pushing a page. Sideways travel says "you went deeper,
  /// back returns you", matching the platform back gesture.
  ///
  /// [Axis.vertical]: for arrivals in place, i.e. tab switches (nothing was pushed)
  /// and the now-playing sheet (which rises). Ignored when [sheet] is true.
  final Axis axis;

  const HydrvTransition({
    super.key,
    required this.animation,
    this.secondaryAnimation,
    this.sheet = false,
    this.axis = Axis.vertical,
    required this.child,
  });

  /// Rotates a vertical offset onto the horizontal axis, so both directions come
  /// from the SAME ported numbers instead of a second set that could drift.
  ///
  /// A positive vertical dy means "below, travelling up". Its horizontal
  /// equivalent is "to the right, travelling left", i.e. dx = dy, which is also
  /// the direction a push should come from in LTR.
  Offset _onAxis(Offset vertical) =>
      axis == Axis.horizontal ? Offset(vertical.dy, 0) : vertical;

  @override
  Widget build(BuildContext context) {
    final enterCurved =
        CurvedAnimation(parent: animation, curve: HydrvMotion.enterCurve);

    Widget result = SlideTransition(
      position: Tween<Offset>(
        begin: _onAxis(
            sheet ? HydrvMotion.sheetEnterOffset : HydrvMotion.enterOffset),
        end: Offset.zero,
      ).animate(enterCurved),
      child: FadeTransition(opacity: enterCurved, child: child),
    );

    final secondary = secondaryAnimation;
    if (secondary != null) {
      final exitCurved =
          CurvedAnimation(parent: secondary, curve: HydrvMotion.exitCurve);
      // Fading the covered page all the way to 0 is not just cosmetic here:
      // every page in this app has a transparent scaffold over the shared
      // DynamicBackground, so two fully-painted pages would show through each
      // other. Reaching 0 opacity keeps that structurally impossible, and a
      // page at 0 opacity costs nothing to paint.
      result = SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: _onAxis(
              sheet ? HydrvMotion.sheetExitOffset : HydrvMotion.exitOffset),
        ).animate(exitCurved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1.0, end: 0.0).animate(exitCurved),
          child: result,
        ),
      );
    }

    return result;
  }
}

/// Applies HYDRV's enter motion to whichever child an [IndexedStack] shows,
/// replaying it on every [index] change. Enter-only: cross-fading two tabs would
/// paint both at once and show through the transparent scaffolds. Costs a single
/// opacity + transform layer.
class HydrvIndexedSwitch extends StatefulWidget {
  final int index;
  final Widget child;

  const HydrvIndexedSwitch({
    super.key,
    required this.index,
    required this.child,
  });

  @override
  State<HydrvIndexedSwitch> createState() => _HydrvIndexedSwitchState();
}

class _HydrvIndexedSwitchState extends State<HydrvIndexedSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: HydrvMotion.enterDuration,
      vsync: this,
      // Starts settled: the first frame must not animate the launch tab in, or
      // the app appears to "arrive" on top of its own splash.
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(HydrvIndexedSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HydrvTransition(animation: _controller, child: widget.child);
  }
}
