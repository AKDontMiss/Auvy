import 'package:flutter/material.dart';

/// Navigation motion, ported 1:1 from HYDRV's fragment transitions.
///
/// Their whole feel comes from two asymmetries that a plain cross-fade misses:
///
///  1. **Everything travels UPWARD.** The incoming page rises from +8% of its
///     own height while the outgoing one keeps drifting up to −4%. Nothing ever
///     reverses direction, so a navigation reads as one continuous movement
///     rather than two things swapping places.
///  2. **Out is faster than in** (160ms vs 180ms) and uses an accelerating
///     curve, while the entrance decelerates. The old page gets out of the way
///     early and the new one settles, which is what makes it feel "clean"
///     instead of crossfade-mushy.
///
/// Source (HYDRV/app/src/main/res/anim/):
///   fragment_fade_in  — alpha 0→1, translate Y  8%→0%, 180ms, fast_out_slow_in
///   fragment_fade_out — alpha 1→0, translate Y  0%→−4%, 160ms, fast_out_linear_in
///
/// Percentages are fractions of the widget's OWN height, which is exactly what
/// Flutter's [SlideTransition] uses, so the port is literal, not approximate.
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

  // Nudged up from HYDRV's literal 180/160 on request — the motion read a touch
  // too quick to follow. Deliberately small: +11%, which is enough to register as
  // settling rather than snapping, and not enough to feel like waiting.
  //
  // The 160/180 RATIO is preserved (178/200 = 0.89), because that asymmetry — exit
  // shorter than enter — is what the whole port is built on. Change these two
  // together or the motion stops reading as one movement.
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

  // Sheet variant (the now-playing screen)
  //
  // Same language, larger gesture. HYDRV's 180/160ms was tuned for swapping
  // fragments WITHIN a screen — small surfaces, small change of context. The
  // player replaces the entire screen, and at 180ms that read as a hard cut
  // rather than a transition: too fast to follow, so it felt abrupt instead of
  // quick.
  //
  // Scaled proportionally rather than by picking new numbers: durations ~1.7x
  // and travel ~1.75x, keeping every ratio HYDRV establishes — exit still
  // shorter than enter, exit travel still ~40% of enter travel, same curves,
  // same upward direction. A bigger surface moving further needs longer to do it
  // at the same apparent speed.
  // Also nudged up (310→345, 250→280), and by slightly more than the page
  // variant: this is the app's largest VERTICAL move — a whole screen rising —
  // and the one that read as most hurried. Same ~0.81 exit/enter ratio as before.
  static Duration get sheetEnterDuration =>
      reduceMotion ? const Duration(milliseconds: 175) : const Duration(milliseconds: 345);
  static Duration get sheetExitDuration =>
      reduceMotion ? const Duration(milliseconds: 142) : const Duration(milliseconds: 280);

  static Offset get sheetEnterOffset =>
      reduceMotion ? Offset.zero : const Offset(0, 0.14);
  static Offset get sheetExitOffset =>
      reduceMotion ? Offset.zero : const Offset(0, -0.06);

  // Face variant (two faces of ONE surface)
  //
  // For the player's artwork ⇄ lyrics swap. Not a navigation: the surface stays
  // put and its CONTENT changes, driven by a horizontal swipe, so the travel
  // axis rotates 90° to follow the finger. See [HydrvFaceSwap].
  //
  // Duration sits between the page and sheet variants by HYDRV's own scaling
  // rule ("a bigger surface moving further needs longer at the same apparent
  // speed"): the artwork card is well over a fragment-sized surface and well
  // under a whole screen, so 240ms sits between 180 and 310 rather than being
  // picked freely.
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

/// Horizontal counterpart of [HydrvTransition]: swaps the two FACES of one
/// surface (the player's artwork ⇄ lyrics) instead of two routes.
///
/// The same two asymmetries as the vertical version, rotated 90°:
///
///  1. **Both faces travel the same way, and that way is the FINGER'S way.**
///     [direction] is +1 when the swipe went right, −1 when it went left. The
///     arriving face enters from the opposite edge and the leaving face keeps
///     going past, so the swap reads as the gesture carrying the card — not as
///     two things trading places.
///  2. **Out ends before in**, on HYDRV's 160/180 ratio, exit accelerating and
///     entrance decelerating.
///
/// This replaced a 3-D `rotateY` "flip", which was reported as buggy for two
/// separate reasons:
///
///  • The resting angle was assigned the TARGET angle *before* the animation
///    started, and the builder only read the animation `while` the controller was
///    animating. Any rebuild NOT driven by the controller — a position tick, a
///    provider write, both constant on the player page — therefore painted the
///    card already flipped, after which the animation replayed the flip from the
///    beginning.
///  • `Curves.easeOutBack` overshoots, and it was driving a rotation to exactly
///    π: the card swung past edge-on and rocked back.
///
/// A slide-and-fade has no orientation to get wrong, and every value here comes
/// from the animation — there is no angle held in mutable state to fall out of
/// sync.
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
            // Mid-swap the old face is decoration, not a target: without this a
            // tap landing on it during the 240ms would hit controls the user can
            // no longer see.
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
  /// [Axis.horizontal] — for PUSHING A PAGE. Sideways travel says "you have gone
  /// somewhere deeper, and back returns you", which is what a push means and what
  /// the platform back gesture already implies. It also reads cleaner than a rise
  /// when the page you left is conceptually beside the one you arrived at.
  ///
  /// [Axis.vertical] — for arrivals in PLACE: tab switches (nothing was pushed,
  /// so nothing should look pushed) and the now-playing sheet (which rises,
  /// because it is a sheet). Ignored when [sheet] is true.
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

/// Applies HYDRV's enter motion to whichever child an [IndexedStack] is
/// currently showing, replaying it on every [index] change.
///
/// Deliberately ENTER-ONLY. An IndexedStack shows one child at a time and keeps
/// the rest alive for state preservation; cross-fading two tabs would mean
/// painting both at once, which reintroduces exactly the see-through ghosting
/// the transparent-scaffold architecture avoids. The rise-and-fade of the
/// arriving tab carries the motion on its own, and tab switches stay one
/// subtree, so this costs a single opacity + transform layer.
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
