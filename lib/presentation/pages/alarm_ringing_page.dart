import 'dart:async';
// ImageFilter — the blurred cover-art background option.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/alarm_service.dart';
import 'package:auvy/services/haptic_service.dart';

/// What the user chose on the ringing screen.
enum AlarmAction { stop, snooze }

/// The alarm screen
///
/// Appears OVER THE LOCKSCREEN the moment the alarm fires, without the phone
/// being touched (MainActivity.showOverLockscreen turns the display on and lets
/// this draw above the keyguard). You hear music, you look at the phone, the two
/// choices are already there.
///
/// Designed around one assumption: whoever is looking at this is barely awake.
/// So —
///
///  • ONE primary action, full width, at the bottom where a thumb already rests.
///    No pair of equal buttons to choose between and mis-tap.
///  • Snooze sits above it and reads as secondary, because stopping is what most
///    mornings need and snoozing is the deliberate exception.
///  • Type is huge, targets are tall, and nothing is a small icon.
///  • The route refuses a back-gesture pop — swiping back would leave the alarm
///    ringing with its screen gone, which is how someone ends up force-quitting
///    an app instead of turning off an alarm.
///
/// STOP MEANS STOP. It ends the alarm audio and does not hand the track to the
/// player: an alarm that silently turns into a listening session is an alarm that
/// keeps playing while you are in the shower.
class AlarmRingingPage extends StatefulWidget {
  const AlarmRingingPage({
    super.key,
    required this.song,
    required this.accent,
  });

  final Song? song;
  final Color accent;

  @override
  State<AlarmRingingPage> createState() => _AlarmRingingPageState();
}

class _AlarmRingingPageState extends State<AlarmRingingPage>
    with SingleTickerProviderStateMixin {
  Timer? _clock;
  late DateTime _now;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    // A live clock: an alarm screen frozen at the minute it opened makes you
    // doubt the phone is even awake.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    // A slow breath behind the artwork. Slow on purpose — this is the one screen
    // in the app that must not feel urgent or busy.
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    // Only run the ticker when the pulse is actually wanted. Repeating it and
    // ignoring the value would still schedule a frame every 16ms all night.
    if (AlarmService.pulse) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String get _timeLabel =>
      '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';

  String get _dateLabel {
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${days[_now.weekday - 1]} · ${_now.day} ${months[_now.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final accent = widget.accent;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF080808),
        body: Stack(
          children: [
            // Background, user's choice
            //
            // 'art' paints the cover blurred behind everything, 'accent' bleeds
            // the theme colour up from behind the artwork, 'plain' paints nothing.
            // See AlarmService.background for why this is a setting.
            //
            // The blur is ImageFiltered on a STATIC image, deliberately not a
            // BackdropFilter: a backdrop filter recomposites everything beneath it
            // every frame, and with the artwork breathing on top that is a blur
            // recomputed 60 times a second on the one screen that must not stutter.
            if (song != null && AlarmService.background == 'art')
              Positioned.fill(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
                  child: AuvyImage(
                    path: song.image,
                    fit: BoxFit.cover,
                    // Decoded small on purpose — the blur destroys the detail a
                    // full-resolution decode would pay for.
                    decodeWidth: 320,
                  ),
                ),
              ),
            // Scrim over the art so white text stays legible on a pale cover.
            if (song != null && AlarmService.background == 'art')
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.55),
                        Colors.black.withOpacity(0.75),
                      ],
                    ),
                  ),
                ),
              ),
            if (AlarmService.background == 'accent')
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, 0.15),
                      radius: 1.1,
                      colors: [
                        accent.withOpacity(0.20),
                        accent.withOpacity(0.06),
                        const Color(0xFF080808),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Column(
                children: [
                  const Spacer(flex: 3),

                  // Time
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.alarm_rounded, color: accent, size: 18),
                      const SizedBox(width: 8),
                      Text('ALARM',
                          style: TextStyle(
                              color: accent,
                              fontSize: 12,
                              letterSpacing: 3,
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _timeLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 84,
                      height: 0.95,
                      fontWeight: FontWeight.w100,
                      letterSpacing: -3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_dateLabel,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3)),

                  const Spacer(flex: 2),

                  // What is playing
                  if (song != null)
                    Column(children: [
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, child) => Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withOpacity(
                                    0.18 + 0.14 * _pulse.value),
                                blurRadius: 40 + 20 * _pulse.value,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: child,
                        ),
                        child: AuvyImage(
                          path: song.image,
                          width: 150,
                          height: 150,
                          borderRadius: 22,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        song.title,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            height: 1.25,
                            fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 14.5),
                      ),
                    ])
                  else
                    // The fallback tone is playing. Said plainly, because the
                    // difference matters: it means the download had not landed.
                    Column(children: [
                      Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withOpacity(0.14),
                        ),
                        child: Icon(Icons.notifications_active_rounded,
                            color: accent, size: 48),
                      ),
                      const SizedBox(height: 20),
                      const Text('Time to wake up',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text('Your music was not ready — this is the\n'
                          'default alarm sound',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.66),
                              fontSize: 13,
                              height: 1.4)),
                    ]),

                  const Spacer(flex: 3),

                  // SNOOZE (secondary)
                  _SnoozeButton(
                    accent: accent,
                    onTap: () {
                      HapticService.light();
                      Navigator.of(context).pop(AlarmAction.snooze);
                    },
                  ),
                  const SizedBox(height: 14),

                  // STOP (primary, thumb-height)
                  _StopButton(
                    accent: accent,
                    onTap: () {
                      HapticService.medium();
                      Navigator.of(context).pop(AlarmAction.stop);
                    },
                  ),
                  const SizedBox(height: 26),
                ],
              ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.accent, required this.onTap});

  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: accent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          // 64px tall: the target has to be findable without aiming.
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 21),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.stop_rounded, color: Colors.black, size: 24),
                SizedBox(width: 10),
                Text('Stop alarm',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SnoozeButton extends StatelessWidget {
  const _SnoozeButton({required this.accent, required this.onTap});

  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.snooze_rounded,
                    color: Colors.white.withOpacity(0.85), size: 21),
                const SizedBox(width: 10),
                // The CONFIGURED length, not a hardcoded "9 minutes". The snooze
                // duration has been a setting for a while and this label went on
                // claiming nine regardless, so a user who set 15 was told the
                // wrong number by the one button that states it.
                Text('Snooze ${AlarmService.snoozeMinutes} minutes',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
