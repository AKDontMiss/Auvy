import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/audio_output_service.dart';
import 'package:auvy/services/haptic_service.dart';

/// The in-app output picker: attached devices by name, tap to send Auvy's audio
/// to one.
///
/// Only ATTACHED outputs can be listed, so the last row hands over to the system
/// settings rather than showing devices this code cannot reach.
///
/// A car stereo is a Bluetooth or USB output like any other while connected, so
/// it appears here by its own name. Android Auto is separate — the car takes over
/// the screen and browses Auvy's media tree, and needs nothing from this sheet.
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

    // ONLY THE PINNED DEVICE UNPINS. Treating the SYSTEM DEFAULT as an unpin
    // too, which it did — made the most obvious action impossible: with a
    // headset connected the phone speaker is not the default, but tapping the
    // speaker released the pin instead of selecting it, so following the system
    // sent audio straight back to the headset and the tap appeared to do nothing.
    //
    // Pinning any listed device is safe now that the list holds one row per
    // physical device; the earlier caution was about a headset exposing both A2DP
    // and LE Audio under one name, and the dedupe fixed that at the source.
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That device is no longer connected'),
      ));
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
        color: const Color(0xFF121212),
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
            Divider(color: Colors.white.withOpacity(0.07), height: 22),
            // Deliberately promises nothing about what the system panel offers —
            // it differs by Android version and OEM skin, and naming Cast or
            // pairing here would be a claim this code cannot keep.
            ListTile(
              leading: Icon(Icons.settings_rounded,
                  color: Colors.white.withOpacity(0.75)),
              title: const Text('Android sound settings',
                  style: TextStyle(color: Colors.white, fontSize: 14.5)),
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
