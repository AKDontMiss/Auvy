import 'package:flutter/material.dart';

/// The standard track-row subtitle: an EXPLICIT badge (when applicable) followed
/// by the artist name.
///
/// One widget instead of six near-identical Rows across album / playlist /
/// artist / home / queue rows, so the badge looks and spaces identically
/// everywhere, and adding it to a new list is a one-liner. Collapses to a plain
/// text line when the track isn't explicit.
class ExplicitArtistLine extends StatelessWidget {
  final bool isExplicit;
  final String text;
  final TextStyle style;
  final double badgeSize;

  const ExplicitArtistLine({
    super.key,
    required this.isExplicit,
    required this.text,
    required this.style,
    this.badgeSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!isExplicit) return label;
    return Row(
      children: [
        ExplicitBadge(isExplicit: true, size: badgeSize),
        Expanded(child: label),
      ],
    );
  }
}

class ExplicitBadge extends StatelessWidget {
  final bool isExplicit;
  final double size;
  
  const ExplicitBadge({
    super.key,
    required this.isExplicit,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (!isExplicit) return const SizedBox.shrink();

    return Container(
      // Trailing gap so the badge never crowds the text that follows it — at 5px
      // it read as one glued-together lump with the artist name.
      margin: const EdgeInsets.only(right: 8),
      padding: EdgeInsets.symmetric(
        horizontal: size * 0.3,
        vertical: size * 0.15,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(size * 0.15),
        border: Border.all(
          color: Colors.white.withOpacity(0.6),
          width: 1,
        ),
      ),
      child: Text(
        'E',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.7,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}