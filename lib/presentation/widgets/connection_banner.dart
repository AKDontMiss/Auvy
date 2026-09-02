import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/providers/theme_provider.dart';

/// A transient banner announcing that the connection dropped, and that it came
/// back.
///
/// It shows the transition, NOT the state.
///
/// A permanent "offline" bar is the obvious build and the wrong one: it steals a
/// strip of every screen for as long as the condition lasts, and the app is
/// deliberately usable offline (downloads, cache, the whole library), so it would
/// be scolding the user about something that mostly does not matter. What they
/// actually need is the MOMENT it changed — that is when playback stalls and when
/// it can resume.
///
/// So each change shows for a few seconds and leaves. "Reconnected" only appears
/// if a drop was actually announced first, otherwise every commute through a
/// tunnel-shaped Wi-Fi handover would pop a green bar for no reason.
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({super.key});

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  static const _visibleFor = Duration(seconds: 4);

  /// A blip is not an outage. A cell handover or a Wi-Fi roam can report offline
  /// for a fraction of a second, and announcing that is noise — playback would
  /// not even have noticed. Only a drop that persists is worth telling anyone
  /// about.
  static const _offlineSettleTime = Duration(seconds: 2);

  bool _showing = false;
  bool _isOffline = false;
  bool _announcedOffline = false;
  Timer? _hideTimer;
  Timer? _settleTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _settleTimer?.cancel();
    super.dispose();
  }

  void _announce({required bool offline}) {
    _hideTimer?.cancel();
    setState(() {
      _isOffline = offline;
      _showing = true;
    });
    _hideTimer = Timer(_visibleFor, () {
      if (mounted) setState(() => _showing = false);
    });
  }

  void _onConnectivityChanged(bool nowOffline) {
    _settleTimer?.cancel();
    if (nowOffline) {
      // Wait for it to stick. See _offlineSettleTime.
      _settleTimer = Timer(_offlineSettleTime, () {
        if (!mounted) return;
        if (!ref.read(connectivityProvider).isOffline) return;
        _announcedOffline = true;
        _announce(offline: true);
      });
      return;
    }
    // Back online. Only worth saying if the loss was announced.
    if (!_announcedOffline) return;
    _announcedOffline = false;
    _announce(offline: false);
  }

  @override
  Widget build(BuildContext context) {
    // select() so this rebuilds on the connection flag alone — the provider also
    // carries data-saver settings that change for unrelated reasons.
    ref.listen<bool>(
      connectivityProvider.select((s) => s.isOffline),
      (prev, next) {
        if (prev == next) return;
        _onConnectivityChanged(next);
      },
    );

    final themeColor = ref.watch(themeProvider);
    final bg = _isOffline ? const Color(0xFF3A2A1E) : const Color(0xFF13251B);
    final fg = _isOffline ? const Color(0xFFFFB74D) : themeColor;

    // IgnorePointer: purely informational, and it sits over the top of whatever
    // page is beneath — swallowing taps there would be worse than the problem it
    // reports.
    return IgnorePointer(
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: _showing ? Offset.zero : const Offset(0, -1.4),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _showing ? 1 : 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: fg.withValues(alpha: 0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isOffline
                          ? Icons.wifi_off_rounded
                          : Icons.wifi_rounded,
                      color: fg,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _isOffline
                            ? "You're offline — playing from downloads and cache"
                            : 'Back online',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
