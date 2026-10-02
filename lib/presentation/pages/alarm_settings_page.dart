import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/alarm_settings_block.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/services/alarm_service.dart';

/// Wake up to music, as a page (like Hidden Songs and Recognised Songs beside it
/// in the Library panel) rather than a bottom sheet: sheets opened from a tab sit
/// under the floating mini-player, which would cover their lower rows, and this is
/// a full settings screen with a picker, slider, time wheel and permission
/// warnings.
class AlarmSettingsPage extends ConsumerWidget {
  const AlarmSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      const Text('Wake Up',
                          style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                      const Spacer(),
                      if (AlarmService.enabled)
                        Text(AlarmService.timeLabel,
                            style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 14),
                  child: Text(
                    'Start your morning with a song instead of a ringtone. '
                    'Auvy downloads it in advance, so it plays even with no '
                    'connection.',
                    style: TextStyle(
                        color: Colors.white60, fontSize: 12.5, height: 1.45),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: AlarmSettingsBlock()),
              // Clears the mini-player and nav bar so the last row is never
              // pinned under them.
              const SliverToBoxAdapter(child: SizedBox(height: 180)),
            ],
          ),
        ),
      ),
    );
  }
}
