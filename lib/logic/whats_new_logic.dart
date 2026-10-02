/// What's New: the pure part. The item model, reading Apple's public iTunes
/// catalogue answers into items, and deciding which items a notification is
/// for. The native background checks (AuvySystemChannels.swift, WhatsNewJobService.kt)
/// apply the same rules to the same answers, so the keys and the rules here
/// must stay in step with them.
library;

import 'package:auvy/data/artist_model.dart';

/// What a feed item is about. [suggested] is a release from an artist the
/// listener doesn't follow but whose music fits their taste ("You might like").
enum WhatsNewKind { release, episode, app, madeForYou, suggested }

class WhatsNewItem {
  /// Unique and stable: `rel:<collectionId>`, `ep:<trackId>`, `app:<version>`,
  /// `mfy:<what>`. Shared with the native checks, which mark notified keys.
  final String key;
  final WhatsNewKind kind;

  /// The release, episode or announcement.
  final String title;

  /// Who it is from: the artist, the podcast, or "Auvy".
  final String source;

  /// "Single", "EP", "Album", "Episode", or '' for announcements.
  final String label;
  final String image;

  /// When it came out (or comes out), ms since epoch.
  final int dateMs;

  /// When this phone first saw it, ms since epoch.
  final int foundMs;

  /// Where a tap goes: the followed artist's id or name for a release, the
  /// podcast's feed URL for an episode, a playlist title for Made for you.
  final String target;

  /// Why a suggestion is here ("You play them a lot"), '' otherwise.
  final String note;

  const WhatsNewItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.source,
    required this.label,
    required this.image,
    required this.dateMs,
    required this.foundMs,
    this.target = '',
    this.note = '',
  });

  bool isUpcoming(DateTime now) => dateMs > now.millisecondsSinceEpoch;

  Map<String, Object> toJson() => {
        'key': key,
        'kind': kind.name,
        'title': title,
        'source': source,
        'label': label,
        'image': image,
        'dateMs': dateMs,
        'foundMs': foundMs,
        'target': target,
        if (note.isNotEmpty) 'note': note,
      };

  static WhatsNewItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final title = raw['title'];
    if (key is! String || key.isEmpty || title is! String) return null;
    final kind = WhatsNewKind.values
            .where((k) => k.name == raw['kind'])
            .firstOrNull ??
        WhatsNewKind.release;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return WhatsNewItem(
      key: key,
      kind: kind,
      title: title,
      source: (raw['source'] as String?) ?? '',
      label: (raw['label'] as String?) ?? '',
      image: (raw['image'] as String?) ?? '',
      dateMs: asInt(raw['dateMs']),
      foundMs: asInt(raw['foundMs']),
      target: (raw['target'] as String?) ?? '',
      note: (raw['note'] as String?) ?? '',
    );
  }

  WhatsNewItem copyWith({WhatsNewKind? kind, int? foundMs, String? note}) => WhatsNewItem(
        key: key,
        kind: kind ?? this.kind,
        title: title,
        source: source,
        label: label,
        image: image,
        dateMs: dateMs,
        foundMs: foundMs ?? this.foundMs,
        target: target,
        note: note ?? this.note,
      );
}

/// Feed window: releases from the last 30 days, and up to two months ahead.
const Duration kReleaseLookBack = Duration(days: 30);
const Duration kReleaseLookAhead = Duration(days: 60);

/// How long an item stays in the feed: 30 days from when it came out or was
/// found, whichever is later, then the oldest go first.
const Duration kFeedKeep = Duration(days: 30);

/// Suggestions are for what is fresh: the last two weeks.
const Duration kSuggestionLookBack = Duration(days: 14);

/// Episodes older than a week are not news.
const Duration kEpisodeLookBack = Duration(days: 7);

/// A notification is only for something that came out in the last three days.
const Duration kNotifyWindow = Duration(days: 3);

/// Names compared loosely: case, punctuation and spacing ignored, and YouTube's
/// " - Topic" channel suffix dropped. The native checks use the same rule.
String normalizeArtistName(String name) {
  var n = name.toLowerCase();
  if (n.endsWith(' - topic')) n = n.substring(0, n.length - 8);
  return n
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((p) => p.isNotEmpty)
      .join(' ');
}

/// The first artist of a credit ("mgk, blackbear" → "mgk"; "A feat. B" → "A").
/// "&" is not split on: it is part of many names (Simon & Garfunkel).
String leadArtist(String credit) => credit
    .split(RegExp(r',\s*|\s+(?:feat\.?|ft\.?|featuring|x|with)\s+', caseSensitive: false))
    .first
    .trim();

/// Whether [name] (a release's credited artists) names [followedNorm], as whole
/// words, so "AURORA & Friend" counts for AURORA but "Auroraborealis" does not.
bool creditsArtist(String name, String followedNorm) {
  if (followedNorm.isEmpty) return false;
  return ' ${normalizeArtistName(name)} '.contains(' $followedNorm ');
}

/// "CELEBRATION - EP" → ("CELEBRATION", "EP").
(String, String) splitReleaseTitle(String collectionName, int trackCount) {
  final name = collectionName.trim();
  for (final (suffix, label) in const [(' - Single', 'Single'), (' - EP', 'EP')]) {
    if (name.endsWith(suffix)) {
      return (name.substring(0, name.length - suffix.length).trim(), label);
    }
  }
  return (name, trackCount > 0 && trackCount <= 3 ? 'Single' : 'Album');
}

/// iTunes artwork comes as 100 px; the same URL serves larger sizes.
String largerArtwork(String url) =>
    url.replaceAll(RegExp(r'/\d+x\d+bb\.'), '/600x600bb.');

/// One followed artist, matched to the catalogue.
class FollowedArtist {
  final int catalogId;
  final String name;

  /// The artist's id in Auvy (a YouTube channel id), for opening the release.
  final String appId;

  /// For a suggested artist: why ("You play them a lot").
  final String note;
  const FollowedArtist(this.catalogId, this.name, this.appId, {this.note = ''});
}

/// Reads a batched `lookup?id=…&entity=album` answer: each artist entry is
/// followed by that artist's releases. Keeps releases inside the feed window
/// that credit the followed artist (their own, or a collaboration naming them),
/// skips video albums, and drops repeats.
///
/// [suggested]: the artists are not followed, so only their own releases from
/// the last two weeks count, and the items are suggestions.
List<WhatsNewItem> parseReleaseLookup(
    Map<String, dynamic> json, Map<int, FollowedArtist> followed, DateTime now,
    {bool suggested = false}) {
  final results = (json['results'] as List?) ?? const [];
  final from = now
      .subtract(suggested ? kSuggestionLookBack : kReleaseLookBack)
      .millisecondsSinceEpoch;
  final until = suggested
      ? now.millisecondsSinceEpoch
      : now.add(kReleaseLookAhead).millisecondsSinceEpoch;
  final out = <String, WhatsNewItem>{};
  FollowedArtist? current;
  for (final raw in results) {
    if (raw is! Map) continue;
    if (raw['wrapperType'] == 'artist') {
      current = followed[(raw['artistId'] as num?)?.toInt() ?? -1];
      continue;
    }
    if (raw['wrapperType'] != 'collection' || current == null) continue;
    final id = (raw['collectionId'] as num?)?.toInt();
    final name = (raw['collectionName'] as String?) ?? '';
    final date = DateTime.tryParse((raw['releaseDate'] as String?) ?? '');
    if (id == null || name.isEmpty || date == null) continue;
    final dateMs = date.millisecondsSinceEpoch;
    if (dateMs < from || dateMs > until) continue;
    if (name.toLowerCase().contains('video album')) continue;
    final credited = (raw['artistName'] as String?) ?? '';
    final ownId = (raw['artistId'] as num?)?.toInt() == current.catalogId;
    if (!ownId && (suggested || !creditsArtist(credited, normalizeArtistName(current.name)))) {
      continue;
    }
    final (title, label) =
        splitReleaseTitle(name, (raw['trackCount'] as num?)?.toInt() ?? 0);
    final item = WhatsNewItem(
      key: 'rel:$id',
      kind: suggested ? WhatsNewKind.suggested : WhatsNewKind.release,
      title: title,
      // The followed artist, not the full credit: a collaboration can credit a
      // dozen names, and the listener follows one of them.
      source: current.name,
      label: label,
      image: largerArtwork((raw['artworkUrl100'] as String?) ?? ''),
      dateMs: dateMs,
      foundMs: now.millisecondsSinceEpoch,
      target: current.appId.isNotEmpty ? current.appId : current.name,
      note: current.note,
    );
    // The same release listed twice (a clean and an explicit edition) shows once.
    final dupe = '${normalizeArtistName(item.source)}|${normalizeArtistName(title)}|$label';
    out.putIfAbsent(dupe, () => item);
  }
  return out.values.toList();
}

/// One followed podcast, matched to the catalogue.
class FollowedPodcast {
  final int catalogId;
  final String name;
  final String feedUrl;
  const FollowedPodcast(this.catalogId, this.name, this.feedUrl);
}

/// Reads a batched `lookup?id=…&entity=podcastEpisode` answer.
List<WhatsNewItem> parseEpisodeLookup(
    Map<String, dynamic> json, Map<int, FollowedPodcast> followed, DateTime now) {
  final results = (json['results'] as List?) ?? const [];
  final from = now.subtract(kEpisodeLookBack).millisecondsSinceEpoch;
  final out = <WhatsNewItem>[];
  for (final raw in results) {
    if (raw is! Map || raw['wrapperType'] != 'podcastEpisode') continue;
    final show = followed[(raw['collectionId'] as num?)?.toInt() ?? -1];
    final id = (raw['trackId'] as num?)?.toInt();
    final title = (raw['trackName'] as String?) ?? '';
    final date = DateTime.tryParse((raw['releaseDate'] as String?) ?? '');
    if (show == null || id == null || title.isEmpty || date == null) continue;
    final dateMs = date.millisecondsSinceEpoch;
    if (dateMs < from || dateMs > now.millisecondsSinceEpoch) continue;
    out.add(WhatsNewItem(
      key: 'ep:$id',
      kind: WhatsNewKind.episode,
      title: title,
      source: show.name,
      label: 'Episode',
      image: largerArtwork((raw['artworkUrl600'] as String?) ??
          (raw['artworkUrl160'] as String?) ??
          ''),
      dateMs: dateMs,
      foundMs: now.millisecondsSinceEpoch,
      target: show.feedUrl,
    ));
  }
  return out;
}

/// Adds [found] to [existing]: a known key keeps its first-seen time (and the
/// newer details; a followed artist's release outranks the same release as a
/// suggestion), new keys are added. Nothing is cleared by a check: an item
/// stays for [kFeedKeep] from when it came out or was found, whichever is
/// later (upcoming ones until then), and past [cap] the oldest go first.
/// Newest first.
List<WhatsNewItem> mergeWhatsNew(
    List<WhatsNewItem> existing, List<WhatsNewItem> found, DateTime now,
    {int cap = 300}) {
  final byKey = {for (final i in existing) i.key: i};
  for (final f in found) {
    final old = byKey[f.key];
    if (old == null) {
      byKey[f.key] = f;
      continue;
    }
    final keepFollowed =
        old.kind == WhatsNewKind.release && f.kind == WhatsNewKind.suggested;
    byKey[f.key] = WhatsNewItem(
      key: f.key,
      kind: keepFollowed ? old.kind : f.kind,
      title: f.title,
      source: keepFollowed ? old.source : f.source,
      label: f.label,
      image: f.image.isNotEmpty ? f.image : old.image,
      dateMs: f.dateMs,
      foundMs: old.foundMs,
      target: keepFollowed ? old.target : (f.target.isNotEmpty ? f.target : old.target),
      note: keepFollowed ? '' : f.note,
    );
  }
  final nowMs = now.millisecondsSinceEpoch;
  int age(WhatsNewItem i) => nowMs - (i.foundMs > i.dateMs ? i.foundMs : i.dateMs);
  final kept = byKey.values.where((i) => age(i) <= kFeedKeep.inMilliseconds).toList()
    ..sort((a, b) => age(a).compareTo(age(b)));
  final capped = kept.length > cap ? kept.sublist(0, cap) : kept;
  return capped..sort((a, b) => b.dateMs.compareTo(a.dateMs));
}

/// One release on an artist's YouTube Music page.
class PageRelease {
  final String id;
  final String title;
  final String year;
  final String recordType;
  final String image;
  const PageRelease(this.id, this.title, this.year, this.recordType, this.image);

  factory PageRelease.fromAlbum(Album a) =>
      PageRelease(a.id, a.title, a.releaseDate, a.recordType, a.image);
}

/// The second source: releases that appeared on a followed artist's YouTube
/// Music page since the last look. YouTube Music gives no date, only the year,
/// so the first look at an artist only notes what is there ([seen] is null),
/// and later ones report what is new, from this year, and not already in the
/// feed under the same title (the catalogue usually has it, with its date).
/// Returns the items and the page's ids to remember.
({List<WhatsNewItem> items, List<String> seen}) pageReleaseItems({
  required FollowedArtist artist,
  required List<PageRelease> releases,
  required List<String>? seen,
  required Iterable<WhatsNewItem> feed,
  required DateTime now,
}) {
  final ids = [for (final r in releases) if (r.id.isNotEmpty) r.id];
  if (seen == null) return (items: const [], seen: ids.take(60).toList());
  final known = seen.toSet();
  final titles = {
    for (final i in feed)
      if (i.kind == WhatsNewKind.release || i.kind == WhatsNewKind.suggested)
        normalizeArtistName(i.title)
  };
  final thisYear = '${now.year}';
  final ms = now.millisecondsSinceEpoch;
  final items = <WhatsNewItem>[];
  for (final r in releases) {
    if (r.id.isEmpty || known.contains(r.id)) continue;
    if (!r.year.contains(thisYear)) continue;
    if (titles.contains(normalizeArtistName(r.title))) continue;
    final type = r.recordType.toLowerCase();
    items.add(WhatsNewItem(
      key: 'yt:${r.id}',
      kind: WhatsNewKind.release,
      title: r.title,
      source: artist.name,
      label: type == 'single' ? 'Single' : (type == 'ep' ? 'EP' : 'Album'),
      image: r.image,
      dateMs: ms,
      foundMs: ms,
      target: artist.appId,
    ));
  }
  // The page's current ids, plus earlier ones still worth remembering.
  final merged = [...ids, ...seen.where((id) => !ids.contains(id))];
  return (items: items, seen: merged.take(60).toList());
}

/// The items a notification should go out for now: releases and episodes out
/// in the last three days that no check on this phone has announced yet.
/// Upcoming releases wait for their day.
List<WhatsNewItem> dueForNotification(
    Iterable<WhatsNewItem> items, Set<String> notified, DateTime now) {
  final nowMs = now.millisecondsSinceEpoch;
  final from = now.subtract(kNotifyWindow).millisecondsSinceEpoch;
  return items
      .where((i) =>
          (i.kind == WhatsNewKind.release || i.kind == WhatsNewKind.episode) &&
          !notified.contains(i.key) &&
          i.dateMs <= nowMs &&
          i.dateMs >= from)
      .toList();
}

/// The notifications for [due]: one each, or a single summary for more than
/// three, so a first check after following many artists doesn't flood.
List<({String id, String title, String body})> notificationsFor(List<WhatsNewItem> due) {
  if (due.isEmpty) return const [];
  String headline(WhatsNewItem i) => i.kind == WhatsNewKind.episode
      ? 'New episode of ${i.source}'
      : 'New ${i.label.toLowerCase()} from ${i.source}';
  if (due.length <= 3) {
    return [for (final i in due) (id: i.key, title: headline(i), body: i.title)];
  }
  final sources = <String>[];
  for (final i in due) {
    if (!sources.contains(i.source)) sources.add(i.source);
  }
  final episodes = due.where((i) => i.kind == WhatsNewKind.episode).length;
  final what = episodes == 0
      ? 'new releases'
      : episodes == due.length
          ? 'new episodes'
          : 'new releases and episodes';
  final names = sources.length <= 2
      ? sources.join(' and ')
      : '${sources.take(2).join(', ')} and ${sources.length - 2} more';
  return [(id: 'summary:${due.first.key}', title: '${due.length} $what', body: names)];
}
