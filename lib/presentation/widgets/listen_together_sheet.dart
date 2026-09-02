import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// Listen Together sheet
/// The one surface for the whole feature: start a session, join with a code,
/// and (while live) see the room code, share it, and watch who's listening.
/// Follows the player-menu conventions: floating solid dark card (no
/// BackdropFilter — the player animates beneath), 24 px radius, hairline
/// border, accent from [themeProvider].
void showListenTogetherSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const ListenTogetherSheet(),
  );
}

class ListenTogetherSheet extends ConsumerStatefulWidget {
  const ListenTogetherSheet({super.key});

  @override
  ConsumerState<ListenTogetherSheet> createState() =>
      _ListenTogetherSheetState();
}

class _ListenTogetherSheetState extends ConsumerState<ListenTogetherSheet>
    with SingleTickerProviderStateMixin {
  static const _card = Color(0xFF1A1A1E);

  bool _joinMode = false;
  String? _error;
  final TextEditingController _codeCtrl = TextEditingController();
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // Started/stopped from build — it only needs to tick while the LIVE dot
    // is actually visible (active session view).
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
  }

  @override
  void dispose() {
    _pulse.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    HapticService.medium();
    setState(() => _error = null);
    final err =
        await ref.read(listenTogetherProvider.notifier).createSession();
    if (!mounted) return;
    if (err != null) setState(() => _error = err);
  }

  Future<void> _join() async {
    HapticService.medium();
    setState(() => _error = null);
    final err = await ref
        .read(listenTogetherProvider.notifier)
        .joinSession(_codeCtrl.text);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final lt = ref.watch(listenTogetherProvider);

    if (lt.active && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!lt.active && _pulse.isAnimating) {
      _pulse.stop();
    }

    // Session dropped while the sheet is open (host ended it, connection
    // lost): surface the reason once, as a toast.
    ref.listen(listenTogetherProvider, (prev, next) {
      final notice = next.notice;
      if (notice != null && mounted) {
        AnimatedToast.show(context,
            text: notice, icon: Icons.headphones_rounded, color: themeColor);
        ref.read(listenTogetherProvider.notifier).clearNotice();
      }
    });

    return SafeArea(
      // Scrollable so the card + Close button can never overflow when the
      // join-code keyboard eats half the height (26px RenderFlex overflow on
      // a 2340px S24+ without this — worse on smaller phones).
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 24,
          // Keep the join code field above the keyboard.
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: _card.withOpacity(0.97),
                  borderRadius: BorderRadius.circular(24),
                  border:
                      Border.all(color: Colors.white.withOpacity(0.1), width: 1),
                ),
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                child: lt.active
                    ? _activeView(lt, themeColor)
                    : _idleView(lt, themeColor),
              ),
            ),
            // The "Close" slab is GONE
            //
            // It was a full-width 60px card below the sheet, styled like a second
            // panel, whose only job was to dismiss. Redundant twice over: a modal
            // sheet already closes by swiping down or tapping outside, and the
            // grabber at the top of the card says so. It also broke the sheet's
            // own composition — two stacked cards of equal weight, so the eye had
            // to work out which one was the content.
            //
            // Nothing is lost: swipe-down and tap-outside both still work, and
            // the session's real exits ("End session" / "Leave") live inside the
            // card where the session state is, which is where they belong.
          ],
        ),
      ),
    );
  }

  // Idle: start or join

  Widget _idleView(ListenTogetherState lt, Color themeColor) {
    return Column(
      key: const ValueKey('idle'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: _grabber()),
        const SizedBox(height: 18),
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: themeColor.withOpacity(0.14),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: themeColor.withOpacity(0.3)),
              ),
              child: Icon(Icons.groups_rounded, color: themeColor, size: 23),
            ),
            const SizedBox(width: 12),
            const Text('Listen Together',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Host a session and share the code, or join a friend\'s. Every track, pause and seek stays in sync — until you leave.',
          style: TextStyle(
              color: Colors.white.withOpacity(0.72),
              fontSize: 13.5,
              height: 1.45),
        ),
        const SizedBox(height: 18),
        if (!_joinMode) ...[
          _primaryButton(
            themeColor,
            icon: Icons.podcasts_rounded,
            label: 'Start a session',
            busy: lt.busy,
            onTap: lt.busy ? null : _create,
          ),
          const SizedBox(height: 12),
          _secondaryButton(
            icon: Icons.pin_rounded,
            label: 'Join with a code',
            onTap: lt.busy
                ? null
                : () {
                    HapticService.light();
                    setState(() {
                      _joinMode = true;
                      _error = null;
                    });
                  },
          ),
        ] else ...[
          TextField(
            controller: _codeCtrl,
            autofocus: true,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 10),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
              UpperCaseTextFormatter(),
            ],
            cursorColor: themeColor,
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••••',
              hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.55), letterSpacing: 10),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: themeColor, width: 1.4),
              ),
            ),
            onSubmitted: (_) => _join(),
          ),
          const SizedBox(height: 14),
          _primaryButton(
            themeColor,
            icon: Icons.arrow_forward_rounded,
            label: 'Join session',
            busy: lt.busy,
            onTap: lt.busy ? null : _join,
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: () => setState(() {
                _joinMode = false;
                _error = null;
              }),
              child: Text('Back',
                  style: TextStyle(color: Colors.white.withOpacity(0.78))),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Text(_error!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13)),
          ),
        ],
      ],
    );
  }

  // Active session

  Widget _activeView(ListenTogetherState lt, Color themeColor) {
    final isHost = lt.role == LtRole.host;
    return Column(
      key: const ValueKey('active'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _grabber(),
        const SizedBox(height: 16),
        Row(
          children: [
            _liveDot(themeColor),
            const SizedBox(width: 8),
            Text('LIVE SESSION',
                style: TextStyle(
                    color: themeColor,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            TextButton(
              onPressed: () {
                HapticService.medium();
                ref.read(listenTogetherProvider.notifier).leaveSession();
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFF6B6B),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(isHost ? 'End session' : 'Leave',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (isHost) ...[
          Text(lt.code ?? '',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 12)),
          const SizedBox(height: 4),
          Text('Share this code — friends join in Auvy',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _secondaryButton(
                  icon: Icons.copy_rounded,
                  label: 'Copy code',
                  onTap: () {
                    HapticService.light();
                    Clipboard.setData(ClipboardData(text: lt.code ?? ''));
                    AnimatedToast.show(context,
                        text: 'Code copied',
                        icon: Icons.check_rounded,
                        color: themeColor);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _secondaryButton(
                  icon: Icons.ios_share_rounded,
                  label: 'Invite',
                  onTap: () {
                    HapticService.light();
                    Share.share(
                        'Listen with me on Auvy Open Listen Together and enter code ${lt.code} — we\'ll hear the same moment, perfectly in sync.');
                  },
                ),
              ),
            ],
          ),
        ] else ...[
          Text('Listening with ${lt.hostName ?? 'Host'}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Session ${lt.code ?? ''} · the host controls playback',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
        ],
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('IN THE SESSION (${lt.members.length})',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 10),
        ...lt.members.map((m) => _memberRow(m, themeColor)),
        if (lt.members.length <= 1)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text('Waiting for friends to join…',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66),
                    fontSize: 13,
                    fontStyle: FontStyle.italic)),
          ),
      ],
    );
  }

  Widget _memberRow(LtMember m, Color themeColor) {
    final initial = m.name.isNotEmpty ? m.name[0].toUpperCase() : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  themeColor.withOpacity(0.85),
                  themeColor.withOpacity(0.45)
                ],
              ),
            ),
            child: Text(initial,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
          if (m.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: themeColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: themeColor.withOpacity(0.4)),
              ),
              child: Text('HOST',
                  style: TextStyle(
                      color: themeColor,
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
            ),
        ],
      ),
    );
  }

  // Small pieces

  Widget _grabber() => Container(
        width: 40,
        height: 5,
        decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(10)),
      );

  Widget _liveDot(Color themeColor) {
    // Compositor-only pulse (see _LiveSessionDot in player_page.dart): fading
    // a static dot repaints nothing; animating shadow geometry repainted the
    // sheet + everything under it every frame.
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.5, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut))
            .animate(_pulse),
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: themeColor,
            boxShadow: [
              BoxShadow(
                  color: themeColor.withOpacity(0.55),
                  blurRadius: 8,
                  spreadRadius: 1.2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _primaryButton(Color themeColor,
      {required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool busy = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            themeColor,
            Color.lerp(themeColor, Colors.black, 0.25)!,
          ]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: themeColor.withOpacity(0.30),
                blurRadius: 16,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Colors.white))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _secondaryButton(
      {required IconData icon,
      required String label,
      required VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white70, size: 19),
              const SizedBox(width: 9),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercases as the user types (room codes are stored uppercase).
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
