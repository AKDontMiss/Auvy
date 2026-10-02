import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:auvy/core/utils/share_origin.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_colors.dart';

/// Listen Together sheet: start a session, join with a code, and while live see the
/// code, invite people, and see who's listening.
///
/// Uses the sleep timer's layout, like the rest of the app:
///   • One header that always carries the state (not in a session, hosting for two,
///     listening with someone), in the accent when something is live.
///   • Choices as rows: hosting and joining are peers, each with a line saying what
///     happens.
///   • Explanations are attached to the controls they describe, not in a paragraph.
///
/// Joining expands in place, so the other choice stays on screen and no back button
/// is needed. Tapping the code copies it; there's no separate Copy button.
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
  /// Every sheet's surface, defined once. See [AppColors.modalPanel] for why it
  /// is not a hex literal here.
  static const _card = AppColors.modalPanel;

  /// Room codes are six alphanumerics. The field, the hint and the button all
  /// derive from this rather than each repeating the number.
  static const _codeLength = 6;

  bool _joinOpen = false;
  String? _error;
  final TextEditingController _codeCtrl = TextEditingController();
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // Started and stopped from build — it only needs to tick while the LIVE
    // dot is on screen.
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    // Redraws the join button as the code becomes complete. Without this the
    // button stays inert-looking until some other rebuild happens to arrive.
    _codeCtrl.addListener(_onCodeChanged);
  }

  @override
  void dispose() {
    _codeCtrl.removeListener(_onCodeChanged);
    _pulse.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final ready = _codeCtrl.text.length == _codeLength;
    if (ready != _codeWasReady) {
      _codeWasReady = ready;
      if (mounted) setState(() {});
    }
  }

  /// Only rebuild on the transition into and out of "complete", not on every
  /// keystroke — five of the six characters change nothing on screen.
  bool _codeWasReady = false;

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

  void _copyCode(String? code, Color themeColor) {
    if (code == null || code.isEmpty) return;
    HapticService.light();
    Clipboard.setData(ClipboardData(text: code));
    AnimatedToast.show(context,
        text: 'Code copied', icon: Icons.check_rounded, color: themeColor);
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
      // Scrollable so the card can never overflow when the join keyboard eats
      // half the height — it overflowed on a tall screen without this, and
      // worse on small ones.
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 24,
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: _grabber()),
              const SizedBox(height: 18),
              _header(lt, themeColor),
              const SizedBox(height: 16),
              if (lt.active)
                ..._liveBody(lt, themeColor)
              else
                ..._idleBody(lt, themeColor),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 16, color: Color(0xFFE57373)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Color(0xFFE57373),
                              fontSize: 12.5,
                              height: 1.35)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Header.

  /// Icon tile, name, and a subtitle that states what's true right now: whether
  /// anything is live, with whom, and how many. In the accent when live, and a pulsing
  /// dot replaces the icon then.
  Widget _header(ListenTogetherState lt, Color themeColor) {
    final active = lt.active;
    final isHost = lt.role == LtRole.host;
    final others = lt.members.length - 1;

    final String subtitle;
    if (!active) {
      subtitle = 'Not in a session';
    } else if (isHost) {
      subtitle = others <= 0
          ? 'Hosting · waiting for someone to join'
          : 'Hosting · $others ${others == 1 ? 'person' : 'people'} listening';
    } else {
      subtitle = 'Listening with ${lt.hostName ?? 'the host'}';
    }

    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: active ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
                color: themeColor.withValues(alpha: active ? 0.34 : 0.18)),
          ),
          child: active
              ? _liveDot(themeColor)
              : Icon(Icons.groups_rounded, color: themeColor, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Listen Together',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      active ? themeColor : Colors.white.withValues(alpha: 0.60),
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Idle: host, or join.

  List<Widget> _idleBody(ListenTogetherState lt, Color themeColor) {
    return [
      _row(
        icon: Icons.podcasts_rounded,
        label: 'Start a session',
        subtitle: 'Share a code — every track, pause and seek stays in sync',
        themeColor: themeColor,
        busy: lt.busy && !_joinOpen,
        onTap: lt.busy ? null : _create,
      ),
      Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
      _row(
        icon: Icons.pin_rounded,
        label: 'Join with a code',
        subtitle: "Enter a friend's code and hear what they hear",
        themeColor: themeColor,
        selected: _joinOpen,
        // Chevron rotates to point down when the field is open, so the row
        // shows whether it is the thing currently expanded.
        trailing: AnimatedRotation(
          turns: _joinOpen ? 0.25 : 0,
          duration: const Duration(milliseconds: 180),
          child: Icon(Icons.chevron_right_rounded,
              size: 20,
              color: _joinOpen
                  ? themeColor
                  : Colors.white.withValues(alpha: 0.35)),
        ),
        onTap: lt.busy
            ? null
            : () {
                HapticService.light();
                setState(() {
                  _joinOpen = !_joinOpen;
                  _error = null;
                  if (!_joinOpen) {
                    _codeCtrl.clear();
                    FocusScope.of(context).unfocus();
                  }
                });
              },
      ),
      // Expands in place; tapping the row above again closes it.
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _joinOpen
            ? Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _codeField(themeColor),
                    const SizedBox(height: 10),
                    _joinButton(lt, themeColor),
                  ],
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
    ];
  }

  Widget _codeField(Color themeColor) {
    return TextField(
      controller: _codeCtrl,
      autofocus: true,
      textAlign: TextAlign.center,
      textCapitalization: TextCapitalization.characters,
      // onSubmitted joins, so label the key for it.
      textInputAction: TextInputAction.go,
      maxLength: _codeLength,
      style: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: 8),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
        UpperCaseTextFormatter(),
      ],
      cursorColor: themeColor,
      decoration: InputDecoration(
        counterText: '',
        // A specimen code shows the length and that letters are allowed.
        hintText: 'ABC123',
        // Not dimmed to placeholder grey: the hint carries real information, so it needs
        // normal contrast.
        hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.55), letterSpacing: 8),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.09)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: themeColor, width: 1.4),
        ),
      ),
      onSubmitted: (_) {
        if (_codeCtrl.text.length == _codeLength) _join();
      },
    );
  }

  /// Inert until the code is complete.
  ///
  /// Not hidden: a field with no visible commit reads as unfinished, and the
  /// difference between "not yet" and "not here" is what tells someone they
  /// have more to type. It fills with the accent the moment the last character
  /// lands, which is the only announcement it needs.
  Widget _joinButton(ListenTogetherState lt, Color themeColor) {
    final ready = _codeCtrl.text.length == _codeLength && !lt.busy;
    return Semantics(
      button: true,
      enabled: ready,
      label: 'Join session',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: ready ? _join : null,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 46,
            width: double.infinity,
            decoration: BoxDecoration(
              color: ready
                  ? themeColor.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: ready
                    ? themeColor.withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.07),
              ),
            ),
            child: Center(
              child: lt.busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: themeColor))
                  : Text(
                      ready
                          ? 'Join session'
                          : 'Enter all $_codeLength characters',
                      style: TextStyle(
                        color: ready
                            ? themeColor
                            : Colors.white.withValues(alpha: 0.38),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // Live session.

  List<Widget> _liveBody(ListenTogetherState lt, Color themeColor) {
    final isHost = lt.role == LtRole.host;
    return [
      // The code is the reason a host has this sheet open, so it is the
      // largest thing on the card. A guest already joined with it — for them
      // it is reference, and it sits at row weight.
      if (isHost)
        _codeHero(lt, themeColor)
      else
        _row(
          icon: Icons.tag_rounded,
          label: lt.code ?? '',
          subtitle: 'Session code · tap to copy and pass it on',
          themeColor: themeColor,
          onTap: () => _copyCode(lt.code, themeColor),
        ),
      const SizedBox(height: 6),
      Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
      if (isHost)
        _row(
          icon: Icons.ios_share_rounded,
          label: 'Invite',
          subtitle: 'Send the code however you like',
          themeColor: themeColor,
          onTap: () {
            HapticService.light();
            // The rect is what makes this work on iPad at all — see shareOriginOf.
            Share.share(
                'Listen with me on Auvy. Open Listen Together, enter code '
                '${lt.code}, and we will hear the same moment together.',
                sharePositionOrigin: shareOriginOf(context));
          },
        ),
      if (!isHost)
        _row(
          icon: Icons.headphones_rounded,
          label: 'The host controls playback',
          subtitle: 'Your track, position and pauses follow theirs',
          themeColor: themeColor,
          onTap: null,
        ),
      Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
      const SizedBox(height: 12),
      Text('IN THE SESSION (${lt.members.length})',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.50),
              fontSize: 10.5,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      ...lt.members.map((m) => _memberRow(m, themeColor)),
      if (lt.members.length <= 1)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text('Waiting for friends to join…',
              style: TextStyle(
                  // Quiet, but still the answer to "is this working?" — so it
                  // is held at reading contrast rather than dimmed to a hint.
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5,
                  fontStyle: FontStyle.italic)),
        ),
      const SizedBox(height: 10),
      Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
      // Ending the session is a destructive row at the bottom (as in the sleep timer),
      // not an easy-to-hit word in the corner.
      _row(
        icon: Icons.logout_rounded,
        label: isHost ? 'End session' : 'Leave session',
        subtitle: isHost
            ? 'Everyone stops listening together'
            : 'Go back to your own queue',
        themeColor: themeColor,
        destructive: true,
        onTap: () {
          HapticService.medium();
          ref.read(listenTogetherProvider.notifier).leaveSession();
        },
      ),
    ];
  }

  Widget _codeHero(ListenTogetherState lt, Color themeColor) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copyCode(lt.code, themeColor),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: themeColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: themeColor.withValues(alpha: 0.22)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // FittedBox because the code is fixed-width and phones are not:
              // six characters at 36pt with 12 of letter-spacing is wider than
              // a narrow handset, and the overflow would land on the one
              // element that has to stay readable.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(lt.code ?? '',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 12)),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.copy_rounded,
                      size: 12, color: Colors.white.withValues(alpha: 0.50)),
                  const SizedBox(width: 5),
                  Text('Tap to copy',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.50),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _memberRow(LtMember m, Color themeColor) {
    final initial = m.name.isNotEmpty ? m.name[0].toUpperCase() : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  themeColor.withValues(alpha: 0.85),
                  themeColor.withValues(alpha: 0.45)
                ],
              ),
            ),
            child: Text(initial,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          if (m.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: themeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: themeColor.withValues(alpha: 0.4)),
              ),
              child: Text('HOST',
                  style: TextStyle(
                      color: themeColor,
                      fontSize: 9.5,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
            ),
        ],
      ),
    );
  }

  // Small pieces.

  /// The sleep timer's row, to the same metrics: icon, label, one line of what
  /// happens, optional trailing. Shared shape rather than shared code because
  /// the two sheets are separate widgets — if a third needs it, it moves out.
  Widget _row({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color themeColor,
    required VoidCallback? onTap,
    bool selected = false,
    bool destructive = false,
    bool busy = false,
    Widget? trailing,
  }) {
    final tint = destructive
        ? const Color(0xFFE57373)
        : (selected ? themeColor : Colors.white);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          // A row with no action is a statement, not a control, and reads as
          // one. It is the guest's "the host controls playback" line.
          opacity: onTap == null && !busy ? 0.75 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
            child: Row(
              children: [
                Icon(icon,
                    size: 19,
                    color: destructive
                        ? tint.withValues(alpha: 0.85)
                        : (selected
                            ? themeColor
                            : Colors.white.withValues(alpha: 0.75))),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: tint,
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600)),
                      const SizedBox(height: 1),
                      Text(subtitle,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.50),
                              fontSize: 11.5,
                              height: 1.3)),
                    ],
                  ),
                ),
                if (busy)
                  SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: themeColor),
                  )
                else
                  ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabber() => Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2)),
      );

  Widget _liveDot(Color themeColor) {
    // Compositor-only pulse (see _LiveSessionDot in player_page.dart): fading
    // a static dot repaints nothing, while animating shadow geometry repainted
    // the sheet and everything under it every frame.
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut))
            .animate(_pulse),
        child: Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: themeColor,
            boxShadow: [
              BoxShadow(
                  color: themeColor.withValues(alpha: 0.55),
                  blurRadius: 8,
                  spreadRadius: 1.2),
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
