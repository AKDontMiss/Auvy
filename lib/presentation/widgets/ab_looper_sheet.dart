import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/duration_ext.dart';
import '../../providers/player_provider.dart';
import '../../services/haptic_service.dart';
import 'animated_toast.dart';
import 'package:auvy/core/app_colors.dart';

/// Interactive modal sheet to configure and control A-B section repeat looping.
/// This tool enables musicians, dancers, language learners, or any music lover
/// to continuously loop any segment of a track with millisecond accuracy.
void showABLooperSheet(
    BuildContext context, WidgetRef ref, Color themeColor) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _ABLooperSheetContent(themeColor: themeColor),
  );
}

class _ABLooperSheetContent extends ConsumerWidget {
  final Color themeColor;

  const _ABLooperSheetContent({required this.themeColor});

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select only the fields this sheet reads: position updates about once a second,
    // and watching the whole state would rebuild the sheet each time. A record
    // compares by value, so it rebuilds only when one of these changes (currentSong
    // compares by identity, which copyWith preserves).
    final s = ref.watch(playerProvider.select((p) => (
          p.currentSong,
          p.loopStart,
          p.loopEnd,
          p.isLoopActive,
          p.duration,
        )));
    final notifier = ref.read(playerProvider.notifier);
    final song = s.$1;
    final loopStart = s.$2;
    final loopEnd = s.$3;
    final isLoopActive = s.$4;
    final songDuration = s.$5;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.modalPanel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Icon(Icons.repeat_on_rounded, color: themeColor, size: 24),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A-B Section Looper',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Loop a solo, chorus, or beat seamlessly',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (isLoopActive)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: themeColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: themeColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    'ACTIVE',
                    style: TextStyle(
                      color: themeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Current song & live position pill
          if (song != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.music_note_rounded,
                      color: Colors.white60, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${song.title} • ${song.artist}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<Duration>(
                    valueListenable: currentPositionProvider,
                    builder: (context, pos, _) {
                      return Text(
                        '${pos.toMmSs()} / ${songDuration.toMmSs()}',
                        style: TextStyle(
                          color: themeColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),

          // Point A & Point B row
          Row(
            children: [
              // Point A Card
              Expanded(
                child: _PointCard(
                  label: 'Point A (Start)',
                  time: _formatDuration(loopStart),
                  isSet: loopStart != null,
                  themeColor: themeColor,
                  onSetCurrent: () {
                    HapticService.selection();
                    final cur = currentPositionProvider.value;
                    notifier.setLoopStart(cur);
                  },
                  onNudgeMinus: loopStart != null && loopStart > Duration.zero
                      ? () {
                          HapticService.light();
                          final newStart = loopStart - const Duration(seconds: 1);
                          notifier.setLoopStart(
                              newStart < Duration.zero ? Duration.zero : newStart);
                        }
                      : null,
                  onNudgePlus: loopStart != null
                      ? () {
                          HapticService.light();
                          notifier.setLoopStart(
                              loopStart + const Duration(seconds: 1));
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 12),

              // Point B Card
              Expanded(
                child: _PointCard(
                  label: 'Point B (End)',
                  time: _formatDuration(loopEnd),
                  isSet: loopEnd != null,
                  themeColor: themeColor,
                  onSetCurrent: () {
                    HapticService.selection();
                    final cur = currentPositionProvider.value;
                    if (loopStart != null && cur <= loopStart) {
                      AnimatedToast.message('Point B must be after Point A');
                      return;
                    }
                    notifier.setLoopEnd(cur);
                  },
                  onNudgeMinus: loopEnd != null
                      ? () {
                          HapticService.light();
                          final newEnd = loopEnd - const Duration(seconds: 1);
                          if (loopStart != null && newEnd <= loopStart) return;
                          notifier.setLoopEnd(newEnd);
                        }
                      : null,
                  onNudgePlus: loopEnd != null &&
                          (songDuration == Duration.zero || loopEnd < songDuration)
                      ? () {
                          HapticService.light();
                          notifier.setLoopEnd(
                              loopEnd + const Duration(seconds: 1));
                        }
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Actions Row: Jump to A, Clear Loop
          Row(
            children: [
              if (loopStart != null)
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.18)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      HapticService.selection();
                      notifier.seek(loopStart);
                    },
                    icon: const Icon(Icons.skip_previous_rounded, size: 18),
                    label: const Text('Jump to A',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ),
              if (loopStart != null) const SizedBox(width: 10),
              if (loopStart != null || loopEnd != null)
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                      foregroundColor: Colors.redAccent,
                      elevation: 0,
                      side: BorderSide(
                          color: Colors.redAccent.withValues(alpha: 0.3)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      HapticService.selection();
                      notifier.clearLoopRegion();
                      AnimatedToast.message('Loop cleared');
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Clear Loop',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PointCard extends StatelessWidget {
  final String label;
  final String time;
  final bool isSet;
  final Color themeColor;
  final VoidCallback onSetCurrent;
  final VoidCallback? onNudgeMinus;
  final VoidCallback? onNudgePlus;

  const _PointCard({
    required this.label,
    required this.time,
    required this.isSet,
    required this.themeColor,
    required this.onSetCurrent,
    this.onNudgeMinus,
    this.onNudgePlus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isSet ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isSet
              ? themeColor.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.08),
          width: 1.2,
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: isSet ? themeColor : Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            time,
            style: TextStyle(
              color: isSet ? Colors.white : Colors.white38,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isSet
                    ? themeColor
                    : Colors.white.withValues(alpha: 0.1),
                foregroundColor: isSet ? Colors.black : Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: onSetCurrent,
              child: const Text('Set at Current',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ),
          if (isSet) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _NudgeButton(label: '-1s', onTap: onNudgeMinus),
                const SizedBox(width: 8),
                _NudgeButton(label: '+1s', onTap: onNudgePlus),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NudgeButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _NudgeButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: enabled ? 0.08 : 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.white70 : Colors.white24,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
