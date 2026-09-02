import 'package:flutter/material.dart';
import 'package:auvy/services/haptic_service.dart';

/// Two-wheel time picker, shared by the alarm (a clock TIME) and the sleep timer
/// (a DURATION).
///
/// Replaces Flutter's `showTimePicker`, which ignores the app's look entirely and
/// whose dark variant is washed out. Wheels also let you land on a value in one
/// spin rather than tapping a keypad.
///
/// [hourCount] is 24 for a clock time, or 12 for a duration in hours.
/// [durationMode] switches the confirm text to "1h 30m" phrasing and prevents
/// 0:00 being confirmed (a zero-length sleep timer is meaningless).
/// [extraActions] are alternative choices rendered as compact rows beneath the
/// wheels — used by the sleep timer for "End of track" and "Off", which aren't
/// durations but belong in the same sheet. Each closes the picker itself.
Future<({int hour, int minute})?> showWheelTimePicker(
  BuildContext context, {
  required Color theme,
  required String title,
  int initialHour = 0,
  int initialMinute = 30,
  int hourCount = 24,
  bool durationMode = false,
  List<({IconData icon, String label, VoidCallback onTap})> extraActions =
      const [],
}) {
  return showModalBottomSheet<({int hour, int minute})>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _WheelTimePickerSheet(
      theme: theme,
      title: title,
      initialHour: initialHour.clamp(0, hourCount - 1),
      initialMinute: initialMinute.clamp(0, 59),
      hourCount: hourCount,
      durationMode: durationMode,
      extraActions: extraActions,
    ),
  );
}

/// A StatefulWidget rather than a StatefulBuilder specifically so the two
/// [FixedExtentScrollController]s have somewhere to live and be disposed.
/// They were previously constructed inline in the builder, which meant a fresh
/// pair on every rebuild, and a rebuild happens on every notch you spin, so a
/// single visit to the sheet leaked dozens of controllers (each with its own
/// ScrollPosition and listener list) and none were ever disposed.
class _WheelTimePickerSheet extends StatefulWidget {
  final Color theme;
  final String title;
  final int initialHour;
  final int initialMinute;
  final int hourCount;
  final bool durationMode;
  final List<({IconData icon, String label, VoidCallback onTap})> extraActions;

  const _WheelTimePickerSheet({
    required this.theme,
    required this.title,
    required this.initialHour,
    required this.initialMinute,
    required this.hourCount,
    required this.durationMode,
    required this.extraActions,
  });

  @override
  State<_WheelTimePickerSheet> createState() => _WheelTimePickerSheetState();
}

class _WheelTimePickerSheetState extends State<_WheelTimePickerSheet> {
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minuteCtrl;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialHour;
    _minute = widget.initialMinute;
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  String _label() {
    if (!widget.durationMode) {
      return '${_hour.toString().padLeft(2, '0')}:'
          '${_minute.toString().padLeft(2, '0')}';
    }
    if (_hour == 0) return '${_minute}m';
    if (_minute == 0) return '${_hour}h';
    return '${_hour}h ${_minute}m';
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required int selected,
    required ValueChanged<int> onChanged,
  }) {
    return SizedBox(
      width: 84,
      height: 190,
      child: ListWheelScrollView.useDelegate(
        itemExtent: 54,
        perspective: 0.004,
        diameterRatio: 1.7,
        physics: const FixedExtentScrollPhysics(),
        controller: controller,
        onSelectedItemChanged: (i) {
          HapticService.selection();
          onChanged(i);
        },
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: count,
          builder: (ctx, i) {
            final isSel = i == selected;
            return Center(
              child: Text(
                i.toString().padLeft(2, '0'),
                style: TextStyle(
                  color: isSel ? Colors.white : Colors.white.withOpacity(0.66),
                  fontSize: isSel ? 38 : 30,
                  fontWeight: isSel ? FontWeight.w800 : FontWeight.w500,
                  height: 1.0,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final canConfirm = !widget.durationMode || _hour > 0 || _minute > 0;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF17171C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(widget.title,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const SizedBox(height: 6),
            Stack(
              alignment: Alignment.center,
              children: [
                // Selection band — the anchor that makes the chosen row obvious.
                Container(
                  height: 54,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: theme.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: theme.withOpacity(0.35)),
                  ),
                ),
                // The wheels sit DIRECTLY in this Row — no wrapping Column.
                // Duration mode briefly had "hours"/"minutes" captions below
                // each wheel, which made those columns taller than the 54px
                // selection band and shifted the numbers up out of the
                // highlight. The band only lines up when the wheels are the
                // only children. The title and the "Set 1h 30m" button already
                // say which unit is which.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _wheel(
                      controller: _hourCtrl,
                      count: widget.hourCount,
                      selected: _hour,
                      onChanged: (v) => setState(() => _hour = v),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(':',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.72),
                              fontSize: 32,
                              fontWeight: FontWeight.w800)),
                    ),
                    _wheel(
                      controller: _minuteCtrl,
                      count: 60,
                      selected: _minute,
                      onChanged: (v) => setState(() => _minute = v),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                        side:
                            BorderSide(color: Colors.white.withOpacity(0.12)),
                      ),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(
                            color: Colors.white54,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: canConfirm
                        ? () => Navigator.pop(
                            context, (hour: _hour, minute: _minute))
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white.withOpacity(0.08),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                    child: Text('Set ${_label()}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 15)),
                  ),
                ),
              ),
            ]),
            if (widget.extraActions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Divider(color: Colors.white.withOpacity(0.07), height: 20),
              for (final a in widget.extraActions)
                InkWell(
                  onTap: () {
                    HapticService.selection();
                    Navigator.pop(context);
                    a.onTap();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(children: [
                      Icon(a.icon,
                          size: 19, color: Colors.white.withOpacity(0.62)),
                      const SizedBox(width: 14),
                      Text(a.label,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
