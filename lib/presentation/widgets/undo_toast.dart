import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// Floating "Undo" pill shown above the mini-player after a destructive swipe
/// (native Android toasts can't host buttons). One toast at a time: showing a
/// new one FINALIZES the previous first — its onExpire runs immediately — so
/// deferred deletions (e.g. disk cleanup) can never be skipped.
class UndoToast {
  UndoToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;
  static VoidCallback? _pendingExpire;
  static GlobalKey<_UndoPillState>? _pillKey;

  /// [onExpire] runs when the window closes WITHOUT an undo — put the
  /// irreversible part of the delete (file wipes) there, never before show().
  /// [icon] is the leading glyph (defaults to a delete icon — pass e.g.
  /// Icons.playlist_remove_rounded to match the action).
  static void show(
    BuildContext context, {
    required String text,
    required VoidCallback onUndo,
    VoidCallback? onExpire,
    IconData icon = Icons.delete_outline_rounded,
    Duration duration = const Duration(seconds: 4),
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    
    // Instantly commit any existing toast before showing the new one
    _finalizeExisting();

    // Same geometry mirror as QueueFlyOverlay: nav bar 70 + inset, then the
    // 64px mini-player bar + its 10px gap when a song is loaded.
    final player = container.read(playerProvider);
    final media = MediaQuery.of(overlay.context);
    final bool barVisible =
        player.currentSong != null && player.miniPlayerVisible;
    final double bottom =
        70.0 + media.padding.bottom + 10.0 + (barVisible ? 74.0 : 0.0) + 16.0;

    _pendingExpire = onExpire;
    _pillKey = GlobalKey<_UndoPillState>();
    
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _UndoPill(
        key: _pillKey,
        text: text,
        icon: icon,
        duration: duration,
        bottom: bottom,
        accent: container.read(themeProvider),
        onUndo: () {
          if (_entry != entry) return;
          _timer?.cancel();
          _pendingExpire = null;
          HapticService.light();
          onUndo();
          _dismiss();
        },
      ),
    );
    
    _entry = entry;
    overlay.insert(entry);
    
    _timer = Timer(duration, () {
      if (_entry != entry) return;
      final expire = _pendingExpire;
      _pendingExpire = null;
      expire?.call();
      _dismiss();
    });
  }

  static void _finalizeExisting() {
    _timer?.cancel();
    _timer = null;
    
    final expire = _pendingExpire;
    _pendingExpire = null;
    expire?.call();
    
    if (_entry?.mounted == true) {
      _entry?.remove();
    }
    _entry = null;
    _pillKey = null;
  }

  static void _dismiss() {
    final entryToRemove = _entry;
    final keyToRemove = _pillKey;
    
    if (entryToRemove != null && keyToRemove?.currentState != null) {
      keyToRemove!.currentState!.reverse().then((_) {
        // Double-check it hasn't been overwritten by a brand new toast while animating out
        if (entryToRemove.mounted) {
          entryToRemove.remove();
        }
        if (_entry == entryToRemove) {
          _entry = null;
          _pillKey = null;
        }
      });
    } else {
      if (entryToRemove?.mounted == true) {
        entryToRemove?.remove();
      }
      if (_entry == entryToRemove) {
        _entry = null;
        _pillKey = null;
      }
    }
  }
}

class _UndoPill extends StatefulWidget {
  final String text;
  final IconData icon;
  final Duration duration;
  final double bottom;
  final Color accent;
  final VoidCallback onUndo;

  const _UndoPill({
    super.key,
    required this.text,
    required this.icon,
    required this.duration,
    required this.bottom,
    required this.accent,
    required this.onUndo,
  });

  @override
  State<_UndoPill> createState() => _UndoPillState();
}

class _UndoPillState extends State<_UndoPill> with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _slide;
  late final Animation<double> _scale;
  // Drains from full → empty over the undo window, so the pill itself shows
  // when the delete will commit.
  late final AnimationController _drain;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    _controller.forward();
    _drain = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _drain.dispose();
    super.dispose();
  }

  Future<void> reverse() async {
    if (mounted) {
      await _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.bottom,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Opacity(
            opacity: _fade.value.clamp(0.0, 1.0),
            child: Transform.translate(
              // Slides smoothly up from slightly below, and back down on dismiss.
              offset: Offset(0, 18 * (1 - _slide.value)),
              child: Transform.scale(
                scale: 0.94 + 0.06 * _scale.value,
                child: child,
              ),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width - 48),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF17171B).withOpacity(0.98),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: Colors.white.withOpacity(0.09)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.55),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: widget.accent.withOpacity(0.10),
                      blurRadius: 32,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 12, right: 8, top: 7, bottom: 5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Leading action glyph in a soft accent chip.
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: widget.accent.withOpacity(0.14),
                              shape: BoxShape.circle,
                            ),
                            child:
                                Icon(widget.icon, color: widget.accent, size: 17),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.95),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),

                          // This explicitly mirrors the attractive "Undo" pill
                          // from QueueSheet.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onUndo,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: widget.accent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.undo_rounded,
                                      color: widget.accent, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Undo',
                                    style: TextStyle(
                                      color: widget.accent,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Countdown drain: how long until the action commits.
                    AnimatedBuilder(
                      animation: _drain,
                      builder: (_, __) => Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: (1 - _drain.value).clamp(0.0, 1.0),
                          child: Container(
                            height: 2.5,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [
                                widget.accent.withOpacity(0.9),
                                widget.accent.withOpacity(0.45),
                              ]),
                            ),
                          ),
                        ),
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