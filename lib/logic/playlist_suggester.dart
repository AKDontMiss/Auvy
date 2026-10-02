/// Song suggestions for a playlist, from the playlist's own sound.
///
/// Used by the playlist page's "Suggested songs" section, by "Keep fresh"
/// playlists and by Weekly Discovery, so all three agree on what belongs.
library;

import 'dart:math' as math;

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/services/search_service.dart';

/// A playlist described by its own contents, for suggestion ranking. Built by
/// [fingerprintPlaylist], which explains how each field is derived.
class PlaylistFingerprint {
  /// Artist → weight, over EVERY track, counting featured credits and biased
  /// toward recently-added entries.
  final Map<String, double> artistWeight;

  /// [artistWeight] keys, heaviest first. The suggestion seeds.
  final List<String> topArtists;

  /// Median release year, or null when no track carries a parseable date.
  final int? medianYear;

  /// ≥70% of tracks share one album — a listening context rather than a taste
  /// profile, so suggestions should reach outside it.
  final bool dominatedBySingleAlbum;

  final bool mostlyExplicit;
  final int trackCount;

  /// How far to trust this playlist over general taste, 0.45…0.95. Derived from
  /// evidence (track count, saturating) and coherence (artist concentration)
  /// rather than fixed. See [fingerprintPlaylist] for why a constant ratio is the wrong
  /// shape.
  final double playlistWeight;

  /// The 0…1 confidence [playlistWeight] was derived from. Drives the header
  /// copy, so the blend the ranking is using is visible rather than hidden.
  final double confidence;

  double get tasteWeight => 1.0 - playlistWeight;

  const PlaylistFingerprint({
    required this.artistWeight,
    required this.topArtists,
    required this.medianYear,
    required this.dominatedBySingleAlbum,
    required this.mostlyExplicit,
    required this.trackCount,
    required this.playlistWeight,
    required this.confidence,
  });
}

/// What this playlist actually is, derived from every track in it (not just the
/// first few in list order, which would change with the sort).
PlaylistFingerprint fingerprintPlaylist(List<Song> tracks) {
  final artistWeight = <String, double>{};
  final albumCount = <String, int>{};
  final years = <int>[];
  var explicitCount = 0;

  for (var i = 0; i < tracks.length; i++) {
    final s = tracks[i];
    if (s.artist.trim().isEmpty) continue;

    // Every credited artist counts, not just the primary. A playlist full of
    // features is characterised by the collaborators too, and `artist` alone
    // throws that away.
    final credited = <String>{
      s.artist,
      ...s.artists.map((a) => a.name).where((n) => n.trim().isNotEmpty),
    };
    // Recency bias: tracks added most recently describe where the playlist is
    // GOING, which is what a suggestion should extend. Oldest entries still
    // count, at about half the weight.
    final recency = 0.5 + 0.5 * (i / math.max(1, tracks.length - 1));
    for (final name in credited) {
      // Secondary credits count less than the lead.
      final w = name == s.artist ? recency : recency * 0.45;
      artistWeight[name] = (artistWeight[name] ?? 0) + w;
    }

    if (s.albumTitle.trim().isNotEmpty) {
      albumCount[s.albumTitle] = (albumCount[s.albumTitle] ?? 0) + 1;
    }
    final year = int.tryParse(
        RegExp(r'(19|20)\d{2}').firstMatch(s.releaseDate)?.group(0) ?? '');
    if (year != null) years.add(year);
    if (s.isExplicit == true) explicitCount++;
  }

  final ranked = artistWeight.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // How much this playlist should be trusted over general taste. Not a fixed ratio:
  // confidence in a playlist's own signal grows with the evidence it provides. Two
  // inputs:
  //
  //  • Evidence: the number of tracks, on a saturating curve (5 → 15 tracks tells
  //    far more than 50 → 60).
  //
  //  • Coherence: how concentrated the artist distribution is (top-3 share). 40
  //    tracks over 38 artists is a shelf; 40 over 6 is a statement.
  //    This is a proxy: a coherent but artist-diverse playlist (one genre, forty
  //    artists) is under-rated, which fails safe by leaning on global taste.
  final n = tracks.length;
  final evidence = n / (n + 12.0); // 10→0.45, 25→0.68, 60→0.83
  final totalWeight =
      artistWeight.values.fold<double>(0, (a, b) => a + b);
  final top3 = ranked.take(3).fold<double>(0, (a, e) => a + e.value);
  final coherence =
      totalWeight <= 0 ? 0.0 : (top3 / totalWeight).clamp(0.0, 1.0);
  final confidence =
      (evidence * 0.55 + coherence * 0.45).clamp(0.0, 1.0);
  // Never below 0.45: even a thin playlist is the thing the user is looking at,
  // so it always outweighs or matches general taste. Never above 0.95: keeping a
  // sliver of taste in the mix is what stops a tight playlist from only ever
  // suggesting the same three adjacent artists.
  final playlistWeight = 0.45 + 0.50 * confidence;

  years.sort();
  return PlaylistFingerprint(
    playlistWeight: playlistWeight,
    confidence: confidence,
    artistWeight: artistWeight,
    topArtists: ranked.map((e) => e.key).toList(),
    // Median year, not mean: one 1972 track in a playlist of 2023 releases
    // should not drag the whole profile back fifty years.
    medianYear: years.isEmpty ? null : years[years.length ~/ 2],
    // A playlist that is entirely one album is a listening context, not a
    // taste profile — suggestions should reach outside it.
    dominatedBySingleAlbum: albumCount.isNotEmpty &&
        albumCount.values.reduce(math.max) >= tracks.length * 0.7,
    mostlyExplicit: tracks.isNotEmpty && explicitCount > tracks.length * 0.5,
    trackCount: tracks.length,
  );
}

/// A signature that survives the same song appearing under different ids, so a
/// track already in the playlist isn't suggested again from another source.
String suggestionSig(Song s) =>
    '${s.title.toLowerCase().trim()}|${s.artist.toLowerCase().trim()}';

/// Up to [limit] songs that belong with [existing], best first (with some variety
/// from [seed]: a different seed gives a different selection). Never returns a
/// song already in [existing] (by id or by title and artist) or in [exclude];
/// songs in [avoid] are passed over while enough others remain.
Future<List<Song>> suggestTracksForPlaylist({
  required SearchService search,
  required IntelligenceNotifier intel,
  required List<Song> existing,
  required int seed,
  Set<String> exclude = const {},
  Set<String> avoid = const {},
  int limit = 15,
}) async {

  if (existing.isEmpty) return <Song>[];
  final fp = fingerprintPlaylist(existing);

  // Seeds. Refresh variety comes from here: each refresh takes a different window
  // over the playlist's artists (plus complements of a different subset), so the
  // queries, and therefore the candidates, differ. Reshuffling the same queries
  // would return the same answers.
  final ranked = fp.topArtists;
  final window = math.max(1, math.min(8, ranked.length));
  final offset = ranked.isEmpty ? 0 : (seed * 2) % ranked.length;
  List<String> rotate(List<String> xs, int by) =>
      xs.isEmpty ? xs : [...xs.skip(by), ...xs.take(by)];

  final rotated = rotate(ranked.take(window).toList(), offset % window);
  final seedArtists = <String>[
    // The playlist's own artists, from a moving window.
    ...rotated.take(3),
    // Complements of a DIFFERENT slice each time. These are where new music
    // actually comes from — searching an artist already in the playlist
    // mostly returns tracks you either have or deliberately skipped.
    for (final a in rotate(rotated, 1).take(3))
      ...intel.getComplementaryArtists(a, limit: 2),
  ];
  // An all-one-album playlist has almost no internal variety to learn from,
  // so lean harder on complements than on its own single artist.
  final queries = (fp.dominatedBySingleAlbum
          ? seedArtists.reversed.toList()
          : seedArtists)
      .toSet()
      .take(7)
      .toList();

  // Seeded from the tracks themselves, not just artist names. Artist text searches
  // mostly return that artist's popular catalogue; `getSongRadio` asks YouTube what
  // goes with an actual track in the playlist, which is what makes a suggestion
  // belong here. Which tracks are used rotates with the refresh seed. Ids that can't
  // have a radio (local imports, podcasts, live streams) are skipped.
  final radioSeeds = existing
      .where((s) => s.id.length == 11 && !s.id.startsWith('http'))
      .toList();
  final chosenSeeds = <Song>[];
  if (radioSeeds.isNotEmpty) {
    for (var i = 0; i < math.min(3, radioSeeds.length); i++) {
      chosenSeeds.add(radioSeeds[(seed * 3 + i) % radioSeeds.length]);
    }
  }

  final candidates = <Song>[];
  // Tracked separately so scoring can prefer them: a catalogue-certified
  // neighbour of a track in this playlist is better evidence than a name match.
  final radioIds = <String>{};

  // All searches run concurrently, with the radio calls in the same wave.
  final results = await Future.wait([
    ...chosenSeeds.map((s) async {
      try {
        return (radio: true, songs: await search.getSongRadio(s.id));
      } catch (_) {
        return (radio: true, songs: <Song>[]);
      }
    }),
    ...queries.map((q) async {
      try {
        return (radio: false, songs: await search.search(q, 'track'));
      } catch (_) {
        return (radio: false, songs: <Song>[]);
      }
    }),
  ], eagerError: false);
  for (final r in results) {
    candidates.addAll(r.songs);
    if (r.radio) radioIds.addAll(r.songs.map((s) => s.id));
  }

  // Exclude what's already here
  final haveIds = existing.map((e) => e.id).toSet();
  final haveSigs = existing.map(suggestionSig).toSet();
  final seen = <String>{};
  candidates.removeWhere((c) {
    final sig = suggestionSig(c);
    if (haveIds.contains(c.id) || haveSigs.contains(sig)) return true;
    if (exclude.contains(c.id)) return true;
    // Also de-dupe the candidate pool against ITSELF: overlapping artist
    // searches return the same popular tracks repeatedly.
    return !seen.add(sig);
  });

  // Also avoid what the last refresh showed (as a preference, not a filter), so the
  // strongest few candidates don't survive every refresh. If avoiding them would
  // leave too little, they come back.
  if (avoid.isNotEmpty) {
    final fresh =
        candidates.where((c) => !avoid.contains(c.id)).toList();
    if (fresh.length >= 10) {
      candidates
        ..clear()
        ..addAll(fresh);
    }
  }

  // Score against the playlist first, then against global taste, so a focused
  // playlist gets suggestions that match its own character.
  final maxWeight = fp.artistWeight.values.isEmpty
      ? 1.0
      : fp.artistWeight.values.reduce(math.max);
  // Blend, scaled by how much this playlist tells us. Both halves are normalised to
  // 0..1 before mixing, so the ratio means something. The weights come from the
  // fingerprint (see `_fingerprint`): a 5-track scratch list lands near 0.55
  // playlist / 0.45 taste, a 60-track playlist around a few artists near 0.92 /
  // 0.08.
  final double kPlaylistWeight = fp.playlistWeight;
  final double kTasteWeight = fp.tasteWeight;

  // Global taste is rescaled against the best candidate in this set, so even a set
  // of mediocre candidates gets a usable order. The clamp below keeps a negative
  // score (a track the model dislikes) at 0.
  final rawTaste = {for (final s in candidates) s.id: intel.getSongScore(s)};
  final maxTaste = rawTaste.values.isEmpty
      ? 1.0
      : math.max(1e-6, rawTaste.values.reduce(math.max));

  final scored = candidates.map((s) {
    // Playlist component (80%)
    // How much this artist already defines the playlist.
    final familiarity = (fp.artistWeight[s.artist] ?? 0) / maxWeight;
    // Peaks at partial familiarity: an artist adjacent to the playlist beats
    // both a stranger and one already all over it.
    final fit = (1.0 - (familiarity - 0.35).abs() * 1.4).clamp(0.0, 1.0);
    // Era agreement, softened so it nudges rather than filters.
    double era = 0.5; // neutral when either side has no date
    final y = int.tryParse(
        RegExp(r'(19|20)\d{2}').firstMatch(s.releaseDate)?.group(0) ?? '');
    if (fp.medianYear != null && y != null) {
      era = 1.0 - ((y - fp.medianYear!).abs() / 25).clamp(0.0, 1.0);
    }
    final explicitFit =
        (s.isExplicit == true) == fp.mostlyExplicit ? 1.0 : 0.0;
    // Weighted inside the playlist half: artist fit is what "sounds like this
    // playlist" mostly means; era and explicitness are supporting evidence.
    var playlistScore =
        (fit * 0.65 + era * 0.25 + explicitFit * 0.10).clamp(0.0, 1.0);

    // A track YouTube puts next to a recording in this playlist is the strongest
    // "belongs here" signal, which the artist-fit curve can't see. Lift its score
    // toward 1.0 (not a flat bonus), so weak-but-adjacent candidates move up without
    // flattening the top.
    if (radioIds.contains(s.id)) {
      playlistScore = (playlistScore + (1.0 - playlistScore) * 0.45)
          .clamp(0.0, 1.0);
    }

    // Taste component (20%)
    // Popularity lives here, not in the playlist half: a track being widely
    // liked says nothing about whether it belongs in THIS playlist.
    final taste = ((rawTaste[s.id] ?? 0) / maxTaste).clamp(0.0, 1.0);
    final tasteScore =
        (taste * 0.75 + (s.popularity / 100.0).clamp(0.0, 1.0) * 0.25);

    return (
      song: s,
      score: playlistScore * kPlaylistWeight + tasteScore * kTasteWeight,
    );
  }).toList();
  scored.sort((a, b) => b.score.compareTo(a.score));

  // Shuffle only the top slice, so refreshing gives variety without ever
  // surfacing the genuinely poor matches at the tail.
  final pool = scored.take(45).toList();
  pool.shuffle(math.Random(seed));

  // Diversity pass: one per artist for the first 8, two after, so the five visible
  // rows aren't dominated by two artists.
  final out = <Song>[];
  final perArtist = <String, int>{};
  for (final item in pool) {
    if (out.length >= limit) break;
    final n = perArtist[item.song.artist] ?? 0;
    final cap = out.length < 8 ? 1 : 2;
    if (n >= cap) continue;
    out.add(item.song);
    perArtist[item.song.artist] = n + 1;
  }

  return out;
}
