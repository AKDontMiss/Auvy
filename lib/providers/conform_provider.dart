import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/artwork_override_provider.dart';

/// What is known about one row's video→audio conform.
///
/// Three-plus-one states, and the distinctions all earn their keep:
///  • entry ABSENT — never looked up, or looked up and still in flight inside the
///    grace window. The row's video thumbnail is SUPPRESSED (see
///    [conformedForDisplay]).
///  • [revealOriginal] — still in flight, but slow enough that waiting costs more
///    than the flicker. Show the original thumbnail now; swap when it lands.
///  • [settled] with [audio] — resolved; paint the audio cover and clean title.
///  • [settled] without [audio] — resolved, there IS no audio equivalent. Keep
///    the original forever. Distinct from "pending" or a blank tile would be
///    permanent.
class ConformEntry {
  final Song? audio;
  final bool settled;
  final bool revealOriginal;

  const ConformEntry({this.audio, this.settled = false, this.revealOriginal = false});

  // Value equality so `select` only rebuilds a row when its OWN entry really
  // changed. Compared by id — Song identity is what matters here, not instance.
  @override
  bool operator ==(Object other) =>
      other is ConformEntry &&
      other.audio?.id == audio?.id &&
      other.settled == settled &&
      other.revealOriginal == revealOriginal;

  @override
  int get hashCode => Object.hash(audio?.id, settled, revealOriginal);
}

/// Progressive, lazy video→audio conform for LIST DISPLAY.
///
/// When audio-only mode is on (the default), a music VIDEO row that YouTube put
/// in a playlist/album/search/home shelf carries a 16:9 video still and the
/// YouTube video title. This overlay resolves each such row to its real AUDIO
/// track (square album cover + clean title) in the background and updates the
/// tile in place — Spotify-style, so lists show audio artwork "from the start"
/// instead of only when a track is played.
///
/// Cost discipline (the user cares about data): a row is looked up ONLY when it
/// is actually rendered on screen (call [conformedForDisplay] from a tile's
/// build → `ListView.builder` only builds visible/near tiles), AT MOST ONCE
/// ever (memoized in [SearchService.conformToAudioCached]), and the result is
/// SHARED with the play-time swap, so scrolling then playing a track never
/// spends a second lookup. A conform is a tiny metadata search (KB), not an
/// audio download.
///
/// This overlay changes only the DISPLAYED cover/title. Playback still targets
/// the original row; the existing (now cache-backed) play-time conform performs
/// the actual audio swap across the queue, so queue/dedup logic is untouched.
class ConformNotifier extends StateNotifier<Map<String, ConformEntry>> {
  ConformNotifier(this._service) : super(const {});
  final SearchService _service;

  final Set<String> _seen = {}; // ids already requested (dedupe / no-retry)
  final List<Song> _queue = []; // waiting for a free lookup slot
  int _active = 0;
  static const int _maxConcurrent = 4; // keep bursts of searches modest

  /// How long a row may show NOTHING while its conform resolves.
  ///
  /// THIS BOUND IS THE WHOLE POINT. Suppressing the video thumbnail avoids
  /// downloading a cover that is about to be replaced, and avoids the visible
  /// swap, but suppressing it UNCONDITIONALLY made big playlists worse than the
  /// flicker ever was: every video row queues a lookup, only [_maxConcurrent] run
  /// at a time, so rows deep in a long list waited seconds showing a blank tile.
  ///
  /// Past this window the original thumbnail is revealed and the conform keeps
  /// running; when it lands the cover still swaps. Fast and cached conforms
  /// (the common case once a list has been seen) finish well inside it, so they
  /// keep the no-double-download, no-flicker behaviour.
  static const Duration _thumbGrace = Duration(milliseconds: 450);

  /// When each in-flight row was requested — drives the grace sweep.
  final Map<String, DateTime> _requestedAt = {};

  /// ONE ticker for all pending rows rather than a timer each: a long list would
  /// otherwise create (and have to cancel) hundreds of timers.
  Timer? _graceTicker;

  /// Whether [song] is a row this notifier intends to replace with its audio
  /// equivalent. Mirrors the guards in [ensure] and lets the display helper
  /// decide — BEFORE any lookup finishes — that fetching the video still would
  /// be wasted bandwidth.
  static bool willConform(Song song) {
    if (SearchService.processVideos) return false;
    final id = song.id;
    if (id.isEmpty || id.startsWith('http')) return false;
    return _looksLikeVideo(song);
  }

  /// Request a one-time background conform for [song] if it looks like a video
  /// row and audio-only mode is on. Safe to call every build — it no-ops once a
  /// row has been requested. Never mutates state synchronously (the result is
  /// applied later from an async callback), so it is safe to call during build.
  void ensure(Song song, {bool visible = true}) {
    if (SearchService.processVideos) return; // videos allowed → keep as-is
    final id = song.id;
    if (id.isEmpty || id.startsWith('http')) return; // radio / local / podcast
    if (!_looksLikeVideo(song)) return;

    // Already requested. If it was only PREFETCHED and is now on screen, start
    // its grace clock and move it to the front — without this a warmed row that
    // had not resolved yet would sit blank with no bound, because the sweep only
    // considers rows in [_requestedAt].
    if (_seen.contains(id) || state.containsKey(id)) {
      if (visible &&
          state[id]?.settled != true &&
          !_requestedAt.containsKey(id)) {
        _requestedAt[id] = DateTime.now();
        _promote(id);
        _startGraceTicker();
      }
      return;
    }

    _seen.add(id);
    if (_seen.length > 2000) _seen.clear(); // bound; re-lookups are cache-cheap
    // THE GRACE CLOCK IS ONLY FOR ROWS ON SCREEN. Starting it for a prefetched
    // row would expire while it is off screen, so by the time it scrolled into
    // view the entry already said "reveal the original" — the video thumbnail
    // would appear and then swap, which is the exact flicker the prefetch exists
    // to remove.
    if (visible) _requestedAt[id] = DateTime.now();
    _queue.add(song);
    if (visible) _startGraceTicker();
    _pump();
  }

  /// Moves [id] to the back of the list, which [_pump] takes FIRST.
  void _promote(String id) {
    final i = _queue.indexWhere((s) => s.id == id);
    if (i < 0 || i == _queue.length - 1) return;
    _queue.add(_queue.removeAt(i));
  }



  void _startGraceTicker() {
    if (_graceTicker != null) return;
    _graceTicker = Timer.periodic(const Duration(milliseconds: 150), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_requestedAt.isEmpty) {
        t.cancel();
        _graceTicker = null;
        return;
      }
      final now = DateTime.now();
      final due = _requestedAt.entries
          .where((e) => now.difference(e.value) >= _thumbGrace)
          .map((e) => e.key)
          .toList();
      if (due.isEmpty) return;
      final next = {...state};
      for (final id in due) {
        _requestedAt.remove(id);
        // Only if it hasn't already settled in the meantime.
        if (next[id]?.settled == true) continue;
        next[id] = const ConformEntry(revealOriginal: true);
      }
      state = next;
    });
  }

  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      // NEWEST first. Rows are requested as they scroll into view, so the most
      // recent request is the one the user is looking at; FIFO made a long
      // backlog of scrolled-past rows resolve ahead of the visible ones.
      final song = _queue.removeLast();
      _active++;
      _service
          .conformToAudioCached(song, strict: !song.isMusicVideo)
          .then((audio) {
        _active--;
        _requestedAt.remove(song.id);
        if (mounted) {
          // Record the OUTCOME either way. A null (no audio equivalent, or the
          // lookup echoed the same id back) is a real answer: it tells the tile
          // to keep the original instead of waiting forever.
          // Keep the row describing the release the user is looking at; only the
          // playable id changes. See SearchService.mergeConformedAudio.
          final resolved = (audio != null && audio.id != song.id)
              ? SearchService.mergeConformedAudio(song, audio)
              : null;
          state = {...state, song.id: ConformEntry(audio: resolved, settled: true)};
        }
        _pump();
      }).catchError((_) {
        _active--;
        _requestedAt.remove(song.id);
        // A THROWN lookup is also terminal — same no-retry policy as _seen.
        if (mounted) {
          state = {...state, song.id: const ConformEntry(settled: true)};
        }
        _pump();
      });
    }
  }

  @override
  void dispose() {
    _graceTicker?.cancel();
    super.dispose();
  }

  /// A row needs conform when it's a confirmed music video, OR when it still
  /// carries a 16:9 `i.ytimg.com/vi/...` still (catches deluxe/compilation OMV
  /// rows that arrive with an EMPTY musicVideoType). Audio tracks use square
  /// `googleusercontent` art and are left alone.
  // Delegates to Song.looksLikeVideo. See the note there for why this stopped
  // being its own copy of the test.
  static bool _looksLikeVideo(Song s) => s.looksLikeVideo;
}

final conformProvider =
    StateNotifierProvider<ConformNotifier, Map<String, ConformEntry>>((ref) {
  return ConformNotifier(ref.read(searchServiceProvider));
});

/// Return the version of [song] to DISPLAY (audio cover + clean title once
/// resolved), and kick off a one-time background lookup for video rows. Call at
/// the top of a song tile's `build`. Falls back to [song] until (or unless) an
/// audio equivalent is found. Use the result for the tile's artwork/title only;
/// keep using the original [song] for tap-to-play so queue logic is unchanged.
Song conformedForDisplay(WidgetRef ref, Song song) {
  // ConformEntry has value equality, so this rebuilds the row only when its own
  // entry actually changes.
  final entry = ref.watch(conformProvider.select((m) => m[song.id]));
  if (entry == null) {
    ref.read(conformProvider.notifier).ensure(song);
  }
  Song resolved = entry?.audio ?? song;

  // Don't pay for a cover we already know we're going to throw away
  // A video row's 16:9 `ytimg.com/vi/...` still is guaranteed to be replaced by
  // the square audio cover once the conform lands. Rendering it meanwhile costs a
  // full image download per row AND produces a visible flicker as every tile
  // swaps art live. Blanking the path makes AuvyImage draw its placeholder — no
  // request at all, and the placeholder then CROSSFADES into the real cover.
  //
  // Suppressed only while the lookup is INSIDE its grace window: a settled entry
  // has its answer, and a `revealOriginal` entry has been waiting too long to
  // keep the tile empty. See ConformNotifier._thumbGrace.
  final suppressThumb = entry == null && ConformNotifier.willConform(song);
  if (suppressThumb) {
    resolved = resolved.copyWith(image: '');
  }

  // A user-chosen cover OUTRANKS everything above it — that is the entire point
  // of setting one. Applied here because this function is the single funnel every
  // list tile already goes through, so one hook covers the whole app's lists.
  // (The player and mini-player read the playing song directly; they call
  // [overriddenArtwork] for the same reason.)
  final override =
      ref.watch(artworkOverrideProvider.select((m) => m[song.id]));
  if (override == null) return resolved;
  return resolved.copyWith(image: override);
}

/// Conforms the next few rows past the one being built.
///
/// A LOOKAHEAD, NOT A BULK PREFETCH. Warming a whole list was the first
/// attempt and it was the wrong trade: each conform is a search, so opening a
/// 60-row playlist fired up to 60 requests at once where the old build-time
/// behaviour fired about eight. Following the viewport instead means requests
/// track what the user is actually approaching — a handful ahead of the scroll,
/// and nothing at all for a list they never scroll through.
///
/// Six rows is roughly a screen beyond the fold, which is enough that a row has
/// settled before it is reached, so its audio cover is there on the first frame
/// instead of swapping in view.
void warmAhead(WidgetRef ref, List<Song> songs, int index, {int ahead = 6}) {
  if (songs.isEmpty) return;
  final notifier = ref.read(conformProvider.notifier);
  final end = (index + 1 + ahead).clamp(0, songs.length);
  for (var i = index + 1; i < end; i++) {
    notifier.ensure(songs[i], visible: false);
  }
}

/// The cover to actually paint for [song], honouring a user override.
///
/// For the surfaces that show the CURRENT track rather than a list row (player
/// artwork, mini-player), which read `playerProvider` and never pass through
/// [conformedForDisplay].
String overriddenArtwork(WidgetRef ref, Song song) =>
    ref.watch(artworkOverrideProvider.select((m) => m[song.id])) ?? song.image;
