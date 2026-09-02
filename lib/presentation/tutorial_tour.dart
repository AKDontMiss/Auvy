import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:auvy/services/cloud_sync_service.dart';

/// The walkthrough itself: WHAT it points at and WHAT it says.
///
/// Split from the [CoachTour] engine on purpose — the engine knows how to dim a
/// screen and draw an arrow, this file knows what Auvy is. Editing the tour means
/// editing this list and nothing else.
///
/// Why this replaced the old tutorial
///
/// The previous one was 1,865 lines of MOCK UI: a fake nav bar, fake tiles, a
/// fake mini-player, all rebuilt inside the tutorial and stepped through with
/// Next. It looked fine and taught the wrong thing. Practising a long-press on a
/// replica tile doesn't tell you where the real one is, and every layout change
/// silently invalidated the lesson without anything failing.
///
/// This points at the real controls in the running app. If a control moves, the
/// spotlight moves with it, because its position is read from the widget itself.
/// The tour deliberately does NOT explain Home, Search and Library.
///
/// Every music app has those three, in that order, at the bottom — a walkthrough
/// that spends three of its seven steps naming them is teaching what the user
/// already knows and burning the attention it needs for what they don't. What is
/// actually undiscoverable is the gesture layer: double-tap to nudge, press-and-
/// hold to change speed, swipe for lyrics, and what "LIVE" means once you pause
/// a radio stream. Those get the steps.
///
/// [openPlayer] is supplied by the caller because opening the full player is a
/// navigation concern, and the steps that describe its controls cannot run until
/// those controls are on screen. If nothing is playing, the player can't open, its
/// anchors never mount, and the engine skips those steps automatically.
List<CoachStep> auvyTourSteps({Future<void> Function()? openPlayer}) => [
      const CoachStep(
        title: 'Welcome to Auvy',
        body:
            "A minute on the parts you would otherwise have to find by accident. "
            "This is the real app, not a picture of it, so everything highlighted "
            "is exactly where it will be later. Skip whenever you like.",
      ),
      const CoachStep(
        targetId: 'miniplayer',
        title: 'The mini player',
        body:
            "Tap to open the full player. Swipe it sideways to change track and "
            "down to dismiss it — it follows you across every tab.",
      ),
      CoachStep(
        targetId: 'player.next',
        onEnter: openPlayer,
        settle: const Duration(milliseconds: 420),
        circular: true,
        title: 'Nudge forward, or speed up',
        body:
            "One tap is the next track — but DOUBLE-tap jumps 5 seconds forward "
            "instead, and press and HOLD plays at 2× for as long as you hold it. "
            "Useful for getting past an intro without losing your place.",
      ),
      const CoachStep(
        targetId: 'player.prev',
        circular: true,
        title: 'The same, backwards',
        body:
            "Tap for the previous track, double-tap to jump back 5 seconds, and "
            "hold to drop to half speed — for catching a lyric or a fast line.",
      ),
      const CoachStep(
        targetId: 'player.lyrics',
        title: 'Swipe across for lyrics',
        body:
            "Swipe sideways anywhere on the artwork to flip to time-synced "
            "lyrics, and back again. Tap a line to jump to it. Lyrics can be "
            "translated, romanised, and shared as a card.",
      ),
      const CoachStep(
        title: 'Podcasts remember you',
        body:
            "Episodes resume to the second, even after you play something else. "
            "Each show has a page with the episode notes and exactly how much of "
            "each episode is left — and where a show timestamps its own sponsor "
            "breaks, Auvy marks them on the progress bar and skips them for you.",
      ),
      const CoachStep(
        title: 'Radio tells you the truth',
        body:
            "Pause a live station and it says PAUSED, then counts how far behind "
            "the broadcast you are — not a permanent \"LIVE\" badge. Tap GO LIVE "
            "to rejoin the live edge whenever you want.",
      ),
      const CoachStep(
        title: 'Hold anything',
        body:
            "Press and hold almost any track, album or artist for its full menu. "
            "And Appearance holds the accent colour, ten progress-bar styles, "
            "artwork shape, cover roundness and list density.",
      ),
      const CoachStep(
        title: "That's the tour",
        body:
            "Replay it any time from Settings. Everything else is yours to "
            "poke at.",
      ),
    ];

/// Mark the tutorial seen, and push that to the cloud.
///
/// Nothing else after this triggers a backup, so without the explicit schedule a
/// reinstall would replay the tour.
Future<void> markTutorialSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('has_seen_tutorial', true);
  CloudSyncService.instance.scheduleBackup();
}

/// Run the tour over the live app.
///
/// [onTab] lets the tour move between tabs; MainLayout supplies it, because the
/// selected tab is its state to change.
Future<void> startAuvyTour(
  BuildContext context, {
  required Color accent,
  void Function(int index)? onTab,
  Future<void> Function()? openPlayer,
}) async {
  await markTutorialSeen();
  if (!context.mounted) return;
  await CoachTour.run(
    context,
    steps: auvyTourSteps(openPlayer: openPlayer),
    accent: accent,
    onTab: onTab,
  );
}
