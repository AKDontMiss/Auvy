import 'package:flutter/material.dart';

/// One cell of a menu's quick-action strip: a tinted circular glyph with a short
/// label under it.
///
/// Shared by the track menu (`content_menus.dart`) and the player menu
/// (`player_menu_sheet.dart`) so the two cannot drift apart — they are the same
/// control in the same app, and a user who learns one should recognise the other.
///
/// WHY A STRIP AT ALL: both sheets grew to nine-plus stacked rows and ended up
/// covering the whole screen, which stops a menu reading as being ABOUT something
/// and starts it reading as a new page. The fix is fewer ROWS, not tighter ones —
/// so the actions that are a single verb, finish immediately, and carry no
/// full-width label move across into a strip. (A grid of icon cells does the
/// same thing for the same reason.)
///
/// Always used inside a [Row]: [Expanded] means N cells divide the sheet evenly,
/// so the strip cannot overflow a narrow screen or leave a gap on a wide one.
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
