import 'package:auvy/services/catalog_api_client.dart';

/// The play count shown on a track row, formatted the same way on every page.
///
/// Two sources, in order:
///
///  1. `song.viewCount` — the text YouTube put in the row itself ("12M plays").
///     Search results and several browse shelves include it.
///  2. The count harvested from a player response the app already made for this
///     track. Album and playlist rows carry NO count in YouTube's own data —
///     those shelves show duration instead, so without this they stay blank
///     however the row is rendered.
///
/// Returns null when neither source knows, and the row then shows nothing rather
/// than a zero or a guess.
String? trackRowViews(String videoId, String rowViewCount) {
  final fromRow = rowViewCount.trim();
  if (fromRow.isNotEmpty) return fromRow;
  final harvested = CatalogApiClient.cachedViewCount(videoId);
  if (harvested == null) return null;
  return formatPlayCount(harvested);
}

/// Turns a raw count ("48213904") into "48M plays".
///
/// Matches the wording YouTube uses in the rows that do carry a count, so a
/// harvested number and a supplied string cannot be told apart on screen.
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
