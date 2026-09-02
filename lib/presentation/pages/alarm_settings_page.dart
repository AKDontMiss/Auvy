import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/alarm_settings_block.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/services/alarm_service.dart';

/// Wake up to music, as a page
///
/// A page rather than a bottom sheet, matching Hidden Songs and Recognised Songs
/// — the two tools it now sits beside in the Library panel. Two reasons beyond
/// consistency:
///
///  • The MINI-PLAYER floats in MainLayout's Stack, above the per-tab Navigator.
///    A sheet opened from a tab renders underneath it and its lower rows become
///    unreachable. A page pushed on the tab navigator scrolls its own content and
///    has no such problem.
///  • This is a settings screen with a picker, a slider, a time wheel and two
///    permission warnings. That is a destination, not a glance.
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
                        color: Colors.white38, fontSize: 12.5, height: 1.45),
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
