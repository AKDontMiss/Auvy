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

/// Mandatory YouTube sign-in, the first screen a new user sees, so it doubles as
/// the welcome screen: brand mark, three feature highlights, one call to action.
///
/// A signed-in session is what unlocks unthrottled, smooth-seeking streaming
/// (those clients refuse guests), so sign-in is required. Afterwards the user goes
/// to onboarding (first run) or the app. There's intentionally no skip.
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

  /// True while [_resumeIfApproved] checks whether the stored verdict still holds.
  /// The verdict this page opens with is from the last check, and it's re-checked
  /// immediately, so the page says "checking" rather than stating a refusal that may
  /// be about to reverse.
  bool _recheckingVerdict = false;

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
    if (_gateStatus == 'device_revoked') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await SessionCookieManager().clearCookies();
          await ref.read(accountProvider.notifier).resetDeviceSession();
        } catch (_) {}
      });
    } else if (_gateStatus == 'pending') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resumeIfApproved());
    }
  }

  /// The invite code field. Owned here so it is disposed with the page — the
  /// code itself lives on AccountNotifier, which is what the gate request reads.
  final TextEditingController _inviteCtrl = TextEditingController();

  @override
  void dispose() {
    _inviteCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _intro.dispose();
    super.dispose();
  }

  /// Approval usually lands while Auvy is closed, so returning to it is the
  /// natural moment to find out.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _gateStatus == 'pending') {
      _resumeIfApproved();
    }
  }

  /// Waits for cloud activation only when its answer decides where the user lands.
  /// Routing needs only `has_onboarded` from it; a user who already has that flag
  /// locally gains nothing by waiting (activation can take ten seconds or more,
  /// mostly Firebase sign-in and App Check). Bounded either way.
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

    // With no local flag the account looks new, and only the backup can say
    // otherwise. A restore can take the better part of half a minute before
    // `has_onboarded` lands, so wait for the real answer and say why; routing early
    // would send a returning user to onboarding. The cap is generous but finite, so a
    // genuinely new account isn't held at a spinner forever.
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
    if (_gateStatus != 'pending') return;
    if (!await SessionCookieManager().hasAuthCookies()) return;
    if (!mounted) return;

    final notifier = ref.read(accountProvider.notifier);
    setState(() => _recheckingVerdict = true);
    // try/finally so the flag comes down on every outcome (approved, refused, thrown);
    // otherwise the spinner could stay forever.
    final ({String status, String? identity, String? detail}) access;
    try {
      // force: this call exists to notice approval changing since the verdict this page
      // opened with, which is exactly what the cache holds.
      access = await notifier.verifyAccess(force: true);
    } finally {
      if (mounted) setState(() => _recheckingVerdict = false);
    }
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

      // Approval gate: ask the Worker whether this account may use Auvy before letting
      // it in.
      //
      // `unavailable` (Worker unreachable, or no cookie) is forgiven only for a device
      // approved before for this account, and only within 14 days of the last
      // successful check. Established users keep their music through an outage (playback
      // needs no server); a never-approved device gets no benefit of the doubt, and a
      // revoked user can't keep access by staying offline.
      final access = await notifier.verifyAccess();
      if (!mounted) return;
      final bool tolerated =
          access.status == 'unavailable' && await notifier.withinOfflineGrace();
      if (!mounted) return;
      if (access.status != 'approved' && !tolerated) {
        // For a pending verdict the session is kept, so the user can be let in later with
        // no second sign-in (see _resumeIfApproved); the button below clears it when the
        // user asks to use a different account (LoginActivity skips the account chooser
        // while a Google session is present). `invite_required` does drop the session and
        // bring the chooser back, since a one-tap re-login would retry the same account.
        // Transient verdicts (`unavailable`/`throttled`/`capacity`) keep the session.
        // Revocation (an account that had access) is handled in MainLayout._ejectTo.
        final aboutTheAccount = access.status == 'pending' ||
            access.status == 'invite_required' ||
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

      // Register the new cookie session so the account icon shows the signed-in user
      // immediately. The Worker's verified identity is the fallback when account_menu
      // won't answer, so the app doesn't show "Guest" after a successful sign-in.
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
    // Re-read the onboarding flag after the cloud restore: a returning user's backup
    // sets has_onboarded=true, so they go straight into the app.
    final prefs = await SharedPreferences.getInstance();
    final hasOnboarded = prefs.getBool('has_onboarded') ?? widget.hasOnboarded;
    print('DIAG: LoginGatePage _proceed: hasOnboarded=$hasOnboarded '
        '(prefs=${prefs.getBool('has_onboarded')}, widget=${widget.hasOnboarded})');
    if (hasOnboarded && !(prefs.getBool('has_onboarded') ?? false)) {
      await prefs.setBool('has_onboarded', true);
    }

    // "No local data" isn't the same as "new user". If the restore failed because the
    // service couldn't be reached, running onboarding would write a fresh profile over
    // the backup about to be restored. So for a transient failure, say so and let the
    // user retry; a definite "no backup" still onboards normally.
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
                      // Room under the notice so it doesn't look cut off.
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
                          if (_gateStatus != null && _recheckingVerdict)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Checking your account…',
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                          if (_gateStatus != null && !_recheckingVerdict)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Column(
                                children: [
                                  Text(
                                    switch (_gateStatus) {
                                      'pending' => 'This account needs to be approved before Auvy can be used.',
                                      'device_revoked' =>
                                        'This device was signed out from another device.',
                                      'invite_required' =>
                                        'Auvy is invite-only. Enter the code you were given, then sign in again.',
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
                                  // The code is typed HERE, not on a screen of
                                  // its own: the person is already looking at
                                  // the refusal that asked for it, and a second
                                  // screen would separate the question from the
                                  // answer.
                                  if (_gateStatus == 'invite_required') ...[
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: _inviteCtrl,
                                      autocorrect: false,
                                      textCapitalization:
                                          TextCapitalization.characters,
                                      textAlign: TextAlign.center,
                                      // The last field on this screen: the
                                      // action key submits rather than hunting
                                      // for a button.
                                      textInputAction: TextInputAction.done,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          letterSpacing: 2,
                                          fontWeight: FontWeight.w700),
                                      decoration: InputDecoration(
                                        hintText: 'XXXX-XXXX-XXXX',
                                        // 0.6 opacity: the hint shows the code's shape (its only clue to length), so
                                        // it carries information and has to meet 4.5:1 contrast.
                                        hintStyle: TextStyle(
                                            color: Colors.white.withOpacity(0.6),
                                            letterSpacing: 2),
                                        filled: true,
                                        fillColor: Colors.white.withOpacity(0.06),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide.none,
                                        ),
                                      ),
                                      onChanged: (v) {
                                        // Carried to the NEXT sign-in attempt.
                                        // Uppercased because the code alphabet
                                        // is, and a lowercase paste should not
                                        // read as a wrong code.
                                        AccountNotifier.pendingInviteCode =
                                            v.trim().isEmpty
                                                ? null
                                                : v.trim().toUpperCase();
                                      },
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Enter the code, then sign in again.',
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
                                      if (_canSwitchAccount ||
                                          _gateStatus == 'device_revoked') {
                                        await SessionCookieManager().clearCookies();
                                        await ref
                                            .read(accountProvider.notifier)
                                            .resetDeviceSession();
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
                                            _gateStatus == 'device_revoked'
                                                ? Icons.login_rounded
                                                : (_canSwitchAccount
                                                    ? Icons.switch_account_rounded
                                                    : Icons.play_circle_fill_rounded),
                                            size: 22),
                                        const SizedBox(width: 10),
                                        Text(
                                            _gateStatus == 'device_revoked'
                                                ? 'Sign in again'
                                                : (_canSwitchAccount
                                                    ? 'Try a different account'
                                                    : 'Continue with YouTube'),
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
                          // Use-at-your-own-risk notice, on this screen because this is where a person hands
                          // over an account. Auvy uses interfaces the service doesn't publish for
                          // third-party apps, and any consequence falls on the signed-in account, so people
                          // should know before signing in. Deliberately generic about the mechanism. Shown
                          // as quiet text alongside the privacy line, not as a blocking consent dialog.
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
