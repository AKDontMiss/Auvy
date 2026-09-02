import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/diagnostics_service.dart';
import 'package:auvy/services/haptic_service.dart';

/// Shows the diagnostics report, then offers to copy or share it.
///
/// The preview is not decoration. This is the one action in Settings that hands
/// information about the device to somebody else, so the full text is on screen
/// before either button exists — an export the user can't read first is just an
/// upload.
Future<void> showDiagnosticsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF17171C),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const _DiagnosticsSheet(),
  );
}

class _DiagnosticsSheet extends ConsumerStatefulWidget {
  const _DiagnosticsSheet();

  @override
  ConsumerState<_DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends ConsumerState<_DiagnosticsSheet> {
  String? _report;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final report = await DiagnosticsService.build();
      if (mounted) setState(() => _report = report);
    } catch (e) {
      // DiagnosticsService already guards every field, so reaching here means
      // something more fundamental — show it rather than an empty sheet.
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final report = _report;

    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text('Diagnostics',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                'Build, device and playback state — no accounts, tokens or '
                'library contents. Read it before you send it.',
                style: TextStyle(color: Colors.white38, fontSize: 12.5, height: 1.4),
              ),
            ),
            Flexible(
              child: report == null && _error == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: themeColor),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                        child: SelectableText(
                          // Type only, never the message — the same rule
                          // DiagnosticsService._why enforces, for the same
                          // reason: an exception string can carry a file path.
                          report ??
                              'Could not build the report '
                                  '(${_error.runtimeType})',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11.5,
                            height: 1.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              child: Row(children: [
                Expanded(
                  child: _Btn(
                    label: 'Copy',
                    icon: Icons.copy_rounded,
                    filled: false,
                    color: themeColor,
                    onTap: report == null
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: report));
                            HapticService.light();
                            AnimatedToast.message('Diagnostics copied');
                          },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Btn(
                    label: 'Share',
                    icon: Icons.ios_share_rounded,
                    filled: true,
                    color: themeColor,
                    onTap: report == null
                        ? null
                        : () async {
                            HapticService.light();
                            await DiagnosticsService.share(report);
                          },
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final Color color;
  final VoidCallback? onTap;

  const _Btn({
    required this.label,
    required this.icon,
    required this.filled,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: filled ? color : Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: filled ? Colors.black : Colors.white),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      color: filled ? Colors.black : Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}
