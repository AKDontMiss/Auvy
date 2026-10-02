import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:auvy/services/event_log.dart';
import 'package:auvy/services/haptic_service.dart';

/// Coach marks: a walkthrough that points at the real app. It dims the actual
/// screen, cuts a hole around the actual widget, draws an arrow to it and explains
/// it. Nothing is simulated, so nothing goes stale: the spotlight rect is read from
/// the widget's own RenderBox when the step opens.
///
/// Targets are registered by wrapping them in [CoachAnchor]. A step whose target
/// is missing (not on screen in this build) is skipped rather than pointing at
/// nothing. See [_CoachOverlayState._resolveFrom].

/// Wrap a real widget to make it targetable by a [CoachStep].
///
/// Registration is by string id, not by passing keys around, so a step can name
/// a target that lives several files away without any plumbing between them.
class CoachAnchor extends StatefulWidget {
  final String id;
  final Widget child;
  const CoachAnchor({super.key, required this.id, required this.child});

  static final Map<String, GlobalKey> _keys = {};

  static GlobalKey _keyFor(String id) =>
      _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'coach:$id'));

  /// The registration key for [id], for a widget that would rather take the key
  /// itself than be wrapped.
  ///
  /// Useful where wrapping is awkward — a widget deep inside a Row of controls,
  /// where adding a parent means restructuring the list. Pass it as that widget's
  /// `key` and it becomes targetable with no other change.
  static GlobalKey keyFor(String id) => _keyFor(id);

  /// The on-screen rect of [id], or null when that widget isn't mounted/laid out.
  static Rect? rectOf(String id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return null;
    final obj = ctx.findRenderObject();
    if (obj is! RenderBox || !obj.hasSize) return null;
    return obj.localToGlobal(Offset.zero) & obj.size;
  }

  @override
  State<CoachAnchor> createState() => _CoachAnchorState();
}

class _CoachAnchorState extends State<CoachAnchor> {
  @override
  Widget build(BuildContext context) {
    // KeyedSubtree rather than putting the key on `child`: the child is supplied
    // by the caller and may already carry a key of its own.
    return KeyedSubtree(
      key: CoachAnchor._keyFor(widget.id),
      child: widget.child,
    );
  }
}

/// One stop on the tour.
class CoachStep {
  /// Which [CoachAnchor] to spotlight. Null centres the card with no cutout —
  /// used for the opening and closing steps, which aren't about one control.
  final String? targetId;
  final String title;
  final String body;

  /// Tab to move to before this step (0 Home, 1 Search, 2 Library). Null stays.
  final int? tab;

  /// Extra settle time before measuring, for a step that follows a tab change or
  /// an animation. Measuring too early yields the pre-animation rect.
  final Duration settle;

  /// Draw the cutout as a circle. Right for round targets (nav icons, artwork);
  /// a rounded rect suits bars and rows.
  final bool circular;

  /// Runs before the step is measured, to put the app into the state the step
  /// describes (e.g. opening the player so its controls exist). If it fails, the
  /// target won't resolve and the step is skipped.
  final Future<void> Function()? onEnter;

  /// Require the user to actually touch the highlighted control before Next
  /// unlocks. The hole in the scrim then stops absorbing touches, so the real
  /// control receives the gesture and it can be tried for real. The step unlocks as
  /// soon as a finger goes down inside the spotlight (the weakest possible
  /// condition: the aim is to get a hand on the right control, not to grade the
  /// gesture). "Skip this step" is always available.
  final bool requireAction;

  /// What to try, in the imperative — "Double-tap it now". Shown as the
  /// unlock chip. Falls back to a generic prompt.
  final String? actionHint;

  const CoachStep({
    this.targetId,
    required this.title,
    required this.body,
    this.tab,
    this.settle = Duration.zero,
    this.circular = false,
    this.onEnter,
    this.requireAction = false,
    this.actionHint,
  })  : assert(!requireAction || targetId != null,
            'An action step needs a target to hand the touch to.');
}

/// Starts and arms the tour.
class CoachTour {
  CoachTour._();

  /// Raised when the tour should begin once the real app is on screen. A signal
  /// rather than a flag because it's armed at two different moments: onboarding arms
  /// it before MainLayout exists (MainLayout reads it on its first frame), and
  /// "Replay tutorial" arms it later from Settings (MainLayout listens for the
  /// change).
  static final ValueNotifier<bool> armedSignal = ValueNotifier<bool>(false);

  static bool get armed => armedSignal.value;
  static set armed(bool v) => armedSignal.value = v;

  static bool _running = false;

  /// True while a tour is on screen (so nothing else tries to start a second).
  static bool get isRunning => _running;

  /// Show [steps] over the current screen. Completes when the tour ends.
  static Future<void> run(
    BuildContext context, {
    required List<CoachStep> steps,
    required Color accent,
    void Function(int index)? onTab,
  }) async {
    if (_running || steps.isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _running = true;

    late OverlayEntry entry;
    final done = <void>[];
    entry = OverlayEntry(
      builder: (_) => _CoachOverlay(
        steps: steps,
        accent: accent,
        onTab: onTab,
        onFinish: () {
          if (done.isEmpty) {
            done.add(null);
            entry.remove();
            _running = false;
          }
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _CoachOverlay extends StatefulWidget {
  final List<CoachStep> steps;
  final Color accent;
  final VoidCallback onFinish;
  final void Function(int index)? onTab;

  const _CoachOverlay({
    required this.steps,
    required this.accent,
    required this.onFinish,
    this.onTab,
  });

  @override
  State<_CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<_CoachOverlay>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  Rect? _target;

  /// Whether the current step's required touch has happened. Reset per step in
  /// [_apply] — an unlock must never carry into the next lesson.
  bool _actionDone = false;

  /// Pending auto-advance after a completed gesture, so the user doesn't have to
  /// confirm with Next. Armed on pointer up and cancelled on every new pointer down,
  /// so it measures time since the user stopped interacting: a double-tap re-arms on
  /// the second release and a hold on the final lift, with no gesture special-cased.
  Timer? _autoAdvance;

  /// How long to wait after the finger lifts.
  ///
  /// Long enough to see what the gesture did — a track change animates for
  /// ~400ms — and short enough that the tour feels like it is keeping up rather
  /// than pausing to think.
  static const Duration _kAutoAdvanceAfter = Duration(milliseconds: 1000);

  /// When the current step opened, so the log can report time spent on it and how
  /// long an action step took. A gesture that takes long to satisfy, or gets
  /// skipped, suggests the hint or the hole placement needs work.
  DateTime? _stepOpenedAt;

  /// Seconds the current step has been open, for the log.
  String get _onStepFor {
    final t = _stepOpenedAt;
    if (t == null) return '?';
    return '${(DateTime.now().difference(t).inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  /// Whether [r] falls outside [size] — a hole nobody can reach.
  static bool _offScreen(Rect r, Size size) =>
      r.right < 0 ||
      r.bottom < 0 ||
      r.left > size.width ||
      r.top > size.height;

  /// Distance kept between the spotlight and the card.
  static const double _kCardGap = 74;

  /// Screen edge the card never crosses.
  static const double _kEdge = 22;

  /// Minimum space on a side worth putting the card in: enough for the header, two
  /// lines, the chip and buttons (the body scrolls under the ceiling), so the card
  /// uses a real side instead of covering the target whenever possible.
  static const double _kMinCard = 150;

  /// Where the card sits, how tall it may be, and whether it had to overlap.
  ///
  /// Computed once per build so the ARROW can be suppressed on the same
  /// decision — an arrow pointing at a target the card is sitting on top of is
  /// noise, and it was drawn regardless before.
  ({double? top, double? bottom, double maxHeight, bool overlaps}) _placeCard(
      Rect? target, Size size) {
    if (target == null) {
      return (
        top: size.height * 0.30,
        bottom: null,
        maxHeight: size.height * 0.52,
        overlaps: false
      );
    }
    final above = target.top - _kCardGap - _kEdge;
    final below = size.height - target.bottom - _kCardGap - _kEdge;

    // Prefer the roomier side, and only if it can actually hold a card.
    if (below >= _kMinCard && below >= above) {
      return (
        top: target.bottom + _kCardGap,
        bottom: null,
        maxHeight: below,
        overlaps: false
      );
    }
    if (above >= _kMinCard) {
      return (
        top: null,
        bottom: size.height - target.top + _kCardGap,
        maxHeight: above,
        overlaps: false
      );
    }
    // A target too large to sit beside — the artwork is nearly full height.
    // Overlap it rather than pushing the card off the screen.
    return (
      top: size.height * 0.26,
      bottom: null,
      maxHeight: size.height * 0.52,
      overlaps: true
    );
  }

  /// The four rectangles that cover [size] except for [hole].
  ///
  /// Cheaper and far more predictable than making one hit region with a hole
  /// in it: the panes are plain rects, so there is no custom hit-test to get
  /// subtly wrong, and an empty one (a hole flush against an edge) simply has
  /// zero area and absorbs nothing.
  static List<Rect> _panesAround(Rect hole, Size size) {
    final h = Rect.fromLTRB(
      hole.left.clamp(0.0, size.width),
      hole.top.clamp(0.0, size.height),
      hole.right.clamp(0.0, size.width),
      hole.bottom.clamp(0.0, size.height),
    );
    return [
      Rect.fromLTRB(0, 0, size.width, h.top),
      Rect.fromLTRB(0, h.bottom, size.width, size.height),
      Rect.fromLTRB(0, h.top, h.left, h.bottom),
      Rect.fromLTRB(h.right, h.top, size.width, h.bottom),
    ].where((r) => r.width > 0 && r.height > 0).toList();
  }
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void initState() {
    super.initState();
    // After the frame, not during it: a step's onEnter may push or pop the player
    // page, and navigating from initState would mark the Overlay dirty mid-build.
    // The mounted check covers the overlay being torn down in between.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _apply(0, first: true);
    });
  }

  @override
  void dispose() {
    // A pending advance outlives this widget otherwise, and fires _next() into
    // a disposed overlay — the "paused is not idle" shape this project has
    // already been bitten by twice.
    _autoAdvance?.cancel();
    _fade.dispose();
    super.dispose();
  }

  /// Move to [i], switching tabs and measuring the target.
  ///
  /// Steps whose target cannot be resolved are skipped forward, which keeps the
  /// tour honest: a control that isn't in this build gets no arrow pointing at
  /// empty space.
  Future<void> _apply(int i, {bool first = false}) async {
    if (i >= widget.steps.length) {
      widget.onFinish();
      return;
    }
    final step = widget.steps[i];
    // Per step, not per tour: an unlock earned on one lesson must not carry
    // into the next one and open its Next button before it is touched.
    _actionDone = false;
    _stepOpenedAt = DateTime.now();
    if (step.tab != null) widget.onTab?.call(step.tab!);
    if (step.onEnter != null) {
      try {
        await step.onEnter!();
      } catch (e) {
        // A step that can't set itself up fails to resolve its target below and is
        // skipped; it never takes the tour down. Logged, because the later "target not
        // found" is a symptom rather than the cause.
        logEvent('tour: step ${i + 1} onEnter FAILED ($e) — its target will '
            'not resolve, so the step is about to be skipped');
      }
      if (!mounted) return;
    }

    // One frame for the tab swap to lay out, plus whatever the step asked for.
    await Future<void>.delayed(step.settle + const Duration(milliseconds: 90));
    if (!mounted) return;

    final rect = _resolveFrom(step);
    if (step.targetId != null && rect == null) {
      // Nothing to point at: move on to the next step rather than showing a floating
      // arrow. Logged, so a step that stops appearing (renamed anchor, moved control)
      // is noticed.
      logEvent('tour: step ${i + 1}/${widget.steps.length} "${step.title}" '
          'SKIPPED — anchor "${step.targetId}" is not mounted or has no size');
      await _apply(i + 1);
      return;
    }

    // The rect is the whole story for an action step: it is the region that
    // will accept touches, so a hole that is tiny, off-screen or around the
    // wrong widget explains every "it did not work" report at a glance.
    final screen = MediaQuery.of(context).size;
    logEvent('tour: step ${i + 1}/${widget.steps.length} "${step.title}"'
        '${step.tab != null ? " tab=${step.tab}" : ""}'
        '${step.requireAction ? " NEEDS-ACTION" : ""} — '
        '${rect == null ? "centred card, no cutout" : 'hole ${rect.width.round()}x${rect.height.round()} '
            'at ${rect.left.round()},${rect.top.round()} '
            'on a ${screen.width.round()}x${screen.height.round()} screen'
            '${_offScreen(rect, screen) ? " ⚠ OFF-SCREEN" : ""}'
            '${step.requireAction && (rect.width < 40 || rect.height < 40) ? " ⚠ SMALL TARGET" : ""}'}');

    setState(() {
      _index = i;
      _target = rect;
    });
    if (!first) {
      _fade
        ..reset()
        ..forward();
    }
  }

  Rect? _resolveFrom(CoachStep step) {
    final id = step.targetId;
    if (id == null) return null;
    final r = CoachAnchor.rectOf(id);
    if (r == null) return null;
    // Breathing room so the ring never crops the control it is highlighting.
    final inflated = r.inflate(step.circular ? 6 : 8);

    // Clamped to the screen: a full-width target plus breathing room would extend
    // past both edges, collapsing the side dim panes to zero width and confusing card
    // placement. The off-screen part was never visible or touchable anyway.
    final size = MediaQuery.of(context).size;
    final clamped = inflated.intersect(Offset.zero & size);
    if (clamped != inflated) {
      logEvent('tour: hole for "$id" clamped to the screen '
          '(${inflated.width.round()}x${inflated.height.round()} at '
          '${inflated.left.round()},${inflated.top.round()} → '
          '${clamped.width.round()}x${clamped.height.round()} at '
          '${clamped.left.round()},${clamped.top.round()})');
    }
    return clamped;
  }

  /// Start the countdown to the next step, once the gesture has been made.
  ///
  /// Only after the unlock, so a stray touch on a step that has not been
  /// satisfied yet does nothing — the point is to skip the redundant Next tap,
  /// not to advance on any contact.
  void _armAutoAdvance() {
    if (!_actionDone) return;
    _autoAdvance?.cancel();
    _autoAdvance = Timer(_kAutoAdvanceAfter, () {
      _autoAdvance = null;
      if (!mounted) return;
      logEvent('tour: step ${_index + 1} auto-advancing — gesture done, no '
          'Next tap needed');
      _next();
    });
  }

  void _next() {
    // Whatever moves the tour along cancels a pending advance, or a manual
    // Next during the window would fire twice and skip the following step.
    _autoAdvance?.cancel();
    _autoAdvance = null;
    HapticService.light();
    _apply(_index + 1);
  }

  void _back() {
    if (_index == 0) return;
    _autoAdvance?.cancel();
    _autoAdvance = null;
    HapticService.light();
    _apply(_index - 1);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final step = widget.steps[_index];
    final target = _target;
    final bool last = _index == widget.steps.length - 1;

    // Where the card fits, decided once — see [_placeCard]. `overlaps` also
    // suppresses the arrow, which is meaningless when the card is sitting on
    // the target it would be pointing at.
    final place = _placeCard(target, size);
    final bool cardIsBelowTarget = place.top != null && target != null;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // The scrim has two arrangements. A reading step absorbs everything: one
          // full-screen pane, tap anywhere to advance, and nothing beneath reacts. An
          // action step must hand the touch over: the paint still covers the screen but
          // isn't interactive, and four absorbing panes are laid out around the hole, so
          // the control beneath gets the gesture untouched (a double-tap stays a double-tap,
          // a hold stays a hold). Tap-to-advance is dropped there.
          if (target == null || !step.requireAction)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _next,
                child: CustomPaint(
                  painter: _SpotlightPainter(
                    target: target,
                    circular: step.circular,
                    accent: widget.accent,
                  ),
                ),
              ),
            )
          else ...[
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SpotlightPainter(
                    target: target,
                    circular: step.circular,
                    accent: widget.accent,
                  ),
                ),
              ),
            ),
            // Absorbing panes around the hole. Opaque so the dimmed app is
            // inert, and with no onTap so a stray touch outside the spotlight
            // does nothing at all rather than skipping the lesson.
            ..._panesAround(target, size).map(
              (r) => Positioned.fromRect(
                rect: r,
                child: const AbsorbPointer(child: SizedBox.expand()),
              ),
            ),
            // Sits OVER the hole and is translucent, so it is told about the
            // pointer while the control underneath still receives it. This is
            // the unlock: a finger went down on the right thing.
            Positioned.fromRect(
              rect: target,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  // A new touch means the gesture is still in progress —
                  // a double-tap's second tap, or a fresh attempt. Cancel any
                  // pending advance so the tour never moves under the finger.
                  _autoAdvance?.cancel();
                  _autoAdvance = null;
                  if (_actionDone) return;
                  // How long the gesture took to arrive is the measurement
                  // this whole feature lives or dies on — see [_stepOpenedAt].
                  logEvent('tour: step ${_index + 1} unlocked after '
                      '$_onStepFor — the touch reached the app through the '
                      'spotlight');
                  HapticService.selection();
                  setState(() => _actionDone = true);
                },
                onPointerUp: (_) => _armAutoAdvance(),
                onPointerCancel: (_) => _armAutoAdvance(),
                child: const SizedBox.expand(),
              ),
            ),
          ],
          // No arrow when the card overlaps its own target: it would point at
          // something underneath the card, from inside it.
          if (target != null && !place.overlaps)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ArrowPainter(
                    target: target,
                    fromBelow: cardIsBelowTarget,
                    accent: widget.accent,
                    screen: size,
                  ),
                ),
              ),
            ),
          // Where the card goes and how tall it may be. The gap on each side of the target
          // is measured and the roomier side wins; if neither side can hold a usable card
          // (e.g. the artwork step, nearly full height), the card is centred and may
          // overlap the spotlight, since a button off screen is worse. The chosen side's
          // height becomes the card's ceiling, and its body scrolls inside it.
          Positioned(
            left: 20,
            right: 20,
            top: place.top,
            bottom: place.bottom,
            child: FadeTransition(
              opacity: _fade,
              child: _CoachCard(
                step: step,
                accent: widget.accent,
                index: _index,
                total: widget.steps.length,
                isLast: last,
                actionDone: _actionDone,
                maxHeight: place.maxHeight,
                onNext: _next,
                onBack: _index == 0 ? null : _back,
                onSkip: widget.onFinish,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dim everything, cut out the target, ring it.
class _SpotlightPainter extends CustomPainter {
  final Rect? target;
  final bool circular;
  final Color accent;
  _SpotlightPainter(
      {required this.target, required this.circular, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    final scrim = Paint()..color = Colors.black.withOpacity(0.82);

    if (target == null) {
      canvas.drawRect(full, scrim);
      return;
    }

    final hole = circular
        ? (Path()..addOval(Rect.fromCircle(
            center: target!.center,
            radius: math.max(target!.width, target!.height) / 2)))
        : (Path()
          ..addRRect(
              RRect.fromRectAndRadius(target!, const Radius.circular(16))));

    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(full), hole),
      scrim,
    );

    canvas.drawPath(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent.withOpacity(0.9),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.target != target || old.circular != circular || old.accent != accent;
}

/// A curved arrow from the caption card toward the spotlight.
class _ArrowPainter extends CustomPainter {
  final Rect target;
  final bool fromBelow;
  final Color accent;
  final Size screen;
  _ArrowPainter(
      {required this.target,
      required this.fromBelow,
      required this.accent,
      required this.screen});

  @override
  void paint(Canvas canvas, Size size) {
    // Start just outside the ring on the card's side, end near the card.
    final double gap = 14;
    final Offset tip = fromBelow
        ? Offset(target.center.dx, target.bottom + gap)
        : Offset(target.center.dx, target.top - gap);
    final double length = 52;
    final Offset tail = fromBelow
        ? Offset(target.center.dx + 26, tip.dy + length)
        : Offset(target.center.dx + 26, tip.dy - length);

    final path = Path()
      ..moveTo(tail.dx, tail.dy)
      ..quadraticBezierTo(
        tail.dx,
        (tail.dy + tip.dy) / 2,
        tip.dx,
        tip.dy,
      );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );

    // Arrowhead, pointing along the final direction of the curve.
    final double dir = fromBelow ? -1 : 1; // up when the card is below
    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - 5.5, tip.dy - dir * -7.5)
      ..lineTo(tip.dx + 5.5, tip.dy - dir * -7.5)
      ..close();
    canvas.drawPath(head, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.target != target || old.fromBelow != fromBelow || old.accent != accent;
}

class _CoachCard extends StatelessWidget {
  final CoachStep step;
  final Color accent;
  final int index;
  final int total;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final VoidCallback onSkip;

  /// Whether this step's required touch has happened yet. Ignored unless
  /// `step.requireAction`.
  final bool actionDone;

  /// The most vertical space this card may take, from [_placeCard].
  ///
  /// A CEILING, NOT A HEIGHT. The card is as short as its content allows and
  /// only starts scrolling its body when the content would exceed this — so a
  /// two-line step stays a small card, and a long one stops running off the
  /// bottom of the phone instead of taking Next with it.
  final double maxHeight;

  const _CoachCard({
    required this.actionDone,
    required this.maxHeight,
    required this.step,
    required this.accent,
    required this.index,
    required this.total,
    required this.isLast,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // The ceiling. Everything inside stays laid out as before; only the body
      // gives way, and only when it has to.
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF17171C),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${index + 1} / $total',
                style: TextStyle(
                    color: accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onSkip,
                behavior: HitTestBehavior.opaque,
                child: Text('Skip',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            step.title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 17.5,
                fontWeight: FontWeight.w800,
                height: 1.25),
          ),
          const SizedBox(height: 7),
          // The only part that gives way under the ceiling: title, chip and buttons keep
          // their space, and the text scrolls.
          Flexible(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Text(
                step.body,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.78),
                    fontSize: 13.5,
                    height: 1.5),
              ),
            ),
          ),
          // The unlock chip, only on an action step: an instruction in the accent colour
          // before the touch, a tick after, confirming the gesture registered.
          if (step.requireAction) ...[
            const SizedBox(height: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: actionDone
                    ? accent.withOpacity(0.18)
                    : Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: actionDone
                      ? accent.withOpacity(0.6)
                      : Colors.white.withOpacity(0.12),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    actionDone
                        ? Icons.check_circle_rounded
                        : Icons.touch_app_rounded,
                    size: 15,
                    color: actionDone ? accent : Colors.white.withOpacity(0.7),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      // Says it's about to move on, since the step advances on its own shortly after
                      // the gesture.
                      actionDone
                          ? 'Nice — moving on…'
                          : (step.actionHint ?? 'Try it on the highlighted control'),
                      style: TextStyle(
                        color: actionDone
                            ? accent
                            : Colors.white.withOpacity(0.82),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (onBack != null)
                GestureDetector(
                  onTap: onBack,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                    child: Text('Back',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              // Space between Back and "Skip this step", so the two don't read as one control.
              if (onBack != null && step.requireAction && !actionDone)
                const SizedBox(width: 18),
              // An action step can always be skipped, so an unresponsive control can't strand
              // the tour. Shown only while the step is still locked.
              if (step.requireAction && !actionDone)
                GestureDetector(
                  onTap: onNext,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                    child: Text('Skip this step',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              const Spacer(),
              // Dimmed and inert until the gesture has been made; "Skip this step" on the left
              // is the deliberate way past.
              _NextButton(
                accent: accent,
                label: isLast ? 'Done' : 'Next',
                enabled: !step.requireAction || actionDone,
                onTap: onNext,
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// The Next / Done pill, which an action step can lock.
///
/// Its own widget because "disabled" has to change three things together —
/// colour, text contrast and hit response — and an inline ternary per property
/// is how one of them gets forgotten and a dead-looking button stays tappable.
class _NextButton extends StatelessWidget {
  final Color accent;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _NextButton({
    required this.accent,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Null, not a no-op: an inert button must also not swallow the tap, or a
      // touch meant for the control underneath is lost to it.
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: enabled ? accent : Colors.white.withOpacity(0.10),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.black : Colors.white.withOpacity(0.45),
            fontSize: 13.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
