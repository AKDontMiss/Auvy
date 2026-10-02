import 'package:flutter/material.dart';

import 'package:auvy/presentation/widgets/coach_marks.dart';

/// The walkthrough content: what each step points at and what it says. Separate
/// from the [CoachTour] engine (which dims the screen and draws arrows), so editing
/// the tour means editing this list.
///
/// It points at the real controls in the running app, so if a control moves, the
/// spotlight follows.
///
/// Steps that teach a gesture set `requireAction`: the spotlight passes real
/// touches through and Next stays locked until the control has been touched, with
/// "Skip this step" always available. Steps that explain a concept (how podcasts
/// resume, what LIVE means on a paused station) stay plain.
///
/// Home, Search and Library aren't explained; every music app has them. The steps
/// go to what's hard to discover: double-tap to nudge, press-and-hold for speed,
/// swipe for lyrics, and LIVE on a paused stream.
///
/// [openPlayer] comes from the caller, since opening the full player is a
/// navigation concern.
///
/// Each step declares the screen it needs: `onEnter` runs whenever a step is
/// applied, forward or backward, so pre-player steps call `closePlayer` and player
/// steps open it. That's what makes Back work.
///
/// Player steps need a track. When nothing is playing they're left out of the list
/// entirely (see [auvyTourSteps]), so the step count is honest and no time is spent
/// on steps that can't run.
List<CoachStep> auvyPlayerTourSteps({
  Future<void> Function()? openPlayer,
  Future<void> Function()? closePlayer,
}) =>
    [
      CoachStep(
        targetId: 'miniplayer',
        // Reached backwards from the player steps, this must close the player itself so
        // it doesn't point at a mini-player hidden behind it.
        onEnter: closePlayer,
        settle: const Duration(milliseconds: 320),
        requireAction: true,
        actionHint: 'Swipe it sideways — the track changes under your finger',
        title: 'The mini player',
        body:
            "Tap it to open the full player.\n"
            "Swipe sideways to change track.\n"
            "Swipe down to dismiss it.",
      ),
      CoachStep(
        targetId: 'player.next',
        onEnter: openPlayer,
        settle: const Duration(milliseconds: 420),
        circular: true,
        requireAction: true,
        actionHint: 'Double-tap it — you should jump 5 seconds, not skip',
        title: 'The next button does three things',
        body:
            "Tap — next track.\n"
            "Double-tap — forward 5 seconds.\n"
            "Hold — 2× speed while you hold it.",
      ),
      const CoachStep(
        targetId: 'player.prev',
        circular: true,
        requireAction: true,
        actionHint: 'Hold it down — everything drops to half speed',
        title: 'And backwards',
        body:
            "Tap — previous track.\n"
            "Double-tap — back 5 seconds.\n"
            "Hold — half speed, for catching a fast line.",
      ),
      const CoachStep(
        // The artwork, not the hint badge in the top bar — this step asks for
        // the swipe, so the hole has to be over the thing that handles it. See
        // the note on the anchor in player_page.
        targetId: 'player.artwork',
        requireAction: true,
        // The direction is part of the instruction: the flip responds to one direction
        // per face (see _handleFlip). The step unlocks on any touch inside the spotlight,
        // and "Skip this step" is always there.
        actionHint: 'Swipe the artwork from right to left',
        title: 'Lyrics',
        body:
            "Swipe the artwork right to left for synced lyrics, and back the "
            "other way.\n"
            "Tap any line to jump straight to it.",
      ),
    ];

/// Everything that needs nothing playing. [playerSteps] is how many of the
/// player lessons are running in the same pass, so the opening card can state a
/// number that matches what the user is about to get.
List<CoachStep> auvyBasicsTourSteps({
  Future<void> Function()? closePlayer,
  int playerSteps = 0,
}) =>
    [
      CoachStep(
        onEnter: closePlayer,
        title: 'Welcome to Auvy',
        body: playerSteps > 0
            ? "${_count(5 + playerSteps)} quick steps on the gestures you'd "
                "otherwise never find. This is the real app — when a step asks "
                "you to try something, do it and it happens for real."
            : "${_count(5)} quick steps to get you started. The gestures inside "
                "the player need something playing, so those come up on their "
                "own the first time you open it.",
      ),
      CoachStep(
        onEnter: closePlayer,
        title: 'Podcasts',
        body:
            "Episodes resume to the second, even after other music.\n"
            "Sponsor breaks are skipped where the show marks them.",
      ),
      CoachStep(
        onEnter: closePlayer,
        title: 'Live radio',
        body:
            "Pause a station and Auvy tells you how far behind you are.\n"
            "Tap GO LIVE to catch back up.",
      ),
      CoachStep(
        onEnter: closePlayer,
        title: 'Hold anything',
        body:
            "Press and hold any track, album or artist for its full menu.\n"
            "Settings → Appearance changes the accent colour and more.",
      ),
      CoachStep(
        onEnter: closePlayer,
        title: "That's the tour",
        body:
            "Replay it any time from Settings.",
      ),
    ];

/// Small numbers read as words in a sentence; anything larger is a digit.
/// The opening card is prose, and "5 quick steps" in the middle of it reads
/// like a spec line.
String _count(int n) =>
    const {4: 'Four', 5: 'Five', 8: 'Eight', 9: 'Nine'}[n] ?? '$n';

/// The whole tour, in order, with the player lessons in their original place.
///
/// [includePlayerSteps] is the caller's answer to "can the player actually open
/// right now?" — it is not something this file can know.
List<CoachStep> auvyTourSteps({
  Future<void> Function()? openPlayer,
  Future<void> Function()? closePlayer,
  bool includePlayerSteps = true,
}) {
  final player = includePlayerSteps
      ? auvyPlayerTourSteps(openPlayer: openPlayer, closePlayer: closePlayer)
      : const <CoachStep>[];
  final basics = auvyBasicsTourSteps(
      closePlayer: closePlayer, playerSteps: player.length);
  // The welcome card first, then the player lessons, then the rest — the order
  // the tour has always had.
  return [basics.first, ...player, ...basics.skip(1)];
}

// The tour runs only when started from Settings; [auvyTourSteps] leaves out the
// player lessons when nothing is playing.

// `markTutorialSeen` is gone with it. It wrote `has_seen_tutorial`, whose only
// job was to stop the tour running itself a second time. Nothing runs it by
// itself any more, so the flag gated nothing and was one more piece of state to
// keep in step across a restore and an account switch.

/// Runs the tour over the live app. [onTab] lets the tour switch tabs (MainLayout
/// supplies it, since the selected tab is its state). [canOpenPlayer] says whether
/// something is playing; when false the player lessons are left out, and the user
/// can start something playing and run the tour again.
Future<void> startAuvyTour(
  BuildContext context, {
  required Color accent,
  void Function(int index)? onTab,
  Future<void> Function()? openPlayer,
  Future<void> Function()? closePlayer,
  bool canOpenPlayer = true,
}) async {
  if (!context.mounted) return;
  await CoachTour.run(
    context,
    steps: auvyTourSteps(
        openPlayer: openPlayer,
        closePlayer: closePlayer,
        includePlayerSteps: canOpenPlayer),
    accent: accent,
    onTab: onTab,
  );
}
