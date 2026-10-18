import 'dart:async';

import 'package:flutter/material.dart';

import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';

/// A press-and-hold target that shows the hold as it charges.
///
/// A bare `onLongPress` gives no feedback: the tile sits still and then a sheet
/// appears, so the gesture can't be discovered and people lift too early. While
/// the hold charges, ink splashes out from under the finger with the pressed
/// highlight, and when it completes the splash bursts as the menu opens.
///
/// It is the ink the Quick Picks rows always showed on a hold, the look the
/// owner picked for every tile (2026-10-16): the splash the theme makes for an
/// InkWell (InkSparkle on Android, InkRipple on iOS), in the theme's own splash
/// and highlight colours, created the way an InkWell creates it. A first copy
/// drew a lighter imitation of the iOS ripple instead, which looked like
/// neither (owner, 2026-10-17: "you haven't apparently"). The ink goes on a
/// see-through Material above the tile, so it shows over artwork too.
///
/// One controller is the clock for both the ink and the action, so the menu
/// opens as the ink bursts and the two can't drift apart.
class HoldToOpen extends StatefulWidget {
  final Widget child;

  /// Fired once the hold completes. Usually a content menu.
  final VoidCallback? onHold;

  /// Pixels of finger movement that abandon the charge.
  ///
  /// These tiles live in scrolling lists, so a press that turns into a scroll
  /// must not arm anything. 10, iOS's own long-press allowance
  /// (UILongPressGestureRecognizer.allowableMovement) and close to Android's 8 dp
  /// touch slop, rather than Flutter's 18: with 18, a finger that rested for a
  /// moment and then started a slow scroll opened the menu as the list began to
  /// move (seen on iOS, 2026-10-16, on every page with these tiles).
  static const double slop = 10;

  /// Corner radius the ink is clipped to. Match the tile it wraps, or the ink
  /// spills past the artwork's corners.
  final BorderRadius borderRadius;

  /// Whether to draw the ink. False for a tile whose child already has its own
  /// (an InkWell or a ListTile): that is the same ink, already splashing under
  /// the same finger, and a second one on top would double it.
  final bool ripple;

  /// Ink features (splashes and highlights) holds have alive, for tests.
  @visibleForTesting
  static int debugLiveInk = 0;

  /// How long the hold takes.
  ///
  /// 500ms on purpose — Flutter's own `kLongPressTimeout`. The gesture must feel
  /// the same as every other long-press on the device; this changes what the
  /// user SEES during those 500ms, not how long they wait.
  static const Duration holdDuration = Duration(milliseconds: 500);

  /// Nothing is drawn for the first 150 ms, so an ordinary tap (well under 100 ms of
  /// contact) never flashes the ink. The charge still starts on touch; only the
  /// drawing waits, and a hold still shows 350 ms of it.
  static const double revealAfter = 0.3;

  const HoldToOpen({
    super.key,
    required this.child,
    this.onHold,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.ripple = true,
  });

  @override
  State<HoldToOpen> createState() => _HoldToOpenState();
}

class _HoldToOpenState extends State<HoldToOpen>
    with TickerProviderStateMixin {
  late final AnimationController _charge = AnimationController(
    vsync: this,
    duration: HoldToOpen.holdDuration,
    // Releasing early rewinds faster than charging. A symmetrical rewind feels
    // like the app is still thinking about it after the finger has gone.
    reverseDuration: const Duration(milliseconds: 140),
    // This is the gesture's clock, not decoration. With the phone's own
    // "reduce motion" / "remove animations" on, a normal controller runs at
    // 5% of its duration, and the hold would fire after 25 ms: a menu on
    // nearly every touch.
    animationBehavior: AnimationBehavior.preserve,
  )
    ..addStatusListener(_onStatus)
    ..addListener(_onCharge);

  /// Where the finger landed, in the tile's own coordinates: the ink splashes
  /// from here.
  Offset? _touch;

  /// The see-through Material above the tile that the ink is drawn on.
  BuildContext? _inkLayer;

  /// This hold's splash and pressed highlight, while they belong to it.
  InteractiveInkFeature? _splash;
  InkHighlight? _highlight;

  /// Every ink feature still on screen, a confirmed or cancelled one included
  /// while it fades. Disposed with the tile: an InkWell does the same, since
  /// the Material they animate on asserts if it goes first with them running.
  final Set<InkFeature> _liveInk = {};

  bool _fired = false;
  Offset? _downAt;

  /// The lists this tile sits in (a shelf scrolls sideways inside a page that
  /// scrolls down), watched while a hold charges: if either moves, the press
  /// was the start of a scroll, whatever the finger's own movement says.
  final List<ScrollPosition> _watched = [];
  final Map<ScrollPosition, double> _pixelsAtDown = {};

  /// The charge is bounded by time as well as events: once a swipe recognizer claims
  /// the pointer, this Listener may never see a move, up or cancel. By holdDuration
  /// the press has either fired or been abandoned, so nothing is left drawn. The
  /// event handlers still cancel immediately.
  Timer? _watchdog;

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _fired) return;
    _fired = true;
    _unwatchScrolls();
    // The charge reaching full IS the trigger. See the note on the class.
    HapticService.medium();
    // The burst: a confirmed splash, as an InkWell's on release. It plays on
    // its own clock while the sheet rises over it.
    _endInk(confirmed: true);
    widget.onHold?.call();
    // The press-in springs straight back.
    _charge.value = 0;
  }

  /// The visible share of the charge: 0 until [HoldToOpen.revealAfter], then
  /// 0→1 by the moment the menu opens. The hidden first 150 ms is skipped, not
  /// compressed.
  double get _shown {
    final t = _charge.value;
    return t <= HoldToOpen.revealAfter
        ? 0.0
        : ((t - HoldToOpen.revealAfter) / (1 - HoldToOpen.revealAfter))
            .clamp(0.0, 1.0);
  }

  /// Starts the ink once the charge shows (see [HoldToOpen.revealAfter]).
  void _onCharge() {
    if (_splash == null &&
        !_fired &&
        widget.ripple &&
        _charge.status == AnimationStatus.forward &&
        _shown > 0) {
      _startInk();
    }
  }

  void _startInk() {
    final layer = _inkLayer;
    final touch = _touch;
    if (layer == null || touch == null || !layer.mounted) return;
    final box = layer.findRenderObject();
    final controller = Material.maybeOf(layer);
    if (box is! RenderBox || !box.hasSize || controller == null) return;
    final theme = Theme.of(context);
    final direction = Directionality.of(context);
    // An InkWell's own choices, since no colour or factory is set on these:
    // the theme's splash factory and splash colour, the theme's highlight
    // colour, clipped to the tile.
    InkHighlight? highlight;
    highlight = InkHighlight(
      controller: controller,
      referenceBox: box,
      color: theme.highlightColor,
      textDirection: direction,
      borderRadius: widget.borderRadius,
      onRemoved: () => _inkGone(highlight!),
    );
    InteractiveInkFeature? splash;
    splash = theme.splashFactory.create(
      controller: controller,
      referenceBox: box,
      position: touch,
      color: theme.splashColor,
      textDirection: direction,
      containedInkWell: true,
      borderRadius: widget.borderRadius,
      onRemoved: () => _inkGone(splash!),
    );
    _liveInk
      ..add(highlight)
      ..add(splash);
    HoldToOpen.debugLiveInk += 2;
    highlight.activate();
    _highlight = highlight;
    _splash = splash;
  }

  /// Ends this hold's ink: confirmed (the burst) when the hold completes,
  /// cancelled (a quick fade) when it's let go. Either way it then disposes
  /// itself once faded.
  void _endInk({required bool confirmed}) {
    final splash = _splash;
    _splash = null;
    if (splash != null) confirmed ? splash.confirm() : splash.cancel();
    _highlight?.deactivate();
    _highlight = null;
  }

  void _inkGone(InkFeature f) {
    if (_liveInk.remove(f)) HoldToOpen.debugLiveInk--;
    if (identical(_splash, f)) _splash = null;
    if (identical(_highlight, f)) _highlight = null;
  }

  /// The scroll positions of the lists around this tile, nearest of each axis.
  List<ScrollPosition> _positions() {
    final out = <ScrollPosition>[];
    for (final axis in Axis.values) {
      final p = Scrollable.maybeOf(context, axis: axis)?.position;
      if (p != null && !out.contains(p)) out.add(p);
    }
    return out;
  }

  void _watchScrolls() {
    _unwatchScrolls();
    for (final p in _positions()) {
      _watched.add(p);
      _pixelsAtDown[p] = p.hasPixels ? p.pixels : 0;
      p.addListener(_onScrolled);
    }
  }

  void _unwatchScrolls() {
    for (final p in _watched) {
      p.removeListener(_onScrolled);
    }
    _watched.clear();
    _pixelsAtDown.clear();
  }

  void _onScrolled() {
    for (final p in _watched) {
      final at = _pixelsAtDown[p];
      if (at != null && p.hasPixels && (p.pixels - at).abs() > 1) {
        _downAt = null;
        _cancel();
        return;
      }
    }
  }

  void _start() {
    if (widget.onHold == null) return;
    // A touch that lands on a list still coasting from a fling stops the list;
    // it isn't a press on this tile, so nothing arms.
    if (_positions().any((p) => p.isScrollingNotifier.value)) {
      _downAt = null;
      return;
    }
    _fired = false;
    _endInk(confirmed: false);
    _watchScrolls();
    // Armed on every press, with a margin past the hold so it never races the
    // real completion.
    _watchdog?.cancel();
    _watchdog = Timer(HoldToOpen.holdDuration + const Duration(milliseconds: 220),
        () {
      if (!mounted) return;
      if (_charge.value == 0) return;
      // Reached only when neither an up/cancel nor a completion resolved this.
      _endInk(confirmed: false);
      _charge.value = 0;
    });
    // The same charge with Reduce motion on. The ink is touch feedback, which
    // the setting leaves alone (an InkWell's ink, Quick Picks' included, shows
    // either way, as iOS's own touch highlights do); only the press-in, a
    // movement of the tile itself, is left out (see build). Until 2026-10-17
    // this mode drew nothing, so with it on every tile but Quick Picks looked
    // dead (owner: "still not working"). One path for both modes also retires
    // the separate timer this mode had, the one that once fired after the
    // finger had lifted.
    _charge.forward(from: 0);
  }

  void _cancel() {
    _watchdog?.cancel();
    _watchdog = null;
    _unwatchScrolls();
    // A press that began before this tile was rebuilt away keeps delivering its
    // pointer events here (the hit test lasts for the whole gesture), so this can
    // run after dispose; touching the controller then throws.
    if (!mounted || _fired) return;
    _endInk(confirmed: false);
    _charge.reverse();
  }

  @override
  void deactivate() {
    // Before the Material above the tile is disposed (children go first), as an
    // InkWell does: ink still fading animates on that Material's ticker.
    for (final f in _liveInk.toList()) {
      f.dispose();
    }
    _liveInk.clear();
    _splash = null;
    _highlight = null;
    super.deactivate();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _unwatchScrolls();
    _charge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listener, not GestureDetector: every wrapped tile already handles its own tap,
    // and a GestureDetector would compete with it for the tap in the gesture arena.
    // Listener only observes raw pointer events, so the tile behaves as before. The
    // slop test is done by hand below.
    return Listener(
      onPointerDown: (e) {
        _downAt = e.position;
        _touch = e.localPosition;
        _start();
      },
      onPointerMove: (e) {
        final from = _downAt;
        if (from == null) return;
        final d = e.position - from;
        // Horizontal movement cancels a little sooner: these tiles are swipe targets,
        // and a swipe starts as a press. 8 px is still well beyond a finger's natural
        // tremor.
        if (d.dx.abs() > HoldToOpen.slop * 0.8 ||
            d.distance > HoldToOpen.slop) {
          // Cancel once; later moves of the same press are ignored.
          _downAt = null;
          _cancel();
        }
      },
      onPointerUp: (_) {
        _downAt = null;
        _cancel();
      },
      onPointerCancel: (_) {
        _downAt = null;
        _cancel();
      },
      child: AnimatedBuilder(
        animation: _charge,
        builder: (context, child) => Transform.scale(
          // A slight settle under the finger, so the tile reads as being pressed
          // INTO. Capped small: this sits in scrolling lists and anything larger
          // turns a scroll that starts on a tile into a visible twitch. Driven
          // by `shown`, so a tap does not nudge the tile either. None with
          // Reduce motion: it moves the tile itself.
          scale: ListeningPolicy.reduceMotion ? 1.0 : 1 - (0.015 * _shown),
          child: child,
        ),
        // Built once: the charge only moves the scale, and the ink animates on
        // the Material by itself, so a hold never rebuilds the tile.
        child: widget.ripple
            ? Stack(
                children: [
                  widget.child,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Material(
                        type: MaterialType.transparency,
                        child: Builder(builder: (layer) {
                          _inkLayer = layer;
                          return const SizedBox.expand();
                        }),
                      ),
                    ),
                  ),
                ],
              )
            : widget.child,
      ),
    );
  }
}
