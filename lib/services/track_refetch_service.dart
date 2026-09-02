import 'dart:io' show File;

import 'package:flutter/widgets.dart' show NetworkImage, FileImage;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/track_refetch.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart' show auvyImageForgetFile;
import 'package:auvy/providers/artwork_override_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/services/lyrics_service.dart';
import 'package:auvy/services/search_service.dart';

/// What a refetch did, for the toast.
class TrackRefetchOutcome {
  /// What changed about the track itself (cover, title, album…).
  final RefetchDelta delta;

  /// Lyrics were re-fetched and something came back.
  final bool lyrics;

  /// A manually-pinned cover is in force, so the refreshed artwork is stored but
  /// not what the user sees. Worth saying, or a refetch looks broken.
  final bool coverOverridden;

  /// Nothing plausible came back from the catalogue at all.
  final bool notFound;

  const TrackRefetchOutcome({
    this.delta = const RefetchDelta(),
    this.lyrics = false,
    this.coverOverridden = false,
    this.notFound = false,
  });

  /// One line, honest about which of the two halves actually moved.
  String get message {
    final parts = <String>[];
    if (delta.any) parts.add('Updated ${delta.summary}');
    if (lyrics) parts.add(parts.isEmpty ? 'Lyrics refetched' : 'lyrics');
    if (parts.isEmpty) {
      return notFound
          ? 'Nothing new found for this track'
          : 'Already up to date';
    }
    var msg = parts.join(' · ');
    if (coverOverridden && delta.cover) {
      msg += ' — your pinned cover is still in use';
    }
    return msg;
  }
}

/// "Refetch track details" — re-resolve EVERYTHING about one track.
///
/// WHY A BUTTON, AND NOT BETTER AUTOMATIC MATCHING. Auvy resolves a track's
/// cover, title, artist, album and lyrics from a catalogue that is genuinely
/// ambiguous: the same song exists as a music video with a 16:9 still, as a
/// remaster, as a topic-channel upload with the artist in the title, and on four
/// lyrics services with different ideas of which recording it is. The matching has
/// been tightened repeatedly and still lands wrong sometimes. Past a point, the
/// honest answer is not another heuristic — it is a way to say "that's wrong, go
/// and look again", which is what this is.
///
/// IT MUST DEFEAT EVERY CACHE, OR IT DOES NOTHING VISIBLE. This is the part
/// that is easy to get wrong. The answer a refetch is trying to escape is memoized
/// in at least five places, each of which would happily replay it:
///   • `SearchService._conformCache` — a video is conformed AT MOST ONCE, ever,
///     `null` results included.
///   • `LyricsService` — RAM cache, a failed-lookup memo, and an on-disk copy.
///   • Flutter's own `ImageCache` and `AuvyImage`'s file-existence memo — keyed by
///     URL/path, so re-using a URL shows the old bytes.
///   • The library's persisted Song copies, which would restore the old values on
///     the next launch.
/// Each is explicitly evicted below.
class TrackRefetchService {
  /// Re-resolve [song] and write the result back into the player and the library.
  ///
  /// Returns what changed. Never throws: a refetch failing is a "nothing found",
  /// not an error dialog.
  static Future<TrackRefetchOutcome> refetch(WidgetRef ref, Song song) async {
    // Live radio has no catalogue entry, no lyrics and no album — there is nothing
    // to refetch, and searching for the station name would return music.
    final isLiveRadio = song.id.startsWith('http') && song.albumTitle != 'Podcast';
    if (isLiveRadio) return const TrackRefetchOutcome(notFound: true);

    final search = ref.read(searchServiceProvider);

    // 1. Drop every cached answer for this track
    SearchService.forgetConform(song.id);
    await LyricsService()
        .clearCacheForSong(song.id, title: song.title, artist: song.artist);
    _evictImage(song.image);

    // 2. Re-resolve metadata + cover
    Song? candidate;

    // The conform is the strongest signal available and the one that fixes the
    // common complaint: a music-video row wearing a letterboxed still where its
    // studio audio has a proper square sleeve.
    if (song.id.length == 11) {
      try {
        candidate = await search
            .conformToAudioCached(song)
            .timeout(const Duration(seconds: 12));
      } catch (_) {}
    }

    // No conform (or not a video id) → search the catalogue with the title
    // stripped of YouTube's video furniture, and accept only a plausible match.
    if (candidate == null) {
      try {
        final results = await search
            .search(refetchQuery(song), 'track')
            .timeout(const Duration(seconds: 12));
        for (final r in results.take(8)) {
          if (isPlausibleRefetch(song, r)) {
            candidate = r;
            break;
          }
        }
      } catch (_) {}
    }

    // Even with a candidate, upgrade the artwork URL to the largest size the CDN
    // will serve — a correct cover at thumbnail resolution still looks wrong on a
    // full-screen player.
    var fresh = song;
    if (candidate != null) {
      final upgraded = candidate.image.isEmpty
          ? candidate
          : candidate.copyWith(image: search.getHighResImage(candidate.image));
      fresh = mergeRefetched(song, upgraded);
    } else if (song.image.isNotEmpty) {
      // Nothing new to merge, but the existing cover may still be pinned at a
      // small size — this alone fixes a blurry player background.
      fresh = song.copyWith(image: search.getHighResImage(song.image));
    }

    final delta = describeRefetch(song, fresh);

    // 3. Apply it everywhere a copy is kept
    if (delta.any) {
      _evictImage(fresh.image);
      ref.read(playerProvider.notifier).applyRefreshedMetadata(fresh);
      ref.read(libraryProvider.notifier).replaceSongEverywhere(fresh);
    }

    // 4. Lyrics, last
    // After the metadata, deliberately: the scan matches on title/artist/duration,
    // so a corrected title is the difference between finding the right lyrics and
    // finding the same wrong ones again. `forceRefresh` also rotates to a
    // DIFFERENT source than last time, which is the whole point when the lyrics
    // that came back were for another song.
    var lyricsFound = false;
    if (fresh.albumTitle != 'Podcast') {
      try {
        final data = await LyricsService()
            .getLyrics(
              fresh.title,
              fresh.artist,
              album: fresh.albumTitle,
              songId: fresh.id,
              forceRefresh: true,
              trackDurationMs: _durationMs(fresh),
            )
            .timeout(const Duration(seconds: 20));
        lyricsFound = data != null &&
            (data.lines.isNotEmpty || data.plainLyrics.trim().isNotEmpty);
      } catch (_) {}
    }

    final overridden = ref.read(artworkOverrideProvider).containsKey(fresh.id);
    return TrackRefetchOutcome(
      delta: delta,
      lyrics: lyricsFound,
      coverOverridden: overridden,
      notFound: candidate == null && !delta.any,
    );
  }

  /// Forget [url] in every image cache that could replay the old bytes.
  ///
  /// Flutter's ImageCache keys on the provider, and a refetch frequently returns
  /// the SAME url with a different size suffix — or genuinely the same url whose
  /// remote content changed. Without eviction the stale decoded image is reused
  /// and the refetch appears to have done nothing.
  static void _evictImage(String url) {
    if (url.isEmpty) return;
    try {
      if (url.startsWith('http')) {
        NetworkImage(url).evict();
      } else {
        FileImage(File(url)).evict();
        auvyImageForgetFile(url);
      }
      PaintingBinding.instance.imageCache.evict(url);
    } catch (_) {}
  }

  /// Track length in ms, parsed from the "3:45" display string. Sharpens the
  /// lyrics match to the right VERSION of a song (single vs extended vs live).
  static int? _durationMs(Song song) {
    final parts = song.duration.split(':');
    if (parts.length < 2) return null;
    final mins = int.tryParse(parts[parts.length - 2]);
    final secs = int.tryParse(parts.last);
    if (mins == null || secs == null) return null;
    var total = mins * 60 + secs;
    if (parts.length == 3) {
      final hours = int.tryParse(parts.first);
      if (hours != null) total += hours * 3600;
    }
    return total <= 0 ? null : total * 1000;
  }
}
