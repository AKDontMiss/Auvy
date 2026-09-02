import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:auvy/services/haptic_service.dart';

/// COACH MARKS — a walkthrough that points at the REAL app.
///
/// Replaces a 1,865-line tutorial built out of MOCK widgets: fake nav bars, fake
/// tiles, a fake mini-player. Mock stages have two problems. They drift — the app
/// changes and the tutorial keeps teaching last month's layout, silently. And
/// they teach the wrong thing: the user practises on a replica, then has to find
/// the real control afterwards anyway.
///
/// So this dims the actual screen, cuts a hole around the actual widget, draws an
/// arrow to it and explains it. Nothing is simulated, which also means nothing
/// can go stale: if a control moves, the spotlight moves with it, because the
/// rect is read from that widget's own RenderBox at the moment the step opens.
///
/// Targets are registered by wrapping them in [CoachAnchor]. A step whose target
/// is missing (a control that isn't on screen in this build) is SKIPPED rather
/// than pointing at nothing. See [_CoachOverlayState._resolveFrom].

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

  /// Run before the step is measured — used to put the app into the state the
  /// step describes, e.g. opening the player page so its controls exist to point
  /// at. Anything it fails to do simply means the target won't resolve, and the
  /// step is skipped rather than pointing at nothing.
  final Future<void> Function()? onEnter;

  const CoachStep({
    this.targetId,
    required this.title,
    required this.body,
    this.tab,
    this.settle = Duration.zero,
    this.circular = false,
    this.onEnter,
  });
}

/// Starts and arms the tour.
class CoachTour {
  CoachTour._();

  /// Raised when the tour should begin as soon as the real app is on screen.
  ///
  /// A SIGNAL rather than a plain flag because it is armed at two very different
  /// moments. Onboarding arms it before MainLayout exists (there is no app behind
  /// onboarding to point at), so MainLayout reads it once on its first frame.
  /// "Replay tutorial" arms it much later, from Settings, long after that frame —
  /// so MainLayout also listens, and starts the tour when the value flips.
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
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void initState() {
    super.initState();
    _apply(0, first: true);
  }

  @override
  void dispose() {
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
    if (step.tab != null) widget.onTab?.call(step.tab!);
    if (step.onEnter != null) {
      try {
        await step.onEnter!();
      } catch (_) {
        // A step that can't set itself up just fails to resolve its target below
        // and gets skipped — never take the tour down with it.
      }
      if (!mounted) return;
    }

    // One frame for the tab swap to lay out, plus whatever the step asked for.
    await Future<void>.delayed(step.settle + const Duration(milliseconds: 90));
    if (!mounted) return;

    final rect = _resolveFrom(step);
    if (step.targetId != null && rect == null) {
      // Nothing to point at — try the next step rather than showing a floating
      // arrow.
      await _apply(i + 1);
      return;
    }

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
    return r.inflate(step.circular ? 6 : 8);
  }

  void _next() {
    HapticService.light();
    _apply(_index + 1);
  }

  void _back() {
    if (_index == 0) return;
    HapticService.light();
    _apply(_index - 1);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final step = widget.steps[_index];
    final target = _target;
    final bool last = _index == widget.steps.length - 1;

    // Card goes on the opposite side of the screen from the target, so it never
    // covers the thing it is describing.
    final bool targetInLowerHalf =
        target != null && target.center.dy > size.height * 0.52;
    final bool centred = target == null;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Scrim with a hole. Absorbs taps too: during a step the app beneath
          // must not react to a stray tap through the dim.
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
          ),
          if (target != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ArrowPainter(
                    target: target,
                    fromBelow: !targetInLowerHalf,
                    accent: widget.accent,
                    screen: size,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            top: centred
                ? size.height * 0.34
                : (targetInLowerHalf ? null : target.bottom + 78),
            bottom: centred
                ? null
                : (targetInLowerHalf
                    ? size.height - target.top + 78
                    : null),
            child: FadeTransition(
              opacity: _fade,
              child: _CoachCard(
                step: step,
                accent: widget.accent,
                index: _index,
                total: widget.steps.length,
                isLast: last,
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

  const _CoachCard({
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
    return Container(
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
          Text(
            step.body,
            style: TextStyle(
                color: Colors.white.withOpacity(0.78),
                fontSize: 13.5,
                height: 1.5),
          ),
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
              const Spacer(),
              GestureDetector(
                onTap: onNext,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Text(
                    isLast ? 'Done' : 'Next',
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
