import 'package:flutter/material.dart';

/// The app's search pill, one implementation so the text is vertically centred on
/// every page.
///
/// A plain TextField in a fixed-height Container can't centre reliably: the
/// decoration's prefix/suffix icons have a 48×48 minimum, and `contentPadding`
/// sets an intrinsic height that only looks centred when it happens to match the
/// Container's. Instead, `isCollapsed: true` gives the field no intrinsic padding
/// (exactly one line tall) and a `Row` centres it, so the pill's height is the only
/// number that matters.
///
/// Tapping anywhere in the pill focuses the field, since a collapsed TextField's
/// own hit area is only as tall as its text.
class AuvySearchField extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;

  /// Leading glyph. Not always a magnifier — the radio country picker uses a
  /// globe.
  final IconData icon;

  final double height;
  final double radius;

  /// Text AND hint size — they must match or the hint jumps when typing starts.
  final double fontSize;

  final Color fillColor;
  final Color borderColor;
  final Color hintColor;
  final Color iconColor;
  final double iconSize;

  /// Clear button, spinner, etc. Sits inside the pill, after the text.
  final Widget? trailing;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Called in addition to focusing, when the pill is tapped.
  final VoidCallback? onTap;

  final bool autofocus;
  final TextInputAction? textInputAction;
  final Color? cursorColor;

  const AuvySearchField({
    super.key,
    this.controller,
    this.focusNode,
    required this.hint,
    this.icon = Icons.search_rounded,
    this.height = 44,
    this.radius = 14,
    this.fontSize = 14,
    this.fillColor = const Color(0x12FFFFFF),
    this.borderColor = const Color(0x10FFFFFF),
    this.hintColor = Colors.white30,
    this.iconColor = Colors.white38,
    this.iconSize = 20,
    this.trailing,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.autofocus = false,
    this.textInputAction,
    this.cursorColor,
  });

  @override
  State<AuvySearchField> createState() => _AuvySearchFieldState();
}

class _AuvySearchFieldState extends State<AuvySearchField> {
  /// Only created when the caller doesn't supply one, and only then disposed,
  /// since disposing a node we were handed would break the owner.
  FocusNode? _internalNode;

  FocusNode get _node => widget.focusNode ?? (_internalNode ??= FocusNode());

  @override
  void dispose() {
    _internalNode?.dispose();
    super.dispose();
  }

  void _focus() {
    if (!_node.hasFocus) _node.requestFocus();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: widget.fillColor,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: widget.borderColor),
      ),
      child: Row(
        children: [
          SizedBox(width: widget.height * 0.28),
          Icon(widget.icon, color: widget.iconColor, size: widget.iconSize),
          const SizedBox(width: 9),
          Expanded(
            // translucent so the whole text band focuses the field, while the
            // TextField's own (deeper) tap recogniser still wins on the text
            // itself for caret placement.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _focus,
              child: Align(
                // y == 0 → vertically centred; widthFactor null → full width.
                alignment: Alignment.centerLeft,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _node,
                  autofocus: widget.autofocus,
                  maxLines: 1,
                  textInputAction: widget.textInputAction,
                  cursorColor: widget.cursorColor,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  onTap: widget.onTap,
                  style: TextStyle(color: Colors.white, fontSize: widget.fontSize),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle:
                        TextStyle(color: widget.hintColor, fontSize: widget.fontSize),
                    border: InputBorder.none,
                    // The one line that makes the centring work. See the class
                    // doc. Do not swap this for isDense + contentPadding.
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
          SizedBox(width: widget.trailing != null ? 6 : widget.height * 0.28),
        ],
      ),
    );
  }
}
