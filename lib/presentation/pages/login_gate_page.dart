import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/logic/session_auth_service.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/pages/onboarding_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// Mandatory YouTube sign-in gate — the first screen a brand-new user sees,
/// so it doubles as the WELCOME screen: brand mark, three quiet feature
/// highlights, one confident call-to-action.
///
/// A logged-in session is what unlocks un-throttled, smooth-seeking streaming
/// (the un-throttled YouTube clients return UNPLAYABLE / LOGIN_REQUIRED for
/// guests), so the app requires sign-in before it can be used. After a
/// successful login the user continues to onboarding (first run) or the main
/// app. There is intentionally no "skip".
class LoginGatePage extends ConsumerStatefulWidget {
  final bool hasOnboarded;

  /// Set when the user was EJECTED mid-session (blocked, or put back in the
  /// queue) rather than arriving here normally. The page then opens already
  /// showing the verdict and which account it applies to, instead of a blank
  /// sign-in screen that gives no hint why they were thrown out.
  final String? initialStatus;
  final String? initialIdentity;

  const LoginGatePage({
    super.key,
    required this.hasOnboarded,
    this.initialStatus,
    this.initialIdentity,
  });

  @override
  ConsumerState<LoginGatePage> createState() => _LoginGatePageState();
}

class _LoginGatePageState extends ConsumerState<LoginGatePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _auth = SessionAuthService();
  bool _busy = false;
  bool _failed = false;

  /// Replaces the generic "sign-in didn't complete" line when the real reason is
  /// known and different — currently: the account signed in, but the cloud backup
  /// could not be reached, so we must NOT treat the empty device as a new user.
  String? _failureNote;
  bool _finishing = false;

  /// Set when the Worker recognised the account but REFUSED it — `pending`,
  /// `blocked`, `closed`, `throttled` or `capacity`. Sign-in itself succeeded, so
  /// this must not read as a sign-in failure: the account is fine, it simply isn't
  /// approved yet. Null while nothing has been refused.
  String? _gateStatus;

  /// Which account was refused, as the Worker resolved it. Shown so the owner can
  /// be told exactly which address to approve.
  String? _gateIdentity;

  /// The HTTP code and error the Worker actually returned.
  ///
  /// Shown for the UNREACHABLE case only. Release builds don't forward `print` to
  /// logcat, so without this on screen there is no way to tell a genuine refusal
  /// from an outage, which is exactly what made this take three passes to
  /// diagnose.
  String? _gateDetail;

  /// True when the refusal was about the ACCOUNT (pending/blocked/closed), so the
  /// session has been dropped and the next attempt will offer the account chooser.
  /// Drives the button label — "Try a different account" rather than "Try again",
  /// because retrying the same one can only fail again.
  bool _canSwitchAccount = false;

  /// Shown under the button while something is genuinely being waited on, so a
  /// pause is explained rather than mysterious.
  String? _busyNote;

  // One controller drives the whole staggered entrance (icon → title →
  // features → CTA). Cheap: implicit per-frame work is just opacity/translate.
  late final AnimationController _intro;

  @override
  void initState() {
    super.initState();
    // Ejected here by MainLayout — show the verdict immediately.
    _gateStatus = widget.initialStatus;
    _gateIdentity = widget.initialIdentity;
    _canSwitchAccount = widget.initialStatus != null;
    _intro = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..forward();
    WidgetsBinding.instance.addObserver(this);
    // Someone told to wait may have been approved since. Check without being
    // asked, so being let in costs them nothing.
    if (_gateStatus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resumeIfApproved());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intro.dispose();
    super.dispose();
  }

  /// Approval usually lands while Auvy is closed, so returning to it is the
  /// natural moment to find out.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _gateStatus != null) {
      _resumeIfApproved();
    }
  }

  /// Enters the app WITHOUT a second sign-in when a kept session has since been
  /// approved.
  ///
  /// No WebView here. The cookies are already on the device; the only open
  /// question was whether the Worker allows this account, and that is one
  /// request. Sending the user back through Google to answer it is what made
  /// approval feel like starting over.
  ///
  /// Silent: a still-pending answer changes nothing on screen, so a failed check
  /// is invisible rather than a second rejection message.
  /// Waits on cloud activation ONLY when its answer decides where the user lands.
  ///
  /// Measured on device: sign-in is under a second, and the cloud step took 11.6s
  /// (Firebase custom-token sign-in, mostly App Check). The single thing routing
  /// needs from it is has_onboarded, so a user who already holds that flag locally
  /// learns nothing by waiting, and the wait is bounded either way, because an
  /// unbounded one turns a slow network into a hung login.
  Future<void> _awaitCloudIfItCanChangeRouting() async {
    final notifier = ref.read(accountProvider.notifier);
    final prefs = await SharedPreferences.getInstance();
    final alreadyOnboarded = prefs.getBool('has_onboarded') ?? false;
    final cloud = notifier.enableCloudBackup(interactive: true);

    // Already onboarded on this device: the restore cannot change the routing, so
    // enter now and let it finish behind the app.
    if (alreadyOnboarded) {
      print('login: already onboarded — entering now, cloud restore continues');
      return;
    }

    // NOT A THREE-SECOND CAP. THAT CAP SENT RETURNING USERS THROUGH ONBOARDING.
    //
    // With no local flag, this account looks new, and the ONLY thing that can say
    // otherwise is the backup. Measured on device: the Worker answers in ~470ms,
    // then the Firebase sign-in plus a 17-part incremental restore takes about 27
    // SECONDS before has_onboarded lands. A 3s cap routed 27s before the answer
    // existed, so an established account was offered onboarding and only got its
    // library back after tapping "quick start", which is exactly how it looked.
    //
    // So this waits for the real answer, and says why it is waiting. A silent
    // 27-second pause would be the original bug; an explained one is a restore.
    // The cap is generous but finite: past it, a genuinely new account should not
    // be held at a spinner for ever.
    if (mounted) {
      setState(() => _busyNote = 'Checking for your library backup…');
    }
    try {
      await cloud.timeout(const Duration(seconds: 45), onTimeout: () {
        print('login: backup check timed out at 45s — treating as a new account');
        return false;
      });
    } finally {
      if (mounted) setState(() => _busyNote = null);
    }
  }

  Future<void> _resumeIfApproved() async {
    if (_busy || _finishing || !mounted) return;
    if (!await SessionCookieManager().hasAuthCookies()) return;
    if (!mounted) return;

    final notifier = ref.read(accountProvider.notifier);
    final access = await notifier.verifyAccess();
    if (!mounted || access.status != 'approved') return;

    _finishing = true;
    setState(() => _busy = true);
    print('gate: approved since last time — entering without a new sign-in');
    await notifier.registerAccountFromSession(
      force: true,
      fallbackIdentity: access.identity,
    );
    if (!mounted) return;
    await _awaitCloudIfItCanChangeRouting();
    if (mounted) await _proceed();
  }

  Future<void> _startLogin() async {
    if (_busy) return;
    HapticService.light();
    setState(() { _busy = true; _failed = false; _failureNote = null; });

    // NATIVE sign-in screen (LoginActivity — a plain WebView, which Google's
    // sign-in accepts where a custom-tab flow is refused).
    final success = await _auth.signInWithNativeWebView();

    if (!mounted) return;
    if (success && !_finishing) {
      _finishing = true;
      final notifier = ref.read(accountProvider.notifier);

      // Approval gate
      //
      // Ask the Worker whether this account may use Auvy BEFORE letting it in.
      //
      // Approval used to gate only cloud backup, which meant an unapproved
      // stranger got a fully working app and was never told anything — the
      // opposite of the intent, and invisible to the owner because the app never
      // contacted the Worker at all unless it had already resolved the account
      // locally (and when that failed it just said "Guest").
      //
      // `unavailable` (Worker unreachable, or no cookie to send) is forgiven ONLY
      // for a device that has been approved before.
      //
      // Treating `unavailable` as "allowed" outright is what let an unapproved
      // account straight in: the app couldn't reach the Worker, shrugged, and
      // opened the door, and because an unavailable answer carries no identity,
      // that user then sat there as "Guest". Established users still keep their
      // music through an outage, since playback needs no server at all; a device
      // that has never once been approved does not get the benefit of a failed
      // request.
      //
      // And that forgiveness now EXPIRES (14 days since the last successful
      // check). Unbounded, it meant a revoked user could keep access simply by
      // staying offline, since revocation can only ever reach a device that
      // talks to the Worker.
      final access = await notifier.verifyAccess();
      if (!mounted) return;
      final bool tolerated =
          access.status == 'unavailable' && await notifier.withinOfflineGrace();
      if (!mounted) return;
      if (access.status != 'approved' && !tolerated) {
        // DROP THE REJECTED SESSION, or the user is STUCK on that account.
        //
        // LoginActivity skips the account chooser whenever a live Google session
        // is already in the WebView jar (one-tap re-login). So after a refusal,
        // every further attempt silently re-signed the SAME rejected account and
        // hit the same wall — there was no way to switch to an approved one.
        // Clearing the session (ours AND the platform jar) puts the chooser back,
        // so a refusal becomes "try a different account" rather than a dead end.
        //
        // Only for verdicts about the ACCOUNT. `unavailable`/`throttled`/
        // `capacity` say nothing about who they are, and forcing a re-login there
        // would just cost them their session over a transient failure.
        // The session is KEPT here, and that is the point.
        //
        // This cleared the cookies for any verdict about the account, so a PENDING
        // user — someone waiting to be let in — lost their sign-in the moment they
        // were told to wait. Approval can come hours later, and by then there was
        // nothing left to approve into: they had to sign in from scratch.
        //
        // The original reason was sound. LoginActivity skips the account chooser
        // while a live Google session sits in the WebView jar, so a refused user
        // could never switch accounts. But that is a reason to clear ON DEMAND, not
        // as a side effect — the button below does it when the user actually asks
        // for a different account, which puts the chooser back exactly when wanted.
        //
        // Keeping it is what lets _resumeIfApproved admit them on the next open
        // with no second sign-in. Revocation is different and still clears: see
        // MainLayout._ejectTo, where the account HAD access and lost it.
        final aboutTheAccount = access.status == 'pending' ||
            access.status == 'blocked' ||
            access.status == 'closed';
        if (!mounted) return;
        setState(() {
          _busy = false;
          _finishing = false;
          _gateStatus = access.status;
          _gateIdentity = access.identity;
          _gateDetail = access.detail;
          _canSwitchAccount = aboutTheAccount;
        });
        return;
      }

      // Register the freshly-captured cookie session in the account provider
      // so the account icon shows the signed-in user immediately. The Worker's
      // verified identity is the fallback for when account_menu won't answer —
      // without it the app lands on "Guest" despite a successful sign-in.
      await notifier.registerAccountFromSession(
        force: true,
        fallbackIdentity: access.identity,
      );
      // Cloud activation, waited on only where it can change the routing —
      // see _awaitCloudIfItCanChangeRouting.
      await _awaitCloudIfItCanChangeRouting();
      if (mounted) await _proceed();
    } else {
      setState(() { _busy = false; _failed = true; });
    }
  }

  Future<void> _proceed() async {
    // Re-read the onboarding flag AFTER the cloud restore above: a returning
    // user's backup sets has_onboarded=true, so they land straight in the app
    // instead of being sent through onboarding again ("reinstall forgets me").
    final prefs = await SharedPreferences.getInstance();
    final hasOnboarded = prefs.getBool('has_onboarded') ?? widget.hasOnboarded;

    //"NO LOCAL DATA" IS NOT THE SAME AS "NEW USER".
    //
    // The restore above can fail because the service could not be REACHED — one
    // slow Worker call was enough. With no local data (a reinstall, or Android's
    // "clear data") that used to read as a brand-new user, so the app ran
    // ONBOARDING over an account with a full cloud backup. To the person holding
    // the phone that is indistinguishable from having their library deleted.
    //
    // Onboarding is destructive in that situation: it writes has_onboarded and a
    // fresh taste profile over the state we were about to restore. So when the
    // failure was transient, refuse to draw the conclusion — say so and let them
    // retry. A definite answer ("this account has no backup") still onboards
    // normally, because then it IS a new user.
    if (!hasOnboarded &&
        ref.read(accountProvider.notifier).cloudActivationUnreachable) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _failureNote =
            "Couldn't reach your backup just now — your library is safe. "
            'Check your connection and try again.';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      pageBuilder: (_, anim, secondary) =>
          hasOnboarded ? const MainLayout() : const OnboardingPage(),
      transitionsBuilder: (_, anim, secondary, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child),
      transitionDuration: const Duration(milliseconds: 700),
    ));
  }

  /// Fade + gentle rise, staggered across the intro timeline.
  Widget _entrance({required double from, required double to, required Widget child}) {
    final curved = CurvedAnimation(
        parent: _intro, curve: Interval(from, to, curve: Curves.easeOutCubic));
    return AnimatedBuilder(
      animation: curved,
      builder: (context, c) => Opacity(
        opacity: curved.value,
        child: Transform.translate(offset: Offset(0, 18 * (1 - curved.value)), child: c),
      ),
      child: child,
    );
  }

  Widget _featureRow(Color themeColor, IconData icon, String title, String detail) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: themeColor.withOpacity(0.14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: themeColor.withOpacity(0.18)),
            ),
            child: Icon(icon, color: themeColor, size: 21),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 12.5,
                        height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Soft ambient glow behind the hero — pure gradient, no blur cost.
            Positioned(
              top: -120,
              left: -80,
              right: -80,
              height: 420,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [themeColor.withOpacity(0.22), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, viewport) {
                  // Proportional so the hero still sits low on a tall screen,
                  // clamped so it cannot eat the page on a short one.
                  final topGap =
                      (viewport.maxHeight * 0.055).clamp(14.0, 58.0);
                  final midGap =
                      (viewport.maxHeight * 0.05).clamp(14.0, 52.0);
                  return SingleChildScrollView(
                    padding: EdgeInsets.only(
                      left: 28,
                      right: 28,
                      top: topGap,
                      // Real breathing room under the notice — it used to end
                      // 28px from the edge and read as cut off even when it fit.
                      bottom: 34,
                    ),
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // Brand mark
                    _entrance(
                      from: 0.0,
                      to: 0.45,
                      child: Row(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                    color: themeColor.withOpacity(0.35),
                                    blurRadius: 34,
                                    spreadRadius: 1),
                                BoxShadow(
                                    color: Colors.black.withOpacity(0.5),
                                    blurRadius: 18,
                                    offset: const Offset(0, 8)),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.asset('assets/icons/app_icon.webp',
                                  fit: BoxFit.cover, filterQuality: FilterQuality.high),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),

                    // Headline
                    _entrance(
                      from: 0.1,
                      to: 0.55,
                      child: const Text(
                        'Millions of songs.\nZero interruptions.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                          letterSpacing: -1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _entrance(
                      from: 0.18,
                      to: 0.62,
                      child: Text(
                        'Welcome to Auvy — your music, podcasts and radio, beautifully in one place.',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: 15,
                            height: 1.45,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 34),

                    // Feature highlights
                    _entrance(
                      from: 0.3,
                      to: 0.75,
                      child: _featureRow(themeColor, Icons.graphic_eq_rounded,
                          'Full-quality streaming', 'Smooth, ad-free playback powered by your YouTube account.'),
                    ),
                    _entrance(
                      from: 0.38,
                      to: 0.83,
                      child: _featureRow(themeColor, Icons.lyrics_rounded,
                          'Live synced lyrics', 'Word-for-word lyrics that follow every track as it plays.'),
                    ),
                    _entrance(
                      from: 0.46,
                      to: 0.9,
                      child: _featureRow(themeColor, Icons.download_rounded,
                          'Made yours, offline', 'Download songs, albums and playlists — listen anywhere.'),
                    ),

                    SizedBox(height: midGap),

                    // Cta
                    _entrance(
                      from: 0.55,
                      to: 1.0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (_failed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _failureNote ??
                                    "Sign-in didn't complete. Give it another try.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.orange.withOpacity(0.9),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          // The account signed in FINE and was then refused. Kept
                          // visually distinct from _failed above, because telling
                          // someone "sign-in didn't complete" when it did — and
                          // they're simply waiting on approval — sends them into a
                          // retry loop that can never succeed.
                          if (_gateStatus != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Column(
                                children: [
                                  Text(
                                    switch (_gateStatus) {
                                      'pending' => 'This account needs to be approved before Auvy can be used.',
                                      'blocked' => 'Access for this account has been removed.',
                                      'closed' => 'Auvy is not accepting new accounts right now.',
                                      'unavailable' => "Couldn't reach the approval service.",
                                      'throttled' => 'Too many sign-ins for this account today. Try again tomorrow.',
                                      'capacity' => "Auvy is at capacity today. Try again tomorrow.",
                                      _ => 'This account cannot use Auvy at the moment.',
                                    },
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        height: 1.4),
                                  ),
                                  // The raw reason, for the unreachable case. Ugly
                                  // on purpose — it is the only channel that
                                  // survives a release build.
                                  if (_gateStatus == 'unavailable' &&
                                      _gateDetail != null) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      _gateDetail!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.orange.withOpacity(0.75),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                  if (_gateIdentity != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      _gateIdentity!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.white.withOpacity(0.66),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                  if (_gateStatus == 'pending') ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Send that address to whoever gave you Auvy. '
                                      'Once approved, just reopen Auvy — you are let '
                                      'straight in, with no need to sign in again.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.white.withOpacity(0.66),
                                          fontSize: 11.5,
                                          height: 1.45),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          if (_busyNote != null) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Text(
                                _busyNote!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.72),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                elevation: 10,
                                shadowColor: Colors.white.withOpacity(0.25),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28)),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      // Clearing HERE, not on the verdict, keeps a
                                      // pending session alive while still giving the
                                      // chooser back on request — LoginActivity
                                      // skips it whenever a live Google session sits
                                      // in the WebView jar.
                                      if (_canSwitchAccount) {
                                        await SessionCookieManager().clearCookies();
                                      }
                                      await _startLogin();
                                    },
                              child: _busy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.4, color: Colors.black54),
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                            _canSwitchAccount
                                                ? Icons.switch_account_rounded
                                                : Icons.play_circle_fill_rounded,
                                            size: 22),
                                        const SizedBox(width: 10),
                                        Text(
                                            _canSwitchAccount
                                                ? 'Try a different account'
                                                : 'Continue with YouTube',
                                            style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800)),
                                      ],
                                    ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock_rounded,
                                  size: 13, color: Colors.white.withOpacity(0.4)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Your sign-in stays on this device. Auvy never sees your password.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.66),
                                      fontSize: 11.5,
                                      height: 1.3),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Use-at-your-own-risk notice
                          //
                          // THIS BELONGS ON THIS SCREEN SPECIFICALLY, because
                          // this is the moment a person hands over an account.
                          // Auvy reaches the music service through interfaces that
                          // are not the ones the service publishes for third-party
                          // apps, and the realistic consequence of that lands on
                          // the SIGNED-IN ACCOUNT, not on the app. Someone deciding
                          // whether to sign in is entitled to know that before they
                          // do, not afterwards.
                          //
                          // Deliberately generic about the mechanism: it says
                          // "interfaces not intended for third-party apps", which is
                          // the honest and relevant fact, without publishing a
                          // how-to. Saying nothing at all would be the actual
                          // problem — an unstated risk the user carries.
                          //
                          // Not a dialog, and not a checkbox: a blocking consent
                          // gate on a personal-use app is theatre. It is placed
                          // where it is read, in the same quiet register as the
                          // privacy line above it.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 13, color: Colors.white.withOpacity(0.32)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Use at your own risk. Auvy is an independent, '
                                  'unofficial app and is not affiliated with any '
                                  'music service. It reaches them through interfaces '
                                  'not intended for third-party apps, which may stop '
                                  'working or affect the account you sign in with.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.66),
                                      fontSize: 10.5,
                                      height: 1.4),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
