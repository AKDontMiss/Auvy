/// Formats a raw count ("48213904") as "48M plays", matching YouTube's wording.
String? formatPlayCount(int count) {
  if (count <= 0) return null;
  if (count >= 1000000000) {
    return '${(count / 1000000000).toStringAsFixed(1)}B plays';
  }
  if (count >= 1000000) {
    final m = count / 1000000;
    return '${m >= 10 ? m.round() : double.parse(m.toStringAsFixed(1))}M plays';
  }
  if (count >= 1000) {
    final k = count / 1000;
    return '${k >= 10 ? k.round() : double.parse(k.toStringAsFixed(1))}K plays';
  }
  return '$count ${count == 1 ? 'play' : 'plays'}';
}
