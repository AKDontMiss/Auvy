import 'package:flutter/material.dart';

/// One cell of a menu's quick-action strip: a tinted circular glyph with a short
/// label. Shared by the track menu (`content_menus.dart`) and the player menu
/// (`player_menu_sheet.dart`) so they look and behave the same.
///
/// The strip keeps menus short: actions that are a single verb, finish
/// immediately, and need no full-width label move into it, so the sheet doesn't
/// grow to cover the screen.
///
/// Always used inside a [Row]; [Expanded] divides the width evenly, so the strip
/// can't overflow a narrow screen or leave a gap on a wide one.
class QuickActionCell extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Glyph colour, and at 14% opacity the disc behind it. Pass the theme accent
  /// to mark a live/active state (an armed sleep timer, a running session).
  final Color color;

  final VoidCallback onTap;

  const QuickActionCell({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        splashColor: Colors.white.withOpacity(0.04),
        highlightColor: Colors.white.withOpacity(0.03),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.14),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
