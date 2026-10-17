import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/audio_output_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/device_presence_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';

/// The in-app output picker: attached devices by name, tap to send Auvy's audio
/// to one.
///
/// Only ATTACHED outputs can be listed, so the last row hands over to the system
/// settings rather than showing devices this code cannot reach.
///
/// A car stereo is a Bluetooth or USB output like any other while connected, so
/// it appears here by its own name. Android Auto is separate — the car takes over
/// the screen and browses Auvy's media tree, and needs nothing from this sheet.
///
/// Below them, the account's other phones (see DevicePresenceService): what each
/// is playing, its controls, and moving playback between them.
Future<void> showAudioOutputSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _AudioOutputSheet(),
  );
}

class _AudioOutputSheet extends ConsumerStatefulWidget {
  const _AudioOutputSheet();

  @override
  ConsumerState<_AudioOutputSheet> createState() => _AudioOutputSheetState();
}

class _AudioOutputSheetState extends ConsumerState<_AudioOutputSheet>
    with WidgetsBindingObserver {
  List<AudioOutput>? _devices;
  bool _carMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The device listener runs for exactly as long as this sheet is on screen.
    AudioOutputService.watch(true, onChanged: _load);
    _load();
  }

  @override
  void dispose() {
    AudioOutputService.watch(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Returning from the system dialog — or plugging something in while the sheet
  /// is open — changes the list, so re-read on resume rather than showing a
  /// snapshot that has gone stale.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final list = await AudioOutputService.list();
    final car = await AudioOutputService.isCarMode();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _carMode = car;
    });
  }

  Future<void> _pick(AudioOutput d) async {
    HapticService.selection();

    // Only the pinned device unpins. The system default is selected like any other
    // device, so tapping the phone speaker while a headset is connected selects the
    // speaker. The list holds one row per physical device (deduplicated at the
    // source), so pinning any row is safe.
    final unpin = d.isPreferred;
    final targetId = unpin ? null : d.id;

    // Paint the new selection NOW. The platform call and the re-list that follows
    // take a moment, and tapping between two devices faster than that left the
    // tick on the previous one — the list looked like it was lagging behind.
    setState(() {
      _devices = _devices
          ?.map((o) => o.withPreferred(!unpin && o.id == d.id))
          .toList();
    });

    final ok = await AudioOutputService.select(targetId);
    if (!mounted) return;
    if (!ok) {
      AnimatedToast.message('That device is no longer connected');
    }
    // Reconcile against the platform, so an optimistic guess cannot persist if
    // the switch was refused.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final devices = _devices;
    final pinned = devices?.any((d) => d.isPreferred) ?? false;

    // A dock/bus output is a car outright. In car mode the phone is driving a
    // head unit, so whichever external output is attached IS the car — the
    // built-in speaker never is.
    final carTarget = devices == null
        ? null
        : devices.where((d) => d.isCar).firstOrNull ??
            (_carMode
                ? devices.where((d) => d.kind != 'speaker').firstOrNull
                : null);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Container(
        color: AppColors.modalPanel,
        padding: EdgeInsets.only(
          top: 10,
          bottom: MediaQuery.of(context).padding.bottom + 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.speaker_group_rounded, color: themeColor, size: 20),
                  const SizedBox(width: 10),
                  const Text(
                    'Play audio on',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  pinned
                      ? 'Auvy is pinned to one device. Tap it again to follow the system.'
                      : 'Following the system. Tap a device to send only Auvy there.',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66), fontSize: 12),
                ),
              ),
            ),
            // Offered, not done automatically. Moving audio without being asked
            // is the kind of "helpful" that plays music into a car the user only
            // sat down in, so this states what was found and waits for a tap.
            if (carTarget != null && !carTarget.isPreferred)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: themeColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: themeColor.withOpacity(0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.directions_car_rounded, color: themeColor, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Car audio detected',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(carTarget.displayName,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.72),
                                    fontSize: 11.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _pick(carTarget),
                        style: TextButton.styleFrom(foregroundColor: themeColor),
                        child: const Text('Play here'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (devices == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              // No devices at all means the platform call failed — a phone always
              // has a speaker. Say so rather than showing an empty list.
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text(
                    "Couldn't read the connected devices on this phone.",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 13),
                  ),
                ),
              ...devices.map((d) => _DeviceRow(
                    device: d,
                    themeColor: themeColor,
                    anyPinned: pinned,
                    onTap: () => _pick(d),
                  )),
            ],
            _OtherDevicesSection(themeColor: themeColor),
            Divider(color: Colors.white.withOpacity(0.07), height: 22),
            // On Android the last row opens the system panel, whose contents differ by
            // version and skin, so its wording promises nothing specific. On iOS it raises
            // AVRoutePickerView, the AirPlay/Bluetooth chooser itself, which switches the
            // route directly (see the `open` case in AuvySystemChannels).
            ListTile(
              leading: Icon(
                  Platform.isIOS
                      ? Icons.airplay_rounded
                      : Icons.settings_rounded,
                  color: Colors.white.withOpacity(0.75)),
              title: Text(
                  Platform.isIOS
                      ? 'AirPlay & Bluetooth'
                      : 'System sound settings',
                  style: const TextStyle(color: Colors.white, fontSize: 14.5)),
              trailing: Icon(Icons.open_in_new_rounded,
                  size: 16, color: Colors.white.withOpacity(0.4)),
              onTap: () async {
                HapticService.light();
                await AudioOutputService.openSystemPicker();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final AudioOutput device;
  final Color themeColor;
  final bool anyPinned;
  final VoidCallback onTap;

  const _DeviceRow({
    required this.device,
    required this.themeColor,
    required this.anyPinned,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Highlighted when Auvy is pinned here, or — with nothing pinned — when this
    // is where the system is sending audio. Both mean "sound is coming out of
    // this", which is the question the row answers.
    final active = device.isPreferred || (!anyPinned && device.isDefault);

    return ListTile(
      onTap: onTap,
      leading: Icon(device.icon,
          color: active ? themeColor : Colors.white.withOpacity(0.75)),
      title: Text(
        device.displayName,
        style: TextStyle(
          color: active ? themeColor : Colors.white,
          fontSize: 14.5,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: device.isPreferred
          ? Text('Auvy only · tap to release',
              style: TextStyle(color: themeColor.withOpacity(0.75), fontSize: 11.5))
          : (device.isDefault && !anyPinned
              ? Text('System default',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66), fontSize: 11.5))
              : null),
      trailing: active
          ? Icon(Icons.check_circle_rounded, color: themeColor, size: 20)
          : null,
    );
  }
}

/// The account's other phones, live: what each is playing, play/pause and skip
/// for it, and moving playback here or there. Only with cloud sync signed in;
/// everything shown was sealed with the account's key on the way. Opening it
/// is what makes the other phones report (see DevicePresenceService), so it
/// costs nothing while closed.
class _OtherDevicesSection extends ConsumerStatefulWidget {
  final Color themeColor;
  const _OtherDevicesSection({required this.themeColor});

  @override
  ConsumerState<_OtherDevicesSection> createState() => _OtherDevicesSectionState();
}

class _OtherDevicesSectionState extends ConsumerState<_OtherDevicesSection> {
  Timer? _tick;
  String? _busy;

  /// Play/pause as just asked of a phone, shown until that phone's own report
  /// arrives (a second or three), so the button doesn't look ignored.
  final Map<String, ({bool playing, int atMs})> _asked = {};

  @override
  void initState() {
    super.initState();
    DevicePresenceService.instance.startWatching();
    // "Checking…" gives way after a few seconds, "playing" runs out with the
    // song, and "last used" ages: redrawn now and then.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    DevicePresenceService.instance.stopWatching();
    super.dispose();
  }

  Future<void> _run(String key, Future<String?> Function() action) async {
    if (_busy != null) return;
    HapticService.selection();
    setState(() => _busy = key);
    String? problem;
    try {
      problem = await action();
    } catch (_) {
      problem = "Couldn't reach that device";
    }
    if (!mounted) return;
    setState(() => _busy = null);
    if (problem != null) AnimatedToast.message(problem);
  }

  Future<String?> _command(AuvyLiveDevice d, String name) async {
    final ok = await DevicePresenceService.instance.send(d.id, name);
    if (ok && (name == 'play' || name == 'pause')) {
      _asked[d.id] = (playing: name == 'play', atMs: DateTime.now().millisecondsSinceEpoch);
    }
    return ok ? null : "Couldn't reach ${d.name}";
  }

  Future<String?> _playHere(AuvyLiveDevice d) {
    final player = ref.read(playerProvider.notifier);
    return DevicePresenceService.instance.bringPlaybackFrom(d, takeOver: player.takeOverHandoff);
  }

  Future<String?> _sendThere(AuvyLiveDevice d) {
    final player = ref.read(playerProvider.notifier);
    return DevicePresenceService.instance.sendPlaybackTo(d, pauseHere: () async {
      if (player.currentState.isPlaying) player.togglePlay(haptic: false);
    });
  }

  static String _ago(int ms) {
    final m = ms ~/ 60000;
    if (m < 1) return 'just now';
    if (m < 60) return '$m min ago';
    final h = m ~/ 60;
    if (h < 24) return '$h h ago';
    final days = h ~/ 24;
    return days == 1 ? 'yesterday' : '$days days ago';
  }

  @override
  Widget build(BuildContext context) {
    if (CloudSyncService.instance.accountDoc == null) return const SizedBox.shrink();
    final hasSongHere = ref.watch(playerProvider.select((s) => s.currentSong != null));
    return ValueListenableBuilder<List<AuvyLiveDevice>>(
      valueListenable: DevicePresenceService.instance.others,
      builder: (context, devices, _) {
        final dim = Colors.white.withOpacity(0.66);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text('YOUR OTHER DEVICES',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1)),
            ),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                child: Text(
                    'Phones signed in to this account show up here when Auvy is open on them.',
                    style: TextStyle(color: dim, fontSize: 12)),
              ),
            for (final d in devices) _row(d, hasSongHere),
          ],
        );
      },
    );
  }

  Widget _row(AuvyLiveDevice d, bool hasSongHere) {
    final theme = widget.themeColor;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Running phones answer within a second or two of the list opening.
    final live = d.here;
    final checking = !live && now - DevicePresenceService.instance.watchStartedMs < 5000;
    final asked = _asked[d.id];
    final stillAsked = asked != null && d.updatedMs < asked.atMs && now - asked.atMs < 6000;
    final playing = live && (stillAsked ? asked.playing : d.playingAt(now));
    final song = d.private
        ? 'Private session'
        : (d.artist.isEmpty ? d.title : '${d.title} · ${d.artist}');
    final status = checking
        ? 'Checking…'
        : !live
            ? 'Not open right now · last used ${_ago(now - d.updatedMs)}'
            : playing
                ? 'Playing · $song'
                : (d.hasSong || d.private)
                    ? 'Paused · $song'
                    : 'Open, nothing playing';
    final canControl = live && (d.hasSong || d.private);
    final canBring = live && d.handoff != null;
    final canSend = live && hasSongHere && !ListeningPolicy.privateSession;
    final busy = _busy;
    final iconColor = playing ? theme : Colors.white.withOpacity(0.75);
    final isPhone = d.platform == 'ios' || d.platform == 'android';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
        decoration: BoxDecoration(
          color: playing ? theme.withOpacity(0.10) : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: playing ? theme.withOpacity(0.30) : Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    isPhone
                        ? (d.platform == 'ios' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded)
                        : Icons.devices_rounded,
                    color: iconColor,
                    size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name.isEmpty ? 'Another device' : d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: playing ? theme : Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                    ],
                  ),
                ),
                if (canControl) ...[
                  IconButton(
                    tooltip: playing ? 'Pause on ${d.name}' : 'Play on ${d.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy != null
                        ? null
                        : () => _run('${d.id}:toggle', () => _command(d, playing ? 'pause' : 'play')),
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Next on ${d.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy != null || d.private ? null : () => _run('${d.id}:next', () => _command(d, 'next')),
                    icon: Icon(Icons.skip_next_rounded,
                        color: d.private ? Colors.white.withOpacity(0.3) : Colors.white),
                  ),
                ],
              ],
            ),
            if (canBring || canSend || (!live && !checking))
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 2),
                child: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (canBring)
                      TextButton.icon(
                        onPressed: busy != null ? null : () => _run('${d.id}:here', () => _playHere(d)),
                        style: TextButton.styleFrom(
                            foregroundColor: theme, visualDensity: VisualDensity.compact),
                        icon: busy == '${d.id}:here'
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.south_west_rounded, size: 16),
                        label: const Text('Play here'),
                      ),
                    if (canSend)
                      TextButton.icon(
                        onPressed: busy != null ? null : () => _run('${d.id}:there', () => _sendThere(d)),
                        style: TextButton.styleFrom(
                            foregroundColor: theme, visualDensity: VisualDensity.compact),
                        icon: busy == '${d.id}:there'
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.north_east_rounded, size: 16),
                        label: const Text('Send there'),
                      ),
                    if (!live && !checking)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Text('Open Auvy there to control it',
                            style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
