import 'package:flutter/material.dart';
import 'package:auvy/services/haptic_service.dart';

/// A small ⓘ that shows explanatory text in a sheet instead of inline, so
/// settings screens stay scannable without losing the explanation.
///
/// [title] heads the sheet; [message] is the body (scrollable if long).
class InfoHint extends StatelessWidget {
  final String title;
  final String message;
  final double size;
  final Color? tint;

  const InfoHint({
    super.key,
    required this.title,
    required this.message,
    this.size = 17,
    this.tint,
  });

  void _show(BuildContext context) {
    HapticService.selection();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF17171C),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(children: [
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: tint ?? Colors.white70),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800)),
                  ),
                ]),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Text(message,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 13.5,
                            height: 1.5)),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.07),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(23)),
                    ),
                    child: const Text('Got it',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 14)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'More information',
      button: true,
      child: GestureDetector(
        onTap: () => _show(context),
        behavior: HitTestBehavior.opaque,
        // Padded so the tap target is comfortable even though the glyph is small.
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(Icons.info_outline_rounded,
              size: size, color: tint ?? Colors.white.withOpacity(0.42)),
        ),
      ),
    );
  }
}
