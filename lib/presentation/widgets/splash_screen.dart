import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/logic/session_auth_service.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/pages/login_gate_page.dart';
import 'package:auvy/presentation/pages/onboarding_page.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/home_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/app_icon_service.dart';
import 'package:auvy/services/listening_policy.dart';

/// Launch screen and first-run router.
///
/// TWO MODES, and which one you get is the point:
///
///  • **Full** ([_SplashGate.shouldAnimate]). The morph sequence, on a COLD
///    START — the app was killed, swiped out of recents, or hasn't run since
///    boot. Starting from nothing is the moment a brand beat reads as a welcome.
///
///  • **Quiet.** No animation — a bare backdrop for as long as boot takes, then
///    straight into the app. This is what a *warm* return gets, and it's the
///    common case precisely because a warm return never reaches this widget:
///    the app resumes into wherever you left it.
///
/// The distinction used to be time-based (an 8-hour cooldown), which measured
/// elapsed wall-clock rather than whether the app had actually restarted — see
/// [_SplashGate] for why that made the splash disappear in practice.
///
/// Boot itself never waits on the network. Routing needs exactly two LOCAL facts
/// ("has onboarded", "is signed in"); the home feed loads behind the home page's
/// own skeletons rather than holding the launch hostage. The sign-in check
/// always resolves BEFORE routing, so the login gate can't flash for a
/// signed-in user, and even the 8s failsafe routes from the durable session
/// marker rather than an unresolved default.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

/// Decides whether this launch earns the full animation.
///
/// ONE RULE: a COLD START animates. Nothing else does.
///
/// A cold start means the Dart process was created — the app was killed by
/// Android, swiped out of the recents/task switcher, or hasn't run since boot.
/// That is already exactly when this widget gets built: it is `main.dart`'s
/// `home:`, so a warm resume (process still alive, task brought forward) never
/// reconstructs it and the animation simply can't play. The signal needs no
/// tracking — being here IS the signal.
///
/// This replaced an 8-hour cooldown keyed on the last time the sequence played.
/// The intent was to keep the animation from becoming a toll booth on repeat
/// launches, but it measured the wrong thing: WALL-CLOCK time since the last
/// animation, not whether this launch was actually a fresh start. Someone who
/// cold-starts Auvy several times inside one 8-hour window — swiping it away and
/// coming back, or having Android reclaim it — got the quiet path every time and
/// effectively stopped seeing the splash at all. Meanwhile the case the cooldown
/// was protecting against never really existed: a warm resume doesn't come
/// through here in the first place.
///
/// The two overrides that survive are the ones that aren't about frequency:
/// reduce-motion, and the dev define.
class _SplashGate {
  const _SplashGate._();

  /// Latched for the life of the PROCESS, which is what makes "cold start" the
  /// unit rather than "every time this widget is built". Logging out pushes a
  /// fresh SplashScreen (see library_page / settings_page) inside the same
  /// process — that is a sign-out, not an arrival, so it takes the quiet path.
  static bool _animatedThisProcess = false;

  /// Development lever: replay the sequence on EVERY build of the splash.
  ///
  ///   flutter run --dart-define=AUVY_FORCE_SPLASH=true
  ///
  /// Iterating on a cold-start-only animation otherwise means force-stopping the
  /// app between looks. A compile-time constant, so a release build without the
  /// define folds it to `false` and drops the branch entirely.
  static const bool _forceAlways =
      bool.fromEnvironment('AUVY_FORCE_SPLASH');

  static Future<bool> shouldAnimate() async {
    if (_forceAlways) return true;
    // Motion sensitivity wins outright — this is the most motion-heavy thing in
    // the app, and someone who asked for less of it should never be shown the
    // loudest version.
    if (ListeningPolicy.reduceMotion) return false;
    if (_animatedThisProcess) return false;
    _animatedThisProcess = true;
    return true;
  }
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  /// Drives the entire sequence, reveal included.
  late final AnimationController _seq;

  /// The quiet mode's only motion.
  late final AnimationController _quietCtrl;
  late final Animation<double> _quietFade;
  late final Animation<double> _quietScale;

  late final DateTime _startTime;

  bool _navigating = false;
  bool _dataReady = false;
  bool _slowBoot = false;
  bool _hasOnboarded = false;
  bool _loggedIn = false;

  /// The Worker's verdict, when it is what held this launch at the gate. Passed
  /// through so the sign-in page opens explaining WHY rather than as a blank
  /// screen that reads like the sign-in simply failed.
  String? _gateStatus;
  String? _gateIdentity;

  /// Null until the gate has answered. Rendering only the backdrop until then is
  /// deliberate: it is the same colour as whatever follows, so there is no
  /// flash, and committing early would risk animating a launch that shouldn't.
  bool? _animate;

  /// Grace so the quiet entrance fade completes before the crossfade out.
  static const Duration _minDisplay = Duration(milliseconds: 550);

  // Storyboard (fractions of _seq)
  // Named so the phases read as the storyboard rather than as magic numbers,
  // and so retiming one can't silently overlap the next.
  static const double _spinEnd = 0.22;     // morph & spin reveal
  static const double _pulseEnd = 0.46;    // soundwave pulse
  static const double _collapseEnd = 0.57; // inward collapse to a dot
  static const double _iconEnd = 0.80;     // dot morphs into the app icon
  // 0.80 → 1.0: the icon becomes a disc that expands past the screen.

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();

    // 1500ms, down from 2400ms. Now that EVERY cold start animates (rather than
    // roughly one in a while under the old time-based gate), the sequence is
    // something you actually meet regularly, and at 2.4s it read as a wait.
    //
    // Safe to retime in one place: the storyboard above is expressed as
    // FRACTIONS of this controller, so every phase scales with it and none can
    // drift into the next. The 1400ms slow-boot timer below is untouched — it
    // only fires on the quiet path (`_animate == false`).
    _seq = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _quietCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _quietFade = CurvedAnimation(parent: _quietCtrl, curve: Curves.easeOut);
    _quietScale = Tween<double>(begin: 0.92, end: 1.0).animate(
        CurvedAnimation(parent: _quietCtrl, curve: Curves.easeOutCubic));

    // Navigate only once the expanding disc has FULLY covered the screen.
    //
    // The obvious design — pushReplacement with a circular-clip route
    // transition — does not work in this app and produced exactly the "residue
    // dot showing up even when the page opened" artifact: every page here has a
    // TRANSPARENT scaffold, because the app-wide DynamicBackground paints behind
    // the Navigator. So the incoming route never covers the outgoing one, and
    // the splash's collapsed dot stayed visible straight through the revealed
    // dashboard for the whole transition.
    //
    // Doing the reveal INSIDE the splash removes the overlap entirely: by the
    // time the route changes, the screen is one opaque colour, and the app fades
    // up out of it.
    _seq.addListener(() {
      if (_seq.value >= 0.995 && !_navigating) _navigate();
    });

    _decideAndStart();
    _bootstrap();

    Timer(const Duration(milliseconds: 1400), () {
      if (mounted && !_navigating && _animate == false) {
        setState(() => _slowBoot = true);
      }
    });

    Timer(const Duration(seconds: 8), () {
      if (mounted && !_navigating) _navigate(force: true);
    });
  }

  Future<void> _decideAndStart() async {
    final animate = await _SplashGate.shouldAnimate();
    if (!mounted) return;
    setState(() => _animate = animate);
    if (animate) {
      _seq.forward();
    } else {
      _quietCtrl.forward();
      _navigate(); // boot may already have finished while the gate was read
    }
  }

  Future<void> _bootstrap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasOnboarded = prefs.getBool('has_onboarded') ?? false;
      try {
        _loggedIn = await SessionAuthService()
            .ensureSession()
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        _loggedIn = await SessionCookieManager().hasPersistentSession();
      }

      // The access gate has to be a gate
      //
      // ROUTING WAS DECIDED FROM LOCAL STATE ALONE — cookies on disk meant
      // "logged in", and nothing here ever asked whether the account was allowed.
      // The check ran later from MainLayout, behind session registration, which
      // sits behind the home-feed warmup. Measured on device, a REFUSED account
      // restarting the app:
      //
      //   09:04:34  launch
      //   09:04:35  Quick Picks generated      ← app fully rendered
      //   09:04:36  home feed cached
      //   09:04:36–09:05:03  27s of artist fetches
      //   09:05:18  verifyAccess: 403 closed   ← asked 43s in
      //   09:05:18  cookies cleared            ← only now ejected
      //
      // Forty-three seconds of full app use, a cached personalised feed and dozens
      // of requests on an account the service had refused. Ejecting afterwards is
      // damage control, not access control.
      //
      // ALWAYS ASK. THE CACHED ANSWER IS ONLY A FALLBACK FOR SILENCE.
      //
      // Skipping the question for an "established" account (anyone inside
      // [withinOfflineGrace]) was wrong, because REVOCATION is precisely the case
      // where the cached answer is stale. Measured on a freshly BLOCKED account
      // that had been approved minutes earlier:
      //
      //   09:40:08  launch, no access check at all
      //   09:40:14  Quick Picks generated
      //   09:40:16  home feed cached
      //   09:40:17 Native-resolving stream: … ← it started PLAYING
      //   09:40:18  cookies cleared              ← ejected 10s in
      //
      // So the rule inverts: ask every time, obey a DEFINITE verdict, and consult
      // the grace window only when no verdict arrives. That still protects an
      // established user from an outage — silence is what grace is for — while a
      // block takes effect on the next launch, which is what it must do.
      //
      // The cost is one request before routing. Measured against this Worker:
      // 219–502 ms. Offline it fails fast rather than waiting out the timeout,
      // and the timeout is deliberately under the 3 s launch target.
      if (_loggedIn) {
        final notifier = ref.read(accountProvider.notifier);
        String status;
        String? who;
        try {
          final v = await notifier
              .verifyAccess()
              .timeout(const Duration(seconds: 3));
          status = v.status;
          who = v.identity;
        } catch (e) {
          status = 'unavailable';
          print('splash: access check did not answer ($e)');
        }

        if (status == 'approved') {
          // Nothing to do — routing proceeds.
        } else if (status == 'unavailable') {
          // No answer from the service. Forgive an ESTABLISHED account (bounded
          // to 14 days, and only for the account the approval belongs to);
          // refuse one that has never been cleared, which has nothing to forgive.
          if (!await notifier.withinOfflineGrace()) {
            _loggedIn = false;
            _gateStatus = status;
            print('splash: holding at the gate (no verdict, no grace)');
          } else {
            print('splash: no verdict — passing on offline grace');
          }
        } else {
          // pending / blocked / closed / throttled / capacity — a definite
          // refusal. It outranks any cached approval.
          _loggedIn = false;
          _gateStatus = status;
          _gateIdentity = who;
          print('splash: holding at the gate (status=$status)');
        }
      }
    } catch (_) {}

    if (!mounted) return;
    ref.read(homeProvider);
    ref.read(playerProvider.notifier).prewarmSession();
    _dataReady = true;
    _navigate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The morph ends ON this image, so it must already be decoded — a decode at
    // that moment would stall the very frame the icon appears on.
    precacheImage(
      AssetImage(AppIconService.assetForAccent(ref.read(themeProvider))),
      context,
    );
  }

  @override
  void dispose() {
    _seq.dispose();
    _quietCtrl.dispose();
    super.dispose();
  }

  void _navigate({bool force = false}) {
    if (_navigating) return;
    if (_animate == null && !force) return;
    if (!_dataReady && !force) return;
    // Animated launches hand over only at full screen coverage.
    if (_animate == true && !force && _seq.value < 0.995) return;

    if (_animate == false && !force) {
      final elapsed = DateTime.now().difference(_startTime);
      if (elapsed < _minDisplay) {
        Future.delayed(_minDisplay - elapsed, () {
          if (mounted) _navigate();
        });
        return;
      }
    }

    _navigating = true;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      pageBuilder: (_, __, ___) => !_loggedIn
          ? LoginGatePage(
              hasOnboarded: _hasOnboarded,
              initialStatus: _gateStatus,
              initialIdentity: _gateIdentity,
            )
          : (_hasOnboarded ? const MainLayout() : const OnboardingPage()),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child),
      // Slightly longer for the animated path: this fade IS step 5 of the
      // sequence (the dashboard rising out of the filled screen), not just a
      // page change.
      transitionDuration:
          Duration(milliseconds: _animate == true ? 320 : 350),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (_animate == true)
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _seq,
                  builder: (_, __) => _MorphSequence(
                    t: _seq.value,
                    accent: themeColor,
                    iconAsset: AppIconService.assetForAccent(themeColor),
                    spinEnd: _spinEnd,
                    pulseEnd: _pulseEnd,
                    collapseEnd: _collapseEnd,
                    iconEnd: _iconEnd,
                  ),
                ),
              ),
            )
          else if (_animate == false)
            Center(
              child: FadeTransition(
                opacity: _quietFade,
                child: ScaleTransition(
                  scale: _quietScale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 92,
                        height: 92,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: themeColor.withOpacity(0.25),
                              blurRadius: 46,
                              spreadRadius: 2,
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 22,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Image.asset(
                            AppIconService.assetForAccent(themeColor),
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Auvy',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.94),
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 3.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Slow-boot indicator — quiet mode only. During the animation the
          // sequence already reads as "something is happening", and a spinner
          // beside it would just look like a bug.
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 56,
            child: AnimatedOpacity(
              opacity: _slowBoot && !_navigating ? 1 : 0,
              duration: const Duration(milliseconds: 400),
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white24,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole sequence, from one normalised [t].
///
/// The mark is built from PRIMITIVES rather than the raster icon, because a
/// bitmap can be moved and scaled but it cannot morph, and every beat here is a
/// shape changing what it is. The icon only arrives at the end, once the shape
/// has become something it can cross-fade into.
///
/// Storyboard:
///  1. **Morph & spin reveal** — a small capsule fades in at centre, rotating
///     counter-clockwise through three quarter-turns while stretching
///     horizontally, arriving level and full width.
///  2. **Soundwave pulse** — the inner bar breathes horizontally, twice, with
///     the shell held still.
///  3. **Inward collapse** — the shell pulls back in from both ends until only a
///     small circular dot remains.
///  4. **Icon morph** — the dot grows and squares off into the app icon, which
///     cross-fades in over the accent fill, and holds.
///  5. **Circular expand** — the icon becomes a disc that scales past the screen
///     diagonal, filling the viewport, out of which the dashboard then fades.
class _MorphSequence extends StatelessWidget {
  final double t;
  final Color accent;
  final String iconAsset;
  final double spinEnd;
  final double pulseEnd;
  final double collapseEnd;
  final double iconEnd;

  const _MorphSequence({
    required this.t,
    required this.accent,
    required this.iconAsset,
    required this.spinEnd,
    required this.pulseEnd,
    required this.collapseEnd,
    required this.iconEnd,
  });

  static const double _dot = 18;        // collapsed diameter
  static const double _fullWidth = 132; // opened capsule width
  static const double _barHeight = 22;
  static const double _iconSize = 92;   // final app-icon size

  /// 0→1 progress within a phase, clamped outside it.
  static double _phase(double t, double from, double to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    // 1. spin + horizontal expand
    final spin = Curves.easeOutCubic.transform(_phase(t, 0.0, spinEnd));
    // Counter-clockwise: start three quarter-turns ahead and unwind to level.
    final angle = (1 - spin) * -(math.pi * 1.5);
    final fadeIn = Curves.easeOut.transform(_phase(t, 0.0, spinEnd * 0.5));

    // 3. collapse
    final collapse =
        Curves.easeInOutCubic.transform(_phase(t, pulseEnd, collapseEnd));

    // 4. icon morph
    final icon = Curves.easeOutCubic.transform(_phase(t, collapseEnd, iconEnd));

    // Geometry: dot → capsule → dot → icon square.
    final openedWidth = _dot + (_fullWidth - _dot) * spin;
    final collapsedWidth = openedWidth + (_dot - openedWidth) * collapse;
    final width = collapsedWidth + (_iconSize - collapsedWidth) * icon;
    final collapsedHeight = _barHeight - (_barHeight - _dot) * collapse;
    final height = collapsedHeight + (_iconSize - collapsedHeight) * icon;
    // Fully round while it is a dot/capsule, squaring off into the icon's
    // 24px corner as it grows.
    final radius = (height / 2) + (24 - height / 2) * icon;

    // 2. soundwave pulse
    // Two breaths, sine-shaped so it never snaps at the turnaround, faded out
    // as the collapse begins so the phases don't fight.
    final pulseT = _phase(t, spinEnd, pulseEnd);
    final envelope = math.sin(pulseT * math.pi).clamp(0.0, 1.0);
    final pulse = 1.0 +
        0.34 * envelope * math.sin(pulseT * math.pi * 4) * (1 - collapse);
    final innerOpacity = (1 - collapse).clamp(0.0, 1.0);

    // 5. circular expand
    final size = MediaQuery.of(context).size;
    final maxRadius =
        math.sqrt(size.width * size.width + size.height * size.height) / 2;
    final expandT = Curves.easeInCubic.transform(_phase(t, iconEnd, 1.0));
    // Grows from the icon's own corner radius so the disc emerges from the icon
    // rather than appearing over it.
    final discRadius = 24 + (maxRadius - 24) * expandT;

    return Stack(
      alignment: Alignment.center,
      children: [
        // The mark. Rotation only applies while it is still a bar — rotating a
        // recognisable app icon would look like a mistake.
        Opacity(
          opacity: fadeIn,
          child: Transform.rotate(
            angle: angle * (1 - icon),
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                // Fades from the flat accent shape to transparent as the icon
                // image takes over, so the two never both read as "the logo".
                color: accent.withOpacity(1 - icon),
                borderRadius: BorderRadius.circular(radius),
                boxShadow: [
                  BoxShadow(
                    color: accent.withOpacity(0.45),
                    blurRadius: 34,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Inner "soundwave" bar. Scaled on X only — a transform on a
                  // solid rect, so no layout and no saveLayer per frame.
                  if (innerOpacity > 0.01)
                    Opacity(
                      opacity: innerOpacity,
                      child: Transform.scale(
                        scaleX: pulse,
                        scaleY: 1,
                        child: Container(
                          width: collapsedWidth * 0.42,
                          height: collapsedHeight * 0.30,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius:
                                BorderRadius.circular(collapsedHeight),
                          ),
                        ),
                      ),
                    ),
                  // The real app icon, cross-faded in for the final form.
                  if (icon > 0.01)
                    Opacity(
                      opacity: icon,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: Image.asset(
                          iconAsset,
                          width: width,
                          height: height,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // The expanding disc. OPAQUE, and painted above everything, so by the
        // time the route changes the screen is a single flat colour, which is
        // what makes the hand-off residue-free (see the note in initState).
        // Lerped toward the app's own backdrop black so the dashboard fades up
        // out of its own background rather than out of a colour flash.
        if (expandT > 0)
          IgnorePointer(
            child: CustomPaint(
              size: Size(size.width, size.height),
              painter: _DiscPainter(
                radius: discRadius,
                color: Color.lerp(accent, const Color(0xFF050505),
                        Curves.easeIn.transform(expandT)) ??
                    accent,
              ),
            ),
          ),
      ],
    );
  }
}

/// A filled circle at the centre. A painter rather than a clipped/faded subtree:
/// this is one `drawCircle` per frame, where a full-screen `Opacity` would force
/// a screen-sized `saveLayer` every frame — the exact cost this codebase spent
/// effort removing from the player page.
class _DiscPainter extends CustomPainter {
  final double radius;
  final Color color;
  const _DiscPainter({required this.radius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      radius,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DiscPainter old) =>
      old.radius != radius || old.color != color;
}
